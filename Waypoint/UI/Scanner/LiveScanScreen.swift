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
// Update 2026-10-18 (branch final-ui-changes):
//             * Tap to place: tap the camera view to drop a yellow pin up to 6 m away; the panel then shows a
//               "New tag here" card with a name field (focused right away, optional) and the type buttons.
//               Tagging without a pin still places the tag 1 m ahead.
//             * Markers: Room, Door, Stairs, Point (NodeKind.taggable).
//             * Technical numbers (points pill, triangles, area, both-ways %, unscanned-areas toggle, box margin)
//               only with Settings > Show debugging tools. The quality ring and the tips always show.
//             * The panel rises above the keyboard; while a spot is pending it shows only the card.
// Status:   SCAFFOLD, UNVERIFIED ON DEVICE.
//
import SwiftUI
import WaypointCore

/// `.sheet(item:)` needs something Identifiable; `NodeKind` is a plain enum used all over the model,
/// so the conformance is kept local to this screen rather than bolted onto the shared type.
private struct TaggingKind: Identifiable {
    let kind: NodeKind
    var id: String { kind.rawValue }
}

struct LiveScanScreen: View {
    @ObservedObject var model: ScanSessionModel
    let onSaved: (BuildingMap) -> Void
    let onDiscard: () -> Void

    @State private var panelExpanded = true
    @State private var confirmDiscard = false
    @FocusState private var labelFocused: Bool
    @FocusState private var spotNameFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(UIPrefs.debugTools) private var debugTools = false

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
        .sensoryFeedback(.selection, trigger: model.spotEvents)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: model.spot)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: model.toast)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: panelExpanded)
        // Stairs and lifts open a sheet instead of tagging straight away: which way they go and where
        // the handrail is cannot be measured, and nothing else will ever supply them.
        .sheet(item: Binding(get: { model.taggingStairs.map { TaggingKind(kind: $0) } },
                             set: { if $0 == nil { model.taggingStairs = nil } })) { pending in
            StairsSheet(kind: pending.kind,
                        knownNames: model.snapshot.knownStairwellNames,
                        onCancel: { model.taggingStairs = nil },
                        onSave: { name, info in
                            model.finishStairsTag(kind: pending.kind, name: name, info: info)
                        })
        }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        .confirmationDialog("Discard this scan?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard scan", role: .destructive, action: onDiscard)
            Button("Keep scanning", role: .cancel) {}
        } message: {
            Text("Nothing from this scan will be saved.")
        }
    }

    private var coverageCaption: String {
        guard s.showCoverage else { return "Yellow tiles mark walls, floor and ceiling the scan has not reached." }
        guard let percent = s.coveragePercent else { return "Measuring…" }
        return String(format: "%.0f%% of the box surfaces scanned. Yellow = not scanned yet.", percent * 100)
    }

    // MARK: Camera

    /// The camera, with a transparent layer on top that turns a tap into a tag spot. The layer and the AR view
    /// share one frame, so the tap location maps straight onto the camera image (LiveScanService.surfacePoint).
    private var camera: some View {
        GeometryReader { geo in
            ZStack {
                if let session = model.service.arSession {
                    LiveScanView(session: session, box: model.service.scanBox, showMesh: !model.isPaused,
                                 coverage: model.isPaused ? nil : model.service.coverageOverlay,
                                 target: model.spot?.position)
                } else {
                    MockCameraView()
                    if let spot = model.spot {
                        // The demo camera does not move, so a pin at the tap point stays put.
                        Image(systemName: "mappin")
                            .font(.system(size: 40, weight: .bold))
                            .foregroundStyle(.yellow)
                            .shadow(radius: 3)
                            .position(x: spot.screenPoint.x, y: spot.screenPoint.y - 20)
                    }
                }
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture(coordinateSpace: .local) { location in
                        labelFocused = false
                        model.selectSpot(at: location, viewSize: geo.size)
                        if model.spot != nil { spotNameFocused = true }
                    }
            }
        }
        .accessibilityHidden(true) // a sighted-only gesture; VoiceOver users tag with the buttons (1 m ahead)
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: Theme.Space.s) {
            StatusPill(text: s.tracking.word, systemImage: trackingSymbol, tint: s.tracking.isNormal ? .green : .orange)
            if debugTools {
                StatusPill(text: "\(s.nodeCount) points", systemImage: "point.3.connected.trianglepath.dotted")
            }
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

            // While a tapped spot waits for its name and type, the panel shows only that card (and errors),
            // so it still fits above the keyboard.
            if model.spot == nil {
                statusSection
            }
            if let error = s.errorMessage ?? model.saveError {
                Banner(text: error, kind: .error)
            }

            if model.spot != nil {
                spotCard
            } else {
                if panelExpanded {
                    expandedControls
                }
                actionRow
            }
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.bottom, Theme.Space.l)
        .background(.regularMaterial, in: UnevenRoundedRectangle(topLeadingRadius: Theme.Radius.hero,
                                                                  topTrailingRadius: Theme.Radius.hero,
                                                                  style: .continuous))
        // Only the container safe area: the panel must still rise above the keyboard when a name field is focused.
        .ignoresSafeArea(.container, edges: .bottom)
    }

    @ViewBuilder
    private var statusSection: some View {
        if s.shouldWalkBack {
            Banner(text: "Walk back the way you came so the map works in both directions.",
                   kind: .warning)
                .accessibilityIdentifier("scan.walkBack")
        }
        HStack {
            QualityRing(quality: s.quality)
            Spacer()
            if debugTools {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(s.triangleCount.formatted()) triangles").font(.footnote.monospacedDigit())
                    if let size = s.boxSize {
                        Text(String(format: "%.1f × %.1f m area", size.x, size.z)).font(.footnote.monospacedDigit())
                    }
                    // Both-directions coverage: a map walked one way only relocalizes badly when the
                    // user returns the other way (D-043).
                    Text("\(Int(s.returnCoverage * 100))% both ways").font(.footnote.monospacedDigit())
                }
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)
            }
        }

        if let status = s.extensionStatus {
            // Extending a saved map: tell the volunteer what the scanner is waiting for. Recording and tagging are paused until it has found its place.
            Banner(text: status, kind: s.canRecord ? .info : .warning)
        }
        // Locating yourself BY HAND. ARKit often will not recognise a space from a new direction, and
        // waiting for it is what blocked extending a map at all. A sighted volunteer can just look at a
        // door they labelled. TWO places are needed: the first says where you are, the second which way
        // you are turned (see ManualAlignment).
        if !s.placesToStandAt.isEmpty, !s.canRecord {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Text(s.confirmedPlaceCount == 0
                     ? "Give it a few seconds first - finding the area itself is more accurate. Not working? Stand at a labelled place and tap it."
                     : "Now walk to a different labelled place, at least \(Int(ManualAlignment.minSeparationMeters)) m away, and tap that one.")
                    .font(.subheadline.weight(.medium))
                    .accessibilityIdentifier("scan.extension.manualHint")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Theme.Space.s) {
                        ForEach(s.placesToStandAt) { place in
                            Button(place.id == s.confirmedPlaceId ? "\(place.label) ✓" : place.label) {
                                model.confirmPlace(place.id)
                            }
                            .buttonStyle(.bordered)
                            .disabled(place.id == s.confirmedPlaceId)
                        }
                    }
                }
                if s.confirmedPlaceCount > 0 {
                    Button("Start over") { model.restartPlaceConfirmation() }
                        .font(.footnote)
                        .accessibilityIdentifier("scan.extension.startOver")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("scan.extension.places")
        }
        if case .limited(let reason) = s.tracking {
            Banner(text: "\(reason). Slow down and point at walls with detail.")
        }
    }

    @ViewBuilder
    private var actionRow: some View {
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

    /// Shown right after a tap on the camera view: name the spot (optional), then pick its type.
    @ViewBuilder
    private var spotCard: some View {
        if let spot = model.spot {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                HStack(spacing: Theme.Space.s) {
                    Image(systemName: "mappin.circle.fill").font(.title2).foregroundStyle(.yellow)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("New tag here").font(.headline)
                        Text("About \(SpokenText.shortDistance(spot.distance)) away · tap the camera again to move it")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Button("Cancel") {
                        spotNameFocused = false
                        model.clearSpot()
                    }
                    .font(.subheadline.weight(.semibold))
                    .accessibilityLabel("Cancel this spot")
                }
                .accessibilityElement(children: .combine)

                TextField("Name (optional), e.g. Room 204", text: $model.spotLabel)
                    .textInputAutocapitalization(.words)
                    .submitLabel(.done)
                    .focused($spotNameFocused)
                    .padding(Theme.Space.m)
                    .frame(minHeight: 48)
                    .background(Color(uiColor: .tertiarySystemFill),
                                in: RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
                    .accessibilityLabel("Name for this spot, optional")

                Text("What is it?").font(.subheadline.weight(.semibold))
                TagPalette(isEnabled: s.isRunning && !model.isPaused) { kind in
                    spotNameFocused = false
                    model.tagAtSpot(kind)
                }
                Text(model.spotLabel.trimmingCharacters(in: .whitespaces).isEmpty
                     ? "No name? You can add it later on the Review screen. Stairs ask for their details next."
                     : "Stairs ask for their details next.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .padding(Theme.Space.m)
            .background(Color.yellow.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .strokeBorder(Color.yellow.opacity(0.6), lineWidth: 1)
            }
            .accessibilityIdentifier("scan.spotCard")
        }
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

        Label("Tip: tap the camera view to tag a spot up to \(Int(TapPlacement.maxDistance)) m away.",
              systemImage: "hand.tap")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityHidden(true)

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
            model.beginTag(kind)
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

        if debugTools {
            Toggle(isOn: Binding(get: { s.showCoverage }, set: { model.service.setShowCoverage($0) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Show unscanned areas").font(.subheadline.weight(.semibold))
                    Text(coverageCaption).font(.footnote).foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("scan.coverage")

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
}
