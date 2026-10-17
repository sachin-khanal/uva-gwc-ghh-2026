//
// File:     Waypoint/UI/Scanner/LiveScanScreen.swift
// Owner:    U3 (UI flows)
// Purpose:  S3, the Polycam-style live scan screen (docs/UI_PLAN.md §6 S3):
//             * full-bleed camera: the EXISTING `LiveScanView` (unchanged) for a live session, or
//               `MockCameraView` for demo data;
//             * glass status pills on top (tracking, points, demo badge) and a discard button;
//             * a collapsible bottom panel: mapping-quality ring, warnings, sign suggestion chip, label field,
//               tag palette, box size, Pause and Finish (enabled by FinishGate, with the reason when disabled).
//           Tagging gives a success haptic + toast (+ VoiceOver announcement). Screen stays awake while scanning.
//           Named LiveScanScreen to avoid confusion with the private `ScanningView` in VolunteerView.swift.
// Status:   SCAFFOLD, UNVERIFIED ON DEVICE.
//
import SwiftUI
import WaypointCore

struct LiveScanScreen: View {
    @ObservedObject var model: ScanSessionModel
    let onSaved: (BuildingMap) -> Void
    let onDiscard: () -> Void

    @State private var panelExpanded = true
    @State private var confirmDiscard = false
    @FocusState private var labelFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var s: ScanSnapshot { model.snapshot }

    var body: some View {
        ZStack(alignment: .bottom) {
            camera.ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 0)
                if let toast = model.toast {
                    Text(toast)
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, Theme.Space.l)
                        .padding(.vertical, Theme.Space.s)
                        .background(.regularMaterial, in: Capsule())
                        .transition(.opacity)
                        .padding(.bottom, Theme.Space.m)
                        .accessibilityHidden(true) // already announced by the model
                }
                panel
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .sensoryFeedback(.success, trigger: model.tagEvents)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: model.toast)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: panelExpanded)
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        .confirmationDialog("Discard this scan?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard scan", role: .destructive, action: onDiscard)
            Button("Keep scanning", role: .cancel) {}
        } message: {
            Text("Nothing from this scan will be saved.")
        }
    }

    // MARK: Camera

    @ViewBuilder
    private var camera: some View {
        if let session = model.service.arSession {
            LiveScanView(session: session, box: model.service.scanBox)
                .accessibilityHidden(true)
        } else {
            MockCameraView()
        }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: Theme.Space.s) {
            StatusPill(text: s.tracking.word, systemImage: trackingSymbol, tint: s.tracking.isNormal ? .green : .orange)
            StatusPill(text: "\(s.nodeCount) points", systemImage: "point.3.connected.trianglepath.dotted")
            if model.isMock { MockBadge() }
            Spacer(minLength: 0)
            Button { confirmDiscard = true } label: {
                Image(systemName: "xmark")
                    .font(.headline)
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .accessibilityLabel("Discard scan")
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.top, Theme.Space.s)
    }

    private var trackingSymbol: String {
        switch s.tracking {
        case .normal: return "checkmark.circle.fill"
        case .starting: return "hourglass"
        case .limited: return "exclamationmark.triangle.fill"
        case .unavailable: return "xmark.circle.fill"
        }
    }

    // MARK: Bottom panel

    private var panel: some View {
        VStack(spacing: Theme.Space.m) {
            Button { panelExpanded.toggle() } label: {
                Capsule().fill(Color.secondary.opacity(0.5)).frame(width: 40, height: 5)
                    .frame(maxWidth: .infinity, minHeight: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(panelExpanded ? "Collapse controls" : "Expand controls")

            HStack {
                QualityRing(quality: s.quality)
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(s.triangleCount.formatted()) triangles").font(.footnote.monospacedDigit())
                    if let size = s.boxSize {
                        Text(String(format: "%.1f × %.1f m area", size.x, size.z)).font(.footnote.monospacedDigit())
                    }
                }
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)
            }

            if case .limited(let reason) = s.tracking {
                Banner(text: "\(reason). Slow down and point at walls with detail.")
            }
            if let error = s.errorMessage ?? model.saveError {
                Banner(text: error, kind: .error)
            }

            if panelExpanded {
                expandedControls
            }

            HStack(spacing: Theme.Space.m) {
                Button { model.togglePause() } label: {
                    Label(model.isPaused ? "Resume" : "Pause", systemImage: model.isPaused ? "play.fill" : "pause.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 52)
                }
                .buttonStyle(.bordered)
                .tint(Color.secondary)

                Button { model.finish(onSaved: onSaved) } label: {
                    Group {
                        if model.isSaving {
                            ProgressView().tint(.white)
                        } else {
                            Label("Finish", systemImage: "checkmark")
                        }
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 52)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .disabled(!model.gate.isReady || model.isSaving)
                .accessibilityLabel(model.isSaving ? "Saving map" : "Finish and save map")
                .accessibilityHint(model.gate.reason ?? "Saves the map and opens the review.")
            }

            if let reason = model.gate.reason {
                Text(reason)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityHidden(true) // read as the Finish button's hint
            }
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.bottom, Theme.Space.l)
        .background(.regularMaterial, in: UnevenRoundedRectangle(topLeadingRadius: Theme.Radius.hero,
                                                                  topTrailingRadius: Theme.Radius.hero,
                                                                  style: .continuous))
        .ignoresSafeArea(edges: .bottom)
    }

    @ViewBuilder
    private var expandedControls: some View {
        if let suggestion = s.suggestion {
            HStack(spacing: Theme.Space.m) {
                Image(systemName: "text.viewfinder").foregroundStyle(Theme.accent).accessibilityHidden(true)
                Text("Sign reads “\(suggestion)”").font(.subheadline.weight(.medium))
                Spacer(minLength: 0)
                Button("Add") { model.acceptSuggestion() }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .accessibilityLabel("Add room \(suggestion)")
                Button { model.dismissSuggestion() } label: { Image(systemName: "xmark") }
                    .accessibilityLabel("Ignore suggestion")
            }
            .padding(Theme.Space.m)
            .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
        }

        TextField("Label for the next tag, e.g. Room 204", text: $model.labelDraft)
            .textInputAutocapitalization(.words)
            .submitLabel(.done)
            .focused($labelFocused)
            .padding(Theme.Space.m)
            .frame(minHeight: 48)
            .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
            .accessibilityLabel("Label for the next tag")

        TagPalette(isEnabled: s.isRunning && !model.isPaused) { kind in
            labelFocused = false
            model.tag(kind)
        }

        if !s.tags.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(s.tags.suffix(4).reversed())) { tag in
                        Badge(text: tag.label ?? tag.kind.displayName, systemImage: tag.kind.symbolName)
                    }
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Recent tags: " + s.tags.suffix(4).reversed().map { $0.label ?? $0.kind.displayName }.joined(separator: ", "))
        }

        HStack {
            Text(String(format: "Box margin %.1f m", s.boxMargin)).font(.footnote).foregroundStyle(.secondary)
            Spacer()
            Button { model.adjustBox(by: -0.1) } label: { Image(systemName: "minus.circle.fill").font(.title2) }
                .accessibilityLabel("Shrink scan box")
            Button { model.adjustBox(by: 0.1) } label: { Image(systemName: "plus.circle.fill").font(.title2) }
                .accessibilityLabel("Grow scan box")
        }
        .tint(Theme.accent)
    }
}
