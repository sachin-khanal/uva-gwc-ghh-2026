//
// File:     Waypoint/UI/Navigator/LocalizingView.swift
// Owner:    U3 (UI flows)
// Purpose:  N4 "Finding your position" (and the failure state). Nothing pulls the user forward here.
//             * pulsing location symbol (static with Reduce Motion);
//             * demo mode: a spoken hint every 8 s, at most 3 times (live mode: NavigationController speaks);
//             * after 20 s, or on failure: Try again / Use the start marker (placeholder, ROADMAP U1.7) /
//               Ask your escort - each as a large button;
//             * Stop is hold-to-confirm.
// Status:   SCAFFOLD, UNVERIFIED ON DEVICE.
//
import SwiftUI
import WaypointCore

struct LocalizingView: View {
    @ObservedObject var model: NavigatorModel
    let onRetry: () -> Void
    let onStop: () -> Void

    @State private var showHelp = false
    @AccessibilityFocusState private var headingFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var failureMessage: String? {
        if case .failed(let message) = model.guidance.phase { return message }
        return nil
    }

    var body: some View {
        VStack(spacing: Theme.Space.xl) {
            Spacer(minLength: 0)

            Image(systemName: failureMessage == nil ? "location.circle.fill" : "location.slash.fill")
                .font(.system(size: 96, weight: .semibold))
                .foregroundStyle(failureMessage == nil ? Theme.Nav.primary : Theme.Nav.danger)
                .symbolEffect(.pulse, isActive: failureMessage == nil && !reduceMotion)
                .accessibilityHidden(true)

            VStack(spacing: Theme.Space.s) {
                Text(failureMessage == nil ? "Finding your position" : "Can't find your position")
                    .font(.largeTitle.weight(.bold))
                    .fontDesign(.rounded)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Theme.Nav.text)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityFocused($headingFocused)
                Text(failureMessage ?? "Stand still, then slowly turn left and right.")
                    .font(.title3)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Theme.Nav.secondaryText)
            }

            if failureMessage != nil || showHelp {
                VStack(spacing: Theme.Space.m) {
                    HeroButton(title: "Try again", systemImage: "arrow.clockwise",
                               style: failureMessage != nil ? .navPrimary : .navSecondary, action: onRetry)
                    HeroButton(title: "Use the start marker", systemImage: "qrcode.viewfinder", style: .navSecondary) {
                        Announcer.say("The start marker is not set up yet. Please ask your escort for help.", interrupt: true)
                    }
                    HeroButton(title: "Ask my escort for help", systemImage: "person.wave.2.fill", style: .navSecondary) {
                        Announcer.say("Please ask your escort for help. They can see where you are on the screen.", interrupt: true)
                    }
                }
            }

            Spacer(minLength: 0)

            HoldToConfirmButton(title: "Hold to stop", confirmTitle: "Stop navigation", action: onStop)
        }
        .padding(Theme.Space.l)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { headingFocused = true }
        }
        .task {
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            if !Task.isCancelled && model.guidance.phase == .localizing {
                showHelp = true
                Announcer.say("Still looking. If this takes too long, ask your escort for help.")
            }
        }
        .task {
            guard !model.speaksForItself else { return }
            for _ in 0..<3 {
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                if Task.isCancelled || model.guidance.phase != .localizing { return }
                Announcer.say("Slowly turn left and right.")
            }
        }
        .onChange(of: model.guidance.phase) { _, phase in
            if case .failed(let message) = phase {
                Announcer.say("I can't find your position. \(message) You can try again.", interrupt: true)
            }
        }
    }
}
