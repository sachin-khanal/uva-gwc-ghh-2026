# Work log

## 2026-10-18 16:30 — Claude (agent, for Sachin) — First on-phone run with the real Floor 4 map: lost-line ping-pong and a stale post-arrival line found and fixed   [tags: BUG]
Area: B. Branch `feature/guidance-overhaul`. Phone: Sachin's iPhone 16 Pro Max (unlocked, `make build install` of this branch; maps backed up first by `make install`/`make uitest`). Map: "Rice Hall · Floor 4" (17 nodes, 409/410/411).
Found on the phone (`make selftest-sim ROOM=409`): (1) my lost-line re-arm ping-ponged - with the voice busy, "Continue straight." and "In 5 meters, turn right." displaced each other and each loss re-armed the cue every tick: 58 "not spoken" lines in one 12 s walk. (2) "In 3 meters, you will arrive at 409." was spoken AFTER "You have arrived at 409." (a waiting line survived the arrival interrupt).
Fixed: `LossThrottle` (core, `Guidance/SpeechQueue.swift`): a line comes back at most once per 3 s; `NavigationController` uses it; arrival calls `Speaker.say(..., clearsQueue: true)` (also `SpeechGuide`). Files edited: `Guidance/SpeechQueue.swift`, `GuidanceOverhaulTests.swift` (+2 tests), `Guidance/Speaker.swift`, `Guidance/SpeechGuide.swift`, `Navigation/NavigationController.swift`. After the fix the same walk: 12 not-spoken lines (was 58), nothing after arrival.
Verified: `make test` -> 398 tests, 0 failures; `make typecheck` OK; on the phone: `make selftest-e2e` -> 25 passed, 0 failed, 1 skipped (cloud write not requested), voice line "this iPhone's default voice"; `make selftest-sim ROOM=409` -> SELFTEST PASS (before and after the fix); the app really called Gemini from the phone: log "narrated: 410 on your left. -> Just passing 410 on your left." (gemini-3.5-flash-lite; two countdowns came back identical to the plain text).
UI tests (`make uitest`, 11 tests): as installed, 7 pass / 4 fail with "SAMPLE map not listed" (they need the bundled sample map, which no longer exists on the phone - the fix is e44a288 on `feature/web-mesh-obj`, not in this branch's base). With that commit's `WaypointUITests.swift` + `NavigatorView.swift` applied TEMPORARILY (reverted, not committed): 10 pass / 1 fail. The failure, `testObstacleIsNamedByTypeInTheSpokenSentence`, times out waiting for the "wall" sentence after the obstacle TYPE is changed while the walker is paused; the likely cause is navigation-overhaul d8afcf1 (a change of obstacle kind is ignored when the user is not moving). NOT confirmed by running the test on the base build.
NOT verified: how anything sounds (nobody listened); VoiceOver ON (the phone ran with VoiceOver off, so the announcement route has not run); a REAL walk on Floor 4 (everything above is the simulated walker); Gemini on cellular.
Limits of the test itself: the simulated walker does not stop for the ~10 s opening briefing as a real person would, so on this 9 m route it reaches the corner before the briefing finishes and the turn cues are mostly never said; judge turn timing on a real walk, not on `selftest-sim`.
Open problems / handoff: (1) merge `feature/web-mesh-obj` (or cherry-pick e44a288) before relying on `make uitest`; update `testObstacleIsNamedByType...` for the standing-user rule. (2) Do the real walk on Floor 4 with headphones: TESTING G1-G9, VoiceOver on and off. (3) Briefing length: it covers ~11 m of walking at 1.4 m/s - consider shortening.

## 2026-10-18 15:25 — Claude (agent, for Sachin) — Narration guard: adverb excuse narrowed to "right there/here/now" (automated security review)   [tags: BUG]
Area: B. Branch `feature/guidance-overhaul`. Finding (MEDIUM, valid): the 15:10 fix excused "right" before 14 words, including at/by/after/on/in/next, so "keep right after the door" passed a left-only landmark. Now only "right there / here / now" are excused (the three that cannot start a direction). Files edited: `Guidance/Narration.swift`, `GuidanceOverhaulTests.swift` (6 new rejects). Not done (suggested alternative): requiring the direction-word multiset to match exactly - stricter than needed; the added-word rule plus must-keep already covers it.
Verified: `make test` -> 396 tests, 0 failures. NOT verified: on device; live Gemini beyond the two sentences of 15:10.
Open problems / handoff: none new.

## 2026-10-18 15:10 — Claude (agent, for Sachin) — First LIVE Gemini call: works; guard falsely rejected "right there"; default model now gemini-3.5-flash-lite   [tags: BUG]
Area: B. Branch `feature/guidance-overhaul`. With the key Sachin put in `Config/Local.xcconfig` (read inside a shell command, never printed or committed) I called the real API with the app's exact system prompt. `gemini-3.5-flash-lite`: HTTP 200 in 0.80 s and 0.64 s. "Room 206 on your left." -> "Room 206 is right there on your left."; "In 10 meters, turn right." -> "In 10 meters, please turn right." The key also lists gemini-3.5/3.6/3.7/3.8-flash, 3.1-flash-lite and 2.5 models.
Bug found by the live reply: the 14:05 guard treated the adverb in "right there" as an ADDED direction and would have rejected the first reply (every landmark would have fallen back to plain). Fixed: `NarrationText.withoutAdverbRight` excuses only the fixed phrases "right there/here/now/next/away/in/at/on/by/over/up/after/before/around"; a bare "right" still counts. Default `GeminiConfig.defaultModel` -> `gemini-3.5-flash-lite` (was the 2.5 model Google has restricted). Files edited: `Guidance/Narration.swift`, `GuidanceOverhaulTests.swift` (+1 test with the real replies).
Verified: `make test` -> 396 tests, 0 failures; live API call as above (curl, not the app).
NOT verified: the app itself calling Gemini on a phone; the 1.5 s deadline margin on cellular (0.64-0.80 s on this Mac's network); wording quality beyond two sentences; free-tier daily quota; thinking-setting behaviour on the 3.x models (no `thinkingConfig` is sent for them; latency was fine without).
Open problems / handoff: run TESTING G8/G9 on the phone; a `make narration-eval` over ~30 sentences and 2-3 models is still unbuilt.

## 2026-10-18 14:05 — Claude (agent, for Sachin) — Narration guard: a rewrite may not ADD a direction or an order (automated security review)   [tags: BUG]
Area: B. Branch `feature/guidance-overhaul`. Finding (MEDIUM, valid): `NarrationGuard.accept` only required the plain sentence's direction words to SURVIVE; a rewrite could still append "then turn left" / "stop here". Fixed: any whole word from `instructionVocabulary` (left, right, ahead, behind, straight, back, around, turn, stop, go, forward, backward, up, down) in the rewrite must already be in the plain sentence. Deliberately conservative (a false reject only costs the plain sentence). Files edited: `Guidance/Narration.swift`, `GuidanceOverhaulTests.swift` (+1 test).
Second finding (MEDIUM, key in the app bundle via `GeminiApiKey` in project.yml): acknowledged, not changed - already surfaced to Sachin and written in D-046 §5 / Narration.swift header: acceptable for our own phones only; a Supabase edge function (auth + rate limit) must replace it before any build leaves the team. Not built yet.
Verified: `make test` -> 395 tests, 0 failures. NOT verified: on device; live Gemini.
Open problems / handoff: build the Gemini proxy edge function before any public build.

## 2026-10-18 13:40 — Claude (agent, for Sachin) — Guidance voice overhaul: VoiceOver-aware single voice, no silently lost lines, optional Gemini wording   [tags: BUG, BUILD]
Area: B (Guidance), touching U3's Settings/GuidingView/Announcer and the E2E self-test line that printed the voice. Branch `feature/guidance-overhaul`, cut from `origin/navigation-overhaul` (d8afcf1), NOT from `main`: `main` lacks d8afcf1 (the "Speak the turn" speech fix).
Why: Sachin asked for (1) testing + review of the voice/guidance state, (2) obstacle-vs-voice priority checked, (3) Gemini for richer guidance with fallback to the manual wording, (4) no overlap with Apple VoiceOver (issue #10), (5) the iPhone's own voice first, the app's Siri pick only as fallback. Design in D-046.
Files created: core `Guidance/SpeechQueue.swift`, `Guidance/Narration.swift`, `Guidance/VoiceSelection.swift`; test `GuidanceOverhaulTests.swift` (40 tests).
Files edited: core `Guidance/SpeechGate.swift` (`allowRepeat`), `Guidance/FeedbackPlanner.swift` (`lineLost`, `info(for:)`, `Rearm`/`LineInfo`, narration eligibility); app `Guidance/Speaker.swift` (rewritten: SpeechQueue, VoiceOver announcements, `prefersAssistiveTechnologySettings`, lost-line callback, utterance identity), `Guidance/SpeechGuide.swift`, `Navigation/NavigationController.swift` (Gemini hook, lost-line wiring), `Services/Announcer.swift` (interrupt now interrupts), `Services/ServiceMode.swift` (3 prefs), `UI/SettingsView.swift` (Voice and wording section), `UI/Navigator/GuidingView.swift` (removed `.updatesFrequently`), `App/E2ESelfTest.swift` (one line: `Speaker.voice` no longer exists, now `Speaker.voiceDescription` - a compile fix in another owner's file), `project.yml` + `Config/Local.xcconfig.example` (GeminiApiKey/GeminiModel); docs DECISIONS (D-046, Update under D-026), MODULES, TESTING (G1-G9).
Files deleted: none.
Commands run: `make test` (baseline on d8afcf1: 354 pass; after: 394), `make gen`, `make typecheck`, `make check`.
Findings from the review that are FIXED here: (a) the planner latched a cue the speaker then dropped -> the cue never came back (root cause of F-1/F-5/F-7); (b) `Announcer.say(interrupt: true)` queued instead of interrupting, and its repeats were swallowed by the 3 s duplicate filter; (c) `GuidingView`'s `.updatesFrequently` made VoiceOver re-read every instruction on top of the app's own voice; (d) `didCancel` of an old utterance could clear the priority of the NEW one (race), letting one safety line cut off another; (e) `NarrationText.clean` glued words together across a newline (caught by a test).
Verified: `make test` -> 394 tests, 0 failures; `make typecheck` -> OK (64 app files, 1 UI test file); `make check` -> BUILD SUCCEEDED (unsigned). Gemini wire format, key-in-header, timeout, every failure mode, the guard rules and the circuit breaker are tested against a fake transport.
NOT verified (all UNVERIFIED ON DEVICE): that anything is audible or sounds right; VoiceOver announcements (priority semantics were read from the iOS 17 headers, never heard; `announcementDidFinishNotification` behaviour with `.low` is assumed); that a voice-less utterance resolves to the person's Spoken Content voice; the LIVE Gemini API (no key was available; model id `gemini-2.5-flash` and the `thinkingConfig` field were not checked against the real endpoint); latency of a rewrite on a phone; Gemini sentence quality; the haptics/beacon (untouched).
Open problems / handoff: (1) Anmol owns Speaker/NavigationController/FeedbackPlanner - tell them before merging; `map-extension`/`stairs-multifloor` also edit NavigationController+FeedbackPlanner and will conflict at the `plan(...)` call and the `perform` loop. (2) The key lives in the app bundle: own phones only; build the Supabase edge-function proxy before any public build. (3) Rewritten opening can delay the briefing up to 1.5 s (deadline) - listen for whether that feels long. (4) Not done: beacon ducking under speech, distance-scaled ping, arrival chime, audio-session interruption handling (call / AirPods route change), speech-rate setting when VoiceOver is off. (5) `.env.local` and `.mcp.json` are untracked in this checkout and NOT part of this change; never `git add -A`.

## 2026-10-18 — Claude (agent, for Anmol) — The way-round advisor was reading a sensor window too narrow to see sideways   [tags: BUG]
Area: B (navigation/feedback) / C (vision wiring). Branch `navigation-overhaul`.
Anmol, after the F-5 fix shipped: "when facing a wall / very close to a chair, it just says stop rather than how
to get around it". The F-5 fix was therefore INCOMPLETE - the advice was reaching the speaker fine, but the
advisor almost never had a side to suggest.

FOUND: there are TWO independent measurements of how much room is on each side, and the advisor was wired to the
wrong one.
  * `DepthHit.clearance`, built in `ObstacleDetector.centerHit`, only samples the middle 28 % of the frame
    (`corridorRowFractions = 0.36...0.64`) and splits left/right at +/-0.35 m lateral. That band is barely wider
    than the "ahead" corridor itself, so `left`/`right` came back nil or near-identical.
  * `SceneContext`, built in `ObstacleDetector.sideClearances`, scans the FULL width (rows 0.05...0.95) and
    records how far the nearest thing on each side is from the centre line.
`AvoidanceAdvisor` was fed the first. With both sides equal, `betterDistance - otherDistance` was ~0, never
reaching `decisiveMargin` (0.6), so `advise` returned nil nearly every time and the user got "Stop." (and, since
the earlier fix, "Back up slowly.") but never "Slightly left".
Fixed: `Waypoint/Navigation/NavigationController.swift` now builds the advisor's `Clearance` from `sceneContext`
(wide scan) with `ahead` still from the centre hit. `AvoidanceAdvisor` itself is unchanged - its thresholds
(`minimumUsable` 1.2 m, `decisiveMargin` 0.6 m) only ever made sense against a real sideways measurement, which
is what they now get.

Also checked this block, at Anmol's request (F-4, relocalization coaching): the good spoken coaching line
("Starting guidance to X. Finding your position. Slowly turn left and right.") exists at
`NavigatorModel.swift:103` - but that is the NEW Navigator UI flow. The recorded walk's "Navigating." at 0:05
comes from `NavigationController.swift:264`, a DIFFERENT flow, so `NavigatorModel`'s line never played. On the
flow actually in use the spoken coaching is the planner's new "Finding your position. Stand still, then turn
slowly.", which had not been installed at the time of Anmol's report. It is said ONCE; if relocalization drags
there is then silence. Not changed.

Verified: `make test` -> **354 tests, 0 failures**. `make typecheck` OK (64 app files). `make check` ->
BUILD SUCCEEDED. Built, signed and installed on Anmol's iPhone 15 Pro (the first install to carry the
"Stop. Stop. Stop." fixes, which had failed to install earlier when the phone dropped off).
NOT verified: UNVERIFIED ON DEVICE. Whether the wide scan actually produces a decisive side in a real hallway is
exactly the open question - `minimumUsable = 1.2 m` of sideways room is a lot in a narrow corridor, so the
likely remaining failure is still falling through to "Back up slowly." where a human would step aside.
Open / handoff: F-3 (the on-route tolerance) is UNDECIDED and needs Anmol's observation: are the label offsets
mostly at doors/rooms (widen `ArrivalRadius` only - no regression risk) or systematic along the route (must
loosen `rerouteMeters`, which re-opens the "did not recalculate until I was very far off" complaint that caused
it to be tightened 5 -> 3). `maxOffRouteMeters` (8) is NOT that knob: it only guards the progress projection and
is near-dead because the 3 m re-route fires first.

---

## 2026-10-18 — Claude (agent, for Anmol) — "Stop. Stop. Stop. Stop." then the sentence: classifier flicker + safety cues cutting each other off   [tags: BUG]
Area: B (navigation/feedback). Branch `navigation-overhaul`. Device report by Anmol after the F-1/F-7 fixes
landed ("amazing fix, but sometimes it'll say Stop Stop Stop Stop then finish the sentence").

CAUSE 1 - the warning was re-issued every tick. `FeedbackPlanner` re-announces an obstacle when the LEVEL or the
KIND changes. Standing in front of one wall, the classifier flickers (wall -> unknown -> table -> wall) and each
flip read as a brand new obstacle. `lastObstacleKind` is updated every tick, so an A/B/A/B flicker produces a
"change" every single tick.
CAUSE 2 - each re-issue cut off the one before it. A STOP is `.critical`, which means interrupt, so warning n+1
silenced warning n after the word "Stop" - hence four stubs and only the last one reaching the part that says
what the hazard actually is.

Fixed (Anmol's own diagnosis: if the person has not moved, a new obstacle cannot have appeared):
* `Package/.../Guidance/FeedbackPlanner.swift`: a change of KIND now only counts as news while `isMoving`.
  Standing still, a different answer from the classifier is noise. A change of LEVEL is deliberately NOT gated -
  an escalation to STOP must still be announced to a stationary user, which is the "somebody walks into your
  path" case (covered by a test).
* `Waypoint/Navigation/NavigationController.swift`: `isMoving` was TRANSLATION ONLY, so a user pivoting on the
  spot counted as still - and they are not, because the camera then sees a genuinely different scene and a new
  obstacle really can appear. `updateMovement` now samples camera YAW as well and treats >= 25 deg/s as moving
  (shortest way round the circle, so crossing +/-pi is not read as a spin). Anmol asked for "gyroscope for
  left/right turn"; the ARKit camera yaw gives exactly that with no CoreMotion and no `NSMotionUsageDescription`,
  which the existing comment on this function explicitly set out to avoid.
* `Package/.../Guidance/SpeechGate.swift` + `Waypoint/Guidance/Speaker.swift`: safety interrupts GUIDANCE, never
  another safety line. `decide` takes a new `speakingPriority:` (defaulted, so existing callers are unaffected)
  and a `.critical` arriving while another `.critical` is mid-sentence now ENQUEUES instead of interrupting.
  `Speaker` tracks the priority of the line it is currently speaking. This is the backstop: even if some other
  path re-issues a warning, the user can no longer be given a half-spoken one.

Verified: `make test` -> **354 tests, 0 failures** (349 before; 5 new: safety does not interrupt safety, safety
still interrupts guidance, flicker is ignored while stationary, a real change IS news while moving, escalation to
STOP is never suppressed). `make typecheck` OK (64 app files). `make check` -> BUILD SUCCEEDED.
NOT verified: ANYTHING on the phone. UNVERIFIED ON DEVICE. In particular the 25 deg/s turn threshold is a guess -
too low and a stationary user's hand-shake reads as turning (so flicker is announced again), too high and a slow
deliberate pivot reads as standing still (so a real new obstacle is suppressed). It needs a walk, and it is the
one number here most likely to be wrong.
Open / handoff: Anmol to re-walk and listen for (1) whether "Stop ..." now completes its sentence, (2) whether
standing in front of a door still produces repeats, (3) whether turning on the spot toward something new is
still announced promptly - that is the case the yaw threshold protects and the one that would break first.

---

## 2026-10-18 — Claude (agent, for Anmol) — The recorded walk: no turn was EVER spoken. Two causes, both fixed   [tags: BUG]
Area: B (navigation/feedback). Branch `navigation-overhaul`. Evidence: Anmol's 45 s screen recording
(`ScreenRecording_10-18-2026_01-48-29_1.mov`) with an auto-transcript checked against the on-screen captions.

THE FINDING: across the whole route the screen showed "Turn around" (0:13), "Turn right 140 degrees" (0:14) and
"Turn right" (0:19), and the voice track contains **no turn instruction at any point**. A blind user walking
that route would have received zero route guidance; everything they heard was obstacle chatter. This is F-1 and
F-7 together, and it is worse than either report suggested.

Two independent causes, both required:
1. `FeedbackPlanner` spoke a CAUTION at `.critical`, contradicting the contract stated a few lines above it
   ("Only an obstacle at STOP range, or losing position, earns this"). `.critical` means interrupt. In a
   cluttered apartment cautions fire every second or two.
2. `Speaker.say`'s `.interrupt` branch did `pending = nil`: every interrupt destroyed the queued line. Since the
   planner latches `lastKey` when it GENERATES a cue, a destroyed turn is never re-emitted.
Together these guarantee that while obstacles are present no turn can ever be spoken. The same interrupt chain
also chopped the cautions themselves into fragments - the transcript's "Careful. An obstacle. Careful. Careful.
An obstacle ahead. Careful." at 0:14 is one sentence being cut by the next, repeatedly (that is F-6's
"talks over itself").

Fixed:
* `Package/.../Guidance/FeedbackPlanner.swift`: caution is now `.high` (queues) - a STOP is still `.critical`.
  The file header's priority paragraph was itself out of date ("`.high` interrupts") and now states the real
  contract.
* `Waypoint/Guidance/Speaker.swift`: `.interrupt` KEEPS what is waiting, so the obstacle is spoken first and the
  turn follows. `didCancel` no longer clears `pending` either - it would have undone this; `stop()` already
  clears it explicitly. Staleness is still enforced by `maxQueuedAge` (4.5 s, raised earlier today).
* `Package/.../Guidance/FeedbackPlanner.swift`: NEW `hasBeenTracking`. "Lost my position." was announced on the
  FIRST untracked tick of every walk (heard at 0:06) because `lastTrackingOK` starts true - there was nothing to
  lose yet, and the screen correctly read "Finding your position" at the same moment. A first fix now says
  "Finding your position. Stand still, then turn slowly." at `.high`; a genuine loss keeps "Lost my position.
  Hold still." at `.critical`.

A test was WRONG, not just missing: `testCautionIsHighPriorityAndNamesTheObject` asserted `.critical` while its
own name said high. The name recorded the original intent and the value had drifted, so the regression was
pinned in place by its own test. Assertion corrected to match the name and the contract.

Verified: `make test` -> **349 tests, 0 failures** (345 before; 4 new: caution queues, stop still interrupts,
first fix is not reported as a loss, losing a real fix is critical; plus 2 corrected assertions).
`make typecheck` OK (64 app files). `make check` -> BUILD SUCCEEDED.
NOT verified: ANYTHING on the phone. UNVERIFIED ON DEVICE - the whole point is how it sounds while walking, and
no walk has been done with these changes.
Open / handoff:
1. Anmol to re-walk the SAME route and compare against the recording. Success = the turns are actually spoken.
   Another recording + transcript would be the best possible evidence; this one found more than the last three
   device reports combined.
2. Still unreconciled (F-1's other half): at 0:20 the voice said "Slightly left" (round the table) while the
   screen said "Turn right" (the route). Both are correct and nothing relates them. Wording that joins the two
   ("Slightly left round a table, then right toward Other Bathroom") is NOT implemented.
3. `Speaker` keeps ONE pending line and, at EQUAL priority, the newer one wins - so a caution can still displace
   a queued turn, just without destroying it outright. The existing comment says it wants "the most important
   one offered - not simply the last", which equal-priority last-wins contradicts. Left alone deliberately:
   deciding whether a turn should outrank a caution needs a walk, not a guess.
4. Also seen in the transcript and NOT investigated: the opening briefing never played, and "You have arrived"
   does not appear in the voice track although the screen shows it at 0:44. Both are consistent with being
   interrupted away, so both may already be fixed by this change - check on the re-walk.

---

## 2026-10-18 — Claude (agent, for Anmol) — F-5 and F-7 were ONE bug: a queued line died because the line ahead of it took too long to say   [tags: BUG]
Area: B (navigation/feedback). Branch `navigation-overhaul`.

FOUND: F-5 ("an obstacle said only Stop, with no way through") and F-7 ("sometimes it never says which
direction to go, mostly while other announcements are happening") have the same single cause.
The planner already emits the way round as its own `.high` line right after the `.critical` stop
(`FeedbackPlanner.swift:233`), and `NavigationController.perform` sorts critical first - so "Stop. You are
heading toward a wall." starts speaking and the advice goes into `Speaker.pending`. That sentence takes about
2.4 s at the default rate plus `postUtteranceDelay`. `Speaker.maxQueuedAge` was **2.0 s**, so by the time
`didFinish` offered the pending line its turn it was ALWAYS already stale, and it was discarded with
"dropped stale line after 2.4s". A line only ever waits because the speaker is busy, so the budget was
shorter than the wait it is meant to tolerate: every `.high` cue queued behind any sentence longer than two
seconds was guaranteed to be thrown away. That is the way round never being heard (F-5) and a direction
going unsaid under other traffic (F-7).

Fixed:
* `Waypoint/Guidance/Speaker.swift`: `maxQueuedAge` 2.0 -> **4.5 s**, with the reasoning in the comment. Long
  enough to clear any single cue we speak, short enough to still drop a line that genuinely sat too long. The
  opening briefing's separate 15 s budget (`openingMaxQueuedAge`) is unchanged.
* `Package/.../Vision/AvoidanceAdvisor.swift`: NEW `isBoxedIn(_:)` - the way ahead is blocked and neither side
  is a usable way round. The side-choosing logic moved into a private pure `bestSide(...)` used by both
  `advise` and `isBoxedIn`, so the two can never disagree. `advise`'s behaviour and signature are unchanged.
* `Package/.../Guidance/SpokenPhrases.swift`: NEW `TurnSpeech.backUp` = "Back up slowly."
* `Package/.../Guidance/FeedbackPlanner.swift`: NEW `backUp: Bool = false` parameter. When the user is boxed
  in, the stop warning is followed by "Back up slowly." instead of nothing at all. Uses the SAME
  `announcedAvoidance` latch as the way round, so it is offered once per obstacle, and a way round always
  wins over backing up - the two are never both spoken. A door on the route is still the way IN and never
  earns a back-up cue.
* `Waypoint/Navigation/NavigationController.swift`: computes `isBoxedIn` AFTER `advise` (which is what knows
  whether a side was found) and passes it through `tick` to the planner.

Deliberately NOT changed: `testTheWayRoundIsSaidOncePerObstacle` pins "said once, not nagged" as a design
decision, so the latch stays and the new cue follows the same rule. The `.interrupt` path still discards a
pending line (`Speaker.say`); whether a turn should survive a safety interrupt needs a walk to decide, not a
guess. The planner still latches "announced" when it GENERATES a line, not when the speaker actually says it -
with a 4.5 s budget that is far less likely to lose anything, but it is the remaining structural weakness
behind F-7 and is the thing to fix properly if it recurs.

Verified: `make test` -> **345 tests, 0 failures** (337 before; 8 new covering boxed-in detection, the
advisor/planner agreeing, back-up wording, way-round-beats-back-up, once-per-obstacle, and the door-on-route
exception). `make typecheck` OK (64 app files). `make check` -> **BUILD SUCCEEDED**.
NOT verified: ANYTHING on the phone. No walk has been done with these changes - the 4.5 s figure is reasoned
from the default speech rate, not measured on device, and whether 4.5 s is the right trade-off between "heard
it at all" and "heard it too late" can only be judged by walking. UNVERIFIED ON DEVICE.
Open / handoff: Anmol to walk a corridor and (1) reach a wall with a clear way round - expect "Stop ..." then
"Slightly left, there is a wall ahead."; (2) reach a dead end / corner with no usable side - expect "Stop ..."
then "Back up slowly."; (3) watch whether directions still go missing under heavy traffic. If a cue still
disappears, grep the console for "dropped stale line after" - that log line names the exact text that was lost.
F-1 (contradicting directions) is untouched and still needs its own walk.

---

## 2026-10-18 — Anmol (device walk, logged by Claude) — Field test of the merged branch: overall good, 8 findings for tomorrow   [tags: DEVICE, BUG]
Area: B (navigation/feedback) mostly, A (relocalization), plus one routing question.
Build: `navigation-overhaul` @ `fecc146` (= `origin/main` content + one WORKLOG commit), installed on Anmol's iPhone 15 Pro.
Anmol's verdict: "works really good, I like it overall." Everything below is what to fix, not a reason to revert.
NOT diagnosed on the machine: these are device observations. Where a cause is named it is a LEAD, not a verified fact,
and is marked so. Several need another walk tomorrow before anyone changes code.

**1. (CRITICAL) Contradicting directions.** Says "left" when the correct way is right; says "left" while the on-screen
arrow points right. Not common, and sometimes the cues arrive in a different ORDER than the queue should produce.
Lead (UNVERIFIED): speech and the arrow are produced from different places - `NavigationController.perform` sorts the
spoken lines by priority separately from the visual heading, so a reordered or delayed line can be spoken against a
heading that has since changed. Anmol will test this specifically tomorrow to pin down when it happens.

**2. Routing prefers the volunteer's breadcrumb path over a shorter mapped way.** If the volunteer never physically
walked a shortcut, the router will not use it, even when the map shows the space is open.
Cause (known, by design today): routing is A* over the BREADCRUMB GRAPH; `MapBuilder.closeLoop` only ever joins nodes the
volunteer actually stood at, so an unwalked shortcut has no edge and cannot be routed. This is the same issue as the
earlier "why is it using the path I've gone rather than the built mesh" report. The intended fix is floor-grid routing
over the LiDAR mesh (designed, approved in principle, NOT started) - see the movable/immovable obstacle discussion.
Anmol considers this preference, not a blocker.

**3. The active-path / arrival radius is too tight.** A labelled point can sit a little away from where it is drawn - a
door point ended up further INTO the shut door than where it was labelled - so the user is judged off-route or
not-arrived when they are in the right place.
Relevant knobs: `ArrivalRadius` (room 2.5 m, door 1.2 m, stairs/elevator 1.5 m, else 1.0 m) and
`RouteFollower.maxOffRouteMeters` (8 m). The door case is the tightest radius and the one that bit.

**4. Relocalization needs very specific viewpoints, and the user is never told what to do.** It sometimes insists on
seeing a particular spot before it recognises the space, with no instruction to pan slowly or walk around.
This is the viewpoint-dependence of ARKit's world-map relocalization (the reason `CoverageTracker` exists). The coaching
is already a known gap: `Relocalizer.swift` header, "TODO(A): surface 'move slowly / look around' coaching while
.searching". Probably not fully fixable, but saying so out loud to the user costs little.

**5. (MAJOR, REGRESSION) An obstacle says only "Stop", with no way through.** Reaching a wall produced a bare stop and no
suggestion. This behaviour existed before and has been lost: `AvoidanceAdvisor`, `ObstacleSpeech.wayThrough` and
`TurnSpeech.avoidance(side:obstacle:)` are all still present. Wanted back: "back up slightly", "turn slightly left",
and the reasoned form "Slightly left, there is a wall ahead."
Lead (UNVERIFIED, worth checking FIRST): the merge of 2026-10-18 06:20 added "my hint stays quiet whenever U2's advisor
has a suggestion" as fix (4) of that entry. If that suppression is wider than intended, or if both paths suppress each
other in some states, the result is exactly a bare "Stop". Start there.

**6. One-shot lines get missed; priority and freshness fight each other.** Something said once can simply be misheard.
Wanted: a little repetition WITHOUT spamming. Worst while the user is moving among several obstacles / turn options,
where the priority rules and the `staysFresh` / `maxQueuedAge` rules interact badly and the app talks over itself.
Knobs involved: `Speaker` (ONE pending slot, `maxQueuedAge = 2.0`, `staysFresh:`), `SpeechGate` (`.normal` is DROPPED
while speaking), `FeedbackPlanner.directionCooldownSeconds = 1.5`. Needs more testing tomorrow before changing.

**7. (BIG) Sometimes it never says which way to go at all.** Most often when other, higher-priority announcements are
happening - an important instruction is simply never delivered. Connected to item 6.
Anmol's proposed fix: when a higher-priority line pre-empts the queue, do not just drop what it displaced - append the
next CORRECT instruction to be spoken after it, re-deriving it if a re-route or another priority event has changed the
situation in the meantime. (Re-derive rather than replay: by the time the speaker is free the user has moved.)
Mechanism that makes this happen today: `Speaker` keeps only one pending line and keeps the most IMPORTANT one, so a
displaced normal-priority direction is gone for good, and `SpeechGate` drops `.normal` outright while speaking.
To discuss properly tomorrow.

**8. (QoL) Starting instructions for the blind user.** There is no orientation at the start of a walk explaining what is
about to happen or how to hold the phone.

Verified in this block: nothing was changed, so nothing to verify. The build itself is `fecc146`, whose `make test`
(337 pass), `make typecheck` and `make check` results are recorded in the merge entry below.
NOT verified: every lead marked UNVERIFIED above; none of items 1-8 has been reproduced on the machine or fixed.
Open / handoff (tomorrow, Anmol): items 1, 5 and 7 are the ones that change whether a blind user can finish a route -
do those first. Items 1, 6 and 7 all need another walk before code changes. Item 5 has the most concrete lead.
Still unfixed from earlier tonight (diagnosed, file:line in the entry below): the 15 s save timeout reported as a
failure, the 60 s "no 3D model" stopwatch, the slow USDZ export, the export reading paused-session Metal buffers,
`CoverageTracker`'s absolute 2 m grid (the 59% after a full retrace), and the 1.0 m/3D vs 1.5 m/2D loop-closure
threshold mismatch that makes the "check before sharing" warning impossible to clear.

---

## 2026-10-17 — Claude (agent, for Anmol) — Map backup read the wrong app container, so it backed up nothing   [tags: BUG, BUILD]
Area: D (build system). Found while installing the merged branch on Anmol's phone.
FOUND: `make install` and `make uitest` both depend on `backup-maps` (Makefile `:101`, `:130`) specifically so a reinstall
cannot lose scans that can only be recreated by walking the building again. But `Makefile` called
`sh scripts/phone-maps.sh backup` WITHOUT passing `BUNDLE_ID`, and the script defaults to
`BUNDLE="${BUNDLE_ID:-io.github.sachin-khanal.waypoint.sachin}"` (`phone-maps.sh:11`) — U1's dev suffix. The Makefile
already computes the right value (`BUNDLE_ID := $(BUNDLE_PREFIX).$(SUFFIX)`, `:34`, from `WAYPOINT_DEV_SUFFIX` in
`Config/Local.xcconfig`) and uses it for every `devicectl process launch`, but not here. On any machine whose suffix is
not `sachin` the backup queried a container that does not exist, got zero files, and printed
"backup: no maps on the phone (or the app is not installed)" — which reads like "you have no scans", not "I looked in
the wrong place". Silent no-op: the protection every install claimed to apply was never applied.
Fixed: `Makefile` `backup-maps` and `restore-maps` now pass `BUNDLE_ID=$(BUNDLE_ID)` through to the script. The script
needed no change — it already honours the env var. `restore-maps` had the same defect and would have restored into the
wrong container.
Verified: `DEVICE=<anmol's phone> make backup-maps` -> "backup: 5 file(s) -> ~/Library/Caches/Waypoint/map-backups/20261017-235526",
42 MB: 2 real recordings (`map.json` + `worldmap-seg_*.arworldmap` each) plus the Rice Hall sample's `map.json`. The
same command before the fix reported no maps on the same phone with the same 3 maps present. Restore precondition
re-checked by hand (`ls Maps/*/worldmap-*.arworldmap` matches), so `restore-maps` would now accept this backup.
Also verified in this block: the merged branch (`fecc146`) builds, signs, installs and launches on Anmol's iPhone 15 Pro
(`make run` -> BUILD SUCCEEDED, "Launched application with io.github.sachin-khanal.waypoint.anmol bundle identifier",
console "[app] INFO loaded 3 map(s)"). The reinstall preserved the existing maps.
NOT verified: `restore-maps` end to end (not run — it would overwrite the phone's live maps); the backup against U1's
own phone (where the old default happened to be correct, so nothing changes for U1); anything about scanning,
navigation, the 3D viewer, Pause or the unscanned-areas overlay — none of the merged features were exercised, only
install and launch.
Open / handoff:
1. Neither existing recording has a `model-*.usdz`, because mesh export arrived in `3c666b0` (main) after both scans
   were made. `ScanReviewView:206` gates "View 3D model" on `store.hasModel(mapId:)`, so for those two maps the button
   is simply absent — no error, nothing to see. Testing the 3D viewer needs a NEW scan on this build.
2. Same for the return-walk coverage: it is a property of how the volunteer walked, not of the file, so the two old
   one-direction maps will still struggle on the walk back whatever code runs against them.
3. Worth a look by U1/U3: other scripts under `scripts/` may carry the same hardcoded `.sachin` default. Only
   `phone-maps.sh` was checked.

## 2026-10-17 — Claude (agent, for Anmol) — Merge `main` into `navigation-overhaul` (27 commits)   [tags: BUILD]
Area: shared.
Brings in `main`'s mesh pipeline and cloud/web work: `MeshExporter` (LiDAR mesh -> cropped -> decimated -> USDZ beside
the map), `MeshDecimator`/`MeshCrop`/`IndexedMesh` in core, `MeshAsset` in the map format, the unscanned-areas
overlay, the 3D model viewer, the standalone web viewer, Supabase storage policies and the `supabase_check` tool.
**The format collision I expected was not there.** `main` had already aligned format 3 to include BOTH their
`meshAssets`/`heightMeters` AND our `keyframes` (see the comment at `BuildingMap.swift:17` and the `CodingKeys` at
`:85`), so the two meanings of "3" had already been reconciled on their side. Zero textual conflicts, and the merged
decoder carries every optional field.
Verified AFTER the merge: `make test` -> **337 tests, 0 failures** (253 ours + main's); `make typecheck` OK (64 app
files, 1 UI test file); `make check` -> BUILD SUCCEEDED. `make gen` run first, since the branch adds files.
NOT verified: nothing was run on a phone in this block. Everything already marked UNVERIFIED ON DEVICE stays so.
Open / handoff:
1. Zero conflicts is not the same as semantically correct. The areas where both sides moved and git merged silently -
   `BuildingMap`, `MapStore`, `FeedbackPlanner`, `NavigationController` - deserve a read by their owners.
2. This unblocks floor-grid routing: `IndexedMesh` and the mesh pipeline are now on the same branch as the guidance
   work, and the mesh is written in the MAP frame, the same frame as the nodes.
3. Not merged to `main`; under ROADMAP Revision 3 that is U1's call.

---

## 2026-10-18 06:20 — Claude (agent, for Sachin) — Integrated U2's navigation-overhaul (12 commits) with main; conflicts resolved; two fixes   [tags: CONTRACT CHANGE, BUILD]
Area: shared integration (U1 merge captain). Branch `integrate/navigation-overhaul` = main f912ef5 + origin/navigation-overhaul a107f85 (Anmol, 12 commits: keyframe relocalization with visual fingerprints OFF by default, "one move at a time" speech, sooner re-routing, route continuously, scan both directions (`CoverageTracker`), suggest a way round a blockage (`AvoidanceAdvisor`)). Cross-referenced first: main = origin/main; U3 and app-ui-workflows unchanged; Anmol pushed 3 more commits while this was being prepared (latest a107f85, minutes old).
Conflicts (4 files, 8 blocks) and how they were resolved, keeping BOTH sides: `FeedbackPlanner.swift` (params `context:` + `isMoving:` + U2's `avoidTowards:`); `BuildingMap.swift` (kept my instance `schemaVersion` + `meshAssets` + U2's `keyframes`; U2's own hand-written decoder was a DUPLICATE of mine and was removed, `keyframes` is now decoded by the single decoder with `decodeIfPresent ?? []`; format 3 now also means `keyframes`, MAP_FORMAT.md updated); `NavigationController.swift` (my sensor context + opening briefing + sign speech + U2's pose-jump guard + avoidance advice); WORKLOG (both entries).
Merge-induced problems found on the phone and fixed: (1) NAME CLASH: U2's `CaptureController.coverage` (CoverageTracker, walked both ways) vs my published `coverage` (unscanned-areas tiles): mine renamed `gaps` (+ HUD id `hud.gaps`); (2) the opening briefing was DROPPED ("dropped stale line after 2.5s") by U2's new speaker rule (one pending line, discarded after 2 s): `Speaker.say(..., staysFresh:)` lets the opening briefing wait up to 15 s and not be displaced by a newer cue (default behaviour unchanged for everything else); (3) "You have arrived at Room 204" was DROPPED the same way when it queued behind the longer briefing: the controller now sends arrival at interrupt priority (planner and its tests untouched); (4) two way-round suggestions at once ("Slightly left, there is a wall ahead" + my "Open space on your left"): my hint stays quiet whenever U2's advisor has a suggestion (+1 test); (5) my briefing test and E2E walk check updated to U2's new wording ("Walk straight about 12 meters." / "Right, toward E2E Room 2.").
Observed, not changed (U2's design): in the 9-node sample map the destination is among the nearest start candidates, so the route becomes the straight line to Room 204 ("route has 1 nodes") and the simulated walk no longer contains the right turn; "route has N nodes" is logged every tick (noisy).
Verified: `make test` 337 pass; `make typecheck` OK (64 app files); `make check` BUILD SUCCEEDED; ON THE PHONE (installed with `make build install`): `make selftest-e2e` 25 passed / 0 failed / 1 skipped, `make uitest` 11/11, `make selftest-sim` PASS (spoken: "Navigating to Room 204." / the opening briefing / "You have arrived at Room 204." with nothing dropped).
NOT verified: ANY of U2's relocalization / keyframe code on a real hallway (it is OFF by default for visual fingerprints; the rest runs); a real walk with the new speech rules; `tools/validate_map.py`, `web/router.js` and migration 0005 do not check `keyframes` yet.
Open problems / handoff: Anmol: pull main (it contains your 12 commits plus the fixes above) and tell me if you object to the `staysFresh` speaker parameter or arrival at interrupt priority; add `keyframes` limits to the validator/web/SQL with U3.

## 2026-10-18 05:40 — Claude (agent, for Sachin) — Phone results for the scan-size policy   [tags: BUILD]
Verified: on Sachin's iPhone 16 Pro Max, build installed with `make build install` (this branch): `make selftest-e2e` 25 passed / 0 failed / 1 skipped, incl. NEW `share.overLimitSavesLocally` (a 51,000,000-byte scan saved and flagged local-only) and `share.overLimitRefusedFromOutside` (an incoming bundle with it is refused); `make uitest` 11/11 (incl. the Share maps sheet); `make selftest-sim` PASS; `make check` BUILD SUCCEEDED; the install made a fresh map backup (10 files).
NOT verified: a real over-50 MB scan from the camera; the oversize captions on the Share screen by eye.

## 2026-10-18 05:10 — Claude (agent, for Sachin) — Scan-size policy (over 50 MB stays on the phone), housekeeping, restore proven   [tags: BUG, BUILD, DOCS]
Area: A (scan save), D (cloud/sync, tooling), U1 housekeeping. Branch `feature/share-size-policy` (off main 4512d4f). Cross-referenced first: `main` = origin/main; `navigation-overhaul` (U2) is 11 ahead / 27 behind (2 new commits in the last hour, one touching `CaptureController`); `U3` and `app-ui-workflows` have nothing new. To avoid conflicts with U2's branch the new logic is in NEW files and `CaptureController`/`MapStore` got one-line edits only.
FOUND: a scan whose ARWorldMap is over 50,000,000 bytes could not even be SAVED: `CaptureController.save` went through `MapStore.importBundle`, whose `MapBundle.validate()` refuses world maps over the cloud limit ("A world map in this bundle is too large"). A 5.5 m scan is already 27.5 MB, so a longer hallway would hit this.
Policy (Sachin): over 50 MB -> kept on the phone only. Implemented: `Cloud/SharePolicy.swift` (verdict from FILE SIZES, no loading: ok / nearLimit > 40 MB / localOnly > 50,000,000 bytes, with sentences for the person), `Model/MapStoreLocalScan.swift` (`MapStore.saveLocalScan` = same validation/merge as an import but no 50 MB cap, local cap 500 MB; `worldMapByteCounts`; `shareVerdict`), `CaptureController.save` now calls `saveLocalScan` (the one line that matters), `SyncEngine.push` refuses before any network call (`CloudError.localOnly`), `MapSync.send` refuses, `SyncView` disables Upload/Send and skips building export bundles for such maps and says why, `ScanReviewView` shows a banner (info near the limit, warning over it). Incoming bundles keep the 50 MB limit.
Housekeeping done: `docs/WORKFLOW.md` branch/merge rules written (ROADMAP U1.2) incl. the iCloud ` 2.swift` duplicate-file warning; ROADMAP snapshot 3 (U1 status); deleted merged branches `fix/guidance-voice` and `fix/format-alignment-security` (remote and local) and local `feature/route-memory` (left `U3` and `app-ui-workflows`: they belong to U3/U4); `scripts/phone-maps.sh` now keeps only the newest 5 backups; RESTORE PROVEN on the phone: backup A -> restore -> backup B, all 10 files byte-for-byte identical (SHA-256).
Tests: `make test` 268 pass (+8 `SharePolicyTests`: thresholds, a 51 MB scan saves locally, incoming bundle still refused, oversize push makes ZERO network requests, extension keeps both scans). Phone results: see next entry.
NOT verified: a real long scan over 50 MB (none exists yet; the 51 MB cases use synthetic data); the Share screen visually with an oversize map; U2's merge with these edits.
Open problems / handoff: U2's branch edits `CaptureController` and `MapStore`; the conflict surface here is the single `saveLocalScan` line plus nothing in MapStore. Finish-gating unchanged (decision pending, see chat).

## 2026-10-18 04:20 — Claude (agent, for Sachin) — Two more security-review findings fixed: NULL-unsafe 0005 and un-validated merge result   [tags: BUG]
Area: D / shared contract. Branch `fix/format-alignment-security`.
Finding A (real bug in my SQL, `0005_map_extras_constraint.sql`): in plpgsql `if <NULL> then` does not fire, so an extent or mesh asset with a MISSING key (`{}`, no `center`, no `boundsMin`, ...) was ACCEPTED (fail-open); my tests only covered wrong values. Fixed by writing every rule as a positive condition wrapped in `coalesce(..., false)` (anything not provably valid is rejected) and requiring node `position`. +17 missing-key cases in `supabase/tests/map_extras_constraint.sql`. Proof in a local Postgres: the PREVIOUS function wrongly accepted 8 of the 32 cases; the fixed one gets 32/32 right and the constraint still refuses a bad row.
Finding B (`BuildingMap.merged` / `importBundle`): only the INCOMING bundle was validated, so merging two valid maps could exceed the 100-file / 80 MB mesh caps (or node limits). `MapStore.importBundle` now validates the MERGED result before saving; test `testImportRefusesAMergeThatBreaksTheMeshFileLimit` (60 + 60 files -> rejected, stored map unchanged).
Python validator: +1 test for missing keys / junk entries (16 tests).
Verified: `make test` 260 pass; Python 16 OK; `make typecheck` OK; local Postgres 32/32.
NOT verified: the SQL on the LIVE project (0004 re-run and 0005 not applied yet); the phone with this last change (only unit-tested).
Open problems / handoff: the Supabase person must run the CURRENT `0004` and `0005` (0005 was changed after it was first pushed: if an earlier copy was run, run the new file again; it is idempotent).

## 2026-10-18 03:40 — Claude (agent, for Sachin) — Phone results for the format-3 alignment + security fixes   [tags: BUILD]
On Sachin's iPhone 16 Pro Max with this branch installed (`make build install`): `make uitest` 11/11, `make selftest-e2e` 23 passed / 0 failed / 1 skipped, `make selftest-sim` PASS. The 3 real scans from the phone's backup, the sample, the web fixture and all three format fixtures pass the stricter `tools/validate_map.py`; `make check` BUILD SUCCEEDED.
NOT verified: see the 03:10 entry (live SQL not applied; web viewer reading app-written maps).

## 2026-10-18 03:10 — Claude (agent, for Sachin) — Browser tests run in Chrome; format-3 alignment FIXED (meshAssets kept); two security-review findings fixed   [tags: CONTRACT CHANGE, BUG, BUILD]
Area: shared contract (Model/*), D (validator, SQL). Branch `fix/format-alignment-security` (off main e77d00f). Requested by Sachin: run the browser-only tests with Chrome, fix the format alignment keeping meshAssets, plus the two automated security findings.
1) BROWSER TESTS (Chrome via the DevTools control; the Claude-in-Chrome connection dropped mid-task): `web/tests.html` 46/46 PASS (incl. the WebGL test that fails under Node), `web/ui-tests.html` 16/16 PASS, served by U3's `web/serve.py` on loopback. Server stopped afterwards.
2) ALIGNMENT (CONTRACT CHANGE, additive, optional fields, no format bump): web "schema 3" and native format 3 are now ONE format: `BuildingMap.meshAssets: [MeshAsset]?` (id, segmentId, format "obj", coordinateFrame "map", byteCount, sha256, boundsMin/Max, storageOwner), `RoomExtent.heightMeters`. Round-trips through load/save (key absent when nil, so maps without it are unchanged), unions on merge by id. `docs/MAP_FORMAT.md` updated (struck the old "known alignment issue", added the field list).
3) SECURITY FINDING 2 (extents not validated): new `Model/MapExtrasValidation.swift`, called from `MapBundle.validate()`: extent only on rooms, finite, half sizes in (0.05, 30] m, 0 < area <= 4*hx*hz+0.01, height in (0, 20], the room's node within hypot(hx,hz)+1 of the rectangle centre; meshAssets rules (<=100, unique ids, segment exists, obj/map, 1..40 MB each, <=80 MB total, 64 lowercase hex sha256, finite ordered bounds). Same rules in `tools/validate_map.py` (+4 tests, U3's web fixture passes them) and server side in NEW `supabase/migrations/0005_map_extras_constraint.sql` (CHECK constraint, because `extend_building` stores the first publication's JSON as is).
4) SECURITY FINDING 1 (storage path parser): `0004_storage_read_policy.sql` now requires the EXACT path `<contributor>/<building>/<segment>.arworldmap` for a pair in `segment_owners` (the old split_part version also exposed `seg1.evil`, `seg1.arworldmap/x`).
Also: found and deleted 4 byte-identical untracked duplicate files (`RouteSimplifier 2.swift`, `SpeechGate 2.swift`, `MeshDecimator 2.swift`, `ContextualGuidanceTests 2.swift`; iCloud-style conflict copies, the repo lives in the iCloud-synced Desktop; they broke the build with "ambiguous use of RouteSimplifier"). Check `git status` for ` 2.` files if the build suddenly complains.
Files created: `Model/MapExtrasValidation.swift`, `Tests/.../MapExtrasTests.swift` (7), `supabase/migrations/0005_map_extras_constraint.sql`, `supabase/tests/map_extras_constraint.sql`. Edited: `MapTypes.swift`, `BuildingMap.swift`, `MapStore.swift`, `tools/validate_map.py`, `tools/test_validate_map.py`, `0004_storage_read_policy.sql`, `supabase/tests/storage_read_policy.sql`, `docs/map-format/map-v3.json` (+meshAssets, +heightMeters), docs.
Verified: `make test` 259 pass (+7); Python 15 OK; local Postgres (supabase image): migration 0005 function 15/15 cases + the constraint refuses a bad row; migration 0004 exact rule: exactly 1 of 8 objects readable (hostile names blocked).
NOT verified: the new SQL on the LIVE project (needs the SQL editor: re-run 0004, run 0005); the app on the phone with this change (see the next entry if run); web viewer reading a map produced by the app; `make check`.
Open problems / handoff: U1/Sachin: apply 0004 (re-run) and 0005 in the Supabase SQL editor, then `python3 tools/supabase_check.py`. U3: please confirm the field list in MAP_FORMAT.md matches `web/router.js`, and tell the app owners if `meshAssets` gets more fields.

## 2026-10-18 02:20 — Claude (agent, for Sachin) — Integrate fix/guidance-voice into main (pre-merge checks)   [tags: BUILD, DOCS]
Area: integration (U1 is merge captain; Sachin asked for the non-breaking, aligned work to go into main).
Pre-merge checks on `fix/guidance-voice` (contains origin/main 4f40b6b + everything): `make test` 252 pass; `make typecheck` OK (63 app files, 1 UI test file); `make check` BUILD SUCCEEDED; Python tests 11 OK; `tools/validate_map.py` PASS (non-map samples skipped); docs hook self-test 15 passed; on the phone `make uitest` 11/11, E2E 23/0/1, simulated walk PASS, live Supabase two-user round trip 33/33. U3's `web/` tests: 45/46 under Node (the 1 failure is the WebGL test needing a browser: "document is not defined"); not run in a browser by me.
Alignment finding: web viewer "schema 3" (`meshAssets`, rooms) vs native format 3 (`extent`): both optional, no break today, but the app would drop `meshAssets` on re-save; documented in MAP_FORMAT.md, needs a U1+U3 decision.
NOT included in main: `origin/navigation-overhaul` commits after c5ba14f (8 commits by U2/Anmol: keyframe relocalization, "one move at a time" speech, sooner re-routing); trial merge conflicts in `BuildingMap.swift` and `NavigationController.swift` and they change the speech style my opening briefing uses; U2 should merge main into his branch and resolve, or we pair on it.
NOT verified: relocalization (Gate G2); a fresh-install first launch with the new defaults; the web viewer in a browser; viewing the three real scans' 3D models in the app.

## 2026-10-18 01:50 — Claude (agent, for Sachin) — Phone results for the new-UI default; backup tool FIXED; first real scans inspected   [tags: BUG, BUILD]
Area: D (tooling) + A/C (scan, export). Continues the 01:15 entry (its "phone results below" are here).
On Sachin's iPhone 16 Pro Max, build = `fix/guidance-voice` + origin/main merge + new-UI default (installed with make build/install): `make uitest` -> 11 tests, 0 failures (new `testNewInterfaceIsTheDefault`; NOTE it only proves the STORED preference on this phone, which already has ui.newInterface=true and ui.serviceMode=live; a true fresh install is untested and no simulator exists on this Mac); `make selftest-e2e` -> 23 passed, 0 failed, 1 skipped; `make selftest-sim` PASS. One `make uitest` run failed to start (no test cases ran) and passed on retry; looked transient (phone asleep), not investigated.
BUG FOUND IN MY OWN TOOL: `scripts/phone-maps.sh backup` printed "no maps on the phone" while 3 real scans were on it, because it listed `Documents/Maps` (devicectl returns nothing for that subdirectory) instead of `Documents`. The safeguard added on 2026-10-17 therefore protected nothing. Fixed (`--subdirectory Documents`); proven: `backup` copied 10 files / 107 MB (3 scans with 3D models) to `~/Library/Caches/Waypoint/map-backups/20261017-194713`. `restore` is still untested.
First REAL saved scans on the phone (Sachin scanned them; read from the backup, all pass `tools/validate_map.py`, all schema 3): "Rice Hall · Floor 4" (12 nodes, room 411, 5.5 x 3.3 m, ARWorldMap 27.5 MB, 3D model 33.6 MB), another "Rice Hall · Floor 4" (3 nodes, room 412, 1.4 x 1.3 m, 5.7 MB, 22.9 MB), "Rice Hall, floor 1" (1 node, 4.6 MB, 18.2 MB). So save -> `model.usdz` export works on real scans.
RISKS SEEN: a 5.5 m x 3.3 m scan already has a 27.5 MB ARWorldMap and a 33.6 MB 3D model; the Supabase buckets cap files at 50,000,000 bytes (`worldmaps`, `meshes`), so a longer hallway can exceed the cap and fail to upload (nothing in the app handles that yet; the model budget is 40 MB, the world map has no budget). The room-extent feature produced no extents (0) in these scans.
NOT verified: opening any of these models in the in-app 3D viewer; relocalization against any of these scans (Gate G2); uploading a 27.5 MB scan to Supabase; restore script.
Open problems / handoff: Sachin: rescan a longer hallway and run the relocalization trials; decide the file-size policy (ARWorldMap and model budgets under 50 MB, or raise the bucket limit).

## 2026-10-18 01:15 — Claude (agent, for Sachin) — New UI is the default; merged origin/main (U3 web viewer); validator fix   [tags: BUILD]
Area: shared (UI default, docs), D (tools). Requested by Sachin.
Merged `origin/main` (rishyam1, "standalone building web viewer", `web/` + `Samples/route-vectors.json`) into `fix/guidance-voice`; one conflict (WORKLOG, kept both). NOT merged: `origin/navigation-overhaul` has 8 newer commits (keyframe relocalization, "one move at a time", re-routing); a dry run shows conflicts in `BuildingMap.swift` and `NavigationController.swift`.
Changes: `UIPrefs.newInterfaceDefault = true` (RootView, SettingsView); `ServiceMode.defaultMode` = Live on a LiDAR iPhone, Demo data otherwise (a fresh install on a Pro phone would otherwise give a volunteer fake demo scans); an explicitly stored preference still wins (Sachin's phone already has newInterface=true, serviceMode=live). Scripted launches and UI tests keep using the classic screens. `tools/validate_map.py`: with no arguments it now SKIPs non-map JSON in `Samples/` (U3's new `route-vectors.json` made U3's own validator FAIL); a file named on the command line is still validated; +1 test. Docs: TESTING.md Level 4 and UI_PLAN R2 struck + Update.
Verified: `make test` 252 pass; `make typecheck` OK; `python3 tools/validate_map.py` PASS + SKIP; Python tests 11 OK. (Phone results below.)
NOT verified: a FRESH install's first launch (the phone already has stored preferences, so the default path itself is untested on a device); the web viewer (`web/`, U3's, not run by me); `make check`.

## 2026-10-17 - Codex for U3 - Publish standalone web viewer to main
User authorized commit and push to main. Prepared isolated publish-web-viewer worktree from origin/main; preserved original U3 working tree and all native/backend edits. Added web/ static explorer, router, OBJ integrity loading and WebGL surfaces, mock/DOM tests, loopback server, web-local synthetic schema-3 sample; added Samples/route-vectors.json. Native sample and Swift sources unchanged to preserve main's schema-2 compatibility. README adds deployment/native integration corrections. Edited docs/MODULES.md and this log additively.
Verification: pre-integration browser 46/46 logic/GPU and 16/16 UI PASS; Python 15 PASS. Integrated browser checks recorded below before push. Native make test/typecheck unavailable on Windows; no Swift changes. Live cloud downloads and real scan fidelity/performance UNVERIFIED ON DEVICE. No dependencies added. Commands: git fetch/worktree, targeted copy/edit, Python loopback server, hidden headless Edge, git diff --check, targeted git add/commit/push. No native/backend files included.
## 2026-10-18 00:50 — Claude (agent, for Sachin) — First REAL LiDAR scan run on the phone (headless probes): export + coverage verified on real mesh data   [tags: BUILD]
Area: A/C (scan, export). Command: `xcrun devicectl ... -- -autoScan YES -scanExportProbe YES -scanCoverage YES` for ~75 s on Sachin's iPhone 16 Pro Max (hand held, a room), current build from `fix/guidance-voice` 6034a76. Nothing was saved to the map store; the probe export file is deleted after reading it back.
Verified on real data: tracking OK at 60 fps; mesh grew to 45 anchors / 249k triangles; scan box 9.7 x 4.0 x 5.9 m; ARKit mapping status reached `mapped` (3) several times, so Finish is reachable in a room. EXPORT PROBE PASS: 8 anchors -> 21,451 triangles, read back by SceneKit 21,451, 1.5 MB USDZ, 364 ms, within budget with no simplification needed. Coverage overlay computation: 10-24% of box-face tiles covered (1,471 open tiles + 2,360 outline dashes at the end, under the 4,000-tile cap); the 1 Hz background fit took 38-158 ms and fps stayed 60.
NOT verified: how the yellow tiles LOOK on screen (headless run has no screen check); whether 10-24% is a sensible reading (the box grows as you scan, so the percentage falls as the box grows; the number is relative to the current box, not to the building); export of the FULL 249k-triangle mesh (probe fired at 21k; the size estimate says about 6 MB, under the 40 MB budget); Save + model open in the viewer; Pause on a real scan.
Open problems / handoff: Sachin to open the scanner, switch on "Show unscanned areas", and judge the tiles; then Save a scan and open "3D model" on its review screen.

## 2026-10-18 00:20 — Claude (agent, for Sachin) — Supabase shared maps VERIFIED live end to end after the storage rule fix   [tags: BUILD]
Area: D / U3 (cloud). The Supabase user pasted the SQL results: (A) the installed `canonical_worldmaps_read` still used `c.name` (the old rule), (B) the corrected logic accepted both uploaded files, (C) `segment_owners` matched. They then ran the corrected rule (drop + create with `objects.name`) in the SQL editor.
Verified (live, real project): `python3 tools/supabase_check.py` -> ALL PASS incl. `storage.otherUserCanDownloadScanFiles` (a brand-new user reads the scan files of the existing test building). Phone round trip on Sachin's iPhone 16 Pro Max, `-autoE2E YES -e2eCloudWrite YES`: 33 passed, 0 failed, 0 skipped: two different users; publish 816 ms; other user lists in 85 ms; other user downloads 4096/4096 scan bytes identical (261 ms); other user extends (444 ms); owner sees 4 nodes, version 1 -> 2; owner downloads BOTH segments (4096 B + 2048 B); stale re-upload keeps the extension; 5 list+download cycles, 0 failed, 140/172/237 ms (min/avg/max).
NOT verified: other networks / cellular; more than 2 users or large (17 MB) scan files (only 4 KB and 2 KB files were used; the 50 MB bucket limit is untested); Supabase free-tier pausing; model.usdz upload (not built); cleanup: this run left a SECOND test building `ZZ CONNECTION TEST ...` plus the first one and 6 small scan files; the app cannot delete them (SQL: `delete from public.canonical_buildings where name like 'ZZ CONNECTION TEST%';`, scan files via Storage in the dashboard).
~~"fails until 0004 is applied"~~ **Update 2026-10-18 (Claude):** in `docs/MODULES.md` the cloud row status is now: map data AND scan-file sharing verified live with the corrected rule.
Open problems / handoff: delete the ZZ test rows; migration 0002's original rule stays in history as applied; 0004 supersedes it (the root cause and fix are in 0004's header and `supabase/tests/storage_read_policy.sql`).

## 2026-10-17 23:58 — Claude (agent, for Sachin) — Retry: scan-file sharing still failed; ROOT CAUSE found (name shadowing in the storage rule) and 0004 corrected   [tags: BUG]
Area: U3 (backend) / D. `python3 tools/supabase_check.py` was re-run after Sachin opened 0004: still FAIL `storage.otherUserCanDownloadScanFiles` (HTTP 400 for both files) - either 0004 had not been run or it was wrong. Reading the SQL again: in `exists (select ... from public.canonical_buildings c ...)` a BARE `name` is `c.name` (the building's name), not the storage object's path. The 0002 rule (`storage.foldername(name)`) and my first 0004 both had this bug, so NO user could ever read another user's scan file.
Reproduced in a local throwaway Postgres (supabase image, stand-in table, `set role authenticated`): bare `name` -> 0 readable objects; `objects.name` -> exactly 1 (the listed segment of the right contributor; a file of the wrong contributor and an unlisted segment stay hidden). Saved as `supabase/tests/storage_read_policy.sql` (run instructions inside).
~~The earlier entry (23:45) says the cause might be a missing policy or the `storage.foldername()` helpers~~ **Update 2026-10-17 (Claude):** it is the name shadowing described above, not a missing policy.
Files edited: `supabase/migrations/0004_storage_read_policy.sql` (uses `objects.name`; idempotent, re-run even if an older 0004 was run), new `supabase/tests/storage_read_policy.sql`. 0002 is left as applied history; 0004 supersedes its storage rule.
Verified: local reproduction + fix (above); `python3 tools/supabase_check.py` still shows the live failure (the live project has NOT been changed).
NOT verified: the fix on the real project (needs the SQL editor); everything downstream (phone round trip, 5x reliability).
Open problems / handoff: Sachin/U3 run the corrected 0004 in the Supabase SQL editor, then `python3 tools/supabase_check.py` (must PASS `storage.otherUserCanDownloadScanFiles`), then the phone round trip, then delete the ZZ test rows.

## 2026-10-17 23:45 — Claude (agent, for Sachin) — Supabase connected; LIVE two-user test of shared map data; scan-file bug found; fix + tools   [tags: BUG, BUILD]
Area: D / U3 (cloud). Sachin put the keys in `Config/Local.xcconfig`; I fixed the URL line (plain `https://` is read as a comment in xcconfig; now `https:/$()/`), key checked: anon role, 208 chars, git-ignored; never printed.
Ran on Sachin's iPhone 16 Pro Max (build installed): `make selftest-e2e` -> 23 passed, 0 failed (cloud.anonymousSignIn, cloud.listBuildings: 0 rows, so migrations are applied). With Sachin's explicit OK, ran the opt-in write test `-autoE2E YES -e2eCloudWrite YES` (new `Waypoint/App/CloudRoundTripTest.swift`): two different anonymous users A and B.
RESULT: PASS two users, publish (A, 490 ms), visible to owner, visible to other user (98 ms), B extends (253 ms), extension visible to A (version 1 -> 2), A's STALE re-upload keeps B's extension. FAIL: B downloads 0 of A's 4096 scan bytes, A downloads 0 of B's seg2, reliability 5/5 cycles failed. Root cause (reproduced read-only from a Mac with a third new user): the stored row is correct (`segment_owners` {seg1: A, seg2: B}) but Storage answers "Object not found" to anyone but the file's owner, i.e. the storage read rule `canonical_worldmaps_read` from migration 0002 is not effective on the live project (0002's SQL test ran on STUBBED storage functions and has no storage case; the live pg_policies were not inspected - needs Sachin/U3 in the SQL editor).
Also found: `SyncEngine.fetchBundle` silently skipped any scan file answering 400/404, so a user would get a map with no position data and no warning. Fixed: `fetchBundleChecked` returns `missingSegments`; `CloudController.download` appends a warning to the import review; +1 test.
Files created: `supabase/migrations/0004_storage_read_policy.sql` (idempotent re-create of the rule with plain string functions), `tools/supabase_check.py` (read-only live check, `--write` round trip, refuses service_role, no secrets in output), `Waypoint/App/CloudRoundTripTest.swift`. Edited: `SyncEngine.swift`, `CloudController.swift`, `CloudTests.swift`, `E2ESelfTest.swift` (opt-in hook), docs (`SETUP.md`, `CANONICAL_MAPS.md`, `tools/README.md`).
SIDE EFFECT ON THE LIVE PROJECT: one building `ZZ CONNECTION TEST 2026-10-17T22:57:03Z (safe to delete)` (3-4 nodes, version 3) and 3 small scan files from two throwaway anonymous users. The app cannot delete it (migration 0002 revokes delete); remove with `delete from public.canonical_buildings where name like 'ZZ CONNECTION TEST%';` in the SQL editor. (I had said last turn it could be deleted afterwards; that was wrong.)
Verified: `make test` -> 252 tests, 0 failures; `make typecheck` OK; the live results above; `python3 tools/supabase_check.py` -> 6 PASS, 1 FAIL (the storage rule).
NOT verified: that 0004 fixes it (not run: needs the SQL editor); scan-file sharing between users; the 5x reliability figure (failed only because of the scan files; list/publish/extend timings were fine in the single run); real-network behaviour away from this Wi-Fi; free-tier pausing; model.usdz upload (not built).
Open problems / handoff: Sachin or U3 runs `0004_storage_read_policy.sql` in the Supabase SQL editor, then `python3 tools/supabase_check.py` (must print PASS storage.otherUserCanDownloadScanFiles) and `make selftest-e2e` ; then delete the ZZ test row.

## 2026-10-17 23:10 — Claude (agent, for Sachin) — Real Pause, "Show unscanned areas" overlay, 3D model export + viewer (start), phone map backup tool   [tags: BUG, ROUTING]
Area: A (scan: CaptureController, LiveScanView, MeshSampler), C (export/viewer), U3's new Scanner files (edited at Sachin's request), D (Makefile/scripts). Branch `fix/guidance-voice`; first merged origin/navigation-overhaul's 2 newer commits (conflicts in FeedbackPlanner/NavigationController resolved by keeping both: `context:` + `isMoving:` params, `.critical` priority with context hints).
1) "Scanner does not stop": in the new Scanner, Pause only stopped tagging (documented limit in LiveScanService) - breadcrumbs, mesh counting, box fitting and overlay kept running. Now `CaptureController.pauseRecording()/resumeRecording()` stop all recording while ARKit keeps TRACKING (pausing the session would lose the map origin). Resume is refused > 2 m from the pause point (`ResumeGuard`) so no edge is drawn through walls. UI hides the mesh overlay while paused. NOT changed: Finish still needs ARKit `mapped`; if Finish stays disabled in a plain corridor that can ALSO feel like "cannot stop" (Discard/Cancel always work) - see open problems.
2) "Show unscanned areas" toggle (both scanners; off by default): core `Scan/CoverageGrid.swift` cuts the six faces of the scan box into ~0.4 m tiles, marks tiles with mesh vertices within 0.3 m, returns unscanned tiles + outline + dashes + coverage %. App: `MeshSampler.samplePoints`, `CaptureController.coverage` (computed in the existing 1 Hz background box fit only when the toggle is on), `LiveScanView` draws yellow translucent tiles and a dashed white outline as two meshes (Apple Measure look). HUD shows "Scanned: N%".
3) 3D model (U3.8 started): core `MeshDecimator`/`MeshCrop`/`IndexedMesh` (vertex clustering to the 40 MB `ExportBudget`; crop to the scan box), `MapStore.modelURL/hasModel` (`model.usdz` next to map.json, not in bundles yet), app `Scan/MeshExporter.swift` (ARMeshAnchor -> IndexedMesh -> crop -> cluster -> MDLMesh with normals -> SceneKit -> USDZ; FOUND ON THE PHONE that ModelIO cannot write .usdz on iOS, `canExportFileExtension("usdz")=false`, SceneKit can), `CaptureController.exportModel` runs after a successful save on a background queue, `Model3D/ModelViewerView.swift` (SceneKit orbit/pan/pinch + place pins + toggle), review screen card replaces the "coming soon" placeholder, classic screen shows status + "View 3D model".
4) Tooling: `scripts/phone-maps.sh` + `make backup-maps | restore-maps | list-map-backups`; `make install` and `make uitest` now back up the phone's maps first. REASON: at the end of this session the phone held only the SAMPLE map and then nothing: the real "Rice Hall · Floor 4" scan (17.8 MB ARWorldMap) and the sample were gone. I do not know why. Nothing in my code or tests deletes maps (only the confirmed trash buttons do, via AppState.deleteMap), the app was running on the phone at the time, and the first loss predates the 18:36 sample re-seed; a person deleting them or an app reinstall resetting its data are both possible. I had copied only the 7 KB map.json earlier (kept at ~/Library/Caches/Waypoint/map-backups/ricehall-floor4-map-JSON-ONLY-no-worldmap.json), not the world map, so the position data cannot be restored: the hallway must be rescanned.
Files created: core `Scan/CoverageGrid.swift`, `Scan/MeshDecimator.swift`, tests `CoverageGridTests` (11), `MeshDecimatorTests` (8); app `Scan/MeshExporter.swift`, `Model3D/ModelViewerView.swift`; `scripts/phone-maps.sh`.
Files edited: `Capture/CaptureController.swift`, `Scan/LiveScanView.swift`, `Scan/MeshSampler.swift`, `Services/{ScanService,LiveScanService,MockScanService}.swift`, `UI/Scanner/{ScanSessionModel,LiveScanScreen,ScanReviewView}.swift`, `UI/VolunteerView.swift`, `App/E2ESelfTest.swift` (+`export.formats`, `export.usdz`), `WaypointUITests` (+2 tests), `Model/MapStore.swift`, `Makefile`.
Verified: `make test` -> 251 tests, 0 failures; `make typecheck` OK (62 app files); ON THE PHONE (installed builds): `make selftest-e2e` -> 21 passed, 0 failed, 1 skipped incl. `export.usdz` (3200 triangles clustered to 392 within a 20 KB budget, written as a 30 KB USDZ by SceneKit and read back by SceneKit with 392 triangles); `make selftest-sim` PASS; `make uitest` -> 10 tests, 9 passed, 1 skipped (`testNewScannerExtendMap...` skips because the Floor 4 scan is gone); new UI tests pass: `testUnscannedAreasToggleExistsAndFlips`, `testNewScannerPauseAndCoverageToggle` (Pause turns into Resume and back; toggle exists, starts off).
NOT verified: the overlay and the export with a REAL LiDAR mesh (the phone lay flat on a desk and built no mesh: `-scanExportProbe`/`-scanCoverage` headless probes are in place but need someone to point the phone at a room); how the tiles LOOK (colour, dash size, whether the box ends read as "frontier" or as noise); performance with the overlay on in a long hallway; saving a real scan end to end and opening its 3D model; the model's orientation/pins against real nodes; `make check`; that Finish can be reached in a real hallway.
Open problems / handoff: (a) rescan Floor 4 (data lost, see 4); (b) hold the phone at a room and run `DEVICE=<id> make selftest-scan EXTRA="-scanExportProbe YES -scanCoverage YES"` for ~30 s and read "EXPORT PROBE" and "coverage=" lines; (c) the 3D model is not yet in .waypointmap bundles or cloud upload; no per-class colouring; (d) Finish gating on `mapped` may be too strict (consider allowing `.extending` after N seconds with a warning) - needs a real-hallway observation first.

## 2026-10-17 22:30 — Claude (agent, for Sachin) — New Scanner "Extend a map" connected to the real extension flow   [tags: ROUTING]
Area: U3 (UI flows: `Waypoint/UI/Scanner/*`, `Waypoint/Services/*`) edited at Sachin's request; U1 owns `CaptureController` (NOT modified: only its existing `start(extending:initialSegment:)`, `extensionStatus`, `canRecord` are used).
Before: the new Scanner's "Extend a map" button opened a "Coming soon" sheet. The real flow existed only in the classic `VolunteerView`.
Files created: `Package/.../Flows/ExtendChoices.swift` (which scan areas can be extended: only segments whose world-map file is on THIS phone), `Tests/.../ExtendChoicesTests.swift` (4 tests).
Files edited: `Flows/ScanFlow.swift` (`FinishGate.evaluate(... extensionPending:)`: Finish is blocked until the scan has found its place in the old map; default false, existing calls unchanged), `Waypoint/Services/ScanService.swift` (+`extensionStatus`, `canRecord` in the snapshot; `start(mapName:extending:initialSegment:)` with a default that just starts a demo scan), `LiveScanService.swift` (forwards to CaptureController), `UI/Scanner/ScanSessionModel.swift`, `ScannerFlowView.swift`, `ScanLibraryView.swift` (picker sheet replaces "Coming soon"; says why when Live mode / LiDAR is missing or no scan has position data), `LiveScanScreen.swift` (status banner), `WaypointUITests/WaypointUITests.swift` (+`testNewScannerExtendMapStartsFindingPlaceInSavedScan`).
Behavior: Extend a map -> choose a saved scan area -> scanner starts in extension mode, loads that area's ARWorldMap, shows the controller's status ("Find the selected scanned area. Move slowly until tracking recovers."), tags are ignored and Finish is disabled until `canRecord`; the new nodes then attach to the old map within 2 m (existing, tested core logic).
Verified: `make test` -> 221 tests, 0 failures; `make typecheck` OK; ON THE PHONE (build installed by the test run): `make uitest` 8/8 incl. the new test against the REAL "Rice Hall · Floor 4" scan: picker lists it, tapping it starts the extension and the screen shows the status text above with Finish disabled; `make selftest-e2e` 20 passed, 0 failed, 1 skipped.
NOT verified: that relocalization in the saved area actually SUCCEEDS (the test stops at "looking for its place"; Gate G2 still untested), recording and attaching new nodes, saving the extended map, the merged result navigating correctly, mock-mode behaviour (extension is refused there by the UI), `make check`. Extension on the real map: UNVERIFIED beyond the first screen.
Open problems / handoff: U1 should do the physical test (TESTING.md extension checklist): stand at the start of Floor 4, Extend, wait for "Extending this building", walk past Room 411, tag, Finish, then navigate to the new room.

## 2026-10-17 21:50 — Claude (agent, for Sachin) — Roadmap cleanup + status snapshot 2 (docs only)   [tags: DOCS]
Area: shared docs. Requested by Sachin: check the connected phone and the roadmap, clean up what is stale, say what is next for U1, cross-referencing branches first.
Files edited: `docs/ROADMAP.md` only (strike-through + labelled Update on 2 stale snapshot rows and the gate line; new section "Update 2026-10-17 21:45" with the branch table, phone contents, what is done and the ordered U1 next steps).
Evidence used: `git fetch` + ahead/behind of every remote branch; `xcrun devicectl device info files` and `copy from` on the phone's app container (Maps/…/map.json, route-memory.json); the on-phone test runs in the 21:30 entry.
Verified: facts above were read from the repo and the phone (Rice Hall · Floor 4: 17 nodes, rooms 409/410/411, schemaVersion 2, passes tools/validate_map.py; one route-memory entry of 12.3 m).
NOT verified: who ran the navigation that wrote that route memory, and whether it really localized in a hallway (no trial table exists); G2 is still untested.
Open problems / handoff: see the new ROADMAP section.

## 2026-10-17 21:30 — Claude (agent, for Sachin) — First real on-phone run of the guidance fixes; tester/launch fixes; briefing de-duplication   [tags: BUG, BUILD]
Area: B (Guidance) + D (tests). Phone: Sachin's iPhone 16 Pro Max, unlocked, build installed with `make build install` (so these results ARE for this code).
Found on the phone: (a) `make selftest-sim` did nothing useful because the phone had the "New interface" preference ON (leftover UserDefaults) and scripted launches landed on the new building picker -> `RootView` now forces the classic screens whenever a launch command is active; UI tests pin `-ui.newInterface NO`. (b) The opening briefing was followed in the same breath by "In 9 meters, turn right. Door to lobby on your left." -> after the queued opening briefing the planner marks the covered countdown thresholds and landmark as announced (plain route briefing unchanged). (c) UI tests slowed to 145-200 s and one failed: `mapPosition`/`headingRadians` (added by navigation-overhaul) were published every tick -> `setIfChanged`. (d) E2E check `nav.simulatedWalk` expected the old "Turn right." -> now accepts "Turn right 90 degrees." (navigation-overhaul wording).
Files edited: `Package/.../Guidance/FeedbackPlanner.swift`, `Tests/.../ContextualGuidanceTests.swift` (+1 test), `Waypoint/UI/RootView.swift`, `Waypoint/Navigation/NavigationController.swift`, `Waypoint/App/E2ESelfTest.swift`, `WaypointUITests/WaypointUITests.swift`.
Verified (this code, on the phone): `make selftest-sim` PASS, spoken: "Navigating to Room 204." / "You are at Door to lobby. Room 204 is about 11 meters away. Walk straight about 9 meters, then turn right." / "In 5 meters, turn right." / "In 2 meters, turn right." / "Turn right 90 degrees." / "You have arrived at Room 204." (no warning at arrival); voice chosen `com.apple.ttsbundle.siri_Nicky_en-US_compact` (13 Siri voices installed incl. Aaron, Nicky); `make selftest-e2e` -> 20 passed, 0 failed, 1 skipped (cloud); `make uitest` -> 7/7 (normal timings 9-30 s); `make test` -> 217 tests, 0 failures; typecheck OK; `make check` BUILD SUCCEEDED (earlier commit).
NOT verified: the sensor side-clearance numbers and hints with REAL LiDAR in a hallway; real arrival at a real door; the voice QUALITY by ear (the chosen Siri voice is the "compact" variant; an enhanced Siri voice may sound better); real-mode (relocalized) opening briefing; origin/navigation-overhaul commits 4158bc0 and c5ba14f (newer than my merge, NOT merged: they conflict in NavigationController).
Open problems / handoff: merge the two newest navigation-overhaul commits (speech queue "only safety interrupts"; saved scans load off the main thread) into this branch before main; they touch Speaker/NavigationController/Relocalizer.

## 2026-10-17 20:50 — Claude (agent, for Sachin) — Safety fix: remove the destination "quiet zone" (automated security review)   [tags: BUG]
Area: B (Guidance). Finding (fail-open safety suppression): `FeedbackPlanner` muted wall/door/window STOP/caution alarms AND kept the beacon on within 3 m of the final destination, so glass or a wall at a corner just before the room would give no warning.
Change: removed `atDestination` / `destinationQuietMeters` from `Guidance/FeedbackPlanner.swift`. Kept: arrival outranks obstacle alarms (navigation-overhaul), the post-arrival latch, and the existing `wayThrough` rule (the door of the destination room/door gives "open it" instructions, not "Stop"). STOP still plays the stop haptic and mutes the beacon everywhere except that wayThrough case.
Tests: replaced the quiet-zone test with `testNearTheDestinationRealObstaclesStillWarnAndStopStillMutesTheBeacon` (wall, window, chair, person all warn + haptic + beacon off 2 m before arrival) and `testTheDoorToTheDestinationRoomIsAnInstructionNotAnAlarm`. Earlier entry (20:30) edited with strike + Update.
Verified: `make test` -> 216 tests, 0 failures; `make typecheck` OK (60 app files).
NOT verified: on a phone (UNVERIFIED ON DEVICE; phone locked); whether the arrival message is reached reliably when a wall fills the depth view at the door (needs a real door).
Open problems / handoff: same as the 20:30 entry.

## 2026-10-17 20:30 — Claude (agent, for Sachin) — Guidance fixes: arrival-only at destination, sensor context in warnings, opening briefing, Siri voice; merged navigation-overhaul (branch fix/guidance-voice)   [tags: BUG, ROUTING, CONTRACT CHANGE]
Area: B (Guidance) + shared. Requested by Sachin (4 bugs). Branch check at start: `main`=dd38866 (pushed); `U3`, `app-ui-workflows` already inside main; NEW `navigation-overhaul` (Anmol Thapa, 10 commits, 7 behind main) overlapped heavily (arrival fix, single voice, re-route, route simplifier).
Merge of origin/navigation-overhaul: conflicts in BuildingMap.swift, Router.swift, NavigationController.swift, RootView.swift, MODULES/TESTING. Resolution: his guidance logic is the base (StartGate, off-route re-route by `distanceFromRoute`, simplified routes, `bestRoute` idea); my RoutePlanner now caches the RAW path (re-validated) and returns `nodes` (simplified, for walking) + `path` (raw), and `plan(fromPosition:)` tries several start nodes like his `bestRoute`; my blockage detour kept (`detourIfBlocked`), my own off-route code removed (his is used). CONTRACT CHANGE: his "schemaVersion = 2 (MapNode.extent)" collided with my format 2; resolved as map FORMAT 3 = adds optional `extent`; format 2 stays "explicit schemaVersion key". `MapSchema.current = 3`, `docs/MAP_FORMAT.md` (+Format 3), `docs/map-format/map-v3.json`, validator `CURRENT_SCHEMA = 3` + `extent` check.
Fixes: (1) arrival: his planner step 1b already puts arrival before obstacles; added a LATCH (after "You have arrived" the planner is silent until reset: no obstacle, lost-tracking or posture speech). ~~and a quiet zone (wall/door/window alarms muted within 3 m of the final destination)~~ **Update (Claude), security review:** the quiet zone was REMOVED before merge: it muted STOP alarms/beacon cut-off for walls and glass at a corner just before the destination (fail-open). Only the arrival priority, the post-arrival latch and the existing door-to-destination `wayThrough` instruction remain. (2) context: new `SceneContext`/`LateralScan`/`SceneAdvice` (core) fed by `ObstacleDetector.sideClearances` (LiDAR depth, sideways distance to nearest obstacle left/right within 3 m); warnings now end with a way out ("Stop. You are about to walk into a chair. Open space on your left."), "Narrow space. Go slowly." (rate-limited), and confirmed signs are spoken ("Sign reads Room 206."). (3) `StartBriefing` (core): where you are / what is around (max 2 named places + one sensor fact) / how far and the first leg; queued into the planner, spoken once at high priority after the position settles; "Navigating to X." shortened. (4) `VoicePicker` (core, tested) + `Speaker.voice`: Siri voice for the phone's language if installed, else best enhanced/premium, else system default (replaces hard-coded `AVSpeechSynthesisVoice(language: "en-US")`). E2E self-test now prints installed Siri voices and the chosen voice.
Files: created `Guidance/SceneContext.swift`, `StartBriefing.swift`, `VoicePicker.swift`, `Tests/.../ContextualGuidanceTests.swift` (16 tests); edited `FeedbackPlanner.swift`, `RoutePlanner.swift`, `Router.swift`, `BuildingMap.swift`, `NavigationController.swift`, `ObstacleDetector.swift`, `Speaker.swift`, `E2ESelfTest.swift`, `tools/validate_map.py`, tests, docs.
Commands run: `make test` -> 215 tests, 0 failures; `make typecheck` OK (60 app files); `python3 -m unittest discover -s tools` 10 OK; `make build` BUILD SUCCEEDED and `make install` onto Sachin's iPhone 16 Pro Max (this IS the current code).
Verified: the commands above (logic + type-check + build + install).
NOT verified: ANYTHING spoken or sensed on the phone with this code: launching was refused because the phone was LOCKED (`selftest-sim`, `selftest-e2e`, `uitest` not run on this build); whether a Siri voice is installed on the phone / actually used; the side-clearance numbers from real LiDAR (lateral axis sign, 3 m, 1.0 m, 1.4 m thresholds are untuned); the opening briefing wording by ear; real arrival at a door. `make check` not run. UNVERIFIED ON DEVICE.
Open problems / handoff: unlock the phone and run `make selftest-sim selftest-e2e uitest`; listen for the opening briefing and the voice; if no Siri voice is installed, download one (Settings > Accessibility > Spoken Content > Voices > English > Siri) and re-run. Branch not merged to main, not pushed.

## 2026-10-17 19:40 — Claude (agent, for Sachin) — Route memory persisted per map + device re-checks after merge/format change   [tags: ROUTING]
Area: B (Routing/Navigation) + D (`MapStore`, additive).
Files edited: `Model/MapStore.swift` (+`loadRouteMemory(mapId:)`, `saveRouteMemory(_:mapId:)`; file `route-memory.json` inside the map folder; a cache: NOT in bundles/sync, corrupt/missing file = empty memory), `Waypoint/Navigation/NavigationController.swift` (real mode loads memory on start and saves on stop; simulation never persists), `Tests/.../RoutePlannerTests.swift` (+2 tests), `docs/MODULES.md`.
Commands run: `make test` -> 129 tests, 0 failures; `make typecheck` OK; on Sachin's iPhone 16 Pro Max (unlocked): `make selftest-sim` -> SELFTEST PASS; `make selftest-e2e` -> 20 passed, 0 failed, 1 skipped (cloud not configured); `make uitest` -> first full run 6/7 (testSimulatedWalkFinishesAndShowsArrival failed: nav.status vanished after a 60 s wait), the test alone passed (22 s), and a second full run passed 7/7.
Verified: all of the above (the device runs of sim/e2e happened with the merge + planner + format 2; the final persist change was device-tested by the sim/e2e run listed here).
NOT verified: cause of the one-off uitest failure (not reproduced twice; treated as flaky, unproven); memory persistence on a real navigation (real-mode path is UNVERIFIED ON DEVICE, needs a scan + relocalization); `make check`; saving only happens on stop(), so a killed app loses that session's new routes.
Open problems / handoff: still no MeshExporter/3D viewer, relocalization test (G2), marker fallback, multi-segment relocalization.
**Update 2026-10-17 (Claude), CORRECTION:** `make selftest-sim` / `selftest-e2e` / `selftest-scan` only LAUNCH the build already installed on the phone; they do NOT rebuild or install (see Makefile). Only `make uitest`, `make run`, or `make build install` put new code on the phone. So the on-phone selftest results quoted in this entry ran on whichever build was installed at that moment (not necessarily this entry's code). The `make uitest` runs did build and install the code current at that time. Treat sim/e2e claims in this entry as NOT verified for this entry's code.

## 2026-10-17 19:00 — Claude (agent, for Sachin) — CONTRACT CHANGE: map format versioning (schemaVersion 2) + per-version specs   [tags: CONTRACT CHANGE]
Area: shared contract (Model/*), validator tool. Requested by Sachin ("add specs for each version, and versioning for the maps").
What changed: `BuildingMap` now has an instance field `schemaVersion` (encoded in the JSON). ~~`static let schemaVersion = 1`~~ (never encoded, unused) replaced by `MapSchema.current = 2` / `oldestReadable = 1` / `migrate(from:)`. Format 1 = the old shape with no key; format 2 = same shape + `"schemaVersion": 2`. Decoding: missing key = 1; 1...current accepted and migrated in memory; newer than the app -> refused ("newer than this app understands. Update Waypoint."); 0/negative refused. Encoding always writes the current format. Because the shapes are identical, old apps can still read format-2 files (unknown key ignored) and the server needs no migration (rows without the key read as format 1).
Files created: `docs/MAP_FORMAT.md` (spec per version + how to add N+1), `docs/map-format/map-v1.json`, `docs/map-format/map-v2.json`, `Package/.../Tests/.../MapSchemaTests.swift` (8 tests).
Files edited: `Model/BuildingMap.swift` (MapSchema, custom init(from:)), `Samples/rice-hall-sample.json` (+schemaVersion 2), `tools/validate_map.py` (+CURRENT_SCHEMA/OLDEST_SCHEMA checks, U3's file, edited with the contract), `tools/test_validate_map.py` (+1 test), `AGENTS.md` (pointer under rule 3), `docs/MODULES.md`.
Commands run: `make test` -> 127 tests, 0 failures; `make typecheck` OK (58 app files); `python3 -m unittest discover -s tools` -> 10 OK; `python3 tools/validate_map.py` PASS; both fixtures validated by Swift and Python tests.
Verified: the commands above (Swift 127 pass, Python 10 pass, sample + both fixtures valid, typecheck OK).
NOT verified: loading a format-1 map already saved on a phone (needs a device; Swift tests cover the decode path only); `make selftest-*` / `make check` after this change (phone locked earlier); SQL (no SQL changed, not re-run); the Supabase server holding old rows (reasoned, not exercised).
Open problems / handoff: teammates must pull before saving maps, otherwise an old app drops nothing but also will not write the key (still readable as format 1). The three validators (Swift, Python, SQL) are still separate implementations.

## 2026-10-17 18:00 — Claude (agent, for Sachin) — Merge app-ui-workflows + wire RoutePlanner into NavigationController (branch feature/route-memory)   [tags: ROUTING, BUILD]
Area: B (Navigation) + shared merge. Touches U3's `app-ui-workflows` files only through the merge; `NavigationController` is B/A.
Merge: `origin/app-ui-workflows` merged into `feature/route-memory` (commit 03d9007). Conflicts resolved by keeping BOTH sides: `Waypoint/UI/RootView.swift` (Home button keeps `toolbar.home` id AND the Settings gear/sheet; E2E `.task` kept AND the new-interface `.onAppear`), `docs/MODULES.md`, `docs/TESTING.md` (both sets of rows).
Files edited: `Package/.../Routing/RoutePlanner.swift` (+`RoutePlanner.offRouteDistance`, `BlockageTracker`), `Tests/.../RoutePlannerTests.swift` (+3 tests), `Waypoint/Navigation/NavigationController.swift` (routes now come from `RoutePlanner`; REAL mode only: re-route when > 6 m off route or STOP obstacle for 4 s, 5 s rate limit, "Path blocked. Taking another way."; `SignReader` now fed with frames, confirmed signs are LOGGED only, not acted on), `docs/MODULES.md`.
Simulation mode deliberately does NOT re-route (the virtual walker follows its fixed route).
Commands run: `make test` -> 119 tests, 0 failures (85 main + 21 app-ui-workflows FlowTests + 13 mine); `make typecheck` -> OK (58 app files, 1 UI test file).
Verified: the two commands above.
NOT verified: `make selftest-sim` / `selftest-e2e` after this change (phone was locked -> launch denied; they passed before the merge); `make check`; `make uitest`; every new live behaviour (re-route, blockage detour, sign logging) is UNVERIFIED ON DEVICE; thresholds (6 m, 4 s, 5 s) are guesses; the new UI (app-ui-workflows) has still not been run on a device by anyone.
Open problems / handoff: unlock the phone and run `DEVICE=<id> make selftest-sim selftest-e2e`; decide whether sign disagreement may re-anchor (needs field logs); `RouteMemory` lives only in memory (not persisted with MapStore); map JSON has no written schema version (see answer in chat: `BuildingMap.schemaVersion` is never encoded).
**Update 2026-10-17 (Claude), CORRECTION:** `make selftest-sim` / `selftest-e2e` / `selftest-scan` only LAUNCH the build already installed on the phone; they do NOT rebuild or install (see Makefile). Only `make uitest`, `make run`, or `make build install` put new code on the phone. So the on-phone selftest results quoted in this entry ran on whichever build was installed at that moment (not necessarily this entry's code). The `make uitest` runs did build and install the code current at that time. Treat sim/e2e claims in this entry as NOT verified for this entry's code.

## 2026-10-17 17:10 — Claude (agent, for Sachin) — Route memory + live-adaptive RoutePlanner (branch feature/route-memory)   [tags: ROUTING]
Area: B (Routing). Requested by Sachin: remember shortest paths between any two points, but never defer to memory; stay adaptable (blockages, signs).
Files created: `Package/WaypointCore/Sources/WaypointCore/Routing/RoutePlanner.swift` (EdgeKey, RouteMemory, RoutePlanner, SignVerdict), `Package/WaypointCore/Tests/WaypointCoreTests/RoutePlannerTests.swift` (10 tests).
Files edited: `Routing/Router.swift` (new optional `avoiding:` edge set, default empty so existing callers are unchanged), `docs/MODULES.md` (new row).
Behavior: memory is a Codable cache keyed (from, to, allowStairs), re-validated on EVERY lookup (nodes/edges exist, no stairs if disallowed, no live blockage, map fingerprint unchanged) or it is recomputed with A*. Blockages are temporary (TTL, default 10 min); detours are not stored so memory keeps the undisturbed shortest path. `warm()` precomputes all labelled-place pairs. `interpretSign` compares a read sign to the believed position: consistent / relocate (re-plan from the sign's node) / ambiguous / unknown.
Commands run: `make test` -> 95 tests, 0 failures (85 old + 10 new); `make typecheck` -> OK; `make test-hooks` -> 15 passed; `python3 tools/validate_map.py Samples/rice-hall-sample.json` PASS; tools unit tests 9 OK; on Sachin's iPhone 16 Pro Max: `DEVICE=... make selftest-sim` -> SELFTEST PASS (simulated walk, arrived at Room 204); `make selftest-e2e` -> 20 passed, 0 failed, 1 skipped (cloud: Supabase not configured).
Verified: all of the above.
NOT verified: RoutePlanner is NOT wired into NavigationController/SignReader/ObstacleDetector yet, so the app does not use it; no real blockage/sign detection on a device (UNVERIFIED ON DEVICE); `make uitest`, `make selftest-scan`, `make check`, SQL/Supabase tests and live cloud were not run; real LiDAR scanning and relocalization (Gate G2) still need a human walk.
Open problems / handoff: TODO(B) wire planner into NavigationController (replace direct `Router.route`, call `detour` when ObstacleClassifier reports a persistent block, call `interpretSign` on SignReader confirmations); persist `RouteMemory` next to the map in MapStore; decide TTL and `signAgreementRadius` (5 m) from field data.
**Update 2026-10-17 (Claude), CORRECTION:** `make selftest-sim` / `selftest-e2e` / `selftest-scan` only LAUNCH the build already installed on the phone; they do NOT rebuild or install (see Makefile). Only `make uitest`, `make run`, or `make build install` put new code on the phone. So the on-phone selftest results quoted in this entry ran on whichever build was installed at that moment (not necessarily this entry's code). The `make uitest` runs did build and install the code current at that time. Treat sim/e2e claims in this entry as NOT verified for this entry's code.
## 2026-10-17 — Claude (agent, for Anmol) — Suggest a way round a blockage, with the reason   [tags: BUILD]
Area: C (Vision) + B (Guidance). Branch `avoidance-reasoning` off `navigation-overhaul`. See D-045.

Request: "there should also be reasonings like 'Turn slightly left, there is a wall ahead'". `TurnReason` existed and
was tested but had no caller, because nothing produced an avoidance turn in the first place.
Files created (WaypointCore): `Vision/AvoidanceAdvisor.swift` - ahead/left/right clearances in, a suggested side out;
conservative by design (see D-045), sticky while blocked so the cue cannot flutter.
Files edited (WaypointCore): `Guidance/SpokenPhrases.swift` (+`TurnSpeech.avoidance(side:obstacle:)`),
`Guidance/FeedbackPlanner.swift` (+`avoidTowards:`; says the way round once per obstacle, re-armed when clear; never
for a door we were routed through).
Files edited (app): `Waypoint/Vision/ObstacleDetector.swift` (`DepthHit.clearance` - nearest thing per side, split by
`Geometry.cameraLocalToUser` so the axis is the USER's left/right, not the image's),
`Waypoint/Navigation/NavigationController.swift` (holds the advisor, feeds it the clearance, passes the suggestion).
Tests added: `AvoidanceAdvisorTests` (8) - silent while the way is open, picks the clearly better side, silent when
neither is clearly better or the better one is still too tight, nothing-detected counts as open, the suggestion is
held while blocked and forgotten when clear, and the wording. `AvoidanceCueTests` (6) - the cue is spoken, the STOP
warning is still given alongside it, said once per obstacle, re-armed for the next, NOT offered for a door on the
route, and absent entirely when no side was measured.
Verified: `make test` -> **253 tests, 0 failures** (was 247); `make typecheck` OK (61 app files, 1 UI test file);
`make check` -> BUILD SUCCEEDED.
NOT verified: **UNVERIFIED ON DEVICE.** No schema change; recordings unaffected. Thresholds (blocked under 1.5 m,
decisive margin 0.6 m, usable 1.2 m, 0.35 m ahead/side split) are guesses.

---

## 2026-10-17 — Claude (agent, for Anmol) — Resume cue was silently dropped; turns name their destination   [tags: BUILD, BUG]
Area: B (Guidance). Branch `turn-context-and-resume` off `navigation-overhaul`. See D-044.

Asked first whether the earlier speech commits had been overridden: **no** - `3537ba1`, `df816a3`, `6478c3b` are all
ancestors of HEAD, verified with `git merge-base --is-ancestor`.
THE BUG: "Continue straight." was `.normal`, and `SpeechGate` drops `.normal` whenever the speaker is busy - which it
always is right after a turn. `FeedbackPlanner` marks a cue announced (`lastKey = key`) regardless of whether the
speaker took it, so it was never retried. The resume cue was lost after every turn, silently.
Files edited (WaypointCore): `Guidance/FeedbackPlanner.swift` (all direction cues are `.high` so they queue instead of
being dropped; both the corner cue and the heading cue pass the destination), `Guidance/SpokenPhrases.swift`
(+`TurnSpeech.withDestination`), `Routing/GuidanceInstruction.swift` (+`destinationLabel`),
`Routing/RouteFollower.swift` (fills it from `route.last?.label` at all three construction sites).
Tests added: `TurnContextAndResumeTests` (6) - a real turn names the destination, corrections and "continue straight"
stay bare, an unlabelled destination changes nothing, the planner actually puts it in the cue, the resume cue is
emitted at `.high`, and the gate QUEUES a `.high` line while a turn is still being spoken.
Two existing assertions pinned `.normal` for "Continue straight." and were updated - that priority is precisely what
caused the bug.
No schema change: `GuidanceInstruction` is a runtime type, never persisted. `schemaVersion` stays 3 and existing
recordings are unaffected.
Verified: `make test` -> **239 tests, 0 failures** (was 233); `make typecheck` OK (61 app files, 1 UI test file);
`make check` -> BUILD SUCCEEDED (run on its own line).
NOT verified: **UNVERIFIED ON DEVICE.** What to listen for: after a turn you should now hear "Continue straight."
rather than silence, and a square corner should say "Right, toward Room 402."
Open / handoff: `TurnReason` (the "why" for turns that are NOT the route, e.g. avoiding a wall) is still built,
tested and unwired - the third option offered and not chosen this round.

---

## 2026-10-17 — Claude (agent, for Anmol) — Scan-both-directions coverage; keyframe recorder off the hot path   [tags: BUILD, BUG]
Area: A (capture/relocalization) + shared core. Branch `bidirectional-coverage` off `navigation-overhaul`. See D-043.

Trigger: "I scan one direction, but when walking back from that direction, it struggles."
Finding that reframed it: the keyframe matcher requires `!usingWorldMap` and every saved scan has a world map, so the
matcher has almost certainly NEVER run on a real map. ARKit's own relocalization is viewpoint-dependent, so the
directional problem is ARKit's, not the fingerprints'.
Files created (WaypointCore): `Scan/CoverageTracker.swift` - floor-plane cells x heading octants; a cell is covered
once two of its headings are roughly reciprocal; `returnCoverage` and `shouldPromptReturnWalk`.
Files edited (WaypointCore): `Model/BuildingMap.swift` (`merged(with:)` now unions keyframes by id - it silently
dropped them before), `Model/MapStore.swift` (`validate()` now checks keyframe count, descriptor size and finiteness;
+`maxKeyframes`, +`maxKeyframeDescriptorBytes`).
Files edited (app): `Waypoint/Capture/CaptureController.swift` (samples `CoverageTracker` ~4 Hz, publishes
`returnCoverage` / `shouldWalkBack`; keyframe recording now gated on `UIPrefs.visualFingerprintsEnabled` AND throttled
to 0.5 s - it used to run on every frame at 60 Hz), `Waypoint/Services/ScanService.swift` + `LiveScanService.swift`
(coverage through the snapshot seam), `Waypoint/UI/VolunteerView.swift` and `Waypoint/UI/Scanner/LiveScanScreen.swift`
(percentage in the HUD + a warning banner; WARNS, never blocks).
Tests added: `CoverageTrackerTests` (11) - one-direction scores 0 and prompts, there-and-back scores 1, half a return
is in between, approximately-opposite headings count, sweeping left/right does NOT count, wrap-around at 350/170
degrees, negative yaw, a short walk is not judged, empty is safe, non-finite poses ignored, reset.
`KeyframeMergeAndValidationTests` (6) - both sides' keyframes survive a merge, no duplicates, NaN position and
infinite yaw refused, oversized descriptor refused, too many refused, a reasonable one passes.
One test of mine failed first and the TEST was wrong, not the code: my `walkBack` helper stopped a stride short of the
start, leaving the first cell seen one way, so coverage read 10/11. A volunteer walks all the way back.
Model/* was touched (`BuildingMap.merged`, `MapStore.validate`) but the JSON SHAPE is unchanged: no field added or
renamed, `schemaVersion` stays 3, `Samples/rice-hall-sample.json` untouched. Behaviour only - a merge that used to
lose keyframes now keeps them, and invalid keyframes are now refused. Hence no CONTRACT CHANGE tag.
Verified: `make test` -> **233 tests, 0 failures** (was 216); `make typecheck` OK (61 app files, 1 UI test file);
`make check` -> BUILD SUCCEEDED (run on its own, not chained).
NOT verified: **UNVERIFIED ON DEVICE.** No map format change - `schemaVersion` stays 3 and existing recordings load
unchanged. Coverage thresholds (2 m cells, 8 octants, 60-degree tolerance, prompt under 60%) are guesses.
Open / handoff - the A/B that tests the hypothesis:
1. Scan a corridor ONE way. HUD coverage should stay low and the prompt appear. Save, kill the app, relaunch, stand at
   the FAR end facing back, Navigate. This is the control; expect the reported difficulty.
2. Scan the same corridor BOTH ways until coverage is high. Save as a second map. Repeat step 1's walk against it.
   Success = it relocalizes from the far end where the one-direction map did not.
3. Console: "using world map for segment X" confirms ARKit's path is in use and keyframes are not involved.
4. `DEVICE=<id> make selftest-scan` shows tracking quality per second - useful for comparing a scan with fingerprints
   on (old behaviour) against off, since per-frame Vision work is the suspect for the degraded maps.
5. Known gap, documented not fixed: `Keyframe` has no `segmentId` (D-043).

---

## 2026-10-17 16:20 — Claude (agent, for Sachin) — Docs-on-every-commit hook for agents and humans (AGENTS.md rule 12)   [tags: BUILD, DOCS]
Area: D (build system/docs), shared; also touches `.github/` (U3's lane per ROADMAP, did not exist yet) at U1's request that every dev follows this.
Files created: `scripts/docs-sync.sh` (check | stub | install | status | session), `scripts/githooks/pre-commit`, `scripts/test-docs-sync.sh`, `.claude/settings.json` (SessionStart auto-installs the hook for Claude Code users), `.gitattributes` (LF for scripts so Git Bash on Windows works), `.github/workflows/docs-check.yml` (PR + push-to-main backstop).
Files edited: `Makefile` (+`hooks`, +`test-hooks`, `setup` installs the hook), `scripts/doctor.sh` (warns if not installed), `AGENTS.md` (rule 12 + `make hooks` row), `docs/DECISIONS.md` (D-024), `docs/WORKFLOW.md`, `docs/SETUP.md`, `docs/TESTING.md`, `docs/MODULES.md` (additive Update notes).
Behavior: a commit touching code files (swift/sql/py/sh/yml/json/plist/xcconfig/Makefile) is refused unless the same commit adds a NEW `## YYYY-MM-DD` entry at the top of docs/WORKLOG.md that has `Verified` and `NOT verified` lines and no leftover FILL placeholders. `docs-sync.sh stub` scaffolds the entry from `git status`. Docs-only commits, merges, rebases and cherry-picks pass. Warnings only: markdown lines removed without ~~strikethrough~~ (rule 11), new Swift files without a header or missing from MODULES.md, Model/* edits without CONTRACT CHANGE. Escape: `WAYPOINT_SKIP_DOCS=1` (CI still checks).
Commands run: `sh scripts/test-docs-sync.sh` -> 15 passed, 0 failed (throwaway repo); `sh scripts/docs-sync.sh install` and `status` in this clone; `make help`, `./scripts/doctor.sh` (hook line PASS).
NOT verified: the GitHub Action has never run (no push yet; it also needs Actions enabled and, to block merges, "required status check" set in repo settings); Claude Code's first-run trust prompt for project hooks in `.claude/settings.json`; behavior on Windows Git Bash (U3/U4) and with Codex (it ignores `.claude/`, so it depends on AGENTS.md + `make hooks`); not run in a worktree.
Limits: git hooks are not cloned. Each dev must run `make hooks` once (or open a Claude Code session here); teammates only get this after they pull. Tell U2, U3, U4 and the Codex/UI agents.
Open problems / handoff: decide whether to mark `docs-check` a required status check; U3 may fold this workflow into INF-2.

## 2026-10-17 16:16 — Claude (agent, for Sachin) — Test run of U3, merge sync, repo-wide docs reconciliation   [tags: DOCS, BUILD]
Area: shared (docs) + two Swift header comments. Requested by U1 ("full depth scan", then "yes" to fixing the findings).
Branch work: checked out `U3`, ran tests, fast-forwarded local `main` to U3 (0fc02d5), then to `origin/main` e22e5cb (rishyam1's docs-only commit). Nothing pushed by this entry.
Verified (I ran these): `make test` -> 85 tests, 0 failures (includes MapExtensionTests x3 and CloudTests); `make typecheck` -> OK (22 app files, 1 UI test file); `python3 tools/validate_map.py` -> sample PASS; Python unit tests -> 9 PASS (Python 3.9.6).
  SQL: throwaway Docker container from the cached `public.ecr.aws/supabase/postgres:17.6.1.136` image (the running `supabase_*_intakeu` stack was NOT touched; container removed afterwards). The image has `auth` but no `storage` schema, so `storage.buckets/objects/foldername/filename` were STUBBED. Migrations 0001, 0002, 0003 applied in order without errors; `supabase/tests/canonical_maps.sql` and `extension_connections.sql` both printed PASS and left no rows. Grants: `authenticated` -> `merge_building_internal` = permission denied; `anon` -> `extend_building` = permission denied; `authenticated` -> `extend_building` runs ("Sign in first").
NOT verified: the storage RLS policy in 0002 (stubbed schema); live Supabase concurrency; any phone behavior (UNVERIFIED ON DEVICE); a merge of `app-ui-workflows` (only a dry-run `git merge-tree`: conflict in `Waypoint/UI/RootView.swift`, docs auto-merge; nothing was compiled).
Docs updated (strike-through + labelled Update, nothing deleted): `docs/SETUP.md` (run migrations 0002 and 0003; test count), `README.md` (counts, canonical maps), `docs/TESTING.md` (closed the "not verified" note; counts 45 -> 85, UI tests 5 -> 7), `docs/MODULES.md` (verification note, Supabase row, layout additions), `Architecture.md` (migration status), `docs/ROADMAP.md` (two stale cells + a status snapshot against Revision 3), `docs/WORKFLOW.md` (branch naming conflict), `docs/DECISIONS.md` (new D-023), this WORKLOG (22:45 entry's stale `origin/U3` statement struck).
Code (comments only): header Status lines in `Cloud/SupabaseClient.swift` and `Model/MapBuilder.swift`.
Known leftover: the "Newest entry at the TOP" header and the entry template further down this file sit below the first U3 entries (they were inserted above it); moving them would rewrite history, so it is only noted here.
Open problems / handoff: ROADMAP snapshot shows Gate G2 (relocalization x5) has not been run, which blocks the critical path; decide on the `app-ui-workflows` merge and who owns `Waypoint/UI/{Scanner,Navigator}` and `Waypoint/Services`; ask U2 what the MacBook Air is working on (no commits or entries from U2).

## 2026-10-17 — Codex for U3 — Main integration authorized after reported checks
Area: shared integration; user explicitly authorized merging U3 into main.
Files edited: `docs/WORKLOG.md` (this verification/handoff entry only).
User-reported verification: make test, make typecheck, and make check all passed on the Mac; migration 0003 and both SQL test scripts also reported success in Supabase. These update earlier pending-check notes; agent did not directly run the Mac or dashboard checks.
Commands: git fetch origin; ancestry and diff whitespace checks; git switch main; git merge --ff-only U3 (0fc02d5, no conflicts); documentation commit and push to origin/main.
NOT verified: real-device scan extension and cross-phone alignment remain UNVERIFIED ON DEVICE. No claim that compile/SQL checks prove AR behavior.
Handoff: teammates pull main; perform the extension checklist in docs/TESTING.md on LiDAR phones before relying on it for navigation.


## 2026-10-17 — Codex for U3 — Align extension rules and add existing-building scan flow
Area: D (SQL/UI), A (capture and MapBuilder); U3 explicitly requested BOTH integration fixes, authorizing these A-owned edits.
Files created: `supabase/migrations/0003_extension_connections.sql`, `supabase/tests/extension_connections.sql`, `Package/WaypointCore/Tests/WaypointCoreTests/MapExtensionTests.swift`.
Files edited: `Model/MapBuilder.swift` (bounded first-breadcrumb attachment), `Waypoint/Capture/CaptureController.swift` (load selected ARWorldMap before recording, preserve building ID, unique segment ID, gate tagging/saving, merge saved snapshot), `Waypoint/UI/VolunteerView.swift` (existing building and scan segment pickers, explicit attachment, cancel/done), `supabase/CANONICAL_MAPS.md`, docs WORKLOG/MODULES/ROADMAP/TESTING.
Behavior: new SQL wrapper rejects previously absent edges joining two pre-existing canonical nodes, preserving the local import protection; internal merge RPC loses API execution grants. Original already-applied 0002 remains unchanged. New segments attach only to corridor/junction nodes within 2 m and 0.75 m vertical offset; missing saved world maps cannot start an extension. No marker-only or new-origin fallback. New scans also get unique segment IDs. Save merges with the current local map and retains existing scan files; acquisition freezes during save and stops on success.
Commands run: `git diff --check`; `python -B tools/validate_map.py` (sample PASS); `python -B -m unittest discover -s tools -p "test_*.py" -q` (9 PASS); `make test` and `make typecheck` (both fail to launch: make not installed on Windows).
Verified: Python regression suite and whitespace check only. Added 3 Swift tests for attachment/identity/route reachability/local import, bounded failure/no mutation, and one-time attachment; SQL test checks shortcut rejection, legitimate new-node path, and repeat/reversed existing edges. New Swift/SQL tests NOT executed here; no Swift/Xcode/PostgreSQL available.
NOT verified: iOS compilation, new Swift tests, new migration/tests, world-map relocalization and cross-phone scan alignment; UNVERIFIED ON DEVICE. Earlier user-reported 0002 test success does not cover 0003.
Handoff: apply 0003 then run both SQL test files; Mac teammate runs make test/typecheck and the new extension device checklist in docs/TESTING.md. No JSON contract changes, dependencies, commit, push, or remote database writes by the agent.


## 2026-10-17 — Codex for U3 — Shared-map verification and branch handoff
Area: D (cloud/backend).
Files edited: `docs/WORKLOG.md` (this entry); committing the canonical-map files listed in the entry below at U3's request.
User-reported verification: U3 ran the full migration `0002_canonical_maps.sql` and the full `supabase/tests/canonical_maps.sql` in the Supabase SQL Editor; both returned success. This updates the earlier unverified SQL status below; the agent did not directly observe the dashboard.
Commands run: `git status --short --branch`, `git diff --check`; commit and push to `origin/U3` requested. No main merge.
Verified: whitespace check passed. Earlier Python regression suite: 9 PASS.
NOT verified: Swift tests/typecheck still require a Mac (prior attempts failed because make is unavailable); live concurrent requests and app integration remain unverified; UNVERIFIED ON DEVICE.
Handoff: Mac teammate should run make test and make typecheck, then device cloud checks. Full extend-existing-map capture flow remains separate.


## 2026-10-17 — Codex for U3 — Canonical shared building map [tags: CONTRACT CHANGE]
Area: D cloud/backend; user explicitly requested one main map per building that other users can extend and see.
Files created: `supabase/migrations/0002_canonical_maps.sql`, `supabase/tests/canonical_maps.sql`, `supabase/CANONICAL_MAPS.md`.
Files edited: core `Cloud/{SupabaseClient,CloudModels,SyncEngine}.swift`, `CloudTests.swift`, app `CloudController.swift`, `SyncView.swift`; docs WORKLOG/MODULES/DECISIONS (additive notes). App UI edits are necessary for the requested cloud behavior (remove private publish option, review every shared download).
CONTRACT CHANGE: cloud endpoint now uses canonical_buildings and rpc/extend_building; optional segment_owners column tracks contributor scan paths. BuildingMap JSON unchanged, so no schemaVersion bump or sample change. Apply migration 0002 before using this client. Original 0001 data remains; existing maps must be republished.
Behavior: one unique map UUID per building; all authenticated users can read; atomic additive merges preserve concurrent/stale contributions; existing-node/edge edits rejected. Different names are not a building identity mechanism. Scan alignment and unique segment IDs remain the capture owner's responsibility.
Commands: `git diff --check`; Python validator tests (9 PASS); `make test` and `make typecheck` attempted, both unavailable because make is not installed on Windows.
Verified: existing Python suite passes, diff whitespace checks pass. Updated Swift request assertions and added contributor-file-path regression; added transactional SQL functional test.
NOT verified: SQL migration/test execution (no PostgreSQL here), Swift tests/typecheck (Mac required), concurrency on live server; UNVERIFIED ON DEVICE. No remote database changed, no dependencies added, no commit/push.
Handoff: apply 0002 and run supabase/tests/canonical_maps.sql in dashboard; Mac owner runs required make checks. Full extend-existing-map capture UI is still a separate roadmap task. Prior D-015 contributor-row behavior is superseded for updated clients, retained for old-client data.


## 2026-10-17 — Codex for U3 — Windows map validator (U3.4)
Area: D (U3 tooling)
Files created: `tools/validate_map.py`, `tools/test_validate_map.py`, `tools/README.md`.
Files edited: `docs/WORKLOG.md` (this entry), `docs/MODULES.md` and `docs/ROADMAP.md` (additive status notes).
Files deleted: none. No Swift, schema, sample, dependencies, or CI workflow changed.
Commands run: `py --version` (launcher reports no installed Python); `python --version` (3.14.0); `make help`, `make test`, `make typecheck` (all unavailable: make not installed on Windows); `python -B tools/validate_map.py`; `python -B -m unittest discover -s tools -p "test_*.py" -v`; `git diff --check`.
Verified: sample PASS; 9 Python tests PASS, including hostile segment ids, nonfinite/overflow coordinates, duplicate UUIDs with different case, bad references, self-loops, distance tolerance, size limits, malformed bundles, required fields, and CLI failure exit codes. Whitespace check passed.
NOT verified: Swift unit tests and iOS typecheck require a Mac; UNVERIFIED ON DEVICE. Python float math approximates SIMD and may differ at rounding boundaries; marker finite-number checking is intentionally stricter. Real-world map truth and existing-map merge checks are outside this tool's scope.
Open problems / handoff: INF-2 CI wiring is still separate, as requested by U3. Mac teammate should run required make checks before merging. No commit or push performed.


**Newest entry at the TOP.** Every human and agent adds an entry when they finish a block of work.
This is how four people plus LLM agents stay in sync, so be explicit and complete.

## Entry template (copy this)

```
## YYYY-MM-DD HH:MM — <name or agent> — <one-line summary>   [tags: CONTRACT CHANGE | BUILD | DOCS | BUG]
Area: A | B | C | D | shared
Files created:  <paths>
Files edited:   <paths + what changed>
Files deleted:  <paths>
Commands run:   <notable commands>
Verified:       <what you ran and the result, e.g. `make test` -> 25 passed>
NOT verified:   <anything involving a phone/AR/audio/haptics/Multipeer: "UNVERIFIED ON DEVICE">
Open problems / handoff: <what the next person must know>
```

---

## 2026-10-17 — Claude (agent, for Anmol) — Fingerprints off by default; align once; arrow follows speech   [tags: BUILD, BUG]
Area: A (relocalization) + UI. Branch `keyframe-oneshot` off `navigation-overhaul`. See D-042.

The user's question answered the diagnosis: the embeddings set `mapToWorld`, and position, route, instructions and
speech are all computed through it, so a bad alignment presents as broken pathfinding. Route length swung 0.7 -> 2.2
-> 10.3 -> 13.3 m between recomputes, i.e. the position was moving, not the router.
Cause: the re-arm added in D-039 fired on every `.limited(.relocalizing)` dip, which in a corridor is constant, so a
different keyframe re-anchored the world every few seconds.
Files edited: `Waypoint/Relocalization/Relocalizer.swift` (re-arm removed - one alignment per session; matching also
gated on the new preference), `Waypoint/Services/ServiceMode.swift` (+`visualFingerprints`, default FALSE, and
`visualFingerprintsEnabled`), `Waypoint/UI/SettingsView.swift` (toggle + explanation),
`Package/WaypointCore/Sources/WaypointCore/Flows/GuidanceState.swift` (+`spokenKind`),
`Waypoint/UI/Navigator/GuidingView.swift` (arrow uses `spokenKind` first).
Tests added: `ArrowMatchesSpeechTests` (3) - the arrow follows the spoken direction rather than the latest
instruction, turn-around and straight are recognised, and non-directions ("You have arrived", "Recalculating", empty,
nil) leave the arrow alone.
Verified: `make test` -> **216 tests, 0 failures** (was 213); `make typecheck` OK (61 app files, 1 UI test file);
`make check` -> BUILD SUCCEEDED.
NOT verified: **UNVERIFIED ON DEVICE.** Recording and the map format are untouched - keyframes are still RECORDED on
every scan, only their USE is now opt-in.
Open / handoff:
1. With fingerprints OFF the app should behave as it did before D-038. That is the configuration to demo with.
2. To make them usable: calibrate `KeyframeIndex.defaultMaxDistance` using the log line
   "recognised a keyframe (distance X)", then turn the toggle on.
3. Still unknown: whether the matcher ever runs on a map that HAS a saved world map (D-040). The console says
   "using world map for segment X" or "no world map on disk".

---

## 2026-10-17 — Claude (agent, for Anmol) — Route continuously; delete the staleness machinery   [tags: BUILD, BUG]
Area: B (Navigation). Branch `continuous-routing` off `navigation-overhaul`. See D-041.

Fourth report of the same fault: the user at Start, the route starting across the building, 5 waypoints / 14.3 m
unchanged across every screenshot. My three previous fixes all added logic to decide WHEN the route had gone stale;
each fixed one case and exposed another.
Change: `NavigationController` recomputes the route from the current position every 0.5 s, unconditionally, and adopts
it silently when it differs. "Recalculating" is spoken only if the user had strayed >3 m from the previous route, at
most once per 5 s. `planner.reset()` is no longer called on a recompute - that was what bypassed the direction
cooldown and caused bursts of contradictory speech.
Deleted: `offRouteTicks`, `routeDistanceHistory`, `rerouteDriftMeters`, `rerouteTicks`, `lastRerouteTime` and the
whole off-route/drift decision. Pose-jump detection remains for one job: keeping a relocalization correction out of
the movement detector.
Added: a log line when the route changes - user position, first waypoint position, distance between them, waypoint
count. If this ever recurs, that line diagnoses it without another walk.
Verified: `make test` -> 213 tests, 0 failures; `make typecheck` OK (61 app files, 1 UI test file); `make check` ->
BUILD SUCCEEDED. No leftover references to the removed machinery.
NOT verified: **UNVERIFIED ON DEVICE.** Recording and the map format are untouched.
Open / handoff:
1. If the route STILL starts away from the user after this, the fault is not in when we recompute but in the position
   itself - the new log line will show the user's position and the route's first waypoint and settle it.
2. Still unknown whether keyframes run at all on a map with a saved world map (D-040); the console says
   "using world map for segment X" or "no world map on disk".

---

## 2026-10-17 — Claude (agent, for Anmol) — Clear the coarse alignment; rebuild the route after a correction   [tags: BUILD, BUG]
Area: A (relocalization) + B (navigation). Branch `route-rebuild-on-fix` off `navigation-overhaul`. See D-040.

Report with screenshots: the user stands at Start while the route begins across the building.
Both faults were mine, from the last two commits.
Files edited: `Waypoint/Relocalization/Relocalizer.swift` - when the fix becomes `.worldMap`, `mapToWorld` is reset to
the identity, because ARKit's world frame IS the map frame once it has relocalized into the saved map; a leftover
keyframe transform offset every coordinate.
`Waypoint/Navigation/NavigationController.swift` - a pose jump now REBUILDS the route from the corrected position
instead of merely being ignored. Quietly: no planner reset and no "Recalculating", since nothing changed for the user,
only our estimate of where they are.
Verified: `make test` -> 213 tests, 0 failures; `make typecheck` OK (61 app files, 1 UI test file); `make check` ->
BUILD SUCCEEDED.
NOT verified: **UNVERIFIED ON DEVICE.** Recording and the map format are untouched; existing recordings are unaffected.
Open / handoff:
1. **Keyframes may not be doing anything on a map that has a saved world map** - the matcher needs `.normal` tracking
   and is skipped when a world map was supplied, and ARKit only reports `.normal` once it has already relocalized.
   The console says which case applies: "using world map for segment X" or "no world map on disk". Worth checking
   before investing further in keyframes.
2. Still uncalibrated: `KeyframeIndex.defaultMaxDistance` (18).

---

## 2026-10-17 — Claude (agent, for Anmol) — Latch the keyframe fix; ignore pose jumps   [tags: BUILD, BUG]
Area: A (relocalization) + B (navigation). Branch `keyframe-latch` off `navigation-overhaul`. See D-039.

Report after testing D-038: relocalization got "very quick", but pathfinding broke and directions came in
contradicting bursts. Screenshots showed the user's marker at the destination, then mid-building, then off the trail.
Cause (mine): the keyframe matcher kept running while `fix == .keyframe`, so a different keyframe re-anchored
`mapToWorld` every 0.5 s. Each re-anchor teleported the position -> looked off-route -> re-route -> `planner.reset()`
-> direction cooldown cleared -> burst of contradictory speech.
Files edited: `Waypoint/Relocalization/Relocalizer.swift` (match only while `fix == .none`; re-arm when tracking is
lost), `Waypoint/Navigation/NavigationController.swift` (pose-jump detection BEFORE anything consumes the position -
over 3 m between ticks resets the off-route counters and the movement sampler and skips the off-route test; re-routes
limited to one per 5 s).
Verified: `make test` -> 213 tests, 0 failures; `make typecheck` OK (61 app files, 1 UI test file); `make check` ->
BUILD SUCCEEDED (run on its own line).
NOT verified: **UNVERIFIED ON DEVICE.** The three new constants (3 m jump, 5 s between re-routes, re-arm on lost
tracking) are guesses.
Open / handoff:
1. Still needs calibration: `KeyframeIndex.defaultMaxDistance` (18) - the log line
   "recognised a keyframe (distance X)" gives the real numbers.
2. If the position still drifts after this, the next suspect is the keyframe pose itself: a descriptor match assumes
   the user stands where the volunteer stood, so a match from 2 m away seeds a pose 2 m out. ARKit should absorb that
   once it relocalizes properly; if it does not, the seed should be treated as a hint for ARKit rather than as the
   answer.

---

## 2026-10-17 — Claude (agent, for Anmol) — Keyframe relocalization (D-035 option 2)   [tags: BUILD, CONTRACT CHANGE]
Area: A (maps/relocalization) + C (vision). Branch `keyframe-relocalization` off `navigation-overhaul`. See D-038.

CONTRACT CHANGE: `BuildingMap.keyframes: [Keyframe]`, `schemaVersion` 2 -> 3.
Files created (WaypointCore): `Model/Keyframe.swift` - `Keyframe` (position, yaw, opaque descriptor; pose recovery by
the same maths as the marker) and `KeyframeIndex` (nearest match with a maxDistance, an AMBIGUITY test, and a spacing
rule), with the distance function injected so the whole thing is testable without Vision.
Files created (app): `Waypoint/Vision/KeyframeRecorder.swift` - Vision feature prints, archived for storage, and the
distance between two of them.
Files edited: `Model/BuildingMap.swift` (+keyframes, +hand-written `init(from:)`), `Waypoint/Capture/CaptureController.swift`
(records one keyframe per 2.5 m on a background queue, only while tracking is normal; written into the map on save),
`Waypoint/Relocalization/Relocalizer.swift` (+`fix` telling coarse from exact; matches a live frame at most twice a
second until something exact arrives).
Tests added: `KeyframeTests` (9) - closest match, REFUSES to choose between two places that look alike, neighbours of
the same spot do not count as ambiguity, nothing-close is no match, uncomparable descriptors are skipped, pose
recovery round-trips, spacing, and TWO format-compatibility tests.
A mistake worth recording: I added `keyframes` with a default value and claimed old maps would still decode. They did
not - Swift's synthesized decoder requires the key regardless of the default - and 37 tests failed at once. Fixed with
an explicit `init(from:)` using `decodeIfPresent`. This is the second time this session a "safe optional field"
assumption was wrong; the lesson is that a default value is not the same as an optional KEY.
Verified: `make test` -> **213 tests, 0 failures** (was 204); `make typecheck` OK (61 app files, 1 UI test file);
`make check` -> BUILD SUCCEEDED; `tools/validate_map.py` PASSes both the sample map and a hand-written map WITH
keyframes.
NOT verified: **UNVERIFIED ON DEVICE.** No feature print has been computed on a phone. The `maxDistance` of 18 is a
guess - Vision's distances are not normalised - and must be calibrated in a real corridor before this is trusted. The
`.right` image orientation passed to Vision assumes a portrait phone and wants checking.
Open / handoff:
1. Calibrate `KeyframeIndex.defaultMaxDistance` and `defaultAmbiguityRatio` on a phone: log the distances of correct
   and incorrect matches in a corridor, then set the threshold between them.
2. Only maps scanned AFTER this change have keyframes; older maps relocalize exactly as before.
3. Map files grow by a few KB per keyframe - worth measuring against the 40 MB export budget on a long scan.

---

## 2026-10-17 — Claude (agent, for Anmol) — One move at a time: stop speaking paragraphs   [tags: BUILD, BUG]
Area: B (Guidance). Branch `one-move-at-a-time` off `navigation-overhaul`. See D-037.

Cause was my own earlier fix: `perform` joined every `.speak` action in a tick into one utterance (D-023, to stop
lines clipping each other), which produced run-on paragraphs.
Files edited (app): `Waypoint/Navigation/NavigationController.swift` (lines handed over separately, sorted most
important first), `Waypoint/Guidance/Speaker.swift` (the one pending slot now keeps the most IMPORTANT line, not the
newest; equal priorities still prefer the newest).
Files edited (WaypointCore): `Guidance/FeedbackPlanner.swift` (`SpeechPriority: Comparable` with an explicit rank),
`Guidance/SpokenPhrases.swift` (briefing drops the ", then turn left" / ". Then there are stairs." tails).
Tests added: `OneMoveAtATimeTests` (5) - the briefing describes only the move being made, arrival keeps its
destination, stairs are still warned by the countdown, NO line the planner emits contains ", then ", and priorities
are ordered.
Three existing briefing assertions were updated to the shorter wording.
Verified: `make test` -> **204 tests, 0 failures** (was 199); `make typecheck` OK (60 app files, 1 UI test file);
`make check` -> BUILD SUCCEEDED (checked on its own, after pushing a broken build earlier today by reading a chained
command's output).
NOT verified: **UNVERIFIED ON DEVICE.** Recording and the map format are untouched; existing recordings are unaffected.
Open / handoff: unchanged - relocalization anchoring (D-035), `TurnReason` has no caller, CarPlay-style layout,
the stashed account-auth work.

---

## 2026-10-17 — Claude (agent, for Anmol) — Fix a broken build I pushed one commit earlier   [tags: BUILD, BUG]
Area: B (Navigation). Branch `navigation-overhaul`.
My previous commit (28c88fd) left an EXTRA CLOSING BRACE in `Waypoint/Navigation/NavigationController.swift` when I
restructured the re-route block, so the app target did not compile. I committed and pushed it anyway: I read
"BUILD SUCCEEDED" from `make check` in a combined command whose earlier step had already failed, and `make test` passes
regardless because it only builds WaypointCore, not the app.
Fix: removed the stray brace. `make typecheck` OK (60 app files, 1 UI test file); `make check` -> BUILD SUCCEEDED;
`make test` -> 199 tests, 0 failures.
Lesson for anyone chaining these: `make test` green says nothing about the app target. Check `make typecheck` or
`make check` output on its own line before committing app-side changes.

---

## 2026-10-17 — Claude (agent, for Anmol) — Faster re-routing; no briefing while facing backwards   [tags: BUILD, BUG]
Area: B (Navigation/Guidance) + UI text. Branch `reroute-and-briefing` off `navigation-overhaul`. See D-036.

Reported after a good run: it did not recalculate until the user was very far off the path, and when it did it said
"walk straight" while the screen and the right action were "turn around".
Files edited (app): `Waypoint/Navigation/NavigationController.swift` - re-route threshold 5 m -> 3 m and 1.5 s -> 1 s,
plus a drift trigger (distance from the route grown by 1.5 m within 2 s while moving). Both counters reset on a
re-route and on `begin`.
Files edited (WaypointCore): `Guidance/FeedbackPlanner.swift` - the route briefing is suppressed while the cue is
`.turnAround`; `Flows/GuidanceState.swift` - `directive(_:)` decides whether the spoken line is short enough to be a
headline, otherwise it becomes the detail line.
Tests added: `RecalculationWordingTests` (5) - no briefing while facing the wrong way, the briefing arrives once they
have turned, a short directive headlines, long narration goes to detail, and directive recognition.
Verified: `make test` -> **199 tests, 0 failures** (was 194); `make typecheck` OK; `make check` -> BUILD SUCCEEDED.
NOT verified: **UNVERIFIED ON DEVICE.** Nothing here touches recording or the map format - existing recordings are
unaffected.
Open / handoff:
1. The drift trigger depends on `isMoving`, which comes from the camera pose; if that proves noisy on a phone the
   trigger will fire late rather than wrongly (it requires movement to fire at all).
2. Still open from D-035: relocalization is slow because nothing anchors it. The printed marker remains the answer.
3. `TurnReason` is still unused by callers - obstacle-driven turns do not yet say why.

---

## 2026-10-17 — Claude (agent, for Anmol) — Turn vocabulary, stale-line fix, screen/speech agreement   [tags: BUILD, BUG]
Area: B (Guidance) + UI. Branch `speech-accuracy` off `navigation-overhaul`. See D-034 and D-035.

Files edited (WaypointCore): `Guidance/SpokenPhrases.swift` (`TurnSpeech` rewritten to the team's bands, +`TurnReason`,
epsilon on the band edges because 5 degrees round-trips through radians as 4.9999995), `Flows/GuidanceState.swift`
(+`lastSpoken`, headline prefers it).
Files edited (app): `Waypoint/Guidance/Speaker.swift` (own single-slot queue with a 2 s freshness limit;
`AVSpeechSynthesizerDelegate` to speak the pending line when the current one ends; cancel clears it),
`Waypoint/Services/LiveGuidanceService.swift` (feeds `lastSpoken`).
Tests added: `TurnWordingTests` (9) - every band, a decided turn never spoken as straight, reasons appended, and the
screen showing the spoken words with a fallback for mock mode.
Seven existing tests asserted the old "Turn right 85 degrees." vocabulary and were updated to the new bands.
Verified: `make test` -> **194 tests, 0 failures** (was 185); `make typecheck` OK; `make check` -> BUILD SUCCEEDED.
NOT verified: **UNVERIFIED ON DEVICE.** The 2 s staleness limit is a guess and is the number most likely to need
tuning - too low and cues go missing, too high and they contradict again.
Open / handoff:
1. **Relocalization slowness is NOT fixed** - analysis in D-035. The honest answer is the printed marker (D-008),
   unbuilt since the first architecture. A cheap stopgap is recording the scan's start pose and telling the user where
   to stand and which way to face.
2. `TurnReason` exists and is tested but no caller passes anything but `.route` yet; wiring the obstacle-driven turns
   to pass `.avoiding(...)` is the follow-up.

---

## 2026-10-17 — Claude (agent, for Anmol) — Load saved scans off the main thread; real loading states   [tags: BUILD, BUG]
Area: A (capture/relocalization) + B (navigation) + UI. Branch `loading-states` off `navigation-overhaul`. See D-033.

Diagnosis: the freeze was a BLOCKED MAIN THREAD, not a missing spinner. `Relocalizer.start` and the extend branch of
`CaptureController.start` both did a synchronous disk read plus `NSKeyedUnarchiver` of a multi-megabyte ARWorldMap on
the main thread, and `ARReferenceImage.referenceImages` was there too.
Files edited (app): `Waypoint/Relocalization/Relocalizer.swift` (background load + decode, new `runSession`, published
`isPreparing`, in-flight load discarded if stopped), `Waypoint/Capture/CaptureController.swift` (`prepareExtension`
does the work off-thread and re-enters `start`; `isPreparing`; `cancelPreparing`; `stop` clears it),
`Waypoint/Navigation/NavigationController.swift` (mirrors `isPreparing`, status "Opening the saved scan..."),
`Waypoint/UI/NavigatorView.swift` (loading row with a spinner, one VoiceOver element).
Files edited (WaypointCore): `Flows/GuidanceState.swift` - "Opening the saved scan" maps to `.localizing`, so the new
interface shows its localizing screen instead of falling through to `.idle` and looking stuck.
Tests added: `LoadingPhaseTests` (3) - the loading status reads as localizing, the old status still does, and a truly
idle controller is still idle.
Verified: `make test` -> **185 tests, 0 failures** (was 182); `make typecheck` OK (60 app files, 1 UI test file);
`make check` -> BUILD SUCCEEDED.
NOT verified: **UNVERIFIED ON DEVICE.** The freeze was measured by the user on a phone; the fix has not been. Nothing
here changes recording or the map format - a map recorded on an earlier build is unaffected.
Open / handoff:
1. If "Start recording" still pauses on a NEW (non-extend) scan, what is left is ARKit starting the camera and
   `ARView` setting up RealityKit, which we cannot move off the main thread. Worth timing before chasing further.
2. The sample-map seeding and `MapStore.listMaps()` at launch are still synchronous; they are small today but would be
   the next thing to move if a phone ever holds many large maps.

---

## 2026-10-17 — Claude (agent, for Anmol) — Speech queues instead of interrupting; no nagging at doors   [tags: BUILD, BUG]
Area: B (Guidance) + navigation. Branch `speech-queue-and-doors` off `navigation-overhaul`. Reasoning in D-032.

Files edited (WaypointCore): `Guidance/FeedbackPlanner.swift` (+`SpeechPriority.critical`; safety lines moved to it;
`isMoving` parameter; the way-through line said once per door via `announcedWayThrough`, re-armed when the way is
clear; stop-repeat now requires movement and never applies to a door we were routed through),
`Guidance/SpeechGate.swift` (+`.enqueue` decision), `Routing/RouteFollower.swift` (arrival = inside the extent OR
within the radius, instead of extent-only).
Files edited (app): `Waypoint/Guidance/Speaker.swift` (queue instead of interrupt for `.high`, 0.25 s
`postUtteranceDelay`), `Waypoint/Navigation/NavigationController.swift` (+movement detection from the camera pose,
fed to the planner).
Tests added: `SpeechPacingTests` (6) - a door is explained once and not repeated while standing at it; stop is not
repeated at someone who has stopped; it IS still repeated while they walk toward a wall; unknown movement keeps the old
behaviour; the next door is explained again; safety is `.critical` while guidance queues. Plus the gate tests were
split into critical-interrupts and high-queues.
Five existing assertions were updated because the behaviour deliberately changed: safety lines are `.critical` now,
not `.high`.
One of my own test assertions was wrong and I fixed the test, not the code: I asserted the first tick at a door says
exactly ONE line, but guidance correctly carries on toward the door, so a navigation cue comes with it. The assertion
now checks what matters - the "open it" line appears once and no "Stop." line appears.
Verified: `make test` -> **182 tests, 0 failures** (was 175); `make typecheck` OK (60 app files, 1 UI test file);
`make check` -> BUILD SUCCEEDED.
NOT verified: **UNVERIFIED ON DEVICE.** Nobody has heard the queued speech. Movement thresholds (0.15 m/s over 0.6 s)
and the 0.25 s gap between lines are guesses.
Open / handoff:
1. Arrival is now more forgiving, but a room whose extent came out too small is still worth catching at SCAN time -
   the review screen lists each room's measured size, so compare it with the real room.
2. Deferred by the user: using an opened door to predict that the destination is about to be reached.

---

## 2026-10-17 — Claude (agent, for Anmol) — Delete recordings, from both interfaces   [tags: BUILD]
Area: D (app shell) + U3 (UI). Branch `delete-recordings` off `navigation-overhaul`.
Request: "add the ability to delete recordings."

What already existed: `MapStore.delete(id:)` (core) and a Delete item in the NEW interface's scan library, hidden in a
long-press context menu. What was missing: any delete at all in the CLASSIC screens, a visible control for sighted
users, and cleanup of the per-map state that outlives a deleted map.
Files edited:
- `Waypoint/App/AppState.swift`: +`deleteMap(_:)` - the single delete path. Removes the map and its ARWorldMaps, then
  clears `ui.recents.<mapId>` and `ui.pendingMapId` when it points at the deleted map. Without this, stale keys build up
  and a map re-imported under the same id inherits someone else's recent destinations. Returns false on failure and
  still reloads, so the list cannot show a map that is no longer on disk.
- `Waypoint/UI/Scanner/ScanLibraryView.swift`: visible trash button (44x44 tap target) beside each card as well as the
  context menu; delete routed through `AppState.deleteMap`; VoiceOver announcement on success AND failure (it only
  announced success before, so a failed delete was silent).
- `Waypoint/UI/NavigatorView.swift` (classic): swipe-to-delete on the Map rows, the same confirmation wording, a
  VoiceOver rotor action (swiping is invisible to VoiceOver), and the selection falls back to another map when the
  selected one is deleted, so the screen never points at a map that no longer exists.
Tests added: `MapDeletionTests` (4) - deleting removes the ARWorldMap binaries too (they are the big files; leaving
them would quietly fill the phone) and nothing with the map id survives on disk; deleting one map leaves the others
and their world maps alone; deleting an unknown or already-deleted map is a harmless no-op (double tap, or a map
removed on another screen); the same map id can be saved again afterwards.
Deliberately NOT changed: delete stays LOCAL. Copies on other phones or in the cloud are untouched, which is what the
confirmation text promises.
Verified: `make test` -> **175 tests, 0 failures** (was 171); `make typecheck` OK (60 app files, 1 UI test file);
`make check` -> BUILD SUCCEEDED.
NOT verified: **UNVERIFIED ON DEVICE** - neither the swipe action nor the trash button has been tapped on a phone.
Open: the sample map is re-seeded on next launch only when the store is EMPTY, so deleting every map brings the sample
back. That is existing behaviour (`seedSampleMapIfNeeded`), not a regression, but it will look like a failed delete.

---

## 2026-10-17 — Claude (agent, for Anmol) — Merge `main` into `navigation-overhaul`; decisions renumbered   [tags: DOCS, BUILD]
Area: shared. Branch `navigation-overhaul` (all nine guidance/scan commits from this session), merged with the six
commits that landed on `origin/main` in the meantime (docs enforcement + hook, map validator, canonical shared maps,
scan extensions and merge rules, U3 integration).

Swift merged cleanly - including `Model/MapBuilder.swift`, where their `attachExtension` and my loop closure both
touch breadcrumb creation. They compose rather than clash: `attachExtension` joins a NEW scan to an existing map, and
it calls the same `dropBreadcrumb` that now also closes loops, so an extension gets loop closure for free. Worth a
second pair of eyes from whoever owns the extension work.
Conflicts (3, all markdown, all "both sides appended"): `docs/DECISIONS.md`, `docs/MODULES.md`, `docs/TESTING.md`.
**DECISION IDS RENUMBERED.** D-023 and D-024 were taken on `main` (canonical shared maps; docs enforcement) while this
branch used the same two ids for other decisions. Theirs are already published, so MINE moved +2: the old D-023..D-029
are now **D-025..D-031**, content unchanged. A numbering note records this at the top of the renumbered block. Every
reference was updated with it - in `docs/WORKLOG.md`, `Waypoint/Guidance/SpeechGuide.swift`,
`Waypoint/Services/Announcer.swift`, `FeedbackAndVisionTests.swift` and `AccessibilityGuidanceTests.swift` - and their
D-023/D-024 references in `AGENTS.md` and `docs/WORKFLOW.md` were deliberately left alone.
Also corrected two statements that the merge made false: MODULES still said the new UI flow logic was "NOT YET RUN by
`make test`" and the screens "not compiled yet"; TESTING row 4.0 still said "the 50 existing tests still pass". Struck
through with labelled Updates per rule 11, nothing deleted.
Verified AFTER the merge: `make test` -> **171 tests, 0 failures** (167 from this branch + 4 of theirs);
`make typecheck` OK (60 app files, 1 UI test file); `make check` -> BUILD SUCCEEDED.
NOT verified: nothing was run on a phone in this block; everything already marked UNVERIFIED ON DEVICE stays so.
Note: `core.hooksPath` is NOT set in this clone, so their pre-commit docs hook did not run here - this entry was
written to satisfy AGENTS.md rule 12 by hand. Run `make hooks` once per clone to activate it.
Open / handoff:
1. Someone who owns the extension work should sanity-check `MapBuilder` now that `attachExtension` and loop closure
   share `dropBreadcrumb`.
2. This branch is NOT merged to `main`; under ROADMAP Revision 3 that is U1's call.

---

## 2026-10-17 — Claude (agent, for Anmol) — Route from the user's position; re-route when off it   [tags: BUILD, BUG]
Area: B (Routing/Navigation). Branch `routing-start-and-reroute` off `main`. See D-031.

Reported with screenshots: the route went the long way round the central core while the user walked the short way, and
only "corrected" later. Causes: (1) the route started from the single nearest NODE, which on a loop can be on the wrong
branch; (2) nothing ever re-routed, so the first decision stood for the whole session.
Files edited (WaypointCore): `Routing/WaypointGraph.swift` (+`nearestNodes(to:limit:)`), `Routing/Router.swift`
(+`bestRoute(in:from:to:)` choosing the start node by walk-in + route length, +`length(of:)`),
`Routing/RouteFollower.swift` (+`distanceFromRoute(position:)`), `Flows/MapHealth.swift` (+`unclosedLoop(count:)` and
`unclosedRevisits`, which counts REVISITS not cycles so a straight corridor is not flagged).
Files edited (app): `Waypoint/Navigation/NavigationController.swift` (`makeFollower` uses `bestRoute`; re-routes after
1.5 s more than 5 m off the route, resets the planner and says "Recalculating.").
Tests added: `LoopRoutingTests` (7) - the shorter branch is chosen from where the user stands, bestRoute still works
when only one way exists, route length, off-route distance, an unclosed loop IS reported, a closed one is not, and a
straight corridor is not flagged.
Two of my own mistakes, both caught by tests: my first health check flagged any map without a cycle, which failed on
the sample map (a straight corridor legitimately has none) - rewritten to look for unjoined revisits; and my loop
fixture ended 2 m from the start, outside the revisit radius, so the test proved nothing until I closed it properly.
Verified: `make test` -> **167 tests, 0 failures** (was 160); `make typecheck` OK; `make check` -> BUILD SUCCEEDED.
NOT verified: **UNVERIFIED ON DEVICE.** Re-routing has never fired on a phone.
Open / handoff:
1. Re-routing only helps if the shorter way EXISTS in the graph. If the scan never joined the loop, no amount of
   re-routing finds it - hence the new review-screen warning. Rescan walking back over your own path.
2. Still not done: the CarPlay-style Navigator layout.

---

## 2026-10-17 — Claude (agent, for Anmol) — Route progress by projection; corner cues; AR path overlay   [tags: BUILD, BUG]
Area: B (Routing/Navigation) + U3 (UI). Branch `follower-progress-and-overlay` off `main` (6c892a1). See D-030.

THE BUG (both reported symptoms, one cause): `RouteFollower.targetIndex` advanced only on coming within 1 m of a
waypoint. After D-028 made waypoints sparse, walking past one slightly off to the side never advanced it, so the
follower aimed behind the user ("turn around", repeatedly) AND arrival was never evaluated, so standing inside the
room did nothing.
Files edited (WaypointCore): `Routing/RouteFollower.swift` (progress by nearest route SEGMENT in a windowed, monotonic
search; arrival by RoomExtent containment regardless of index; `projectedIndex`), `Routing/GuidanceInstruction.swift`
(+`Maneuver.angleRadians`), `Guidance/FeedbackPlanner.swift` (corner cues from route geometry at 1.2 m; heading cue
stays silent while a corner is within 4 m; `turnInProgress` guard).
Files edited (app): `Waypoint/Navigation/NavigationController.swift` (+`routeWorldPositions`, rebuilt only when the
route or map->world transform changes), `Waypoint/UI/Navigator/NavDebugView.swift` (AR route overlay: floor markers +
ribbon), `Waypoint/UI/Scanner/ScanReviewView.swift` (room boundary list + "rooms sized" stat).
Tests added: `FollowerProgressTests` (5) - walking past a waypoint off to one side still progresses and does not say
turn around, progress never rewinds, far off-route does not jump ahead, inside the room is arrival even with a lagging
index, outside is not.
Debugging note: I got this wrong twice before getting it right, and the tests found both. (a) My first projection
window started at the segment AHEAD of the user, so progress jumped straight to the destination and the walk announced
"you will arrive" nine metres early. (b) I then assumed the duplicate turn cue came from the heading cue firing after
the corner; instrumenting it showed the opposite - the heading cue fired FIRST at 51 degrees, the corner second at the
route's real 90. The fix is for the heading cue to defer to an upcoming corner, not the other way round.
Verified: `make test` -> **160 tests, 0 failures** (was 155); `make typecheck` OK (60 app files, 1 UI test file);
`make check` -> BUILD SUCCEEDED.
NOT verified: **UNVERIFIED ON DEVICE.** The AR overlay has never been rendered. New constants to tune on a phone:
progressWindow 4 segments, maxOffRouteMeters 8, cornerDistanceMeters 1.2, cornerSuppressionMeters 4.
Open / handoff:
1. NOT done: the CarPlay-style multi-card Navigator layout. The debug overlay was extended instead; the guiding screen
   itself is unchanged.
2. Room extents still only exist for rooms tagged after D-029, so a rescan is needed to see boundaries at all.
3. Still open: off-route re-routing (U2.5) - we now DETECT >8 m off route but only decline to skip ahead; we do not
   recompute the route.

---

## 2026-10-17 — Claude (agent, for Anmol) — Rooms have a floor area, from the mesh's wall faces   [tags: BUILD, CONTRACT CHANGE]
Area: A (maps/scan) + B (arrival). Branch `room-extents` off `main` (4e278e2). Reasoning in D-029.

CONTRACT CHANGE: `MapNode.extent: RoomExtent?`; `BuildingMap.schemaVersion` 1 -> 2. Optional field, so schema-1 maps
decode unchanged (there is a test that decodes hand-written schema-1 JSON). `Samples/rice-hall-sample.json` left as is.
Files created (WaypointCore): `Scan/RoomExtractor.swift` (occupancy grid + flood fill + rectangle fit; returns nil for
unenclosed space).
Files edited (WaypointCore): `Model/MapTypes.swift` (+`RoomExtent` with `contains`), `Model/BuildingMap.swift`
(schemaVersion 2), `Model/MapBuilder.swift` (`addPOI(..., extent:)`), `Routing/RouteFollower.swift` (arrival is
containment when an extent exists, 0.5 m doorway margin, else the old radius).
Files edited (app): `Waypoint/Scan/MeshSampler.swift` (+`wallPoints`: first code in the app to READ
`ARMeshAnchor.geometry.classification`), `Waypoint/Capture/CaptureController.swift` (computes the extent when a room is
tagged; logs the area or why it could not), `Waypoint/UI/DesignSystem/PlanView.swift` (draws room rectangles, so the
debug overlay shows what the scan actually understood).
Tests added: `RoomExtractorTests` (10) - finds a rectangular room and its area, inside/outside containment, arrival by
containment from the far end of the room (not the pin), fallback when there is no extent, open space and corridors
yield nil, standing in a wall is refused, a sub-cell doorway does not leak, JSON round trip, and schema-1 decode.
Verified: `make test` -> **155 tests, 0 failures** (was 145); `make typecheck` OK (60 app files, 1 UI test file);
`make check` -> BUILD SUCCEEDED.
NOT verified: **UNVERIFIED ON DEVICE.** No real mesh has been through `wallPoints`. The parameters most likely to need
tuning on a phone: the 0.4-1.8 m height band, faceStride 3, grid resolution 0.15 m, search radius 12 m.
Open / handoff:
1. Extents are computed when a room is TAGGED, so only rooms tagged after this change have one. Rescan.
2. Objects (tables, chairs) are still not segmented - only wall and door faces are read. If object boundaries matter,
   that is a further change.
3. L-shaped rooms are covered by their bounding rectangle; `areaSquareMeters` shows the real enclosed area.
4. Classification must be ON (default per D-020). With it off, `wallPoints` is empty and extents are nil.

---

## 2026-10-17 — Claude (agent, for Anmol) — Route simplification + sighted debug overlay   [tags: BUILD]
Area: B (Routing/Navigation) + U3 (UI). Branch `route-simplify-and-debug` off `main` (cdd8331).
Trigger: Rice Hall walk - "weird turns: straight, turn right, turn around, then straight" where the route was
"straight then left"; and "the blind user tryout should show the camera and the pathfinding being calculated".

Diagnosis: A* is correct. The GRAPH is a trail of the volunteer's footsteps, so the optimal path over it still
contains their detours. See D-028.
Files created: `Routing/RouteSimplifier.swift` (detour removal + thinning, with a protected-node rule),
`Waypoint/UI/Navigator/NavDebugView.swift` (camera + plan + raw status).
Files edited: `Routing/Router.swift` (`simplify:` parameter, default true; passes hazard-edge endpoints as protected),
`Waypoint/Navigation/NavigationController.swift` (+debug telemetry: activeMap, routeNodeIds, mapPosition,
headingRadians), `Waypoint/UI/DesignSystem/PlanView.swift` (user position/heading arrow; route drawn as its own
polyline - highlighting edges no longer works once straight runs are collapsed), `Waypoint/Services/GuidanceService.swift`
(+`debugController`, nil by default), `LiveGuidanceService.swift` (exposes its controller), `ServiceMode.swift`
(+`ui.debugOverlay`), `SettingsView.swift` (toggle), `GuidingView.swift` (shows the overlay),
`NavigatorModel.swift` (passes the controller through).
Tests added: `RouteSimplifierTests` (8) - there-and-back removed, straight run collapses to its endpoints, a real
corner survives, the simplified path stays within tolerance of every walked point, tagged/protected nodes are never
removed, a detour PAST something tagged is not collapsed, short routes untouched, and segment-vs-infinite-line distance.
A test caught a real safety bug I introduced: the first version of thinning removed a stairs node and its hazard
warning disappeared. Fixed with the protected-node rule, then covered directly.
Three existing tests were updated because the behaviour deliberately changed: `testRouteToRoom204` now pins RAW A*
(`simplify: false`) and a new test pins the simplified walk; the FlowTests route summary expects the collapsed node
list; my own start-gate test asserts the starting node rather than a node count.
Verified: `make test` -> **145 tests, 0 failures** (was 136); `make typecheck` OK (60 app files, 1 UI test file);
`make check` -> BUILD SUCCEEDED.
NOT verified: **UNVERIFIED ON DEVICE.** Nobody has seen the overlay or walked a simplified route. 1.2 m shortcut
radius and 0.6 m tolerance are guesses.
Open / handoff:
1. NOT addressed: the mesh is one blob rather than separated walls/objects, so there is still no notion of being
   "inside a room" - the app drives you to the exact tagged point. This needs room geometry derived from the
   classified mesh and is a bigger change; see the reply to the user, nothing was built for it.
2. Loop closure (D-027) still only applies to maps scanned after that change - old maps remain chains.
3. Still open: off-route re-routing (U2.5).

---

## 2026-10-17 — Claude (agent, for Anmol) — Natural path following, loop closure, doors as doors, turn angles   [tags: BUILD]
Area: B (Navigation/Feedback) + A (MapBuilder). Branch `guidance-path-and-graph` off `main` (73b189c).
Trigger: six findings from walking Rice Hall. Full reasoning in D-027.

Files created (WaypointCore): `Routing/HeadingCue.swift` (turn classification with hysteresis + debounce; also holds
`ArrivalRadius`).
Files edited (WaypointCore):
- `Model/MapBuilder.swift` - LOOP CLOSURE: a new breadcrumb also links to an older node the volunteer walked back to
  (revisitRadius 1.0 m, minChainSeparation 4). This is the fix for "it made me walk around the whole room": the graph
  was a chain, so A* had no short way across a central core.
- `Routing/RouteFollower.swift` - steers at a point 3 m further along the route (`steeringPoint`) instead of the next
  breadcrumb; cue classification delegated to `HeadingCue`; arrival radius now depends on the destination's kind; the
  beacon is placed at the steering point. The two old threshold constants are kept but deprecated.
- `Vision/ObstacleKind.swift` - `RouteFeature.isWayThrough`.
- `Guidance/SpokenPhrases.swift` - `ObstacleSpeech.wayThrough` (says to OPEN the door), `TurnSpeech` (angles rounded to 5 degrees).
- `Guidance/FeedbackPlanner.swift` - way-through handling (caution + keep guiding, instead of stop + silence);
  turn cues use TurnSpeech; `directionCooldownSeconds` = 1.5 s with the held cue re-tried rather than dropped.
Tests added: `NaturalGuidanceTests` (16) - wobble never produces a turn, a real turn must persist, hysteresis, first cue
immediate, steering aims past the next breadcrumb, room vs door arrival distance, a walked loop is closed, parallel
corridors are NOT joined through the wall, doors say "open it" while guidance continues, a person still stops you,
angle rounding, and that directions are spaced out but not lost.
Two tests I wrote FAILED first and found real problems: (1) the follower only evaluates arrival once it has stepped
through to the last node, so the test had to walk the route rather than teleport; (2) my first "parallel corridors"
assertion was wrong - the edge joining the end of one corridor to the start of the next is a legitimate CHAIN edge the
volunteer walked. Rewritten to assert the graph stays a pure chain. Also tightened revisitRadius 1.2 -> 1.0 m.
Three existing tests asserted the old wording ("Turn left.") and now match a prefix, since the angle is TurnSpeech's job.
Verified: `make test` -> **136 tests, 0 failures** (was 120); `make typecheck` OK (59 app files, 1 UI test file);
`make check` -> BUILD SUCCEEDED.
NOT verified: **UNVERIFIED ON DEVICE.** Every threshold is a guess: 3 m lookahead, 45/22 degree deadband, 3-tick
debounce, 1.0 m revisit radius, 1.5 s direction cooldown, arrival radii 2.5/1.2/1.5/1.0 m. They want one real walk.
Open / handoff:
1. Loop closure only helps maps scanned AFTER this change - existing saved maps are still chains. Rescan Rice Hall.
2. A room has no extent in the model (a MapNode is a point), so "inside the room" is approximated by a 2.5 m radius.
   Real room bounding boxes would be a shared-model change.
3. Still open: the mesh-detail question, and off-route re-routing (U2.5).

---

## 2026-10-17 — Claude (agent, for Anmol) — One voice: single synthesizer; merged main into the UI branch   [tags: BUILD]
Area: B (Guidance) + U3 (UI services). Branch `app-ui-workflows`.
Trigger: "sometimes multiple voice lines speak at the same time, especially when reaching the destination", heard while
testing the new UI.

Merge first: `git merge main` into `app-ui-workflows`, bringing 4e90396 (E2E framework), 7fbcb76 (obstacle
identification + speech guidance) and 2d7aca7 (arrival / start-gate fixes). ONE conflicted file, `Waypoint/UI/RootView.swift`,
two hunks, both resolved by keeping BOTH sides (the UI branch's Settings gear and new-interface auto-open, plus main's
accessibility identifiers and the `-autoE2E` self-test task). Nothing was dropped. -> `make test` 112 passed.

Cause of the overlap: `SpeechGuide` and `Announcer` each owned an `AVSpeechSynthesizer`. Each one's anti-overlap logic
only applied to its own instance, so they could never prevent each other; at arrival both spoke. With VoiceOver on it was
worse - Announcer posted a VoiceOver announcement while SpeechGuide spoke aloud.
Files created: `Waypoint/Guidance/Speaker.swift` (the app's only synthesizer), `Package/WaypointCore/Sources/WaypointCore/Guidance/SpeechGate.swift`
(the rules: interrupt on `.high`, drop `.normal` while busy, drop identical text inside 3 s - pure logic so it is testable).
Files edited: `Waypoint/Guidance/SpeechGuide.swift` (now a thin forwarder; same API, so `NavigationController` is untouched),
`Waypoint/Services/Announcer.swift` (forwards to Speaker; no longer posts a VoiceOver announcement for `say` - see the
trade-off in D-026), `docs/DECISIONS.md` (+D-026).
Tests added: `SpeechGateTests` (8) - interrupt vs drop, repeat window, different text never suppressed, empty text,
reset, and that a DROPPED line does not reserve the repeat window.
Verified: `make test` -> **120 tests, 0 failures**; `make typecheck` OK (59 app files, 1 UI test file); `make check` ->
BUILD SUCCEEDED. `grep "AVSpeechSynthesizer()"` now matches exactly ONE line in the whole repo (Speaker.swift).
NOT verified: **UNVERIFIED ON DEVICE.** Nobody has heard it. The thing to listen for is arrival with the new UI in
Live mode: one voice, one arrival sentence, no second line on top.
Open / handoff:
1. Test on a phone, with and without VoiceOver.
2. Still open: mesh detail question (see the previous entry); off-route re-routing (U2.5).
3. My account-auth work is still in `stash@{0}`; its ADR claims D-019 and needs renumbering to the next free id.

---

## 2026-10-17 — Claude (agent, for Anmol) — Arrival vs obstacle, route start race, speech clipping   [tags: BUILD, CONTRACT CHANGE]
Area: B (Navigation/Feedback) + shared core. Branch `guidance-arrival-and-start` off `main` (7fbcb76).
Trigger: three issues found testing on the iPhone 15 Pro.

CONTRACT CHANGE: `GuidanceInstruction` gains `targetKind: NodeKind?` (optional, defaulted last in the initializer, so
every existing call site and the on-disk map JSON are unaffected; `BuildingMap.schemaVersion` NOT bumped - no JSON change).
`RouteFollower` fills it from the target node.

Files created (WaypointCore): `Routing/StartGate.swift` (pure logic: N consecutive ticks within maxJump before the
first route may be computed).
Files edited (WaypointCore): `Routing/GuidanceInstruction.swift` (+targetKind), `Routing/RouteFollower.swift` (sets it on
both the arrival and the normal instruction), `Guidance/SpokenPhrases.swift` (+`ArrivalSpeech`, phrasing driven by
NodeKind, plural agreement for stairs), `Guidance/FeedbackPlanner.swift` (new step 1b: arrival is handled before
obstacles and returns; the old `.arrived` case in step 4b is now unreachable and says so).
Files edited (app): `Waypoint/Navigation/NavigationController.swift` (StartGate gates follower creation + reset in
`begin`; `perform` coalesces a tick's `.speak` actions into one utterance at the highest priority).
Tests added: `ArrivalAndStartGateTests` in RoutingTests - arrival wording per NodeKind, arrival announced at STOP range,
said once not per tick, obstacle warnings unchanged while walking, gate waits out a jumping pose, lost tracking restarts
the count, non-finite rejected, and a routing test showing the converging pose picks the scan-origin node (4-node route)
while the settled pose picks the right one (2-node route).
Verified: `make test` -> **91 tests, 0 failures** (was 81); `make typecheck` OK (22 app files, 1 UI test file);
`make check` -> BUILD SUCCEEDED.
NOT verified: **UNVERIFIED ON DEVICE.** Nobody has heard the new arrival wording or confirmed the gate fixes the
walk-back-to-the-scan-origin behaviour on a phone. `StartGate` defaults (10 ticks, 0.35 m) are a guess and want tuning
in a real corridor - at ARKit's ~60 Hz that is ~0.17 s, at the simulator's 10 Hz it is 1 s.
Open / handoff:
1. Re-test the original two reports on a phone: arrive at a labelled door, and start navigation from a spot far from
   where the scan began.
2. Still open, NOT in this branch: the third report (mesh detail / "polygon calcs") - no mesh is stored anywhere and
   ARKit's reconstruction resolution is not tunable, so the question back to the team is which symptom was actually
   seen (overlay density, frame rate/heat, or a reported size).
3. Still open: the dual-synthesizer overlap on `app-ui-workflows` (Announcer + SpeechGuide), and off-route re-routing
   (U2.5), which would also recover from a bad start node rather than only preventing one.
4. My earlier account-auth work is still in `stash@{0}` and its ADR must be renumbered (it claims D-019, which is taken).

---

## 2026-10-17 22:45 — Claude (agent, for Sachin) — Branch review before commit: app-ui-workflows is merge-safe with one fix   [tags: BUILD]
Area: shared (integration check requested by U1 before committing)
Branches: ~~`origin/U3` = no own commits (old pointer, 3 behind main).~~ **Update 2026-10-17 (Claude):** `origin/U3` now holds 3 commits (map validator, canonical maps, scan extensions) that were fast-forwarded into `main` (0fc02d5). `origin/app-ui-workflows` (neehamikki, ca2ece5) = 1 commit, 49 files / ~5,100 lines: new Scanner + Navigator interface behind a default-OFF "Interface" setting,
  WaypointCore `Flows/*` + 21 `FlowTests`, `Waypoint/Services/*` (mock + live adapters around CaptureController/NavigationController), design system. Based on 27365ec (older than main), written on Windows, never compiled before this check.
Method: throwaway git worktree outside the repo = main + ALL of Sachin's uncommitted work, then `git merge origin/app-ui-workflows`; nothing in the real working tree was touched except the fix below; worktree and its build folders deleted afterwards.
Findings: (1) no duplicate type names in WaypointCore or the app; (2) their logging, CaptureController and NavigationController calls are all still valid (APIs only gained defaulted params);
  (3) ONE compile break: their `LiveScanScreen.swift:68` calls `LiveScanView(session:box:)`, but today's lossless pass added a required `showMesh:` -> fixed on OUR side with a default (`var showMesh: Bool = true`), applied to the working tree;
  (4) ONE textual conflict, `Waypoint/UI/RootView.swift` (both edited the toolbar + modifier chain): resolution = keep both (our `toolbar.home` id + `-autoE2E` task, their gear/Settings sheet/auto-open; gear gets id `toolbar.settings`); docs auto-merged cleanly.
Verified on the MERGED code: unit tests 102/102 (81 ours + 21 theirs); type-check 58 app files, 0 errors, 0 warnings; signed `build-for-testing` for the iPhone 16 Pro Max succeeded; ON DEVICE `make uitest`-equivalent 7/7 and the in-app E2E 20/0/1 (Classic interface unchanged). Sachin's own build was reinstalled afterwards.
NOT verified: their NEW interface (Interface = New) at runtime - no UI tests cover it yet; their Live adapters with a real scan/route.
Note: the commit labels its work "U3 (UI flows)"; per ROADMAP Revision 3 the author's lane (Windows + non-Pro iPhone 17) is U4. Worth agreeing who owns `Waypoint/UI/{Scanner,Navigator}` + `Waypoint/Services` going forward.

---

## 2026-10-17 22:15 — Claude (agent, for Sachin) — Accessibility features verified on the phone; UI churn fixed; config-tracking question answered   [tags: BUILD, BUG]
Area: B/D; U1 said the phone's VPN profile prevents auto-lock, so tests were run directly.
Verified ON DEVICE (iPhone 16 Pro Max): `make uitest` 7/7 (was 5; +`testObstacleIsNamedByTypeInTheSpokenSentence`, +`testPhonePostureCoachSpeaksAndRecovers`); `make selftest-e2e` 20 passed / 0 failed / 1 skipped (cloud); unit tests 81/81; `make typecheck` OK.
Phone's REAL Vision vocabulary (1,303 labels) for tuning `ObstacleLabelMapper`: trash -> `trash_can` (only one); people -> adult, baby, child, crowd, people (no plain "person"); seating -> armchair, bench, chair, chair_other, folding_chair, high_chair, seat, sofa, stool, swivel_chair, wheelchair (+car_seat, toilet_seat);
  furniture -> bed, cabinet, cart, desk, refrigerator, shopping_cart, table; structure -> door, elevator, escalator, stairs, window (+glass types); objects -> backpack, bicycle, cardboard_box, decorative_plant, extinguisher, flower, luggage, machine, plant, pole, sign, stroller, suitcase. No "wall" label: walls rely on the ARKit mesh class.
Bugs found by the on-device UI tests and fixed:
 1. The navigation screen was re-rendered 10x per second even when nothing changed (assigning equal values to @Published properties). It kept the app from ever going idle, so UI tests waited minutes (145 s -> 26 s for the same test after the fix). Now `setIfChanged` (also saves battery on a real walk). Same class of bug as the scan HUD fix.
 2. Posture recovery said "Phone position is good." and, in the same tick, "Continue straight.", so the confirmation was instantly replaced. The planner now says only the confirmation on that tick and resumes guidance on the next (unit test updated).
 3. UI tests raced the 15-second simulated walk; added a "Pause walker" control (`nav.pauseWalk`, useful for a sighted helper too) and a short speech history on screen (`nav.recentSpeech`).
Files edited: `Waypoint/Navigation/NavigationController.swift` (setIfChanged, `simulationPaused`, `recentSpeech`), `Waypoint/UI/NavigatorView.swift`, `Waypoint/Guidance/FeedbackPlanner.swift`... (path: Package/.../Guidance/FeedbackPlanner.swift), `Tests/.../AccessibilityGuidanceTests.swift`, `WaypointUITests/WaypointUITests.swift`, `Package/.../Vision/ObstacleKind.swift` (+`.furniture`; chair += wheelchair), `Waypoint/Capture/CaptureController.swift` (posture in the scan line).
STILL NOT verified (needs a person holding the phone): the real-phone posture axes/signs (TESTING.md A1-A3), the beacon being in the correct ear (A5), real depth hits and naming of real objects (A6), hallway countdown timing (A7), haptic feel, calibration, and blind-user review of the wording.
Config question answered: tracked = `Config/Base.xcconfig` (shared defaults, bundle prefix, empty Supabase placeholders) and `Config/Local.xcconfig.example` (template), `project.yml`; NOT tracked = `Config/Local.xcconfig` (your team id, dev suffix, and later the Supabase URL + anon key) - git-ignored and never committed (checked all history).

---

## 2026-10-17 21:30 — Claude (agent, for Sachin) — Accessibility: phone-posture coach, named obstacles, distance-aware instructions   [tags: BUILD, BUG, CONTRACT CHANGE]
Area: B (guidance), C (vision), shared geometry; requested by U1 ("remember this is for visually impaired": posture stabilization + explicit/granular instructions + object-type classification)
Files created (core, tested): `Guidance/PhonePosture.swift`, `Guidance/SpokenPhrases.swift`, `Vision/ObstacleKind.swift`, `Tests/.../AccessibilityGuidanceTests.swift` (24 tests).
Files created (app): `Waypoint/Vision/ObstacleIdentifier.swift` (mesh class lookup + Vision `VNClassifyImageRequest` on a crop).
Files edited (code): `Guidance/FeedbackPlanner.swift` (REWRITTEN: posture, obstacle kinds + repeat, briefing, 10/5/2 m countdown, landmarks; new haptic cue `.holdPhoneUpright`), `Routing/GuidanceInstruction.swift` (+`Maneuver`, `Landmark`, optional fields), `Routing/RouteFollower.swift` (look-ahead along the route, landmarks),
  `Geometry/Geometry.swift` (`cameraTransform` now ARKit's real portrait convention + pitch/roll; `cameraLocalToUser`), `Tests/.../ScanAndSimulationTests.swift` (camera test updated), `Waypoint/Vision/ObstacleDetector.swift` (REWRITTEN), `Waypoint/Navigation/NavigationController.swift`, `Waypoint/Relocalization/Relocalizer.swift` (labelled mesh during navigation),
  `Waypoint/Guidance/HapticsGuide.swift`, `Waypoint/UI/NavigatorView.swift` (obstacle-type and phone-held pickers, on-screen "what was just said"), `Waypoint/Capture/CaptureController.swift` (posture reading in the scan monitor), `Waypoint/App/E2ESelfTest.swift` (+posture, phrases, Vision vocabulary), `WaypointUITests/WaypointUITests.swift` (+2 tests).
Docs (strike/update): `docs/DECISIONS.md` (D-022), `docs/TESTING.md` (accessibility checks A1-A7), `docs/ROADMAP.md` (A11Y-1..6), `docs/MODULES.md`.
REAL BUG FOUND while designing posture: ARKit's camera frame is fixed to the sensor (portrait: +x toward the BOTTOM of the phone, +y toward the user's right). The real-device audio beacon treated camera-local x as "right"; the simulation's fake camera hid it. Fixed centrally (`Geometry.cameraLocalToUser`); the old depth region was also the wrong shape for portrait and the floor could look like an obstacle (now world-space + `ObstacleBand`).
  These fixes are derived from Apple's documented axes and proven only with synthetic poses -> MUST be confirmed on a real phone (TESTING.md A1-A5).
Verified: `make test` 81/81 (24 new: posture round trip at any heading, dwell/hysteresis/repeat/recovery, label mapping with whole-word matching, every spoken sentence verbatim, look-ahead turn/stairs/arrival distances along the route, landmarks, planner countdown with no bursts, posture mutes guidance but not obstacle warnings);
  `make typecheck` OK (22 app files + UI tests). ON DEVICE (iPhone 16 Pro Max): `make selftest-e2e` -> 20 passed, 0 failed, 1 skipped (cloud): posture math ok (upright 0/0, down -49, lean +39), the simulated L-shaped walk now says "Walk straight about 12 meters, then turn right. / In 10 meters... / E2E Room 1 on your right. / In 5 ... In 2 meters, turn right. / Turn right. ...  In 2 meters, you will arrive at E2E Room 2." and ends with arrival;
  Vision on this phone: 1,303 labels incl. trash_can, chair/folding_chair/swivel_chair/armchair/wheelchair, door, stairs, table, window, plant/decorative_plant, cabinet; no label for "wall" or "person" was in the first list (so walls rely on the ARKit mesh class); the classifier runs without error.
NOT verified: ~~(1) the two new UI tests and the rest of `make uitest` after these changes (phone locked); (2) the wider `vision.labels.*` printout (phone locked on the rerun; mapper extended with cabinet/wheelchair from the first list);~~ **Update 2026-10-17 (22:15): (1) and (2) are DONE, see the next entry.** (3) everything that needs a person holding the phone: real posture axes, ear/direction of the beacon, real depth hits, mesh-class and Vision naming of real objects, thresholds, haptic feel, and any blind-user review of the wording.
Open: U1/U2 do TESTING.md A1-A7; U4 reviews wording; unlock the phone and run `make uitest` + `make selftest-e2e`.

---

## 2026-10-17 20:05 — Claude (agent, for Sachin) — End-to-end testing on the phone; found + fixed repeated "Continue straight."   [tags: BUILD, BUG]
Area: D (E2E harness), B (planner fix); requested by U1 ("continue testing, how about e2e")
Files created: `Waypoint/App/E2ESelfTest.swift` (A device capabilities, B storage + Keychain, C synthetic scan -> save -> reload -> share -> validate -> route -> simulated walk, D bundled resource, E optional cloud read).
Files edited (code): `Waypoint/App/LaunchCommand.swift` (+`.e2e`, `-autoE2E YES`), `Waypoint/App/AppState.swift`, `Waypoint/UI/RootView.swift` (runs the E2E once then `exit(0/1)`), `Makefile` (+`selftest-e2e`),
  `Package/.../Guidance/FeedbackPlanner.swift` (announce on change of instruction KIND, not on every new target; hazard announced once per hazardous target; reset clears it), `Tests/.../FeedbackAndVisionTests.swift` (+3 tests).
Docs (strike/update where needed): `docs/TESTING.md` (new E2E section + layer table + plan for the real-backend layer), `AGENTS.md` (+`selftest-e2e` row).
Bug found by the on-device E2E: with real-scan spacing (a node every 1.5 m) the planner spoke "Continue straight." at every waypoint (the sample map's 3 m spacing hid it). Fixed; unit tests 57/57.
Verified ON DEVICE (iPhone 16 Pro Max, iOS 27.0.1): E2E run 1 -> 17 passed, 0 failed, 1 skipped (cloud not configured). Capability matrix: LiDAR mesh yes, mesh+classification yes, scene depth yes, haptics yes, en-US voice yes, text recognition yes, audio engine starts, Documents writable, Keychain round trip works.
  Run 2 (after the planner fix): the walk spoke "Continue straight / Turn right / Continue straight / Turn left / Continue straight / arrived" (correct for an L-shaped hallway); my own assertion (<= 2 straights) was wrong -> 16 passed 1 failed; assertion corrected to "no phrase twice in a row".
  `make selftest-sim` after the fix: Turn right, Continue straight, You have arrived at Room 204, PASS.
NOT verified: the corrected E2E assertion on the phone (phone locked at the final rerun); real Supabase (SQL never executed anywhere; Docker daemon is not running here, no Supabase CLI); two-phone Multipeer; LiDAR geometry; relocalization; audio/haptic feel.
Open: (1) U1 unlock the phone and rerun `make selftest-e2e` (expect 17/0/1). (2) Run it on other teammates' phones (esp. the non-LiDAR ones: expect `lidar.mesh false`). (3) Decide how to E2E-test the SQL: Supabase project (U3) or local Postgres via Docker/Homebrew (needs a download; not done without approval).

---

## 2026-10-17 19:20 — Claude (agent, for Sachin) — "Keep lossless": classification default ON + start-screen switch; test status check   [tags: BUILD, DOCS]
Area: A (scan); requested by U1 ("keep lossless, implement the changes; what's happening with the current tests?")
Files edited (code): `Waypoint/Capture/CaptureController.swift` (`start(mapName:recordSurfaceLabels:)`; classification ON by default, `-scanClassification NO` to disable; logs `surfaceLabels=`), `Waypoint/UI/VolunteerView.swift` (start form toggle "Record surface labels", id `scan.labels`),
  `WaypointUITests/WaypointUITests.swift` (re-activate the app if it is not in the foreground; header warns not to use the phone during a run).
Docs (strike/update): `docs/DECISIONS.md` (D-020 item 4 struck + updated; new D-021 lossless-first policy, vector layer parked, capture-vs-display reversibility rule), `docs/TESTING.md` (A/B step 4 wording; "do not touch the phone" note).
Test status right now: unit tests 54/54 pass (`make test`); `make typecheck` OK (20 app files + 1 UI test file); `make check`/test-bundle build OK; ON THE PHONE `make uitest` 5/5 pass after the change (earlier today 5/5 too).
Failures seen and explained: (1) toggle tapped in its middle (test bug, fixed); (2) one-off "Home screen missing" and (3) one-off "Navigate button missing": both runs started with the app NOT usable in the foreground; the recording for (3) shows the app launching over another app ("<| Instagram" in the status bar), i.e. the phone was being used mid-run. Not app bugs; mitigated with re-activation + the do-not-touch note.
Not run / not verified: the lag A/B numbers (needs a real room + someone holding the phone), `make selftest-sim` after the latest change (UI test covers the same screen text), anything on LiDAR mesh content, relocalization, cloud.
Open: U1 still owes TESTING 3.1-3.6 in a real room. Classification is now on, so expect slightly more compute while scanning; use the A/B recipe to see what it costs.

---

## 2026-10-17 18:40 — Claude (agent, for Sachin) — Scan lag: lossless performance pass   [tags: BUILD]
Area: A (scan) ; requested by U1: "make this lag a lot less ... only if it's lossless"
Diagnosis (from code, NOT yet measured on a phone - nobody had a real mesh running while I could observe): (1) RealityKit `.showSceneUnderstanding` redraws the whole mesh every frame; (2) box fit on the main thread, brute force, every 6th vertex only;
(3) ~60 unnecessary SwiftUI re-renders/s from @Published writes of unchanged values; (4) plane detection on but unused; (5) per-face classification on but unused; (6) Debug (unoptimised) builds.
Files created: `Package/.../Scan/ConvexHull2D.swift`. Files edited (code): `Scan/OrientedBox.swift` (`fitBest` now hull-based and EXACT; `fitBest(hull:minY:maxY:)`; brute force kept as `fitBestBruteForce` for tests), `Tests/.../ScanAndSimulationTests.swift` (+4 tests in `FastBoxFitTests`),
  `Waypoint/Scan/MeshSampler.swift` (REWRITTEN: `measure` reads ALL vertices, per-anchor hulls), `Waypoint/Capture/CaptureController.swift` (background fit with no overlap, publish-only-on-change, classification/plane detection off by default, fps/fitMs/overlay telemetry, `showMeshOverlay`),
  `Waypoint/Scan/LiveScanView.swift` (overlay switch, unused render effects off), `Waypoint/UI/VolunteerView.swift` (overlay toggle, id `scan.overlay`), `Makefile` (`EXTRA=` passes launch args to `selftest-scan`).
Docs (strike/update): `Architecture.md` (risk row), `docs/DECISIONS.md` (D-020 rules + what was deliberately NOT done), `docs/TESTING.md` (new "Measuring scan performance" A/B recipe).
Verified: `make test` -> 54 tests, 0 failures. The new equivalence test proves the fast box equals the brute-force box on 60 random clouds (that is what "lossless" means for the box); 300k-point fit in a DEBUG test build: brute force 484 ms vs hull 254 ms (sorting dominates there; in the app each anchor is hulled separately and off the main thread).
  `make typecheck` OK; `make build` and `CONFIG=Release make build` -> BUILD SUCCEEDED (Debug installed on the phone).
NOT verified: any improvement on a real phone (no before/after numbers yet); the app launch after this change (phone was LOCKED, so the regression run of `make selftest-sim` could not start); LiDAR mesh in a real room.
Honest limits: if the dominant cost is ARKit's own mesh reconstruction + camera pipeline (system code), none of this can remove it; the remaining lossless lever is the overlay switch. Things that would help but are NOT lossless and were not done: lower video resolution/fps, decimating meshes, slower mesh updates.
Next for U1: unlock the phone, run the 4-step A/B in docs/TESTING.md, paste the `scan:` lines. U2/U3 can reuse `EXTRA=` for other launch flags.

---

## 2026-10-17 18:00 — Claude (agent, for Sachin) — UI tests on the phone from the CLI (taps + screenshots); first scan-screen evidence   [tags: BUILD]
Area: D (tests) with A/B findings; requested by U1 ("yes do 1 and 2")
Tools check: I have NO desktop computer-use tool (twice searched; only browser/Figma-scoped ones surfaced), so no mirroring. Substitute built: scripted UI tests on the device itself.
Files created: `WaypointUITests/WaypointUITests.swift` (5 tests; attaches screenshots + HUD values; interruption monitor accepts permission prompts; returns to Home at start).
Files edited (code/config): `project.yml` (+`WaypointUITests` target `bundle.ui-testing`, explicit `Waypoint` scheme that runs it), `Makefile` (+`uitest`, `uitest-shots`, `ONLY=`), `scripts/typecheck.sh` (also type-checks the UI tests; needs `-F <platform>/Developer/Library/Frameworks -I <platform>/Developer/usr/lib`),
  `Waypoint/UI/RootView.swift`, `VolunteerView.swift`, `NavigatorView.swift` (stable `.accessibilityIdentifier`s: mode.navigate, mode.scan, toolbar.home/share, scan.start/save/tag.*, hud.tracking/mapping/mesh/box, nav.simulate.*, nav.status/instruction/obstacle/injectObstacle/stop).
Docs (strike/update where old text changed): `docs/TESTING.md` (new UI-test section; Level-3 "meshAnchors=0" explanation struck + updated), `AGENTS.md` (+`make uitest` row), `docs/SETUP.md` (+headless testing note).
Verified ON DEVICE (iPhone 16 Pro Max): `make uitest` -> 5 of 5 passed. Along the way: (a) a UI-test compile error caught by `make typecheck` (helper named `wait(for:)` clashed with XCTest) -> fixed; (b) obstacle test first failed because tapping a Toggle row in its middle does not flip it (tap the switch at the right edge) -> fixed;
  (c) one run failed with "Home screen missing": the app was on the Navigator picker at launch (cause not found; a normal launch is clean) -> made `setUp` return to Home; 5/5 afterwards. If it recurs, check `app launch command` lines in the console.
Scan-screen evidence (phone lying on a desk): Tracking OK, Mapping not available, Nodes 1, Mesh 0 triangles, no box; screenshot shows live (blurry) camera + HUD + controls rendered. Conclusion: our AR delegate receives frames, so the "AR view steals the session" risk is ruled out; mesh/box on a real scene is STILL UNVERIFIED (needs the phone held up in a room).
Observed: `devicectl list devices` also lists "Neeha's iPhone" (iPhone 17, unavailable) - a teammate's phone was connected to this Mac before; a non-LiDAR iPhone 17 can be used for the no-LiDAR QA (U4 tasks) once connected.
NOT verified: LiDAR mesh/box in a real room; audio quality; haptic feel; cloud (not configured); relocalization.
Open for U1: hold the phone in a room and run `DEVICE=00008140-000914590E01801C make selftest-scan` (or the Scan screen by hand) -> U1.4, then U1.5/U1.6.

---

## 2026-10-17 17:10 — Claude (agent, for Sachin) — Headless on-phone testing + first real device run; arrival-speech bug found and fixed   [tags: BUILD, BUG]
Area: B (guidance) + D (harness); requested by U1 ("can you test this headless / CLI?")
Findings before building anything:
- I have NO tool that can see/click the Mac screen (only browser/Figma tools), so iPhone Mirroring cannot be driven by me. It is also unsuited to AR (phone must be locked while mirrored; camera/AR likely unavailable - not verified).
- `devicectl --console` showed NOTHING from the app: it captures stdout/stderr only, and we logged with os.Logger. The earlier docs claim "make launch streams logs" was wrong (struck through in docs/TESTING.md).
Files created: `Waypoint/App/LaunchCommand.swift` (launch-argument switches `-autoSimulate "<label>"`, `-autoFacingAway YES`, `-autoScan YES`).
Files edited (code): `Waypoint/App/Log.swift` (REWRITTEN: `AppLog` writes to os.Logger AND stderr), `Waypoint/App/AppState.swift` (reads the launch command, picks the mode), `Waypoint/UI/NavigatorView.swift`
  (auto-runs the simulated walk, exits 0/1/2), `Waypoint/UI/VolunteerView.swift` (auto-starts scanning), `Waypoint/Capture/CaptureController.swift` (1 Hz `scan:` status line),
  `Waypoint/Navigation/NavigationController.swift` (logs instruction changes, haptics, beacon direction ~1/s), `Makefile` (`selftest-sim`, `selftest-scan`, `ROOM=`; app args need a `--` after the bundle id),
  `Package/.../Guidance/FeedbackPlanner.swift` (arrival, turns, hazards now `.high` speech priority) and `Tests/.../FeedbackAndVisionTests.swift` (3 assertions updated).
Files edited (docs, strike/update): `docs/TESTING.md` (logs claim corrected + new "Headless tests" section), `AGENTS.md` (command table +3 rows).
Bug found by the on-phone test: `.normal` speech is skipped while the voice is busy, so "You have arrived at Room 204." was never spoken (it arrived while "Continue straight." was talking). Fixed by making arrival/turn/hazard speech `.high`
  (interrupts); re-ran on the phone: arrival now spoken. Also found while building the test: my first harness picked `maps.first` (alphabetical), which was U1's own scan, so it failed with exit 2; now it searches all maps.
Observed state: the phone already holds 2 maps (the seeded SAMPLE map and a map saved by U1 - name "Rice Hall, floor 1"), i.e. U1 has already saved at least one scan (U1.5 partly done; relocalization U1.6 still unmeasured).
Verified ON DEVICE (iPhone 16 Pro Max, iOS 27, USB, unlocked): `make selftest-sim` -> instruction changes continueStraight -> turnRight(57 deg) -> continueStraight -> arrived; `say:` lines incl. arrival; `haptic: turnRight`, `haptic: arrived` (no haptic errors);
  `spatial audio started` (no audio errors); beacon local x=+1.50 (to the right) at the right turn; `SELFTEST PASS`, exit 0. Also `make test` 50 pass, `make typecheck` OK (20 app files), build succeeded and installed.
NOT verified: that the audio is actually audible/directional to a human (needs headphones + ears), that haptics are felt, `make selftest-scan` (not run yet), anything LiDAR/mesh/relocalization.
Open: U1 to run `make selftest-scan` while walking (U1.4). U2 owns tuning audio now that the walk is reproducible with one command.

---

## 2026-10-17 16:20 — Claude (agent, for Sachin) — U1.1 signing: certificate found, Team ID set, app built + installed on iPhone 16 Pro Max   [tags: BUILD]
Area: U1 (setup)
What happened: Sachin created the Apple Development certificate in Xcode (Personal Team, certificate under khanalsachin@icloud.com). Read the real team id from the certificate OU
  (5S33HP2CPC) and wrote `DEVELOPMENT_TEAM` and `WAYPOINT_DEV_SUFFIX = sachin` into the git-ignored `Config/Local.xcconfig`.
Doc bug found and fixed: our instructions said the team id is the "(XXXXXXXXXX)" in `security find-identity`; that value is a certificate/person id (here YN84BMTT4S) and is NOT the team id.
  Added `scripts/team-id.sh` + `make team-id`; corrected `Config/Local.xcconfig.example` (comment) and `docs/SETUP.md` (old text struck through, labelled Update).
Verified (real device, not simulated):
- `make doctor` all PASS, phone `connected`, Developer Mode Enabled (queried via devicectl).
- `DEVICE=00008140-000914590E01801C make build` -> BUILD SUCCEEDED, signed with "Apple Development: khanalsachin@icloud.com", profile "iOS Team Provisioning Profile: io.github.sachin-khanal.waypoint.sachin".
- `make install` -> "App installed", bundleID io.github.sachin-khanal.waypoint.sachin.
NOT yet verified: launching. `make launch` was denied by iOS (error: "profile has not been explicitly trusted by the user"). Expected for free profiles: the developer must be trusted once on the phone
  (Settings > General > VPN & Device Management > Apple Development: khanalsachin@icloud.com > Trust). After that U1.1 is done when the app opens and camera + local network prompts are accepted.
Note for U2-U4: use `make team-id` for your own team id; each person's Apple ID gets its own id.

---

## 2026-10-17 15:40 — Claude (agent, for Sachin) — Bundle id prefix changed from edu.virginia.* to io.github.sachin-khanal.waypoint   [tags: BUILD, CONTRACT CHANGE]
Area: shared (U1 asked while doing U1.1 signing)
Why: I had used a UVA domain for bundle ids without asking; the team does not own or represent that domain. See D-019.
Files edited (code/config): `Config/Base.xcconfig` (+`WAYPOINT_BUNDLE_PREFIX`), `project.yml` (`bundleIdPrefix`, `PRODUCT_BUNDLE_IDENTIFIER` now uses the variable),
  `Makefile` (reads the prefix from xcconfig), `scripts/doctor.sh`, `Waypoint/App/Log.swift` (logger subsystem), `Package/.../Cloud/CloudModels.swift` (Keychain service),
  `Package/.../Tests/.../CloudTests.swift`, `Config/Local.xcconfig.example` (comment).
Files edited (docs, strike-through + Update): `Architecture.md` (setup checklist), `docs/SETUP.md` (troubleshooting row), `docs/TESTING.md` (log subsystem); `docs/DECISIONS.md` (+D-019).
Effect for everyone: final bundle id is `io.github.sachin-khanal.waypoint.<WAYPOINT_DEV_SUFFIX>` (e.g. ...waypoint.sachin). Nothing else to do except pick a suffix in your `Config/Local.xcconfig`.
  Anyone who had already installed a build would now see it as a different app (nobody had).
Verified: `make test` -> 50 tests, 0 failures; `make typecheck` OK; `make check` -> BUILD SUCCEEDED; built Info.plist CFBundleIdentifier = `io.github.sachin-khanal.waypoint.<suffix from Local.xcconfig>` (it showed the unedited placeholder suffix `replacewithyourname`, so set a real suffix); `make doctor` shows the new prefix.
NOT verified: signing/installing with the new id (no signing identity exists on this Mac yet; U1.1 in progress).

---

## 2026-10-17 15:10 — Claude (agent, for Sachin) — Detailed per-person roadmap (Revision 3)   [tags: DOCS]
Area: shared (docs only, no code, tests not re-run)
Request: "make a roadmap with explicit granular details from start to finish, what we have so far, and what is attributed to each user" with the real team: U1 Mac Pro + iPhone 16 Pro Max, U2 Mac Air + iPhone Pro, U3 Windows + iPhone Pro, U4 Windows + regular iPhone.
Files edited (strike-through + Update rule respected, nothing deleted):
- `docs/ROADMAP.md` — old per-letter "Recommended assignment" struck through with a pointer; appended **Revision 3**: device capability matrix, state-of-the-project table, phases P0-P6 with gates G1-G5 and the critical path,
  full task tables for U1-U4 (ID, estimate, blocked-by, done-when), dependency sketch, branch/merge rules, check-in rhythm, cut order with owners, open questions.
- `AGENTS.md` (Human team) and `docs/MODULES.md` (team line): struck the "fill in names" placeholders, added the U1-U4 mapping (A=U1, B=U2, C=U2+U3, D=U2+U3+U4).
Assumptions to confirm: about 24 h remain; U3/U4 cannot build iOS so they get backend/web/tooling and field/QA/demo lanes (Swift changes via Live Share on a Mac host); the regular iPhone has no LiDAR, so no scanning or obstacle detection there.
New task IDs introduced: INF-1 (`make ipa` + sideload path), INF-2 (CI workflow); both unbuilt.
Verified: nothing to run (docs). Open: see "Open questions" at the end of Revision 3.

---

## 2026-10-17 14:40 — Claude (agent, for Sachin) — Security fixes: unsafe segment ids (path traversal) + Keychain session   [tags: BUG, CONTRACT CHANGE]
Area: D (cloud/sync) + shared Model
Trigger: automated commit-time security review, 2 findings (both MEDIUM, both judged valid):
1. Path traversal: `segmentId` from untrusted maps flowed into the Storage download path AND, worse than reported, into the LOCAL file name in
   `MapStore` (`worldmap-<segmentId>.arworldmap`) - a hostile map/bundle could write outside its folder.
2. Session tokens were stored in UserDefaults.
Files edited (code):
- `Model/MapTypes.swift` (+`SegmentID.isValid`: `[A-Za-z0-9_-]`, 1-64 bytes).
- `Model/MapStore.swift` (`MapBundle.validate()` checks node segment ids and world-map keys; `saveWorldMap`/`loadWorldMap` refuse unsafe ids).
- `Cloud/SyncEngine.swift` (`worldMapPath` now `throws` and requires a safe segment + UUID owner; `push`/`fetchBundle` updated; `fetchBundle` validates the
  map before any URL is built).
- `Cloud/CloudModels.swift` (`UserDefaultsSessionStore` REMOVED, `KeychainSessionStore` added: generic password, AfterFirstUnlockThisDeviceOnly; `import Security`).
- `Waypoint/Cloud/CloudController.swift` (uses `KeychainSessionStore`).
Tests added (+5, total 50): `testSegmentIdAlphabet`, `testValidationRejectsPathTraversalSegments`, `testStoreNeverWritesOutsideItsFolderForHostileSegments`,
  `testHostileSegmentIdNeverReachesAURL` (asserts zero /storage/ requests), `testKeychainSessionStoreRoundTrip` (skips itself if no keychain).
Docs (strike-through + Update per the new markdown rule): `docs/DECISIONS.md` (D-015 update, new D-018), `Architecture.md` §10.3 notes.
Contract note: `MapNode.segmentId` values outside the safe alphabet are now rejected on import/push. Maps created by the app use "seg1" and are unaffected.
Verified: `make test` -> 50 tests, 0 failures (Keychain test executed, not skipped); `make typecheck` OK; `make check` -> BUILD SUCCEEDED.
NOT verified: Keychain behaviour on a real iPhone (the code path is the standard Security API; test ran on macOS); nothing against a live Supabase project.
Open: a sideloaded free-profile build can use the Keychain without extra entitlements, but if a device ever reports a keychain error the app simply
re-signs-in anonymously (new user id), it does not crash. Anonymous users that lose their session cannot see their old private rows - acceptable for the demo, note for D.

---

## 2026-10-17 14:10 — Claude (agent, for Sachin) — New markdown rule + stale-docs pass (strike-through + labelled updates)   [tags: DOCS]
Area: shared (docs only; NO code changed, so tests/typecheck were not re-run)
Trigger: team rule: "for changes in markdown files, don't overwrite/delete — strike through the old text and add the new text (label updates)". Does not apply to code.
Files edited (all additive or strike-through; nothing deleted):
- `AGENTS.md` — new hard rule 11 (the convention, exceptions, how to handle tables/headings/code blocks/WORKLOG) + pointer to ROADMAP/TESTING in "Orient yourself".
- `docs/WORKFLOW.md` — principle 6 (same rule).
- `Architecture.md` — struck + updated: §1 constraint rows (no backend / Multipeer), §2 note (cloud, simulator), §3 note (Node/Edge -> MapNode/MapEdge),
  §4.7 note (cloud primary, Multipeer fallback, approvals), §5 note (original layout lines restored from git commit 370d66f as struck text), §6 owners/timeline notes,
  §7 four new risk rows + nice-to-have line, §9 three new open decisions, §10 heading/status ("PROPOSED" struck -> IN PROGRESS), new §10.5 implementation-status table.
- `docs/DECISIONS.md` — D-007 amended note; D-013..D-016 "PROPOSED" struck with labelled status updates (D-014 flagged as "REST was my default, not explicitly confirmed");
  new D-017 recording the markdown rule.
- `docs/ROADMAP.md` — header status struck/updated; new "status after build block 1" table; "start right now" items marked done.
- `docs/MODULES.md` — update note under the legend; "backlog additions after build block 1" per owner appended.
- `README.md` — "no server" sentence struck + updated; repo map gains `supabase/`; status paragraph gets a block-1 update.
- `docs/SETUP.md` — CoreSimulator known issue marked resolved on Sachin's Mac.
Not changed on purpose: older WORKLOG entries (history; they remain accurate for their time), `docs/TESTING.md` (new today).
Known imperfection: earlier today I overwrote a few numeric strings in place before this rule existed (test counts 25/27 -> 45 in README.md and docs/SETUP.md). They are plain count corrections; git history holds the old values.
Verified: grep shows each struck phrase still present next to its labelled update; `git diff --stat` touches only `.md` files in this pass.
Open: none new. If you want the old counts restored as struck text too, say so.

---

## 2026-10-17 — Claude (agent, for U3) — New Scanner + Navigator interface, mock-first (behind a default-OFF switch)   [tags: BUILD]
Area: shared (UI). Branch `app-ui-workflows`. Implements docs/UI_PLAN.md §2-§9; status and deviations in UI_PLAN §13.
Files created - WaypointCore (pure, with tests):
- `Flows/ScanFlow.swift` (ScanFlow, ScanQuality, ScanTracking.from(summary:), FinishGate), `Flows/NavigateFlow.swift`
  (NavigateFlow, defaultStart), `Flows/GuidanceState.swift` (GuidancePhase, GuidanceSnapshot, parse/derive of
  NavigationController strings), `Flows/RouteSummary.swift`, `Flows/MapHealth.swift`, `Flows/PlanLayout.swift`,
  `Flows/SpokenText.swift`; `Tests/WaypointCoreTests/FlowTests.swift` (21 tests).
Files created - app:
- `Waypoint/Services/`: ServiceMode (settings keys, factory, LiDAR check), ScanService + MockScanService + LiveScanService,
  GuidanceService + MockGuidanceService + LiveGuidanceService, Announcer (VoiceOver / spoken prompts, headphone check).
- `Waypoint/UI/DesignSystem/`: Theme, HeroButton, CardRow, MockBadge, StatusPill, QualityRing, Banner, TagPalette,
  PlanView, HoldToConfirmButton.
- `Waypoint/UI/Scanner/`: ScannerFlowView, ScanSessionModel, ScanLibraryView, ScanSetupView, LiveScanScreen,
  ScanReviewView, ScanShareView, MockCameraView.
- `Waypoint/UI/Navigator/`: NavigatorFlowView (+NavScreen, NavInfoRow), NavigatorModel (+Recents), BuildingPickerView,
  DestinationPickerView, RouteConfirmView, LocalizingView, GuidingView, ArrivedView, EscortPanel.
- `Waypoint/UI/SettingsView.swift`.
Files edited:
- `Waypoint/UI/RootView.swift` (owner D): gear button -> SettingsView; `ui.newInterface` (default false = Classic shows
  VolunteerView/NavigatorView exactly as before); optional open-in-Navigate on launch (new interface only).
- Docs (appended only): `docs/UI_PLAN.md` §13, `docs/MODULES.md` (3 rows), `docs/TESTING.md` (Level 4), this entry.
NOT edited (by design, UI_PLAN R1/R3): CaptureController, NavigationController, Relocalizer, LiveScanView, guides, MapSync,
  CloudController, VolunteerView, NavigatorView, SyncView, AppState, any existing WaypointCore file, project.yml.
Data contract: unchanged (no CONTRACT CHANGE). Renaming a place in Review re-saves map.json with version + 1.
Commands run:   none that compile (written on Windows: no Swift toolchain). Static review only.
Verified:       NOTHING COMPILED. Checked by reading: every new type defined once, no name clashes with existing app/core
  types, protocol conformances complete, memberwise-init argument orders, iOS 17 API availability, no `#Preview`
  macro (PreviewProvider used so plain `swiftc -typecheck` works). FlowTests expectations computed by hand from the
  sample map.
NOT verified:   `make test`, `make typecheck`, `make check` - must be run on a Mac first. Everything in Waypoint/ is
  UNVERIFIED ON DEVICE (VoiceOver flow, spoken prompts, live adapters, plan view, haptics).
Open problems / handoff:
1. A Mac owner: pull `app-ui-workflows`, run `make test && make typecheck`, fix any compile errors, log the result here.
2. U1 review `LiveScanService` mapping; U2 review `LiveGuidanceService` + Navigator accessibility (UI_PLAN §12 Q1).
3. Run TESTING Level 4 on phones (4.3 with VoiceOver and eyes closed is the important one).

## 2026-10-17 — Claude (agent, for U3) — UI plan for Scanner + Navigator workflows (mock-first)   [tags: DOCS]
Area: shared (UI). Branch `app-ui-workflows`.
Files created:  `docs/UI_PLAN.md` (plan only, no code).
Files edited:   `docs/WORKLOG.md` (this entry).
Files deleted:  none.
Commands run:   none (read-only review of the repo).
Verified:       n/a (documentation).
NOT verified:   nothing built yet.
Open problems / handoff: plan proposes new files only plus a default-off switch in `RootView`; needs answers to
  UI_PLAN.md §12 from U1/U2 (ownership of `Waypoint/UI/Navigator/`, RootView switch) before P1 starts.

## 2026-10-17 13:30 — Claude (agent, for Sachin) — Build block 1: live scanner, simulate mode, Supabase client + schema   [tags: BUILD, CONTRACT CHANGE]
Area: A (scan view), B (simulation), D (cloud), C (budget) - scaffolded together; owners should take over each part.
Why: user said "continue building" and to integrate Supabase while building (ROADMAP.md revision 2).

Files created - WaypointCore (all unit-tested):
- `Scan/OrientedBox.swift` (gravity-aligned box, yaw search, contains/corners/expanded), `Scan/ExportBudget.swift`
  (40 MB cap vs Supabase 50 MB/file limit).
- `Simulation/PoseSimulator.swift` (virtual walker that turns before walking).
- `Cloud/HTTPTransport.swift`, `Cloud/CloudModels.swift` (SupabaseConfig, AuthSession, SessionStore, BuildingRow,
  RemoteMap, CloudError), `Cloud/SupabaseClient.swift` (actor: anonymous auth + refresh + one 401 retry, PostgREST
  upsert/list, Storage upload/download; plain REST, no SDK), `Cloud/SyncEngine.swift` (push uploads world maps
  BEFORE the row; fetch validates).
- Tests: `ScanAndSimulationTests` (6), `CloudTests` (11, mock transport) -> **45 tests total**.
Files created - app (type-checked only): `Waypoint/Scan/MeshSampler.swift`, `Waypoint/Scan/LiveScanView.swift` (RealityKit
  ARView + `.showSceneUnderstanding` mesh overlay + green wireframe box), `Waypoint/Cloud/CloudController.swift`.
Files created - other: `supabase/migrations/0001_init.sql` (tables buildings/scans, RLS, private buckets
  worldmaps/meshes, storage policies, updated_at trigger), `docs/TESTING.md`.
Files edited:
- `Geometry/Geometry.swift` (+`cameraTransform(position:forward:)`).
- `Waypoint/Capture/CaptureController.swift` (meshWithClassification, ~1 Hz box fit, stats, `adjustBoxMargin`).
- `Waypoint/Navigation/NavigationController.swift` (REWRITTEN: shared `tick` loop driven by AR frames OR the simulator;
  `startSimulation`, `simulatedObstacle`).
- `Waypoint/UI/VolunteerView.swift` (full-screen live scan + HUD + box controls), `NavigatorView.swift` (Simulate section +
  obstacle toggle), `SyncView.swift` (Cloud section as its own observing view `CloudSection`).
- `Waypoint/App/AppState.swift` (+`cloud`), `project.yml` + `Config/Base.xcconfig` + `Config/Local.xcconfig.example`
  (SUPABASE_URL / SUPABASE_ANON_KEY -> Info.plist keys `SupabaseURL`/`SupabaseAnonKey`; empty = cloud disabled).
- Docs: `docs/SETUP.md` (+Supabase section §5), `docs/MODULES.md`, `README.md`.
Data contract: `BuildingRow`/table `buildings` is new (one row per owner+map_id; clients merge). `BuildingMap` unchanged.
Bugs found by tests while building: mock matched "/authenticated/" as "auth" (test bug); 401-retry test logic (test bug).
  One real review catch: SyncView did not observe CloudController (would not redraw) -> fixed with `CloudSection`.
Verified: `make test` -> **45 tests, 0 failures**; `make typecheck` OK (19 app files); `make check` (xcodebuild, unsigned) ->
  BUILD SUCCEEDED, no warnings.
NOT verified (UNVERIFIED ON DEVICE / vs real server): live mesh overlay and box on a phone; ARView sharing our ARSession
  (we rely on ARView NOT replacing the session delegate); mesh vertex reading layout; simulate-mode audio; every Supabase
  call against a real project (SQL never executed; Anonymous Sign-Ins must be enabled by a human); cloud UI.
Open / handoff:
1. Someone creates the Supabase project and follows SETUP.md §5, then runs TESTING.md level 2.9.
2. A: validate 3.1-3.5 in docs/TESTING.md; replace debug mesh overlay with per-anchor coloured entities; MeshExporter (USDZ) +
   viewer are NOT built yet (C).
3. B: TESTING.md 2.2-2.6 with headphones; tune cues.
4. Security note: nothing in the repo contains a Supabase key; never commit the service_role key.

---

## 2026-10-17 12:30 — Claude (agent, for Sachin) — Direction change: Supabase + Polycam-style scanner (docs only)   [tags: DOCS]
Area: shared
Trigger: user said the app is native-iPhone-only (not published), uses Supabase free tier, and needs a
live bounding-box -> 3D LiDAR scanner like Polycam.
Files created: `docs/ROADMAP.md` (workstreams 0-7, owners, milestones M0-M5, cut lines, tasks an agent
can start without a phone).
Files edited: `Architecture.md` (+section 10 "Revision 2", PROPOSED); `docs/DECISIONS.md` (+D-013..D-016, all
PROPOSED; D-016 amends D-007).
Code changed: none. No tests affected.
Verified: nothing to run (docs only).
Open: team must approve the proposals; then start stream 0 (device bring-up) and the phone-free tasks in
ROADMAP.md. Supabase project must be created by a human (needs their account); never commit the service-role key,
only the public anon key belongs in the app config.

---

## 2026-10-17 12:05 — Claude (agent, for Sachin) — xcodebuild now works; first full app build succeeds   [tags: BUILD]
Area: shared
Context: after the CoreSimulator fix (`sudo xcodebuild -runFirstLaunch`, run by Sachin), retried the build.
Files edited: `project.yml` (+`UIRequiresFullScreen: true` to silence the "all orientations" build
warning; app is portrait-only); `Waypoint/Info.plist` regenerated by `make gen`.
Verified: `make doctor` -> CoreSimulator PASS; `make check` (unsigned `xcodebuild`, generic iOS) ->
**BUILD SUCCEEDED**, no warnings after the orientation fix; `make test` -> 27 pass.
NOT verified: signing (`make build`/`run` need `Config/Local.xcconfig` + Apple ID, none set up on this
Mac yet), installing on a phone, and any runtime behaviour. No iPhone was connected.
Handoff: next step is SETUP.md section 3 (Apple ID, team id, Developer Mode, trust), then `DEVICE=<id> make run`.

---

## 2026-10-17 11:40 — Claude (agent, for Sachin) — Security fix for map sync (approval + validation)   [tags: BUG, CONTRACT CHANGE]
Area: D (Sync) + shared Model
Trigger: automated background security review flagged `MapSync.swift`: it auto-accepted every
Multipeer invitation and auto-imported any received map (MEDIUM, missing auth / untrusted import).
Judged valid: a hostile map could steer a blind user somewhere unsafe.
Files edited:
- `Package/WaypointCore/Sources/WaypointCore/Model/MapStore.swift` — added `MapStoreError.rejected`,
  `MapBundle.validate()` (limits, finite positions, unique ids, edges reference nodes, distance vs
  geometry), `importBundle` now validates and refuses NEW edges between two already-known nodes when
  merging. `import simd` added.
- `Waypoint/Sync/MapSync.swift` — invitations held in `pendingInvitation` until
  `respondToInvitation`; received files are size-checked, decoded, validated, then held in
  `pendingMap` until `respondToIncomingMap(accept:)`; nothing touches disk before approval.
- `Waypoint/UI/SyncView.swift` — two alerts: "Connect to <phone>?" and "Import this map?" (shows name,
  sender, node/edge counts).
- `Package/WaypointCore/Tests/WaypointCoreTests/ModelTests.swift` — +2 tests
  (`testValidationRejectsHostileBundles`, `testImportRefusesNewEdgeBetweenExistingNodes`); `import simd`.
- `docs/DECISIONS.md` (D-012), `README.md` and `docs/SETUP.md` (test count 25 -> 27).
Verified: `make test` -> **27 tests, 0 failures**; `make typecheck` -> OK (16 app files).
NOT verified: **UNVERIFIED ON DEVICE** - the alerts and Multipeer flow have never run on phones.
Known limits / handoff:
- Multipeer has no strong peer identity; the human approval is the control. A pairing code in the
  invitation context would be a stronger, optional upgrade (D).
- Loop-closing between two existing nodes is blocked on merge (documented in D-012).
- The AirDrop/Files import path has no UI yet; when D adds an "open .waypointmap" handler it must
  show the same approval step before calling `importBundle` (which validates but does not ask).

---

## 2026-10-17 11:15 — Claude (agent, for Sachin) — Initial scaffold of the whole project   [tags: BUILD, DOCS, CONTRACT CHANGE]
Area: shared (all four areas scaffolded; nothing here was written by A/B/C/D individually yet)

**Why:** team has 24 hours, 4 people, free Apple ID signing, Live Share and/or git (undecided);
wanted a CLI-first build and docs readable by humans and agents.

### Tooling installed on this Mac
- `brew install xcodegen` (v2.46.0). Nothing else installed. No sudo used.

### Files created — build system and config
- `project.yml` — XcodeGen spec: app target `Waypoint` (iPhone only, iOS 17, Swift 5 mode), local
  package dependency `WaypointCore`, Info.plist keys (camera, local network + Bonjour
  `_waypoint-map._tcp/_udp`, arkit capability, Files-app sharing), bundles `Samples/` as resources.
- `Config/Base.xcconfig` — defaults + optional `#include? Local.xcconfig`.
- `Config/Local.xcconfig.example` — template for per-developer team id + bundle suffix.
- `Makefile` — targets: help, setup, doctor, gen, test, typecheck, check, build, install, launch,
  run, logs, devices, open, clean, clean-all. Builds into `~/Library/Caches/Waypoint` (D-005).
- `scripts/doctor.sh` — machine diagnostics. `scripts/typecheck.sh` — builds WaypointCore for the
  iOS SDK and `swiftc -typecheck`s the whole app without xcodebuild.
- `.gitignore` — ignores `*.xcodeproj`, `Config/Local.xcconfig`, build dirs, `.DS_Store`.
- `Waypoint/Info.plist` — GENERATED by XcodeGen from `project.yml` (edit the yml, not this file).

### Files created — docs
- `AGENTS.md` (rules for agents/humans), `CLAUDE.md` (imports AGENTS.md), `docs/SETUP.md`,
  `docs/WORKFLOW.md` (Live Share vs git), `docs/MODULES.md` (ownership/status/interfaces),
  `docs/DECISIONS.md` (D-001..D-011), this file. `README.md` rewritten (was one line).
- `Architecture.md` (created earlier in the session) edited: type names, repo layout, build system.

### Files created — `Package/WaypointCore` (pure logic, tested; no Apple UI/AR frameworks)
- `Package.swift` — SwiftPM manifest (iOS 17 + macOS 14 so `swift test` runs on the Mac).
- `Model/MapTypes.swift` — `NodeKind`, `Hazard`, `MapNode`, `MapEdge`, `MarkerRef`.
- `Model/BuildingMap.swift` — the map document, JSON helpers, `merged(with:)` (union by id,
  local copy wins, version = max+1), `destinations`, `segmentIds`.
- `Model/MapStore.swift` — disk layout `<Documents>/Maps/<uuid>/map.json` + `worldmap-<seg>.arworldmap`;
  `MapBundle` (+ `.waypointmap` export file, import-with-merge).
- `Model/MapBuilder.swift` — breadcrumb every 1.5 m + POI nodes attached to last breadcrumb.
- `Geometry/Geometry.swift` — point/direction transforms, `signedBearing` (right = positive),
  `rotationY`, marker -> `mapToWorldTransform`.
- `Routing/WaypointGraph.swift`, `Router.swift` (A*, stairs penalty 1000 unless allowed),
  `GuidanceInstruction.swift`, `RouteFollower.swift` (advance within 1 m; straight < 25°, turn-around > 135°).
- `Guidance/FeedbackPlanner.swift` — priority/de-dupe rules producing `speak/haptic/beacon` actions.
- `Vision/ObstacleClassifier.swift` — stop <0.6 m, caution <1.2 m, 0.15 m hysteresis.
- `Vision/RoomNumberParser.swift` — `\b\d{3}[A-Z]?\b` extraction + `ConsensusFilter` (3 reads).
- Tests: `ModelTests` (5), `RoutingTests` (13), `FeedbackAndVisionTests` (7) = **25 tests**.

### Files created — iOS app target `Waypoint/` (needs a phone)
- `App/WaypointApp.swift`, `App/AppState.swift` (seeds the sample map on first launch), `App/Log.swift`.
- `UI/RootView.swift`, `UI/VolunteerView.swift`, `UI/NavigatorView.swift`, `UI/SyncView.swift`.
- `Capture/CaptureController.swift` (ARSession + LiDAR mesh, breadcrumbs, POI tag, save ARWorldMap).
- `Relocalization/Relocalizer.swift` (initialWorldMap + optional marker fallback).
- `Navigation/NavigationController.swift` (per-frame integration loop).
- `Guidance/SpatialAudioGuide.swift` (AVAudioEnvironmentNode ping), `HapticsGuide.swift`
  (CoreHaptics: 1 tap = left, 2 = right), `SpeechGuide.swift`.
- `Vision/ObstacleDetector.swift` (LiDAR depth region min), `Vision/SignReader.swift` (Vision OCR, NOT wired in).
- `Sync/MapSync.swift` (MultipeerConnectivity, `sendResource` of `.waypointmap`).
- `Samples/rice-hall-sample.json` — HAND-WRITTEN fake corridor with Room 204/206, stairs, door.
  It is test data, not a real scan of Rice Hall.

### Commands run and results
- `swift test` (default build dir inside repo) -> compiled, then **FAILED at codesign**:
  `resource fork, Finder information, or similar detritus not allowed`. Cause: repo is under
  iCloud-synced `~/Desktop`. Fix: build outside the repo (D-005). Stray `.build` dir deleted.
- `make test` -> **25 tests, 0 failures**.
- `make typecheck` -> **OK, 16 app files** (builds WaypointCore for the iPhoneOS 27.1 SDK, then
  type-checks every app file; no errors or warnings).
- `make gen` -> generates `Waypoint.xcodeproj` successfully.
- `make check` (xcodebuild) -> **FAILS on this Mac before compiling anything**:
  `IDESimulatorFoundation ... CoreSimulator.framework ... no such file` ("A required plugin
  failed to load"). Needs `sudo xcodebuild -runFirstLaunch` by a human (not run by the agent).
  Also `xcrun simctl` is unusable for the same reason. `make doctor` now flags this.
- `make doctor` -> works; no devices connected, no `Local.xcconfig` yet, no signing identity yet.

### NOT verified (important)
- **UNVERIFIED ON DEVICE:** everything under `Waypoint/` at runtime — ARKit capture, world-map
  save/relocalize, marker fallback, LiDAR depth read, spatial audio, haptics, speech, OCR,
  Multipeer sync, all screens. It type-checks against the iOS SDK; it has never run.
- **Never built with xcodebuild or signed.** Signing flow in `docs/SETUP.md` is unexercised.
- Depth-region orientation, audio coordinate handling, and the marker yaw convention are
  best-effort and flagged with TODOs in the file headers.

### Open problems / handoff
1. Someone with admin rights must run `sudo xcodebuild -runFirstLaunch` on each Mac (see SETUP.md).
2. Each dev: `make setup`, fill `Config/Local.xcconfig`, do the one-time Xcode signing run (SETUP.md §3).
3. First integration target: install on a Pro iPhone, choose Navigate -> the seeded SAMPLE map ->
   confirm the app launches and permission prompts appear. (Navigation on the sample map cannot
   relocalize without a real world map; it will sit in "Looking for your position" until A's
   scan/marker path works. B/C can still test audio/haptics/obstacles by temporarily feeding fake poses.)
4. Fill in team names in `docs/MODULES.md`; decide Live Share vs git (`docs/WORKFLOW.md`).
5. Known logic gaps are listed per owner at the bottom of `docs/MODULES.md`.

**Update 2026-10-17 (Codex):** isolated main integration re-run: 46/46 browser logic/GPU/mock checks and 16/16 UI checks PASS; git diff --check PASS. Temporary preview server stopped.
