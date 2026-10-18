// File:     Waypoint/App/NarrationSelfTest.swift
// Owner:    B (Guidance) with D (on-device self-tests).
// Purpose:  Opt-in phone -> Supabase -> Gemini -> app guard checks, plus deterministic failure paths
//           through the same ProxyNarrator. Run with -autoE2E YES -e2eNarration YES.
// Design:   Live calls use SharedCloud's authenticated client; fault callers never change server settings.
//           No keys, tokens, images, map IDs or real place names are logged or sent by this test.
// Status:   Automated phone checks PASS (see WORKLOG); audible quality remains UNVERIFIED ON DEVICE.
import Foundation
import WaypointCore

enum NarrationSelfTest {
    static var requested: Bool { UserDefaults.standard.bool(forKey: "e2eNarration") }

    @MainActor
    static func run(client: SupabaseClient, report: (String, Bool, String) -> Void) async {
        do { _ = try await client.ensureSession() }
        catch { report("narration.auth", false, "could not sign in"); return }

        let facts = [
            NarrationFact(kind: .landmark, plain: "Room 206 on your left."),
            NarrationFact(kind: .countdown, plain: "In 10 meters, turn right."),
            NarrationFact(kind: .briefing, plain: "Walk straight about 12 meters.")
        ]
        let proxy = ProxyNarrator(caller: client)
        var accepted = 0
        for fact in facts {
            let start = ProcessInfo.processInfo.systemUptime
            if let text = await proxy.narrate(fact) {
                accepted += 1
                report("narration.live.\(fact.kind.rawValue)", NarrationGuard.accept(text, for: fact) == text,
                       "accepted in \(Int((ProcessInfo.processInfo.systemUptime - start) * 1000)) ms: \(text)")
            } else {
                // An individual refusal/timeout is allowed; a wholly broken live path fails the aggregate below.
                Log.guidance.info("narration self-test: \(fact.kind.rawValue) used plain fallback")
            }
        }
        report("narration.live.accepted", accepted > 0, "\(accepted)/\(facts.count) accepted within the app deadline")

        do {
            _ = try await client.callFunction("narrate", json: Data(#"{"kind":"turn","sentence":"Turn left."}"#.utf8))
            report("narration.invalidKind", false, "server accepted a forbidden kind")
        } catch CloudError.http(let status, _) {
            report("narration.invalidKind", status == 400, "HTTP \(status)")
        } catch { report("narration.invalidKind", false, "request failed before input validation") }

        let fact = facts[0]
        let faults: [(String, FaultCaller)] = [
            ("offline", FaultCaller(mode: .offline)),
            ("server503", FaultCaller(mode: .server)),
            ("null", FaultCaller(mode: .reply(#"{"text":null}"#))),
            ("malformed", FaultCaller(mode: .reply("not JSON"))),
            ("unsafeDirection", FaultCaller(mode: .reply(#"{"text":"Room 206 on your left, then turn right."}"#)))
        ]
        for (name, caller) in faults {
            let result = await ProxyNarrator(caller: caller).narrate(fact)
            report("narration.fallback.\(name)", result == nil && (result ?? fact.plain) == fact.plain,
                   "injected fault returns the original sentence")
        }
        let start = ProcessInfo.processInfo.systemUptime
        let timed = await ProxyNarrator(caller: FaultCaller(mode: .slow), timeout: 0.1).narrate(fact)
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        report("narration.fallback.timeout", timed == nil && elapsed < 1,
               "injected slow request cancelled in \(Int(elapsed * 1000)) ms")
    }

    private struct FaultCaller: FunctionCaller {
        enum Mode: Sendable { case offline, server, slow, reply(String) }
        let mode: Mode

        func callFunction(_ name: String, json body: Data) async throws -> Data {
            switch mode {
            case .offline: throw URLError(.notConnectedToInternet)
            case .server: throw CloudError.http(status: 503, message: "injected test failure")
            case .slow: try await Task.sleep(nanoseconds: 10_000_000_000); return Data()
            case .reply(let text): return Data(text.utf8)
            }
        }
    }
}
