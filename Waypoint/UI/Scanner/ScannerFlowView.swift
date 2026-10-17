//
// File:     Waypoint/UI/Scanner/ScannerFlowView.swift
// Owner:    U3 (UI flows)
// Purpose:  Entry of the NEW Scanner (volunteer) workflow (docs/UI_PLAN.md §6), shown by RootView only when the
//           "New interface" setting is on. Drives the screens with ScanFlow (WaypointCore):
//             library -> setup -> scanning -> review -> share.
//           Lives inside RootView's NavigationStack, so it switches screens in place rather than pushing.
// Status:   SCAFFOLD, UNVERIFIED ON DEVICE.
//
import SwiftUI
import WaypointCore

struct ScannerFlowView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var flow = ScanFlow()
    @State private var session: ScanSessionModel?
    @State private var reviewMap: BuildingMap?

    var body: some View {
        ZStack {
            switch flow.step {
            case .library:
                ScanLibraryView(
                    onNewScan: { flow.newScan() },
                    onExtend: { option, map in
                        flow.newScan()
                        startSession(name: map.name, extending: map, segment: option.segmentId)
                    },
                    onOpen: { map in
                        reviewMap = map
                        flow.openReview()
                    })
            case .setup:
                ScanSetupView(
                    onStart: { name in startSession(name: name) },
                    onBack: { _ = flow.back() })
            case .scanning:
                if let session {
                    LiveScanScreen(
                        model: session,
                        onSaved: { map in
                            app.reloadMaps()
                            reviewMap = map
                            self.session = nil
                            flow.finishScanning()
                        },
                        onDiscard: {
                            session.cancel()
                            self.session = nil
                            flow.discardScan()
                        })
                }
            case .review:
                if let reviewMap {
                    ScanReviewView(
                        map: reviewMap,
                        onShare: { updated in
                            self.reviewMap = updated
                            flow.share()
                        },
                        onDone: { flow.done() })
                }
            case .share:
                if let reviewMap {
                    ScanShareView(map: reviewMap, onBack: { _ = flow.back() }, onDone: { flow.done() })
                }
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: flow.step)
        .onDisappear {
            session?.cancel()
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    private func startSession(name: String, extending map: BuildingMap? = nil, segment: String? = nil) {
        let service = ServiceFactory.makeScanService(mode: ServiceMode.current, store: app.store, deviceName: app.deviceName)
        let model = ScanSessionModel(service: service, mapName: name, extending: map, initialSegment: segment)
        session = model
        flow.startScanning()
        model.start()
    }
}
