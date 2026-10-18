//
// File:     Waypoint/UI/Navigator/LocalizingView.swift
// Owner:    U3 (UI flows)
// Purpose:  N4, shown from Start guidance until the user's position is found (branch final-ui-changes, 2026-10-18):
//             * "Getting ready" while the pre-navigation instructions are spoken (NavigatorModel.isBriefing);
//             * then "Finding your position". Nothing pulls the user forward, and there is NO help screen: the
//               search simply continues. Every 15 s without a position, `NavigatorModel.strugglingMessage` is
//               spoken (move slightly, stand still, turn slowly; how to stop), until found or stopped.
//             * The whole screen is hold-to-stop (HoldToStopSurface); it is the only control.
//           With Settings > Show debugging tools, a small Escort button (test tools) appears above it.
// Status:   SCAFFOLD, UNVERIFIED ON DEVICE.
//
import SwiftUI
import WaypointCore

struct LocalizingView: View {
    @ObservedObject var model: NavigatorModel
    let onStop: () -> Void

    /// Seconds without a position before the "struggling" message, and between repeats.
    static let strugglingInterval: UInt64 = 15

    @State private var showEscort = false
    @AccessibilityFocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(UIPrefs.debugTools) private var debugTools = false

    private var title: String { model.isBriefing ? "Getting ready" : "Finding your position" }
    private var detail: String {
        model.isBriefing
            ? "Hold the phone upright at chest level, back camera facing forward."
            : "Stand still, then slowly turn left and right."
    }

    var body: some View {
        VStack(spacing: Theme.Space.m) {
            if debugTools {
                HStack {
                    Spacer()
                    Button("Escort") { showEscort = true }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.Nav.secondaryText)
                        .padding(.horizontal, Theme.Space.m)
                        .padding(.vertical, Theme.Space.s)
                        .background(Theme.Nav.surface, in: Capsule())
                        .accessibilityHidden(true) // test tools for a sighted helper
                }
            }

            HoldToStopSurface(accessibilityText: "\(title). \(detail)", onStop: onStop) {
                VStack(spacing: Theme.Space.xl) {
                    Spacer(minLength: 0)
                    Image(systemName: model.isBriefing ? "iphone" : "location.circle.fill")
                        .font(.system(size: 96, weight: .semibold))
                        .foregroundStyle(Theme.Nav.primary)
                        .symbolEffect(.pulse, isActive: !model.isBriefing && !reduceMotion)
                    VStack(spacing: Theme.Space.s) {
                        Text(title)
                            .font(.largeTitle.weight(.bold))
                            .fontDesign(.rounded)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(Theme.Nav.text)
                        Text(detail)
                            .font(.title3)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(Theme.Nav.secondaryText)
                    }
                    .padding(.horizontal, Theme.Space.l)
                    Spacer(minLength: 0)
                    HoldToStopHint()
                }
                .background(Theme.Nav.surface)
            }
            .accessibilityAddTraits(.isHeader)
            .accessibilityFocused($focused)
        }
        .padding(Theme.Space.l)
        .sheet(isPresented: $showEscort) { EscortPanel(model: model) }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { focused = true }
        }
        // Restarts when the briefing ends, so the first reminder comes 15 s after the search actually began.
        .task(id: model.isBriefing) {
            guard !model.isBriefing else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.strugglingInterval * 1_000_000_000)
                guard !Task.isCancelled, model.isActive, !model.isBriefing,
                      model.guidance.phase == .localizing else { return }
                Announcer.say(NavigatorModel.strugglingMessage)
            }
        }
    }
}
