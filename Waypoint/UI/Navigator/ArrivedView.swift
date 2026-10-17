//
// File:     Waypoint/UI/Navigator/ArrivedView.swift
// Owner:    U3 (UI flows)
// Purpose:  N6 "You have arrived": the arrival is already spoken by the guidance (live) or the model (demo),
//           so this screen's spoken prompt only lists the choices, without interrupting. Choices are large
//           buttons: guide me back (not in simulated mode, whose walker always starts at the map start),
//           new destination, done.
// Status:   SCAFFOLD.
//
import SwiftUI
import WaypointCore

struct ArrivedView: View {
    @ObservedObject var model: NavigatorModel
    let onRouteBack: () -> Void
    let onNewDestination: () -> Void
    let onDone: () -> Void

    private var name: String { model.guidance.destinationLabel.isEmpty ? "your destination" : model.guidance.destinationLabel }

    var body: some View {
        NavScreen(
            title: "You have arrived",
            subtitle: name,
            prompt: model.canRouteBack
                ? "Choose: guide me back, new destination, or done."
                : "Choose: new destination, or done.",
            interruptPrompt: false
        ) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 96, weight: .semibold))
                .foregroundStyle(.green)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Theme.Space.l)
                .accessibilityHidden(true)

            VStack(spacing: Theme.Space.m) {
                if model.canRouteBack {
                    HeroButton(title: "Guide me back", subtitle: "to the start", systemImage: "arrow.uturn.backward",
                               style: .navPrimary, hint: "Shows the route back, then you can start it.", action: onRouteBack)
                }
                HeroButton(title: "New destination", systemImage: "mappin.and.ellipse",
                           style: model.canRouteBack ? .navSecondary : .navPrimary, action: onNewDestination)
                HeroButton(title: "Done", systemImage: "house.fill", style: .navSecondary,
                           hint: "Returns to the home screen.", action: onDone)
            }
        }
    }
}
