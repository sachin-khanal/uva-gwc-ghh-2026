//
// File:     Waypoint/Guidance/Speaker.swift
// Owner:    B (Navigation/Feedback), used by U3's UI layer
// Purpose:  THE one voice of the app. Everything audible goes through here, so two parts of the app can never talk over each other.
//
// Why:      `SpeechGuide` (guidance) and `Announcer` (the new UI) each owned a synthesizer. Neither could see the other, and at arrival the user
//           heard two voices at once (reported on device 2026-10-17, D-026).
//
// Rules:    live in `SpeechGate` and `SpeechQueue` (WaypointCore), where they are unit-tested; this file is the AVFoundation / VoiceOver plumbing.
//
// VoiceOver (2026-10-18, D-046 - replaces the "VoiceOver reads its own, we speak ours" compromise of D-026):
//           * VoiceOver running (and Settings > "Speak through VoiceOver" on, the default): lines are POSTED AS VOICEOVER ANNOUNCEMENTS. Then there
//             is exactly one voice - the person's own VoiceOver voice at their own speed - and VoiceOver queues them itself, so it cannot be
//             talked over. `.critical` posts at VoiceOver's high priority (interrupts); everything else posts at low priority, i.e. joins VoiceOver's queue. Whether an announcement was actually
//             spoken comes back in `announcementDidFinishNotification`; one that was not (the person touched the screen, a newer one interrupted)
//             is reported as LOST so the planner says it again.
//           * VoiceOver running, route switched off: still AVSpeechSynthesizer, but with `prefersAssistiveTechnologySettings` (their voice + rate).
//           * VoiceOver off: AVSpeechSynthesizer with the voice from `VoiceSelection` (the phone's own default; the app's Siri pick only as a fallback).
//           Nothing here can PAUSE VoiceOver - iOS offers no such API; the answer is to speak through it.
//
// Lost lines: a line that is displaced, expires, or is cut off is never dropped quietly. `onLineLost` tells the owner (NavigationController ->
//           `FeedbackPlanner.lineLost`), because the planner records a cue as announced the moment it makes it.
//
// Threading: main thread only (all callers are already on it).
// Status:   SCAFFOLD, UNVERIFIED ON DEVICE (needs a phone with VoiceOver on AND off, and headphones).
//
import AVFoundation
import UIKit
import WaypointCore

final class Speaker: NSObject {

    static let shared = Speaker()

    /// A line was thrown away before the person heard all of it. Called with the exact text that was passed to `say`.
    var onLineLost: ((String) -> Void)?

    private let synthesizer = AVSpeechSynthesizer()
    private var gate = SpeechGate()
    /// At most ONE line waits its turn, and it is always the most important one offered (see `SpeechQueue`).
    private var queue = SpeechQueue()
    /// Priority of the line being spoken right now, so `SpeechGate` can keep one safety cue from cutting off another. nil when quiet.
    private var speakingPriority: SpeechPriority?

    /// Utterances in flight, by identity: `didCancel` can arrive AFTER the next line has started, and must not be mistaken for it.
    private var inFlight: [ObjectIdentifier: (text: String, priority: SpeechPriority)] = [:]
    private var currentUtterance: AVSpeechUtterance?

    /// The VoiceOver announcement we are waiting to finish, if any.
    private var announcing: (text: String, priority: SpeechPriority)?
    private var announcementWatchdog: DispatchWorkItem?

    private override init() {
        super.init()
        synthesizer.delegate = self
        NotificationCenter.default.addObserver(self, selector: #selector(announcementFinished(_:)),
                                               name: UIAccessibility.announcementDidFinishNotification, object: nil)
    }

    /// Monotonic clock: unaffected by the wall clock changing mid-demo.
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    private var isBusy: Bool { synthesizer.isSpeaking || announcing != nil }

    /// Speak through VoiceOver's own queue rather than beside it.
    private var viaVoiceOver: Bool { UIAccessibility.isVoiceOverRunning && UIPrefs.speakViaVoiceOverEnabled }

    // MARK: Voice

    private static let candidates: [VoiceCandidate] = AVSpeechSynthesisVoice.speechVoices().map {
        VoiceCandidate(identifier: $0.identifier, name: $0.name, language: $0.language, quality: $0.quality.rawValue)
    }

    /// Decided per line (cheap): VoiceOver can be switched on or off while the app runs.
    private static func voiceDecision() -> VoiceDecision {
        let language = AVSpeechSynthesisVoice.currentLanguageCode()
        return VoiceSelection.choose(source: UIPrefs.guidanceVoiceSource,
                                     voiceOverRunning: UIAccessibility.isVoiceOverRunning,
                                     phoneDefaultResolvable: AVSpeechSynthesisVoice(language: language) != nil,
                                     candidates: candidates, language: language)
    }

    private static var loggedVoice = false

    /// For the on-phone self test: what the next spoken line would use.
    static var voiceDescription: String {
        let d = voiceDecision()
        if d.useAssistiveSettings { return "VoiceOver's own voice and rate (VoiceOver is on)" }
        guard let id = d.voiceIdentifier, let v = AVSpeechSynthesisVoice(identifier: id) else { return "this iPhone's default voice (no voice set on the utterance)" }
        return "app pick: \(v.name) [\(v.language), quality \(v.quality.rawValue)]"
    }

    // MARK: Saying things

    /// - Parameters:
    ///   - staysFresh: the opening briefing - not thrown away as stale, and only displaced by another such line.
    ///   - userRequested: the PERSON asked for this (repeat, distance). Never swallowed as a duplicate.
    func say(_ text: String, priority: SpeechPriority, staysFresh: Bool = false, userRequested: Bool = false) {
        switch gate.decide(text: text, priority: priority, isSpeaking: isBusy, now: now,
                           speakingPriority: speakingPriority, allowRepeat: userRequested) {
        case .drop:
            return
        case .interrupt:
            // Safety only - and what is waiting is KEPT: it used to be discarded, which silenced route guidance completely in a cluttered
            // room (F-1, F-7, 2026-10-18). The line being cut off is reported lost by `didCancel` / the announcement result, so it is said again.
            synthesizer.stopSpeaking(at: .immediate)
        case .enqueue:
            if let lost = queue.hold(text: text, priority: priority, now: now, staysFresh: staysFresh) {
                Log.guidance.info("not spoken (displaced or outranked): \(lost.text)")
                onLineLost?(lost.text)
            }
            return
        case .speak:
            break
        }
        speakNow(text, priority: priority)
    }

    private func speakNow(_ text: String, priority: SpeechPriority) {
        speakingPriority = priority
        if viaVoiceOver {
            announce(text, priority: priority)
        } else {
            speakWithSynthesizer(text, priority: priority)
        }
        Log.guidance.info("say: \(text)")
    }

    private func speakWithSynthesizer(_ text: String, priority: SpeechPriority) {
        let utterance = AVSpeechUtterance(string: text)
        let decision = Self.voiceDecision()
        utterance.prefersAssistiveTechnologySettings = decision.useAssistiveSettings
        if !decision.useAssistiveSettings {
            // nil identifier = leave the voice unset, so iOS uses the voice this iPhone is set up with.
            utterance.voice = decision.voiceIdentifier.flatMap { AVSpeechSynthesisVoice(identifier: $0) }
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        }
        // A short pause after each line so two queued cues do not run together as one sentence.
        utterance.postUtteranceDelay = 0.25
        if !Self.loggedVoice {
            Self.loggedVoice = true
            Log.guidance.info("voice: assistive=\(decision.useAssistiveSettings) id=\(decision.voiceIdentifier ?? "phone default")")
        }
        inFlight[ObjectIdentifier(utterance)] = (text, priority)
        currentUtterance = utterance
        synthesizer.speak(utterance)
    }

    // MARK: VoiceOver route

    private func announce(_ text: String, priority: SpeechPriority) {
        var line = AttributedString(text)
        // iOS 17 priorities: `.high` interrupts what VoiceOver is saying and cannot itself be interrupted (exactly the safety contract: a stop warning
        // is not cut off by the next one); `.low` is QUEUED and spoken when VoiceOver is free. `.default` would interrupt, so it is never used.
        line.accessibilitySpeechAnnouncementPriority = (priority == .critical) ? .high : .low
        announcing = (text, priority)
        AccessibilityNotification.Announcement(line).post()

        // If the "finished" notification never comes (VoiceOver switched off mid-line), do not stay busy forever.
        announcementWatchdog?.cancel()
        let watchdog = DispatchWorkItem { [weak self] in self?.announcementEnded(text: text, success: true) }
        announcementWatchdog = watchdog
        DispatchQueue.main.asyncAfter(deadline: .now() + max(4, Double(text.count) * 0.12 + 2), execute: watchdog)
    }

    @objc private func announcementFinished(_ note: Notification) {
        let text = note.userInfo?[UIAccessibility.announcementStringValueUserInfoKey] as? String
        let ok = note.userInfo?[UIAccessibility.announcementWasSuccessfulUserInfoKey] as? Bool ?? true
        DispatchQueue.main.async { [weak self] in
            guard let text else { return }
            self?.announcementEnded(text: text, success: ok)
        }
    }

    private func announcementEnded(text: String, success: Bool) {
        if !success { onLineLost?(text) } // the person touched the screen, or a newer announcement cut it off
        guard let current = announcing, current.text == text else { return } // an older one that was interrupted: nothing else to do
        announcing = nil
        announcementWatchdog?.cancel()
        speakingPriority = nil
        speakPendingIfFresh()
    }

    // MARK: Queue

    /// Speaks whatever is waiting, if it is still worth saying.
    private func speakPendingIfFresh() {
        let next = queue.next(now: now)
        if let lost = next.lost {
            Log.guidance.info("dropped stale line: \(lost.text)")
            onLineLost?(lost.text)
        }
        if let line = next.speak { speakNow(line.text, priority: line.priority) }
    }

    func stop() {
        queue.clear()
        speakingPriority = nil
        // Forget in-flight lines BEFORE cancelling, so the cancel is not reported as a loss: stopping is deliberate.
        inFlight.removeAll()
        currentUtterance = nil
        announcing = nil
        announcementWatchdog?.cancel()
        synthesizer.stopSpeaking(at: .immediate)
        gate.reset()
    }
}

extension Speaker: AVSpeechSynthesizerDelegate {

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        inFlight[ObjectIdentifier(utterance)] = nil
        guard utterance === currentUtterance else { return }
        currentUtterance = nil
        speakingPriority = nil
        speakPendingIfFresh()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        // Cancelled by a safety interrupt (stop() clears `inFlight` first, so a deliberate stop never lands here). Whatever was waiting is KEPT
        // (see `say`); the line that was cut off is reported so the planner can say it again if it still applies.
        let cut = inFlight.removeValue(forKey: ObjectIdentifier(utterance))
        if utterance === currentUtterance {
            currentUtterance = nil
            speakingPriority = nil
        }
        if let cut { onLineLost?(cut.text) }
    }
}
