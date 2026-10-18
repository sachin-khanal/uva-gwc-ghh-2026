//
// File:     Waypoint/UI/Navigator/GuidingView.swift
// Owner:    U3 (UI flows)
// Purpose:  N5, the screen the user never has to look at (docs/UI_PLAN.md §7 N5):
//             * the instruction, its arrow and the distance, large and high contrast;
//             * "Position lost" and "STOP" take over the whole area, with no arrow pulling the user forward;
//             * the WHOLE screen is hold-to-stop and it is the only control (branch final-ui-changes, 2026-10-18;
//               it used to be a tap-to-repeat area plus a Stop bar). VoiceOver: double tap, then confirm.
//             * VoiceOver custom actions (not on-screen buttons): Repeat instruction, Distance remaining;
//               magic tap repeats the instruction.
//           With Settings > Show debugging tools: the Escort button (test tools) and, if also switched on, the
//           debug overlay (camera + computed route). Neither is shown otherwise.
//           No decorative haptics here: one tap / two taps already mean left / right (D-011).
// Status:   SCAFFOLD, UNVERIFIED ON DEVICE.
//
import SwiftUI
import WaypointCore

struct GuidingView: View {
    @ObservedObject var model: NavigatorModel
    let onStop: () -> Void

    @State private var showEscort = false
    @AccessibilityFocusState private var mainFocused: Bool
    @AppStorage(UIPrefs.debugTools) private var debugTools = false
    @AppStorage(UIPrefs.debugOverlay) private var debugOverlay = false

    private var g: GuidanceSnapshot { model.guidance }

    var body: some View {
        VStack(spacing: Theme.Space.m) {
            if debugTools {
                debugRow
                // Sighted debugging only: the camera the app is tracking with and the route it actually computed.
                // Absent in mock mode, which has no controller.
                if debugOverlay, let controller = model.debugController {
                    NavDebugView(controller: controller)
                }
            }

            HoldToStopSurface(accessibilityText: g.spokenText, onStop: onStop) {
                instruction
                    .background(areaColor)
            }
            .accessibilityAddTraits(.updatesFrequently)
            .accessibilityAction(named: "Repeat instruction") { model.repeatInstruction() }
            .accessibilityAction(named: "Distance remaining") { model.announceDistanceRemaining() }
            .accessibilityFocused($mainFocused)
        }
        .padding(Theme.Space.l)
        .accessibilityAction(.magicTap) { model.repeatInstruction() }
        .sheet(isPresented: $showEscort) { EscortPanel(model: model) }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { mainFocused = true }
        }
    }

    private var instruction: some View {
        VStack(spacing: Theme.Space.l) {
            header
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
            Spacer(minLength: 0)
            HoldToStopHint()
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.top, Theme.Space.l)
    }

    private var header: some View {
        VStack(spacing: 2) {
            Text("To \(g.destinationLabel)")
                .font(.headline)
                .foregroundStyle(Theme.Nav.text)
            if let remaining = g.distanceRemaining {
                Text("\(SpokenText.capitalizingFirst(SpokenText.distance(remaining))) left")
                    .font(.subheadline)
                    .foregroundStyle(Theme.Nav.secondaryText)
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// Test tools for a sighted helper, only with debugging tools on.
    private var debugRow: some View {
        HStack {
            Spacer()
            Button("Escort") { showEscort = true }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.Nav.secondaryText)
                .padding(.horizontal, Theme.Space.m)
                .padding(.vertical, Theme.Space.s)
                .background(Theme.Nav.surface, in: Capsule())
                .accessibilityHidden(true) // keeps VoiceOver focus on guidance
        }
    }

    private var symbol: String {
        switch g.phase {
        case .guiding:
            // Follow the WORDS, not the raw instruction: speech is rate limited, so `kind` can be a
            // second or two ahead of what the user was told, and the arrow then contradicts the voice.
            switch g.spokenKind ?? g.kind ?? .continueStraight {
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
