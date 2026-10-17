//
// File:     Waypoint/UI/Navigator/RouteConfirmView.swift
// Owner:    U3 (UI flows)
// Purpose:  N3 "Confirm": what the walk will be like before it starts (distance, turns, stairs), a headphone
//           check (read-only, never blocks), how to hold the phone, and ONE very large Start target.
//           VoiceOver magic tap (two-finger double tap) also starts guidance.
// Status:   SCAFFOLD, UNVERIFIED ON DEVICE.
//
import SwiftUI
import WaypointCore

struct RouteConfirmView: View {
    @ObservedObject var model: NavigatorModel
    let destination: MapNode
    let onStart: () -> Void
    let onChange: () -> Void

    @State private var headphones = AudioRoute.headphonesConnected

    private var name: String { model.displayName(destination) }
    private var summary: RouteSummary? { model.summary }

    var body: some View {
        NavScreen(
            title: name,
            subtitle: summary?.shortSummary,
            prompt: "\(summary?.spokenSummary ?? name) Tap the large yellow button at the bottom of the screen to start."
        ) {
            VStack(spacing: Theme.Space.m) {
                if let summary, summary.hasStairs {
                    NavInfoRow(systemImage: "figure.stairs", text: "This route includes stairs. You will be warned before them.",
                               tint: Theme.Nav.caution)
                }
                if let summary {
                    let others = summary.hazards.filter { $0 != .stairs }
                    if !others.isEmpty {
                        NavInfoRow(systemImage: "exclamationmark.triangle.fill",
                                   text: "Watch for " + others.map(SpokenText.hazard).joined(separator: " and ") + ".",
                                   tint: Theme.Nav.caution)
                    }
                }
                NavInfoRow(systemImage: headphones ? "headphones" : "speaker.wave.2.fill",
                           text: headphones ? "Headphones connected." : "Spatial audio works best with headphones.",
                           tint: headphones ? .green : Theme.Nav.caution)
                NavInfoRow(systemImage: "iphone",
                           text: "Hold the phone upright at chest height, with the back camera facing forward.")
                if model.mode == .mock {
                    NavInfoRow(systemImage: "theatermasks", text: "Demo guidance: no real positioning. Change it in Settings.")
                }
            }

            HeroButton(title: "Start guidance", subtitle: "to \(name)", systemImage: "figure.walk",
                       style: .navPrimary, hint: "Starts finding your position, then guides you with sound.", action: onStart)

            HeroButton(title: "Change destination", systemImage: "chevron.left", style: .navSecondary, action: onChange)
        }
        .accessibilityAction(.magicTap) { onStart() }
        .onAppear { headphones = AudioRoute.headphonesConnected }
    }
}
