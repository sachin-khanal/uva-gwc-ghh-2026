//
// File:     Waypoint/UI/Navigator/NavigatorFlowView.swift
// Owner:    U3 (UI flows)
// Purpose:  Entry of the NEW Navigator (blind user) workflow (docs/UI_PLAN.md §7), shown by RootView only when
//           the "New interface" setting is on. Always dark and high contrast; the small navigation bar is hidden
//           and replaced by large in-screen controls. Screens, driven by NavigateFlow (WaypointCore):
//             building -> destination -> confirm -> active (finding position / guiding) -> arrived.
//           VoiceOver escape (two-finger Z) goes back one screen, but never ends an active route.
// Also:     `NavScreen`, the shared layout for the pre-route screens: a heading that receives VoiceOver focus
//           on appear, and a spoken introduction when VoiceOver is off (Announcer.prompt).
// Status:   SCAFFOLD, UNVERIFIED ON DEVICE.
//
import SwiftUI
import WaypointCore

struct NavigatorFlowView: View {
    @EnvironmentObject var app: AppState
    @StateObject private var model = NavigatorModel()

    var body: some View {
        ZStack {
            Theme.Nav.background.ignoresSafeArea()
            if model.isConfigured { content }
        }
        .preferredColorScheme(.dark)
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { model.configure(maps: app.maps) }
        .onDisappear { model.leave() }
        .accessibilityAction(.escape) { goBack() }
    }

    @ViewBuilder
    private var content: some View {
        let map = model.selectedMap(in: app.maps)
        switch model.flow.step {
        case .building:
            BuildingPickerView(maps: app.maps, onPick: { model.chooseMap($0) }, onExit: leaveNavigate)
        case .destination:
            if let map {
                DestinationPickerView(model: model, map: map, onBack: goBack, onExit: leaveNavigate)
            } else {
                BuildingPickerView(maps: app.maps, onPick: { model.chooseMap($0) }, onExit: leaveNavigate)
            }
        case .confirm:
            if let map, let destination = model.destination {
                RouteConfirmView(model: model, destination: destination,
                                 onStart: { model.start(map: map, store: app.store) },
                                 onChange: goBack)
            }
        case .active:
            if let map {
                if showsLocalizing {
                    LocalizingView(model: model,
                                   onRetry: { model.retry(map: map, store: app.store) },
                                   onStop: { model.stop() })
                } else {
                    GuidingView(model: model, onStop: { model.stop() })
                }
            }
        case .arrived:
            if let map {
                ArrivedView(model: model,
                            onRouteBack: { model.routeBack(map: map) },
                            onNewDestination: { model.newDestination() },
                            onDone: leaveNavigate)
            }
        }
    }

    private var showsLocalizing: Bool {
        switch model.guidance.phase {
        case .idle, .localizing, .failed: return true
        case .guiding, .lost, .obstacleStop, .arrived: return false
        }
    }

    private func goBack() {
        if !model.back() { leaveNavigate() }
    }

    private func leaveNavigate() {
        model.leave()
        app.mode = .none
    }
}

/// Shared layout for the navigator's list-style screens.
struct NavScreen<Content: View>: View {
    let title: String
    var subtitle: String?
    /// Spoken when the screen appears and VoiceOver is off.
    var prompt: String
    var interruptPrompt = true
    @ViewBuilder let content: Content

    @AccessibilityFocusState private var headingFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    Text(title)
                        .font(.largeTitle.weight(.bold))
                        .fontDesign(.rounded)
                        .foregroundStyle(Theme.Nav.text)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityFocused($headingFocused)
                    if let subtitle {
                        Text(subtitle)
                            .font(.title3)
                            .foregroundStyle(Theme.Nav.secondaryText)
                    }
                }
                content
            }
            .padding(.horizontal, Theme.Space.l)
            .padding(.vertical, Theme.Space.xl)
        }
        .scrollIndicators(.hidden)
        .onAppear {
            Announcer.prompt(prompt, interrupt: interruptPrompt)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { headingFocused = true }
        }
    }
}

/// One line of information with an icon (headphones, stairs, how to hold the phone).
struct NavInfoRow: View {
    let systemImage: String
    let text: String
    var tint: Color = Theme.Nav.secondaryText

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.m) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 32)
                .accessibilityHidden(true)
            Text(text)
                .font(.title3)
                .foregroundStyle(Theme.Nav.text)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(Theme.Space.l)
        .background(Theme.Nav.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}
