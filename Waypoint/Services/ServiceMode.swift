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
    static let visualFingerprints = "ui.visualFingerprints"

    /// Show the sighted debug overlay (camera + computed route) during guidance. Default false.
    static let debugOverlay = "ui.debugOverlay"
    static func recentsKey(mapId: UUID) -> String { "ui.recents.\(mapId.uuidString)" }

    // MARK: Voice and wording of the guidance (2026-10-18)
    /// While VoiceOver is running, say guidance THROUGH VoiceOver (one voice, its queue, its rate) instead of beside it. Default true.
    static let speakViaVoiceOver = "guidance.viaVoiceOver"
    /// Let Gemini reword the non-urgent lines (briefing, landmarks, far countdowns). Default true; only does anything when a key is configured
    /// (`Config/Local.xcconfig`), and every failure falls back to the plain sentence.
    static let richNarration = "guidance.richNarration"
    /// "phone" = the voice this iPhone already uses (default); "app" = the app's own Siri pick. See `VoiceSelection`.
    static let guidanceVoice = "guidance.voice"
    /// The voice picked in Settings (an `AVSpeechSynthesisVoice` identifier), used when `guidanceVoice` is "chosen".
    static let guidanceVoiceId = "guidance.voiceId"
    /// Speaking speed as a factor of the system default (1.0). Ignored while VoiceOver is on: its own rate applies.
    static let speechRate = "guidance.speechRate"
}

extension UIPrefs {
    static var speakViaVoiceOverEnabled: Bool {
        UserDefaults.standard.object(forKey: UIPrefs.speakViaVoiceOver) as? Bool ?? true
    }
    static var richNarrationEnabled: Bool {
        UserDefaults.standard.object(forKey: UIPrefs.richNarration) as? Bool ?? true
    }
    static var guidanceVoiceIdentifier: String? { UserDefaults.standard.string(forKey: UIPrefs.guidanceVoiceId) }
    static var speechRateFactor: Double {
        SpeechRate.clamp(UserDefaults.standard.object(forKey: UIPrefs.speechRate) as? Double ?? SpeechRate.defaultFactor)
    }
    static var guidanceVoiceSource: VoiceSource {
        VoiceSource(rawValue: UserDefaults.standard.string(forKey: UIPrefs.guidanceVoice) ?? "") ?? .phone
    }
    /// Defaults to false: see `visualFingerprints`.
    static var visualFingerprintsEnabled: Bool {
        UserDefaults.standard.bool(forKey: UIPrefs.visualFingerprints)
    }
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

    static var current: ServiceMode {
        ServiceMode(rawValue: UserDefaults.standard.string(forKey: UIPrefs.serviceMode) ?? "") ?? defaultMode
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
