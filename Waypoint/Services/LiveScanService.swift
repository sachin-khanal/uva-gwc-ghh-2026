//
// File:     Waypoint/Services/LiveScanService.swift
// Owner:    U3 (UI flows) - mapping to be reviewed by U1 (owner of CaptureController)
// Purpose:  Connects the new Scanner screens to the EXISTING `CaptureController`, observe-only
//           (docs/UI_PLAN.md rule R3): it calls only CaptureController's existing methods
//           (start, stop, tagPOI, adjustBoxMargin, save) and reads its existing @Published properties.
//           CaptureController itself is not modified. (2026-10-17: also forwards `extending:` / `initialSegment:` and reads
//           `extensionStatus` / `canRecord`, which already existed, for the "Extend a map" flow.)
// Mapping:  trackingSummary -> ScanTracking.from(summary:) (tested in FlowTests)
//           mappingStatus   -> ScanQuality
//           nodeCount, triangleCount, scanBox, boxMargin, errorMessage copied as they are.
// Limits:   * Pause is REAL since 2026-10-17: CaptureController.pauseRecording stops breadcrumbs, tags, mesh counting and box fitting while
//             ARKit keeps tracking (stopping the session would lose the map origin). Resume is refused far from the pause point.
//           * Tags are recorded here as they are requested; CaptureController.tagPOI silently ignores a tag
//             made before the first camera frame, so the list can very rarely include one extra tag.
// Threading: CaptureController publishes on the main queue; we hop to the next run-loop turn after
//           objectWillChange so the new values are readable.
// Status:   SCAFFOLD, UNVERIFIED ON DEVICE.
//
import ARKit
import Combine
import WaypointCore

final class LiveScanService: ScanService {

    var onUpdate: ((ScanSnapshot) -> Void)?
    private(set) var snapshot = ScanSnapshot() { didSet { if snapshot != oldValue { onUpdate?(snapshot) } } }
    let isMock = false
    var arSession: ARSession? { controller.session }
    var scanBox: OrientedBox? { controller.scanBox }

    let controller: CaptureController
    private var cancellables: Set<AnyCancellable> = []
    private var finishCancellables: Set<AnyCancellable> = []
    private var tags: [ScanTag] = []
    private var isPaused = false
    private var finishCompletion: ((Result<BuildingMap, Error>) -> Void)?

    init(store: MapStore, deviceName: String) {
        controller = CaptureController(store: store, deviceName: deviceName)
        controller.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
    }

    func start(mapName: String) {
        tags = []
        isPaused = false
        controller.start(mapName: mapName)
        refresh()
    }

    func start(mapName: String, extending map: BuildingMap?, initialSegment: String?) {
        tags = []
        isPaused = false
        controller.start(mapName: mapName, extending: map, initialSegment: initialSegment)
        refresh()
    }

    func pause() {
        isPaused = true
        controller.pauseRecording()
        refresh()
    }

    func resume() {
        if controller.resumeRecording() { isPaused = false }
        refresh()
    }

    var coverageOverlay: CoverageSnapshot? { controller.coverage }

    func setShowCoverage(_ on: Bool) {
        controller.showCoverage = on
        refresh()
    }

    func tag(kind: NodeKind, label: String?) {
        guard controller.isRunning, !isPaused else { return }
        let before = controller.nodeCount
        controller.tagPOI(kind: kind, label: label)
        // tagPOI updates nodeCount synchronously when the tag was accepted.
        if controller.nodeCount > before {
            tags.append(ScanTag(id: UUID(), kind: kind, label: label))
        }
        refresh()
    }

    func dismissSuggestion() {} // no sign reader wired yet (ROADMAP U2.7)

    func adjustBox(by delta: Float) { controller.adjustBoxMargin(by: delta) }

    func finish(completion: @escaping (Result<BuildingMap, Error>) -> Void) {
        finishCompletion = completion
        finishCancellables = []
        let previousError = controller.errorMessage

        controller.$savedMap
            .compactMap { $0 }
            .first()
            .receive(on: RunLoop.main)
            .sink { [weak self] map in self?.complete(.success(map)) }
            .store(in: &finishCancellables)

        controller.$errorMessage
            .dropFirst()
            .compactMap { $0 }
            .filter { $0 != previousError }
            .first()
            .receive(on: RunLoop.main)
            .sink { [weak self] message in self?.complete(.failure(ScanServiceError(message: message))) }
            .store(in: &finishCancellables)

        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            self?.complete(.failure(ScanServiceError(message: "Saving took too long. Try again.")))
        }
        controller.save()
    }

    func cancel() {
        controller.stop()
        finishCompletion = nil
        finishCancellables = []
    }

    // MARK: Private

    private func complete(_ result: Result<BuildingMap, Error>) {
        guard let completion = finishCompletion else { return } // only the first outcome counts
        finishCompletion = nil
        finishCancellables = []
        if case .success = result { controller.stop() }
        completion(result)
    }

    private func refresh() {
        var s = ScanSnapshot()
        s.isRunning = controller.isRunning
        s.tracking = ScanTracking.from(summary: controller.trackingSummary)
        s.quality = Self.quality(controller.mappingStatus)
        s.nodeCount = controller.nodeCount
        s.triangleCount = controller.triangleCount
        s.boxSize = controller.scanBox?.size
        s.boxMargin = controller.boxMargin
        s.tags = tags
        s.errorMessage = controller.errorMessage
        s.extensionStatus = controller.extensionStatus
        s.isPaused = controller.isPaused
        s.showCoverage = controller.showCoverage
        s.coveragePercent = controller.coverage?.percent
        s.canRecord = controller.extensionStatus == nil || controller.canRecord
        snapshot = s
    }

    private static func quality(_ status: ARFrame.WorldMappingStatus) -> ScanQuality {
        switch status {
        case .notAvailable: return .notAvailable
        case .limited: return .limited
        case .extending: return .extending
        case .mapped: return .mapped
        @unknown default: return .notAvailable
        }
    }
}
