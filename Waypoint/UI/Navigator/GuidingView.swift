//
// File:     Waypoint/UI/Navigator/GuidingView.swift
// Owner:    U3 (UI flows)
// Purpose:  N5, the screen the user never has to look at (docs/UI_PLAN.md §7 N5):
//             * almost the whole screen is ONE target: tap it (VoiceOver: double tap) to repeat the instruction;
//             * VoiceOver custom actions: Distance remaining, Pause/Resume (demo only), Stop navigation;
//             * magic tap = pause/resume (or repeat when the source cannot pause);
//             * "Position lost" and "STOP" take over the whole area, with no arrow pulling the user forward;
//             * Stop is hold-to-confirm; the small Escort button is for the sighted escort and hidden from VoiceOver.
//           No decorative haptics here: one tap / two taps already mean left / right (D-011).
//           Guidance speech comes from the service (live) or the model (demo); this view only shows it.
// Status:   SCAFFOLD, UNVERIFIED ON DEVICE.
//
import SwiftUI
import WaypointCore

struct GuidingView: View {
    @ObservedObject var model: NavigatorModel
    let onStop: () -> Void

    @State private var showEscort = false
    @State private var confirmStop = false
    @AccessibilityFocusState private var mainFocused: Bool

    private var g: GuidanceSnapshot { model.guidance }

    var body: some View {
        VStack(spacing: Theme.Space.l) {
            header

            Button(action: model.repeatInstruction) {
                VStack(spacing: Theme.Space.l) {
                    Spacer(minLength: 0)
                    Image(systemName: symbol)
                        .font(.system(size: 120, weight: .bold))
                        .foregroundStyle(symbolColor)
                    Text(g.headline)
                        .font(.system(.largeTitle, design: .rounded).weight(.heavy))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Theme.Nav.text)
                        .minimumScaleFactor(0.6)
                    if !g.detail.isEmpty {
                        Text(g.detail)
                            .font(.title2.weight(.semibold))
                            .multilineTextAlignment(.center)
                            .foregroundStyle(Theme.Nav.secondaryText)
                    }
                    if g.obstacle == .caution && g.phase == .guiding {
                        Label("Obstacle ahead", systemImage: "exclamationmark.triangle.fill")
                            .font(.title3.weight(.bold))
                            .foregroundStyle(Theme.Nav.onPrimary)
                            .padding(.horizontal, Theme.Space.l)
                            .padding(.vertical, Theme.Space.s)
                            .background(Theme.Nav.caution, in: Capsule())
                    }
                    if model.isPaused {
                        Label("Paused", systemImage: "pause.fill")
                            .font(.title3.weight(.bold))
                            .foregroundStyle(Theme.Nav.text)
                    }
                    Spacer(minLength: 0)
                }
                .padding(Theme.Space.l)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(areaColor, in: RoundedRectangle(cornerRadius: Theme.Radius.hero, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.hero, style: .continuous))
            }
            .buttonStyle(PressableStyle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(g.spokenText + (model.isPaused ? " Paused." : ""))
            .accessibilityHint("Double tap to repeat.")
            .accessibilityAddTraits(.updatesFrequently)
            .accessibilityAction(named: "Distance remaining") { model.announceDistanceRemaining() }
            .accessibilityAction(named: pauseActionName) { model.togglePause() }
            .accessibilityAction(named: "Stop navigation") { confirmStop = true }
            .accessibilityFocused($mainFocused)

            Text("Tap the screen to repeat")
                .font(.footnote)
                .foregroundStyle(Theme.Nav.secondaryText)
                .accessibilityHidden(true)

            HoldToConfirmButton(title: "Hold to stop", confirmTitle: "Stop navigation", action: onStop)
        }
        .padding(Theme.Space.l)
        .accessibilityAction(.magicTap) { model.togglePause() }
        .confirmationDialog("Stop navigation?", isPresented: $confirmStop, titleVisibility: .visible) {
            Button("Stop navigation", role: .destructive, action: onStop)
            Button("Keep going", role: .cancel) {}
        }
        .sheet(isPresented: $showEscort) { EscortPanel(model: model) }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { mainFocused = true }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("To \(g.destinationLabel)")
                    .font(.headline)
                    .foregroundStyle(Theme.Nav.text)
                if let remaining = g.distanceRemaining {
                    Text("\(SpokenText.capitalizingFirst(SpokenText.distance(remaining))) left")
                        .font(.subheadline)
                        .foregroundStyle(Theme.Nav.secondaryText)
                }
            }
            .accessibilityElement(children: .combine)
            Spacer()
            Button("Escort") { showEscort = true }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.Nav.secondaryText)
                .padding(.horizontal, Theme.Space.m)
                .padding(.vertical, Theme.Space.s)
                .background(Theme.Nav.surface, in: Capsule())
                .accessibilityHidden(true) // for the sighted escort; keeps VoiceOver focus on guidance
        }
    }

    private var pauseActionName: String {
        guard model.supportsPause else { return "Repeat instruction" }
        return model.isPaused ? "Resume guidance" : "Pause guidance"
    }

    private var symbol: String {
        switch g.phase {
        case .guiding:
            switch g.kind ?? .continueStraight {
            case .continueStraight: return "arrow.up"
            case .turnLeft: return "arrow.turn.up.left"
            case .turnRight: return "arrow.turn.up.right"
            case .turnAround: return "arrow.uturn.down"
            case .arrived: return "flag.checkered"
            }
        case .lost: return "location.slash.fill"
        case .obstacleStop: return "hand.raised.fill"
        case .arrived: return "flag.checkered"
        case .localizing: return "location.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .idle: return "pause.circle.fill"
        }
    }

    private var symbolColor: Color {
        switch g.phase {
        case .obstacleStop: return Theme.Nav.text
        case .lost: return Theme.Nav.caution
        default: return Theme.Nav.primary
        }
    }

    private var areaColor: Color {
        switch g.phase {
        case .obstacleStop: return Theme.Nav.danger
        case .lost: return Color(red: 0.28, green: 0.18, blue: 0.0)
        default: return Theme.Nav.surface
        }
    }
}
