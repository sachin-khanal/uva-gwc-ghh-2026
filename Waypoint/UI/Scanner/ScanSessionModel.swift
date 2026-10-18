//
// File:     Waypoint/UI/Scanner/ScanSessionModel.swift
// Owner:    U3 (UI flows)
// Purpose:  View model for one scanning session: owns the ScanService (mock or live), republishes its
//           snapshot to SwiftUI, and holds UI-only state (label draft, paused, saving, toast).
// Tap to place (2026-10-18): `selectSpot` turns a tap on the camera view into a pending spot (TapPlacement,
//           WaypointCore); the screen then asks for an optional name and the type, and `tagAtSpot` places the tag
//           there (Stairs first opens the stairs sheet, then saves at the spot). Without a spot, tagging works as
//           before (1 m ahead).
// Threading: main thread only (services call back on main).
// Status:   SCAFFOLD.
//
import SwiftUI
import WaypointCore

final class ScanSessionModel: ObservableObject {

    @Published private(set) var snapshot = ScanSnapshot()
    @Published var labelDraft = ""
    @Published private(set) var isPaused = false
    @Published private(set) var isSaving = false
    @Published var saveError: String?
    /// Short confirmation shown after tagging ("Door tagged").
    @Published private(set) var toast: String?
    /// Increments on every successful tag; drives the success haptic.
    @Published private(set) var tagEvents = 0

    /// A spot the volunteer tapped in the camera view, waiting for a name and a type.
    struct PendingSpot: Equatable {
        /// Where the tag will go, LIVE SESSION frame, already adjusted by TapPlacement.
        var position: SIMD3<Float>
        /// Floor-plane metres from the volunteer when it was tapped.
        var distance: Float
        /// Where on the camera view it was tapped (draws the pin over the demo camera).
        var screenPoint: CGPoint
    }
    @Published private(set) var spot: PendingSpot?
    /// Name typed for the pending spot (optional; can be added later in Review).
    @Published var spotLabel = ""
    /// Increments when a spot is picked; drives a selection haptic.
    @Published private(set) var spotEvents = 0

    let service: ScanService
    let mapName: String
    /// Set when this session extends a saved map (new Scanner "Extend a map").
    let extending: BuildingMap?
    let initialSegment: String?
    private var toastWork: DispatchWorkItem?

    init(service: ScanService, mapName: String, extending: BuildingMap? = nil, initialSegment: String? = nil) {
        self.service = service
        self.mapName = mapName
        self.extending = extending
        self.initialSegment = initialSegment
        service.onUpdate = { [weak self] snapshot in self?.snapshot = snapshot }
    }

    var isMock: Bool { service.isMock }
    var gate: FinishGate { snapshot.finishGate }

    func start() {
        service.start(mapName: mapName, extending: extending, initialSegment: initialSegment)
        snapshot = service.snapshot
    }

    func togglePause() {
        if isPaused {
            service.resume()
            isPaused = service.snapshot.isPaused // the live engine refuses to resume far from where it was paused
        } else {
            service.pause()
            isPaused = true
        }
        Announcer.voiceOverOnly(isPaused ? "Scan paused" : "Scan resumed")
    }

    /// "I am standing at this labelled place" while extending a saved map. Deliberately NOT gated on
    /// `canRecord`: the whole point is that recording is still blocked because the scanner has not
    /// found its place, and this is how the volunteer gives it one.
    func confirmPlace(_ id: UUID) {
        service.confirmPlace(id: id)
        snapshot = service.snapshot
        if let status = snapshot.extensionStatus { Announcer.voiceOverOnly(status) }
    }

    /// A stairs or lift tag that is waiting for the volunteer to fill in the sheet, nil otherwise.
    @Published var taggingStairs: NodeKind?

    /// Stairs and lifts carry metadata nothing can measure (which way they go, where the handrail is),
    /// so tapping them opens a sheet rather than dropping a bare node. Everything else tags directly.
    func beginTag(_ kind: NodeKind) {
        guard !isPaused, snapshot.canRecord else { return }
        if kind == .stairs || kind == .elevator {
            taggingStairs = kind
        } else {
            tag(kind)
        }
    }

    func finishStairsTag(kind: NodeKind, name: String, info: StairsInfo) {
        taggingStairs = nil
        guard !isPaused, snapshot.canRecord else { return }
        // Stairs picked for a tapped spot go to that spot; otherwise 1 m ahead as before.
        if let pending = spot {
            place(kind: kind, label: name, stairs: info, at: pending)
            return
        }
        let before = snapshot.tags.count
        service.tagStairs(kind: kind, label: name, info: info)
        snapshot = service.snapshot
        guard snapshot.tags.count > before else { return }
        labelDraft = ""
        tagEvents += 1
        showToast("\(kind.displayName) \u{201C}\(name)\u{201D} tagged")
    }

    func restartPlaceConfirmation() {
        service.restartPlaceConfirmation()
        snapshot = service.snapshot
        if let status = snapshot.extensionStatus { Announcer.voiceOverOnly(status) }
    }

    func tag(_ kind: NodeKind) {
        guard !isPaused, snapshot.canRecord else { return }
        let label = labelDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let before = snapshot.tags.count
        service.tag(kind: kind, label: label.isEmpty ? nil : label)
        snapshot = service.snapshot
        guard snapshot.tags.count > before else { return }
        labelDraft = ""
        tagEvents += 1
        showToast(label.isEmpty ? "\(kind.displayName) tagged" : "\(kind.displayName) “\(label)” tagged")
    }

    // MARK: Tap to place

    /// A tap on the camera view at `point` (in a view of `viewSize`). Picks the spot, or says why not.
    func selectSpot(at point: CGPoint, viewSize: CGSize) {
        guard snapshot.isRunning else { return }
        guard !isPaused, snapshot.canRecord else {
            showToast(isPaused ? "Resume recording to place a tag." : "Wait until the scan has found its place.")
            return
        }
        guard let hit = service.surfacePoint(at: point, viewSize: viewSize), let camera = service.cameraPosition else {
            showToast("Nothing scanned there yet. Sweep the camera over it first.")
            return
        }
        switch TapPlacement.evaluate(hit: hit, camera: camera) {
        case .placeable(let position, let distance):
            if spot == nil { spotLabel = "" } // keep a half-typed name when the volunteer only re-aims
            spot = PendingSpot(position: position, distance: distance, screenPoint: point)
            spotEvents += 1
            Announcer.voiceOverOnly("Spot picked, \(SpokenText.distance(distance)) away. Name it, then choose a type.")
        case .tooFar(let distance):
            showToast("That spot is about \(Int(distance.rounded())) m away. Walk closer: up to \(Int(TapPlacement.maxDistance)) m.")
        }
    }

    func clearSpot() {
        spot = nil
        spotLabel = ""
    }

    /// Tags the pending spot as `kind`, named with `spotLabel`. Stairs open the stairs sheet first.
    func tagAtSpot(_ kind: NodeKind) {
        guard let pending = spot, !isPaused, snapshot.canRecord else { return }
        if kind == .stairs || kind == .elevator {
            taggingStairs = kind // finishStairsTag places it at the spot
            return
        }
        let label = spotLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        place(kind: kind, label: label.isEmpty ? nil : label, stairs: nil, at: pending)
    }

    private func place(kind: NodeKind, label: String?, stairs: StairsInfo?, at pending: PendingSpot) {
        if let camera = service.cameraPosition, !TapPlacement.isInRange(pending.position, camera: camera) {
            clearSpot()
            showToast("You have walked too far from that spot. Tap it again.")
            return
        }
        let before = snapshot.tags.count
        service.tag(kind: kind, label: label, stairs: stairs, at: pending.position)
        snapshot = service.snapshot
        guard snapshot.tags.count > before else {
            showToast("Could not place the tag. Try again.")
            return
        }
        clearSpot()
        tagEvents += 1
        let what = label.map { "\(kind.displayName) \u{201C}\($0)\u{201D}" } ?? kind.displayName
        showToast("\(what) tagged \(Int(pending.distance.rounded())) m away")
    }

    /// Uses the sign-reader suggestion as the label of a new Room tag.
    func acceptSuggestion() {
        guard let suggestion = snapshot.suggestion else { return }
        labelDraft = suggestion
        tag(.room)
        service.dismissSuggestion()
    }

    func dismissSuggestion() { service.dismissSuggestion() }

    func adjustBox(by delta: Float) { service.adjustBox(by: delta) }

    func finish(onSaved: @escaping (BuildingMap) -> Void) {
        guard gate.isReady, !isSaving else { return }
        isSaving = true
        saveError = nil
        service.finish { [weak self] result in
            guard let self else { return }
            self.isSaving = false
            switch result {
            case .success(let map):
                Announcer.voiceOverOnly("Map saved")
                onSaved(map)
            case .failure(let error):
                self.saveError = error.localizedDescription
            }
        }
    }

    func cancel() {
        toastWork?.cancel()
        service.cancel()
    }

    private func showToast(_ text: String) {
        toast = text
        Announcer.voiceOverOnly(text)
        toastWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.toast = nil }
        toastWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8, execute: work)
    }
}
