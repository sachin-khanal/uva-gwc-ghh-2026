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
    /// false = classic screens (VolunteerView / NavigatorView), true = new flows. Default false (UI_PLAN R2).
    static let newInterface = "ui.newInterface"
    static let serviceMode = "ui.serviceMode"
    /// Speak screen prompts with the phone's voice when VoiceOver is off. Default true.
    static let spokenPrompts = "ui.spokenPrompts"
    /// Skip the mode picker and open Navigate on launch (for the blind user's own phone).
    static let openInNavigate = "ui.openInNavigate"
    /// One-shot: map id the Navigator should preselect ("Try it in Navigate" from the scanner).
    static let pendingMapId = "ui.pendingMapId"
    static func recentsKey(mapId: UUID) -> String { "ui.recents.\(mapId.uuidString)" }
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

    static var current: ServiceMode {
        ServiceMode(rawValue: UserDefaults.standard.string(forKey: UIPrefs.serviceMode) ?? "") ?? .mock
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
