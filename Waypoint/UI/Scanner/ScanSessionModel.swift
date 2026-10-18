//
// File:     Waypoint/UI/Scanner/ScanSessionModel.swift
// Owner:    U3 (UI flows)
// Purpose:  View model for one scanning session: owns the ScanService (mock or live), republishes its
//           snapshot to SwiftUI, and holds UI-only state (label draft, paused, saving, toast).
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
        let before = snapshot.tags.count
        service.tagStairs(kind: kind, label: name, info: info)
        snapshot = service.snapshot
        guard snapshot.tags.count > before else { return }
        labelDraft = ""
        tagEvents += 1
        showToast("\(kind.displayName) \u{201C}\(name)\u{201D} tagged")
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
