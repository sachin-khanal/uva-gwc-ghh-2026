//
// File:     Waypoint/UI/NavigatorView.swift
// Owner:    D (UI) with B (NavigationController)
// Purpose:  Navigator screen: pick a map and a destination, press Start. While navigating the
//           screen only shows status text - the blind user relies on audio and haptics. (A sighted
//           helper/judge escort can read the status.)
// Simulate: "Simulate walk" runs a virtual walker along the route (no scan or relocalization needed) so the
//           audio/haptic/speech cues can be tested on any iPhone; "Inject obstacle" fakes a close obstacle.
// Status:   SCAFFOLD. TODO(D): voice destination input (SFSpeechRecognizer, stretch goal),
//           one giant Start target, keep-screen-awake while navigating.
//
import SwiftUI
import WaypointCore

struct NavigatorView: View {
    @EnvironmentObject var app: AppState
    @StateObject private var nav = NavigationController()
    @State private var selectedMapId: UUID?
    @State private var isNavigating = false
    @State private var autoRun = false // true while a -autoSimulate self-test is running
    /// Map awaiting a delete confirmation. Deleting a recording is irreversible on this phone, so it
    /// is never a single tap.
    @State private var pendingDelete: BuildingMap?

    private var selectedMap: BuildingMap? { app.maps.first { $0.id == selectedMapId } ?? app.maps.first }

    var body: some View {
        Group {
            if isNavigating {
                navigatingBody
            } else {
                pickerBody
            }
        }
        .onDisappear { stopNavigation() }
        .onAppear(perform: runLaunchCommandIfNeeded)
        .confirmationDialog(
            "Delete \(pendingDelete?.name ?? "this map")?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete map", role: .destructive) { deletePending() }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("The map and its saved scan are removed from this phone. Copies on other phones or in the cloud are not affected.")
        }
        .onChange(of: nav.statusText) { _, status in
            // Headless self-test (-autoSimulate): finish once the walker has arrived.
            if autoRun, status == "Simulation finished" {
                Log.app.info("SELFTEST PASS: simulated walk finished")
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { exit(0) }
            }
        }
    }

    /// `-autoSimulate "<label>"` (see LaunchCommand): start the simulated walk with no taps and exit when done.
    private func runLaunchCommandIfNeeded() {
        guard case .simulate(let label, let facingAway) = app.launchCommand, !autoRun else { return }
        autoRun = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) {
            Log.app.error("SELFTEST FAIL: timed out after 120 s")
            exit(1)
        }
        // First map (alphabetical) that actually contains a destination matching the label.
        guard let (map, destination) = app.maps.lazy.compactMap({ m in
                  WaypointGraph(map: m).nodes(matchingLabel: label).first.map { (m, $0) }
              }).first else {
            Log.app.error("SELFTEST FAIL: no map has a destination matching \"\(label)\" (maps: \(app.maps.map(\.name)))")
            exit(2)
        }
        Log.app.info("SELFTEST start: \"\(map.name)\" -> \(destination.label ?? "?")")
        startSimulation(map: map, destination: destination, facingAway: facingAway)
    }

    private var pickerBody: some View {
        List {
            if app.maps.isEmpty {
                Text("No maps yet. Scan one in Volunteer mode or receive one via Share maps.")
            }
            Section("Map") {
                ForEach(app.maps) { map in
                    Button {
                        selectedMapId = map.id
                    } label: {
                        HStack {
                            Text(map.name)
                            Spacer()
                            if map.id == selectedMap?.id { Image(systemName: "checkmark") }
                        }
                    }
                    // The classic screens had no way to remove a recording at all.
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { pendingDelete = map } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                    // Swiping is invisible to VoiceOver, so expose the same thing as a rotor action.
                    .accessibilityAction(named: "Delete map") { pendingDelete = map }
                }
            }
            if let map = selectedMap {
                Section("Go to...") {
                    ForEach(map.destinations) { dest in
                        Button(dest.label ?? "Unnamed") { startNavigation(map: map, destination: dest) }
                            .accessibilityLabel("Navigate to \(dest.label ?? "unnamed")")
                    }
                }
                Section("Simulate (no scan needed)") {
                    ForEach(map.destinations) { dest in
                        Button("Simulate walk to \(dest.label ?? "unnamed")") {
                            startSimulation(map: map, destination: dest, facingAway: false)
                        }
                        .accessibilityIdentifier("nav.simulate.\(dest.label ?? "unnamed")")
                    }
                    if let dest = map.destinations.first {
                        Button("Simulate, starting facing the wrong way") {
                            startSimulation(map: map, destination: dest, facingAway: true)
                        }
                    }
                }
            }
        }
    }

    private var navigatingBody: some View {
        VStack(spacing: 20) {
            Text(nav.statusText).font(.title).accessibilityIdentifier("nav.status")
            Text(nav.instructionText).font(.title3).foregroundStyle(.secondary).accessibilityIdentifier("nav.instruction")
            if nav.obstacleLevel != .clear {
                Text(nav.obstacleLevel == .stop ? "STOP" : "Obstacle ahead")
                    .font(.largeTitle).bold().foregroundStyle(.red)
                    .accessibilityIdentifier("nav.obstacle")
            }
            if !nav.postureText.isEmpty {
                Text(nav.postureText).font(.headline).foregroundStyle(.orange).multilineTextAlignment(.center)
                    .accessibilityIdentifier("nav.postureText")
            }
            if !nav.lastSpoken.isEmpty {
                // What the user just heard (for a sighted helper, and for the UI tests).
                Text("\u{201C}\(nav.lastSpoken)\u{201D}").font(.callout).italic().multilineTextAlignment(.center)
                    .accessibilityIdentifier("nav.lastSpoken")
            }
            if !nav.recentSpeech.isEmpty {
                Text(nav.recentSpeech.joined(separator: "\n")).font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .accessibilityIdentifier("nav.recentSpeech")
            }
            if nav.isSimulating {
                Toggle("Pause walker (keep listening)", isOn: $nav.simulationPaused)
                    .padding(.horizontal)
                    .accessibilityIdentifier("nav.pauseWalk")
                Toggle("Inject obstacle (0.5 m ahead)", isOn: $nav.simulatedObstacle)
                    .padding(.horizontal)
                    .accessibilityIdentifier("nav.injectObstacle")
                Picker("Obstacle type", selection: $nav.simulatedObstacleKind) {
                    ForEach(ObstacleKind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("nav.obstacleKind")
                Picker("Phone held", selection: $nav.simulatedPosture) {
                    ForEach(SimulatedPosture.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("nav.posture")
            }
            Button("Stop") { stopNavigation() }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .accessibilityIdentifier("nav.stop")
        }
        .padding()
    }

    private func startNavigation(map: BuildingMap, destination: MapNode) {
        isNavigating = true
        UIApplication.shared.isIdleTimerDisabled = true // keep the screen on while walking
        nav.start(map: map, destination: destination, store: app.store)
    }

    private func startSimulation(map: BuildingMap, destination: MapNode, facingAway: Bool) {
        isNavigating = true
        UIApplication.shared.isIdleTimerDisabled = true
        nav.startSimulation(map: map, destination: destination, startFacingAway: facingAway)
    }

    /// Deletes the confirmed map. If it was the one selected, the selection falls back to whatever
    /// is left, so the screen never points at a map that no longer exists.
    private func deletePending() {
        guard let map = pendingDelete else { return }
        pendingDelete = nil
        let wasSelected = (selectedMapId == map.id)
        if app.deleteMap(map), wasSelected {
            selectedMapId = app.maps.first?.id
        }
    }

    private func stopNavigation() {
        guard isNavigating else { return }
        nav.stop()
        isNavigating = false
        UIApplication.shared.isIdleTimerDisabled = false
    }
}
