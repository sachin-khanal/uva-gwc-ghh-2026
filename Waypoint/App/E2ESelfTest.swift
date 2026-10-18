//
// File:     Waypoint/App/E2ESelfTest.swift
// Owner:    D (App/Sync/Integration); everyone can add checks.
// Purpose:  Headless END-TO-END self-test that runs INSIDE the app on a real phone (`make selftest-e2e`, launch switch `-autoE2E YES`).
//           It covers everything that can be proven without a person walking through a building:
//             A. DEVICE      what this phone can do: ARKit, LiDAR mesh (+classification), scene depth, haptics, speech voice, text recognition, audio engine
//             B. STORAGE     the app's real Documents folder + the Keychain on THIS phone
//             C. DATA PATH   synthetic scan -> MapBuilder -> save (+world map bytes) -> reload with a fresh store -> export bundle -> import into a
//                            second store -> validation -> route -> simulated walk through RouteFollower/FeedbackPlanner -> "arrived"
//             D. RESOURCES   the bundled sample map decodes
//             E. CLOUD       only if Supabase is configured: anonymous sign-in + list (read-only). SKIPPED otherwise.
//           Output: one `[e2e] PASS|FAIL|INFO|SKIP name - detail` line each, a summary, then exit(0) if nothing FAILed else exit(1).
// Limits:   cannot check real LiDAR geometry, relocalization, audio loudness/direction or haptic feel (those need a person), and the synthetic scan
//           feeds positions straight into MapBuilder instead of ARKit. Temp data lives in Documents/E2E-<uuid> and is deleted at the end.
// Run on every teammate's phone: the INFO lines are a capability matrix (does this phone have LiDAR? haptics? ...), useful for the U4 no-LiDAR checks.
//
import ARKit
import ModelIO
import SceneKit
import CoreHaptics
import AVFoundation
import Vision
import WaypointCore

enum E2ESelfTest {

    private struct Tally { var pass = 0, fail = 0, skip = 0 }

    @MainActor
    static func run(app: AppState) async -> Bool {
        var tally = Tally()
        func pass(_ name: String, _ detail: String = "") { tally.pass += 1; line("PASS", name, detail) }
        func fail(_ name: String, _ detail: String) { tally.fail += 1; line("FAIL", name, detail) }
        func skip(_ name: String, _ detail: String) { tally.skip += 1; line("SKIP", name, detail) }
        func info(_ name: String, _ detail: String) { line("INFO", name, detail) }
        func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") { ok ? pass(name, detail()) : fail(name, detail()) }

        let device = UIDevice.current
        info("device", "\(device.model) iOS \(device.systemVersion) id=\(app.deviceName)")

        // ---- A. DEVICE capabilities
        check("arkit.worldTracking", ARWorldTrackingConfiguration.isSupported)
        let mesh = ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
        let meshClass = ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification)
        let depth = ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
        info("lidar.mesh", "\(mesh)  (false = no LiDAR: volunteer scanning and obstacle detection unavailable on this phone)")
        info("lidar.meshWithClassification", "\(meshClass)")
        info("lidar.sceneDepth", "\(depth)")
        info("haptics", "\(CHHapticEngine.capabilitiesForHardware().supportsHaptics)")
        let hasVoice = AVSpeechSynthesisVoice(language: "en-US") != nil
        check("speech.voice.enUS", hasVoice, hasVoice ? "" : "no en-US voice installed")
        let siri = AVSpeechSynthesisVoice.speechVoices().filter { $0.identifier.lowercased().contains("siri") || $0.name.lowercased().contains("siri") }
        info("speech.siriVoices", "\(siri.count) installed: \(siri.prefix(4).map { "\($0.name) [\($0.language)]" })  (none = download one in Settings > Accessibility > Spoken Content > Voices)")
        info("speech.voice.chosen", Speaker.voiceDescription)
        let rows = Speaker.voiceRows
        info("speech.voice.picker", "\(rows.count) voices offered; best 3: \(rows.prefix(3).map { "\($0.title) (\($0.detail))" })")
        let languages = (try? VNRecognizeTextRequest().supportedRecognitionLanguages()) ?? []
        check("vision.textRecognition", !languages.isEmpty, "languages=\(languages.prefix(3))")
        do {
            let audio = SpatialAudioGuide()
            try audio.start()
            audio.stop()
            pass("audio.engine.start")
        } catch { fail("audio.engine.start", "\(error)") }

        // ---- B. STORAGE on this phone
        let docs = (try? FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
        guard let docs else { fail("storage.documents", "no Documents directory"); return finish(tally) }
        let scratch = docs.appendingPathComponent("E2E-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        do {
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            let probe = scratch.appendingPathComponent("probe.bin")
            try Data([1, 2, 3]).write(to: probe)
            check("storage.documents.writable", try Data(contentsOf: probe) == Data([1, 2, 3]), "\(docs.path)")
        } catch { fail("storage.documents.writable", "\(error)") }

        let keychain = KeychainSessionStore(service: "io.github.sachin-khanal.waypoint.e2e.\(UUID().uuidString)", account: "t")
        let session = AuthSession(accessToken: "a", refreshToken: "r", userId: "u", expiresAt: Date(timeIntervalSince1970: 2_000_000_000))
        keychain.save(session)
        check("storage.keychain.roundTrip", keychain.load() == session, "save/load of a session")
        keychain.save(nil)
        check("storage.keychain.clear", keychain.load() == nil)

        // ---- C. DATA PATH with a synthetic scan (an L-shaped hallway, 12 m + 6 m, two tagged rooms)
        let builder = MapBuilder(map: BuildingMap(name: "E2E synthetic hallway"), segmentId: "seg1", deviceName: "e2e", breadcrumbSpacing: 1.5)
        var z: Float = 0
        while z >= -12 { builder.observe(position: [0, 0, z]); z -= 0.25 }
        builder.addPOI(kind: .room, label: "E2E Room 1", position: [1.5, 0, -6])
        var x: Float = 0
        while x <= 6 { builder.observe(position: [x, 0, -12]); x += 0.25 }
        let last = builder.addPOI(kind: .room, label: "E2E Room 2", position: [6, 0, -13.5])
        let map = builder.map
        check("scan.builder", map.nodes.count > 10 && map.edges.count >= map.nodes.count - 3 && last.label == "E2E Room 2",
              "\(map.nodes.count) nodes, \(map.edges.count) edges")

        let storeA = MapStore(rootURL: scratch.appendingPathComponent("A", isDirectory: true))
        let worldBytes = Data((0..<4096).map { UInt8($0 % 251) })
        do {
            try storeA.save(map)
            try storeA.saveWorldMap(worldBytes, mapId: map.id, segmentId: "seg1")
            pass("store.save")
            let reopened = MapStore(rootURL: storeA.rootURL) // a fresh object, as after an app relaunch
            check("store.reload.map", (try? reopened.load(id: map.id)) == map)
            check("store.reload.worldMap", (try? reopened.loadWorldMap(mapId: map.id, segmentId: "seg1")) == worldBytes)
            check("store.list", ((try? reopened.listMaps().count) ?? 0) == 1)
        } catch { fail("store.save", "\(error)") }

        let storeB = MapStore(rootURL: scratch.appendingPathComponent("B", isDirectory: true))
        do {
            let file = try storeA.writeBundleFile(id: map.id)
            let imported = try storeB.importBundle(data: Data(contentsOf: file))
            check("share.exportImport", imported == map && (try? storeB.loadWorldMap(mapId: map.id, segmentId: "seg1")) == worldBytes,
                  "bundle file \((try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0) bytes")
            try? FileManager.default.removeItem(at: file)
        } catch { fail("share.exportImport", "\(error)") }
        check("validate.ownMap", (try? MapBundle(map: map).validate()) != nil)
        var hostile = map
        hostile.nodes[0].segmentId = "../escape"
        check("validate.rejectsTraversal", (try? MapBundle(map: hostile).validate()) == nil, "hostile segment id must be refused")

        // Route + simulated walk through the same pure logic the Navigator uses.
        let graph = WaypointGraph(map: map)
        if let startNode = map.nodes.first(where: { $0.kind == .corridor }),
           let goal = graph.nodes(matchingLabel: "E2E Room 2").first,
           let route = Router.route(in: graph, from: startNode.id, to: goal.id) {
            var sim = PoseSimulator(route: route)
            let follower = RouteFollower(route: route, graph: graph)
            var planner = FeedbackPlanner()
            var spoken: [String] = []
            var steps = 0
            while steps < 1_500 {
                steps += 1
                let instruction = follower.update(position: sim.position, forward: sim.forward)
                for case .speak(let text, _) in planner.plan(instruction: instruction, obstacle: .clear, trackingOK: true) { spoken.append(text) }
                if instruction.kind == .arrived { break }
                sim.step(dt: 0.1)
            }
            // No chatter: the same phrase must never be spoken twice in a row (it used to repeat "Continue straight." at every waypoint).
            let noRepeats = zip(spoken, spoken.dropFirst()).allSatisfy { $0 != $1 }
            check("nav.simulatedWalk", spoken.last == "You have arrived at E2E Room 2." && spoken.contains { $0.hasPrefix("Turn right") || $0.hasPrefix("Right") } && noRepeats,
                  "route \(route.count) nodes, \(steps) steps, said \(spoken)")
        } else {
            fail("nav.simulatedWalk", "no route in the synthetic map")
        }

        info("export.formats", ["usd", "usda", "usdc", "usdz", "obj", "ply", "stl", "abc"].map { "\($0)=\(MDLAsset.canExportFileExtension($0))" }.joined(separator: " "))
        // 3D model export on THIS phone: a synthetic 40 x 40 floor grid goes through decimation, ModelIO and USDZ writing, then is read back.
        do {
            var verts: [SIMD3<Float>] = [], idx: [UInt32] = []
            for z in 0...40 { for x in 0...40 { verts.append([Float(x) * 0.1, 0, Float(z) * 0.1]) } }
            for z in 0..<40 { for x in 0..<40 { let a = UInt32(z * 41 + x); idx += [a, a + 1, a + 41, a + 1, a + 42, a + 41] } }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("e2e-\(UUID().uuidString).usdz")
            defer { try? FileManager.default.removeItem(at: url) }
            let fitted = MeshDecimator.fit(IndexedMesh(vertices: verts, indices: idx), budgetBytes: 20_000, startCellSize: 0.1)
            try MeshExporter.writeUSDZ(fitted.mesh, to: url)
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            let scene = try? SCNScene(url: url, options: nil)
            var triangles = 0
            scene?.rootNode.enumerateHierarchy { node, _ in for e in node.geometry?.elements ?? [] { triangles += e.primitiveCount } }
            check("export.usdz", size > 0 && triangles > 0 && fitted.fitsBudget,
                  "\(size) bytes, \(triangles) triangles read back (from \(idx.count / 3), cell \(fitted.cellSize.map { String(format: "%.2f", $0) } ?? "none"))")
        } catch { fail("export.usdz", "\(error)") }

        // Size policy on THIS phone: a 51 MB scan file (over the 50 MB sharing limit) must save locally, be flagged local-only, and an INCOMING
        // bundle with the same file must still be refused.
        do {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("e2e-big-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let bigStore = MapStore(rootURL: root)
            let a = MapNode(kind: .corridor, position: [0, 0, 0], segmentId: "seg1"), b = MapNode(kind: .room, label: "Big Room", position: [3, 0, 0], segmentId: "seg1")
            let bigMap = BuildingMap(name: "E2E big scan", nodes: [a, b], edges: [MapEdge(from: a.id, to: b.id, distance: 3)])
            let big = Data(count: 51_000_000)
            try bigStore.saveLocalScan(map: bigMap, worldMap: big, segmentId: "seg1")
            let stored = (try? bigStore.loadWorldMap(mapId: bigMap.id, segmentId: "seg1"))?.count ?? 0
            check("share.overLimitSavesLocally", stored == 51_000_000 && bigStore.shareVerdict(mapId: bigMap.id).isLocalOnly,
                  "stored \(stored) bytes, verdict \(bigStore.shareVerdict(mapId: bigMap.id))")
            check("share.overLimitRefusedFromOutside", (try? MapBundle(map: bigMap, worldMaps: ["seg1": big]).validate()) == nil, "incoming bundle with a 51 MB scan is refused")
        } catch { fail("share.overLimit", "\(error)") }

        // ---- D. RESOURCES
        if let url = Bundle.main.url(forResource: "rice-hall-sample", withExtension: "json"),
           let sample = (try? Data(contentsOf: url)).flatMap({ try? BuildingMap.from(jsonData: $0) }) {
            check("resource.sampleMap", sample.nodes.count == 9, "\(sample.nodes.count) nodes")
        } else { fail("resource.sampleMap", "bundled sample map missing or undecodable") }

        // ---- F. ACCESSIBILITY: phone posture maths, the sentences users hear, and what Apple's image classifier can name on THIS phone
        func postureAt(_ pitch: Float, _ roll: Float) -> PostureReading {
            PostureMonitor.reading(cameraTransform: Geometry.cameraTransform(position: [0, 1.3, 0], forward: [0, 0, -1], pitchDegrees: pitch, rollDegrees: roll))
        }
        let upright = postureAt(0, 0), down = postureAt(-50, 0), lean = postureAt(0, 40)
        check("posture.math", abs(upright.pitchDegrees) < 1 && abs(upright.rollDegrees) < 1 && abs(down.pitchDegrees + 50) < 1 && abs(lean.rollDegrees - 40) < 1,
              "upright (\(Int(upright.pitchDegrees)),\(Int(upright.rollDegrees))) down (\(Int(down.pitchDegrees)),\(Int(down.rollDegrees))) lean (\(Int(lean.pitchDegrees)),\(Int(lean.rollDegrees)))")
        info("phrase.stop.wall", ObstacleSpeech.stop(ObstacleReport(kind: .wall, distanceMeters: 0.5)))
        info("phrase.stop.trashCan", ObstacleSpeech.stop(ObstacleReport(kind: .trashCan, distanceMeters: 0.5)))
        info("phrase.caution.chair", ObstacleSpeech.caution(ObstacleReport(kind: .chair, side: .left, distanceMeters: 1.4)))
        info("phrase.posture.tiltedDown", PostureIssue.tiltedDown.message)

        do {
            let identifiers = try VNClassifyImageRequest().supportedIdentifiers()
            check("vision.classify.vocabulary", !identifiers.isEmpty, "\(identifiers.count) labels")
            // Print the labels that could matter for walking indoors, grouped by the words we look for, so ObstacleLabelMapper can be tuned
            // against the REAL vocabulary of this phone (matching here is by whole word, like the mapper).
            let groups: [(String, [String])] = [
                ("trash", ["trash", "garbage", "waste", "rubbish", "bin", "litter", "dustbin"]),
                ("people", ["person", "people", "adult", "child", "baby", "man", "woman", "boy", "girl", "crowd", "pedestrian", "human"]),
                ("seating", ["chair", "stool", "bench", "sofa", "couch", "armchair", "wheelchair", "seat"]),
                ("furniture", ["table", "desk", "counter", "cabinet", "shelf", "bookcase", "dresser", "wardrobe", "refrigerator", "bed", "cart"]),
                ("structure", ["wall", "door", "doorway", "window", "glass", "stairs", "staircase", "escalator", "elevator", "ladder", "railing", "pillar", "column", "gate"]),
                ("objects", ["plant", "flower", "bicycle", "bike", "stroller", "luggage", "suitcase", "backpack", "box", "extinguisher", "fountain", "machine", "vending", "sign", "pole"]),
            ]
            for (name, words) in groups {
                let found = identifiers.filter { id in
                    let tokens = Set(id.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init))
                    return !tokens.isDisjoint(with: words)
                }
                info("vision.labels.\(name)", "\(found.count): \(found.prefix(40).joined(separator: ", "))")
            }
            // The classifier runs on this phone: a plain grey image should classify without error (the label itself is not meaningful).
            let grey = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: CGRect(x: 0, y: 0, width: 224, height: 224))
            let request = VNClassifyImageRequest()
            try VNImageRequestHandler(ciImage: grey, options: [:]).perform([request])
            check("vision.classify.run", true, "top: \(request.results?.first?.identifier ?? "-")")
        } catch { fail("vision.classify", "\(error)") }

        // ---- E. CLOUD (read-only; only when configured)
        if let config = SupabaseConfig.validated(urlString: Bundle.main.object(forInfoDictionaryKey: "SupabaseURL") as? String,
                                                 anonKey: Bundle.main.object(forInfoDictionaryKey: "SupabaseAnonKey") as? String) {
            let client = SupabaseClient(config: config, sessionStore: InMemorySessionStore())
            do {
                let s = try await client.ensureSession()
                pass("cloud.anonymousSignIn", "user \(s.userId.prefix(8))...")
                let rows = try await client.listBuildings()
                pass("cloud.listBuildings", "\(rows.count) visible row(s)")
            } catch { fail("cloud", "\(error)") }
            if NarrationSelfTest.requested {
                await NarrationSelfTest.run(client: SharedCloud.client ?? client) { name, ok, detail in check(name, ok, detail) }
            }
            // Opt-in WRITE test (two users, publish, share, extend, stale upload, reliability). See CloudRoundTripTest.
            if CloudRoundTripTest.requested {
                await CloudRoundTripTest.run(config: config) { name, ok, detail in check(name, ok, detail) }
            } else {
                skip("cloudrt", "write round-trip not requested (add -e2eCloudWrite YES to run it; it leaves one clearly named test building)")
            }
        } else {
            skip("cloud", "Supabase not configured (SUPABASE_URL / SUPABASE_ANON_KEY in Config/Local.xcconfig)")
            if NarrationSelfTest.requested {
                fail("narration.config", "the requested proxy test requires cloud configuration")
            }
        }

        return finish(tally)
    }

    private static func finish(_ t: Tally) -> Bool {
        line(t.fail == 0 ? "PASS" : "FAIL", "SUMMARY", "\(t.pass) passed, \(t.fail) failed, \(t.skip) skipped")
        return t.fail == 0
    }

    private static func line(_ level: String, _ name: String, _ detail: String) {
        fputs("[e2e] \(level) \(name)\(detail.isEmpty ? "" : " - \(detail)")\n", stderr)
    }
}
