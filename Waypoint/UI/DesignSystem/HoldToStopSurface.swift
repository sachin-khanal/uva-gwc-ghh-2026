//
// File:     Waypoint/UI/DesignSystem/HoldToStopSurface.swift
// Owner:    U3 (UI flows)
// Purpose:  While navigating, the WHOLE screen is the stop control (branch final-ui-changes, 2026-10-18): the user
//           presses and holds anywhere for `duration` seconds while a red fill rises; letting go early does nothing,
//           so brushing the screen while walking never ends a route. It is the only control on the guiding and
//           position-finding screens.
// VoiceOver: one element whose label is what the screen shows (the caller passes it). Double tap asks
//           "Stop navigation?" and a second confirmation stops; VoiceOver's double-tap-and-hold also works.
//           Callers may add custom actions (e.g. "Repeat instruction") to the element.
// Status:   DONE, UNVERIFIED ON DEVICE.
//
import SwiftUI

struct HoldToStopSurface<Content: View>: View {
    var duration: Double = 1.0
    /// What VoiceOver reads for the screen (e.g. the current instruction).
    let accessibilityText: String
    let onStop: () -> Void
    @ViewBuilder let content: Content

    @State private var progress: CGFloat = 0
    @State private var confirming = false

    var body: some View {
        ZStack(alignment: .bottom) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            GeometryReader { geo in
                Rectangle()
                    .fill(Theme.Nav.danger.opacity(0.45))
                    .frame(height: geo.size.height * progress)
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.hero, style: .continuous))
        .contentShape(Rectangle())
        .onLongPressGesture(minimumDuration: duration, maximumDistance: 60) {
            progress = 0
            onStop()
        } onPressingChanged: { pressing in
            withAnimation(pressing ? .linear(duration: duration) : .easeOut(duration: 0.2)) {
                progress = pressing ? 1 : 0
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint("To stop navigation, double tap, then confirm.")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { confirming = true }
        .confirmationDialog("Stop navigation?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Stop navigation", role: .destructive, action: onStop)
            Button("Keep going", role: .cancel) {}
        }
    }
}

/// The line at the bottom of the navigating screens that says how to stop.
struct HoldToStopHint: View {
    var body: some View {
        Label("Press and hold anywhere to stop", systemImage: "hand.raised.fill")
            .font(.headline)
            .foregroundStyle(Theme.Nav.secondaryText)
            .padding(.bottom, Theme.Space.l)
            .accessibilityHidden(true) // the surface's VoiceOver hint says it
    }
}

struct HoldToStopSurface_Previews: PreviewProvider {
    static var previews: some View {
        HoldToStopSurface(accessibilityText: "Turn right.", onStop: {}) {
            VStack {
                Spacer()
                Text("Turn right").font(.largeTitle.bold()).foregroundStyle(.white)
                Spacer()
                HoldToStopHint()
            }
            .background(Theme.Nav.surface)
        }
        .padding()
        .background(Color.black)
    }
}
