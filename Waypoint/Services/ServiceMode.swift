//
// File:     Waypoint/Services/ServiceMode.swift
// Owner:    U3 (UI flows)
// Purpose:  Settings for the new interface and the factory that picks which service the new screens talk to
//           (docs/UI_PLAN.md §2):
//             * Mock      - timer-driven fakes, no ARKit/audio; works on every iPhone (default).
//             * Simulated - real NavigationController.startSimulation (real audio/haptics/speech, no scan).
//             * Live      - real CaptureController / NavigationController.
//           The scanner has no "simulated" variant: Simulated uses the mock scanner. Live scanning needs LiDAR;
//           without it the mock scanner is used and the screen says so.
// Status:   SCAFFOLD, UNVERIFIED ON DEVICE.
//
import ARKit
import Foundation
import WaypointCore

/// UserDefaults keys (read with @AppStorage in views). Prefixed so they never clash with other code.
enum UIPrefs {
    /// false = classic screens (VolunteerView / NavigatorView), true = new flows. Default TRUE since 2026-10-18 (was false, UI_PLAN R2); a person can
    /// switch back in Settings, and scripted launches (-autoSimulate, -autoE2E, -autoScan) and the UI tests always use the classic screens.
    static let newInterface = "ui.newInterface"
    static let newInterfaceDefault = true
    static let serviceMode = "ui.serviceMode"
    /// Speak screen prompts with the phone's voice when VoiceOver is off. Default true.
    static let spokenPrompts = "ui.spokenPrompts"
    /// Skip the mode picker and open Navigate on launch (for the blind user's own phone).
    static let openInNavigate = "ui.openInNavigate"
    /// One-shot: map id the Navigator should preselect ("Try it in Navigate" from the scanner).
    static let pendingMapId = "ui.pendingMapId"
    /// Use stored visual fingerprints to recognise the place when relocalizing. Default OFF.
    ///
    /// It makes relocalization much faster, but a keyframe match is a COARSE alignment and everything
    /// downstream - position, route, instructions - is computed through it. Until the distance
    /// threshold has been calibrated on real hardware, the safe default is the behaviour that has been
    /// walked successfully: ARKit's own relocalization only (D-042).
    /// Warn about drops in the floor from the LIDAR (`FloorAhead`). OFF by default, and it is not a
    /// tuning problem: the check compares what it sees against `cameraY - ObstacleBand.assumedPhoneHeight`,
    /// a FIXED 1.3 m guess at how high the phone is held. Hold it at 1.5 m and the assumed floor sits
    /// 0.2 m above the real one, so every ordinary floor sample reads as a step down and a flat corridor
    /// announces "Careful. A step down about 3 steps ahead." (device report 2026-10-18, Rice Hall).
    /// Stairs are announced from the MAP instead - the volunteer tags them, so we know where they are.
    static let floorDropDetection = "ui.floorDropDetection"
    static let visualFingerprints = "ui.visualFingerprints"

    /// Show the sighted debug overlay (camera + computed route) during guidance. Default false.
    static let debugOverlay = "ui.debugOverlay"
    /// Settings > "Show debugging tools". Default OFF. While off, every developer option below falls back to
    /// its safe default and every test tool is hidden (branch final-ui-changes, 2026-10-18):
    ///   * interface = New, data source = Live on a LiDAR iPhone / Demo data otherwise (`ServiceMode.defaultMode`);
    ///   * visual fingerprints, floor-drop detection and the guiding debug overlay = off;
    ///   * hidden: the Escort panel, the demo "Say a destination" button, scanner technical numbers.
    /// Turning it back on restores whatever was chosen before; nothing stored is thrown away.
    static let debugTools = "ui.debugTools"
    static func recentsKey(mapId: UUID) -> String { "ui.recents.\(mapId.uuidString)" }
}

extension UIPrefs {
    static var debugToolsOn: Bool { UserDefaults.standard.bool(forKey: debugTools) }

    /// True when `key` was passed as a launch argument (`-ui.newInterface NO`, as the UI tests and `make` targets
    /// do). An explicit argument always wins over the debugging switch, so scripted runs keep working with it off.
    static func isLaunchArgument(_ key: String) -> Bool {
        UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)[key] != nil
    }

    /// A developer option's stored value, honoured only while debugging tools are on (or when set by launch argument).
    static func developerValue(_ key: String) -> Bool {
        (debugToolsOn || isLaunchArgument(key)) && UserDefaults.standard.bool(forKey: key)
    }

    /// The interface to show: New unless debugging tools (or a launch argument) say otherwise.
    static var newInterfaceEnabled: Bool {
        guard debugToolsOn || isLaunchArgument(newInterface) else { return true }
        return UserDefaults.standard.object(forKey: newInterface) == nil
            ? newInterfaceDefault : UserDefaults.standard.bool(forKey: newInterface)
    }

    /// Defaults to false: see `floorDropDetection`.
    static var floorDropDetectionEnabled: Bool { developerValue(floorDropDetection) }

    /// Defaults to false: see `visualFingerprints`.
    static var visualFingerprintsEnabled: Bool { developerValue(visualFingerprints) }

    static var debugOverlayEnabled: Bool { developerValue(debugOverlay) }
}

enum ServiceMode: String, CaseIterable, Identifiable {
    case mock, simulated, live

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mock: return "Demo data"
        case .simulated: return "Simulated walk"
        case .live: return "Live"
        }
    }

    var detail: String {
        switch self {
        case .mock: return "Screens run on made-up data. Works on any iPhone, no scanning or audio engine."
        case .simulated: return "Navigator uses the real audio, haptics and speech with a virtual walker. Scanner uses demo data."
        case .live: return "Real LiDAR scanning and real positioning. Needs a Pro iPhone and a scanned map."
        }
    }

    /// What a fresh install uses: real scanning and positioning on a LiDAR iPhone (a demo scan there would be a trap for a volunteer), demo data
    /// on a phone that cannot scan (the new screens still run). Anyone can change it in Settings.
    static var defaultMode: ServiceMode { DeviceCapabilities.hasLiDAR ? .live : .mock }

    /// The chosen data source while debugging tools are on (or set by launch argument); otherwise `defaultMode`.
    static var current: ServiceMode {
        guard UIPrefs.debugToolsOn || UIPrefs.isLaunchArgument(UIPrefs.serviceMode) else { return defaultMode }
        return ServiceMode(rawValue: UserDefaults.standard.string(forKey: UIPrefs.serviceMode) ?? "") ?? defaultMode
    }
}

enum DeviceCapabilities {
    /// True on iPhones with LiDAR (scene reconstruction). False on the regular iPhone (U4).
    static var hasLiDAR: Bool { ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) }
}

enum ServiceFactory {

    static func makeScanService(mode: ServiceMode, store: MapStore, deviceName: String) -> ScanService {
        if mode == .live && DeviceCapabilities.hasLiDAR {
            return LiveScanService(store: store, deviceName: deviceName)
        }
        return MockScanService(store: store, deviceName: deviceName)
    }

    static func makeGuidanceService(mode: ServiceMode, store: MapStore) -> GuidanceService {
        switch mode {
        case .mock: return MockGuidanceService()
        case .simulated: return LiveGuidanceService(store: store, simulate: true)
        case .live: return LiveGuidanceService(store: store, simulate: false)
        }
    }
}
