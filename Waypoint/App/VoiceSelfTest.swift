// File:     Waypoint/App/VoiceSelfTest.swift
// Owner:    B (Guidance) with D (device self-tests).
// Purpose:  Opt-in audible integration checks through the actual singleton Speaker and OS callbacks.
// Run:      -autoE2E YES -e2eVoice YES; keep phone unlocked and listen to the phrases.
// Design:   Main actor; restores observers and stops test speech. Never changes persistent voice settings.
// Status:   VoiceOver-OFF phone checks PASS; user confirmed clear output. VoiceOver ON remains unverified.
import AVFoundation
import UIKit
import WaypointCore

@MainActor
enum VoiceSelfTest {
    static var requested: Bool { UserDefaults.standard.bool(forKey: "e2eVoice") }

    static func run(report: (String, Bool, String) -> Void) async {
        let speaker = Speaker.shared
        let previousObserver = speaker.onSpeechEvent, previousLost = speaker.onLineLost
        var events: [(String, String, TimeInterval)] = [], lost: [String] = []
        speaker.stop()
        speaker.onSpeechEvent = { event in
            let name: String, text: String
            switch event {
            case .started(let t): name = "start"; text = t
            case .finished(let t): name = "finish"; text = t
            case .cancelled(let t): name = "cancel"; text = t
            case .announcementPosted(let t): name = "posted"; text = t
            case .announcementFinished(let t, let ok): name = ok ? "announced" : "announcementLost"; text = t
            }
            events.append((name, text, ProcessInfo.processInfo.systemUptime))
            Log.guidance.info("voice-test \(name): \(text)")
        }
        speaker.onLineLost = { lost.append($0) }
        defer {
            speaker.stop()
            speaker.onSpeechEvent = previousObserver
            speaker.onLineLost = previousLost
        }
        func has(_ kind: String, _ text: String) -> Bool { events.contains { $0.0 == kind && $0.1 == text } }
        func wait(_ kind: String, _ text: String, seconds: Double = 18) async -> Bool {
            let deadline = ProcessInfo.processInfo.systemUptime + seconds
            while ProcessInfo.processInfo.systemUptime < deadline {
                if has(kind, text) { return true }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            return false
        }
        func ordered(_ first: String, _ a: String, _ second: String, _ b: String) -> Bool {
            guard let i = events.firstIndex(where: { $0.0 == first && $0.1 == a }),
                  let j = events.firstIndex(where: { $0.0 == second && $0.1 == b }) else { return false }
            return i < j
        }
        let audio = AVAudioSession.sharedInstance()
        report("voice.outputVolume", audio.outputVolume > 0, "volume=\(audio.outputVolume); route=\(audio.currentRoute.outputs.map { $0.portType.rawValue })")

        if UIAccessibility.isVoiceOverRunning && UIPrefs.speakViaVoiceOverEnabled {
            let phrase = "VoiceOver integration test. Room 206 is on your left."
            speaker.say(phrase, priority: .high)
            let completed = await wait("announced", phrase, seconds: 30)
            report("voice.voiceOver.finished", completed, "requires a real announcement completion notification, not the watchdog")
            report("voice.voiceOver.noSynthesizer", !has("start", phrase), "app did not speak beside VoiceOver")
            return
        }

        if let client = SharedCloud.client {
            _ = try? await client.ensureSession()
            let fact = NarrationFact(kind: .landmark, plain: "Room 206 on your left.")
            let rich = await ProxyNarrator(caller: client).narrate(fact)
            report("voice.gemini.accepted", rich != nil, "live proxy reply must pass the app guard")
            let phrase = rich ?? fact.plain
            speaker.say(phrase, priority: .high)
            let done = await wait("finish", phrase)
            report("voice.gemini.spokenToCompletion", done && has("start", phrase), "real AVSpeechSynthesizer didStart and didFinish for accepted text")
        } else { report("voice.gemini.config", false, "cloud configuration required") }

        speaker.stop(); events.removeAll(); lost.removeAll()
        let turn = "Turn right.", resume = "Continue straight."
        speaker.say(turn, priority: .high)
        _ = await wait("start", turn)
        speaker.say(resume, priority: .high)
        let resumed = await wait("finish", resume)
        report("voice.queue.afterTurn", resumed && ordered("finish", turn, "start", resume), "both directions finished in order")

        speaker.stop(); events.removeAll(); lost.removeAll()
        let long = "Voice interruption test. Walk straight along this hallway toward the next room. Keep listening to this longer sentence until the safety test interrupts it."
        let stop = "Stop. Obstacle ahead.", recovery = "The voice test is continuing."
        speaker.say(long, priority: .high)
        _ = await wait("start", long)
        try? await Task.sleep(nanoseconds: 400_000_000)
        speaker.say(stop, priority: .critical)
        _ = await wait("start", stop)
        speaker.say(recovery, priority: .high, staysFresh: true)
        let recovered = await wait("finish", recovery)
        report("voice.safety.interrupt", has("cancel", long) && lost.contains(long) && has("finish", stop), "OS cancelled the long line, reported loss, and finished STOP")
        report("voice.safety.recovery", recovered && ordered("finish", stop, "start", recovery), "queued guidance finished after STOP")

        speaker.stop(); events.removeAll(); lost.removeAll()
        let first = "Stop. A wall is directly ahead.", second = "Stop. A person is ahead."
        speaker.say(first, priority: .critical)
        _ = await wait("start", first)
        speaker.say(second, priority: .critical)
        let both = await wait("finish", second)
        report("voice.safety.noStopStutter", both && ordered("finish", first, "start", second) && !has("cancel", first), "two safety sentences completed without interrupting each other")

        speaker.stop(); events.removeAll(); lost.removeAll()
        let stale = "In 3 meters, you will arrive.", arrival = "You have arrived. Voice arrival test complete."
        speaker.say(long, priority: .high)
        _ = await wait("start", long)
        speaker.say(stale, priority: .high)
        speaker.say(arrival, priority: .critical, clearsQueue: true)
        let arrived = await wait("finish", arrival)
        try? await Task.sleep(nanoseconds: 400_000_000)
        report("voice.arrival.clearsStale", arrived && !has("start", stale), "arrival completed; stale countdown never started")

        speaker.stop(); events.removeAll()
        let sample = "Room 206 on your left. In 5 meters, turn right."
        var durations: [Double] = []
        for factor in [0.8, 1.4] {
            events.removeAll()
            speaker.preview(sample, voiceIdentifier: nil, factor: factor)
            let done = await wait("finish", sample)
            let start = events.first { $0.0 == "start" && $0.1 == sample }?.2
            let end = events.first { $0.0 == "finish" && $0.1 == sample }?.2
            report("voice.preview.\(factor)", done && start != nil, "preview finished through the same synthesizer")
            if let start, let end { durations.append(end - start) }
        }
        report("voice.preview.speed", durations.count == 2 && durations[1] < durations[0], "measured durations=\(durations)")
        if let row = Speaker.voiceRows.first {
            events.removeAll()
            let text = "This is the installed voice selection test."
            speaker.preview(text, voiceIdentifier: row.identifier, factor: 1)
            let done = await wait("finish", text)
            report("voice.preview.installedVoice", done && has("start", text), "\(row.title): actual preview completed")
        }
    }
}
