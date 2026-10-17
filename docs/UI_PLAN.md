# UI plan — Scanner and Navigator workflows (mock-first)

Status: **PROPOSED** · Author: U3 (with Claude) · Date: 2026-10-17 · Branch: `app-ui-workflows`
Scope: the two user-facing workflows of the one Waypoint app — the **sighted volunteer who scans** and the
**blind user who navigates** — rebuilt as clean, modern, fully accessible SwiftUI screens running on **mock
services** first, so that U1/U2's real scanning, relocalization and guidance can be plugged in later by
swapping one object.

Related: `Architecture.md` §4 and §8 (accessibility notes), `docs/ROADMAP.md` Revision 3 (U2.7, U2.10, U2.11,
U1.7, U1.10, U3.8 are the features this UI leaves slots for), `docs/DECISIONS.md` D-003, D-011, D-012.

---

## 0. Ground rules (how this avoids breaking what works)

The current app works end to end on paper (scan → save → navigate / simulate → share). This plan treats it as
**read-only**:

| Rule | What it means in practice |
|---|---|
| **R1 — Add, don't modify.** | All new code lives in new files and new folders (§9). Existing files `CaptureController`, `NavigationController`, `Relocalizer`, `LiveScanView`, `SpatialAudioGuide`, `HapticsGuide`, `SpeechGuide`, `MapSync`, `CloudController`, `VolunteerView`, `NavigatorView`, `SyncView`, `AppState` and everything in `WaypointCore` are **not edited**. |
| **R2 — One switch, default OFF.** | The only edit to an existing file is a ~10-line change in `Waypoint/UI/RootView.swift` (§8): if the "New interface" preference is on, show the new flows; otherwise show exactly today's screens. Default is **Classic** until the team signs off. Turning it off restores today's app byte-for-byte in behaviour. |
| **R3 — Live adapters only observe.** | The adapters that connect new screens to the real controllers (§4) call only the controllers' existing public methods (`start`, `stop`, `tagPOI`, `adjustBoxMargin`, `save`, `startSimulation`, …) and subscribe to their existing `@Published` properties. No new properties are required on U1/U2 code. Anything that *would* be nicer with a new property is listed as an optional request in §11, never done unilaterally. |
| **R4 — Contract untouched.** | No change to `BuildingMap`, `MapNode`, `MapEdge`, `MapBundle`, JSON shape or `schemaVersion`. No `CONTRACT CHANGE`. |
| **R5 — Security behaviour preserved.** | Map imports (Multipeer, cloud, AirDrop) keep the approval alerts and `MapBundle.validate()` from D-012/D-015. The new Save & Share screen reuses `SyncView` as-is (presented as a sheet) instead of re-implementing sharing. |
| **R6 — No dependencies.** | Apple frameworks only (D-003): SwiftUI, SF Symbols, system materials. No design libraries, no custom fonts. |
| **R7 — Ownership.** | New folders are owned by U3. `Waypoint/UI/Navigator/` overlaps U2's lane (Navigator UI + accessibility, U2.10) → agree with U2 before starting (§12). |

---

## 1. Users, devices, and what each workflow must do

| | **Scanner (volunteer)** | **Navigator (blind user)** |
|---|---|---|
| Who | Sighted teammate or volunteer | Blind or low-vision person (demo: blindfolded judge), with a sighted escort nearby |
| How they use the phone | Looking at the screen, walking slowly, sweeping the camera | Phone held upright at chest height, camera forward; **does not look at the screen**; headphones on |
| Primary output | A saved, labelled map | Arrival at a room, guided by spatial audio + haptics + speech |
| Input | Taps, typing labels | VoiceOver gestures, a few huge targets, (later) voice |
| Phones | Pro iPhones (LiDAR). Regular iPhone (U4) must not crash: camera-only + mock mesh | Any iPhone (U4.8 checks the regular one) |
| Failure that matters most | Saving a bad/incomplete map | Being pulled forward when the app doesn't know where it is → **silence and say so** |

The two workflows are **two modes of one app**, not two apps (free signing allows only 3 sideloaded apps per
phone; Architecture §2 assumes one app).

---

## 2. Architecture of the new UI layer

```
 SwiftUI screens (Waypoint/UI/Scanner, Waypoint/UI/Navigator)       ← look, layout, accessibility
          │  observe @Published view state, call intents
          ▼
 View models: ScanSessionModel, NavigatorModel  (Waypoint/UI/...)   ← own the flow, talk to ONE service
          │  use pure flow logic from WaypointCore/Flows (unit-tested)
          ▼
 Service protocols  ScanService / GuidanceService (Waypoint/Services)
          ├── Mock…Service    timer-driven fakes, no ARKit/audio needed  ← NOW
          └── Live…Service    thin adapters over CaptureController /     ← LATER (U1/U2 review)
                              NavigationController, observe-only (R3)
```

**Why a seam:** screens never import ARKit types (e.g. `ARFrame.WorldMappingStatus`); they use our own small
enums. This lets the screens run on any iPhone, render in Xcode `#Preview` on a Mac with no phone, and be
switched to live behaviour by changing which service is injected.

**Service selection** (`Waypoint/Services/ServiceFactory.swift`):

| Preference "Data source" | Scanner gets | Navigator gets |
|---|---|---|
| **Mock** (default while building) | `MockScanService` | `MockGuidanceService` (silent, scripted) |
| **Simulated** | `MockScanService` | `LiveGuidanceService` using `NavigationController.startSimulation` (real audio/haptics/speech, no scan needed) |
| **Live** | `LiveScanService` (needs LiDAR; on non-LiDAR phones it falls back to Mock with a banner) | `LiveGuidanceService` using `NavigationController.start` (real relocalization) |

LiDAR check: `ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)`.

### 2.1 Service protocols (sketch — final names may change)

```swift
// Waypoint/Services/ScanService.swift
enum ScanTracking: Equatable { case starting, normal, limited(String), unavailable }
enum ScanQuality: Equatable  { case notAvailable, limited, extending, mapped }   // mirrors WorldMappingStatus

struct ScanSnapshot: Equatable {
    var tracking: ScanTracking
    var quality: ScanQuality
    var nodeCount: Int
    var triangleCount: Int
    var boxSize: SIMD3<Float>?        // metres
    var boxMargin: Float
    var tags: [MapNode]               // POIs tagged so far (for the "recent tags" strip)
    var suggestion: String?           // OCR label suggestion slot (U2.7), nil until wired
    var errorMessage: String?
}

protocol ScanService: ObservableObject {
    var snapshot: ScanSnapshot { get }
    var supportsLiveMesh: Bool { get }   // false → screen shows the mock camera placeholder
    var arSession: ARSession? { get }    // non-nil only for Live; used by LiveScanView
    func start(mapName: String)
    func pause(); func resume()
    func tag(kind: NodeKind, label: String?)
    func adjustBox(by delta: Float)
    func finish() async throws -> BuildingMap   // saves via MapStore, returns the map for Review
    func cancel()
}

// Waypoint/Services/GuidanceService.swift
enum GuidancePhase: Equatable { case idle, localizing, guiding, lost, obstacleStop, arrived, failed(String) }

struct GuidanceSnapshot: Equatable {
    var phase: GuidancePhase
    var instruction: String?          // "Turn right", "Continue straight"
    var distanceToNext: Float?        // metres
    var distanceRemaining: Float?     // nil if the live controller doesn't expose it (see §11)
    var obstacle: ObstacleLevel       // from WaypointCore
    var destinationLabel: String
}

protocol GuidanceService: ObservableObject {
    var snapshot: GuidanceSnapshot { get }
    var speaksForItself: Bool { get }  // true for Live/Simulated (SpeechGuide talks) → UI must not repeat it
    func start(map: BuildingMap, destination: MapNode)
    func repeatInstruction()
    func pause(); func resume()
    func stop()
    // Escort / debug only:
    func injectObstacle(_ on: Bool)
    func forceLost()
}
```

### 2.2 Mock behaviour (deterministic, so screens and previews are predictable)

- **MockScanService:** every 0.5 s adds triangles and grows the box; a breadcrumb node every ~2 s; quality goes
  `notAvailable → limited (3 s) → extending (8 s) → mapped (15 s)`; at ~6 s a 2-second
  `limited("Moving too fast")` episode to exercise the warning banner; at ~10 s offers `suggestion = "Room 204"`.
  `finish()` builds a map from the sample graph (`Samples/rice-hall-sample.json`) with a new id and the entered
  name + suffix ` · demo`, plus the tags the user added, and saves it with `MapStore.save` so it shows up in
  Navigate (it has no world map, so it is usable with **Simulate**, not real relocalization — shown as a badge).
- **MockGuidanceService:** timeline using the real route from `Router` on the chosen map:
  `localizing (3 s) → guiding` through each route step with distance counting down at 1.2 m/s →
  one `caution` obstacle mid-route that clears after 2 s → `arrived`. Has controls to force `lost` and
  `failed("Couldn't find your position")`. Silent: it does not speak; the UI posts VoiceOver announcements
  for it (`speaksForItself == false`).

---

## 3. Pure flow logic in WaypointCore (unit-tested, CI-verifiable)

New folder `Package/WaypointCore/Sources/WaypointCore/Flows/` — no SwiftUI/ARKit, so it builds and tests on macOS
and in CI. New tests in `Tests/WaypointCoreTests/FlowTests.swift`. **Nothing existing in the package is modified.**

| File | What it does | Tests |
|---|---|---|
| `ScanFlow.swift` | `enum ScanStep { library, setup, scanning, review, share }` + `ScanFlow` reducer: allowed transitions, when *Finish* is enabled (quality == mapped AND ≥ 1 tagged destination, else explain why), discard confirmation rules | transitions; finish gating; discard |
| `NavigateFlow.swift` | `enum NavStep { building, destination, confirm, localizing, guiding, arrived }` + reducer; auto-skip *building* when only one map; "route back" from arrived (swap start/destination) | auto-skip; back-route; stop from every state |
| `RouteSummary.swift` | From `Router.route` + `WaypointGraph`: total distance, number of turns (> 25° bearing change between legs), stairs/hazards on route, spoken one-liner ("Room 204. About 25 metres, 2 turns, no stairs.") | known sample routes; stairs route; unreachable |
| `MapHealth.swift` | Review warnings: no destinations, unlabeled room/door nodes, disconnected components, duplicate labels, very short map | each warning on hand-built maps; clean sample has none |
| `PlanLayout.swift` | Projects node x/z into a 2D rect (fit + padding, north-up = map −z up) for the Review plan view | fit math; single-node map; aspect ratio |
| `SpokenText.swift` | Distance and number phrasing for speech ("about 3 metres", "less than a metre"), rounding rules | rounding table |

---

## 4. Live adapters (written now, reviewed and turned on later by owners)

| Adapter | Wraps (unchanged) | Mapping |
|---|---|---|
| `LiveScanService` | `CaptureController(store:deviceName:)` | `trackingSummary` → `ScanTracking` (string "Tracking OK" → `.normal`, else `.limited(text)`); `mappingStatus` → `ScanQuality`; `nodeCount`, `triangleCount`, `scanBox?.size`, `boxMargin`, `errorMessage` copied; `tag` → `tagPOI`; `adjustBox` → `adjustBoxMargin`; `finish` → `save()` then waits for `savedMap` (Combine `first(where:)`, 10 s timeout); `arSession` → `controller.session` for `LiveScanView`. `pause/resume` → `stop()`/`start()` are **not** used (would restart the map) → pause only hides the HUD and stops accepting tags until U1 adds real pause (§11). |
| `LiveGuidanceService` | `NavigationController()` | `start` → `start(map:destination:store:)` or `startSimulation(...)`; `statusText` / `instructionText` / `obstacleLevel` / `isSimulating` observed; phase derived: "Looking for your position…" → `.localizing`, "Position lost…" → `.lost`, `obstacleLevel == .stop` → `.obstacleStop`, instruction prefix "arrived" → `.arrived`, else `.guiding`. `injectObstacle` → `simulatedObstacle`. `repeatInstruction` → re-announces current `instructionText` through VoiceOver (the controller has no repeat yet, §11). `speaksForItself = true`. |

String-matching is a stop-gap and is documented in the adapter header as fragile; §11 asks U2 for an additive
`@Published phase` enum, after which the adapter simplifies. The existing `NavigatorView` keeps working
regardless because it is not touched.

---

## 5. Visual design system (clean, modern, accessible)

One file, `Waypoint/UI/DesignSystem/Theme.swift`, plus a few reusable components. Built only on SwiftUI and
system styles, so Dark Mode, Dynamic Type, Bold Text, Increase Contrast and Reduce Motion all work for free.

### 5.1 Tokens

| Token | Value | Notes |
|---|---|---|
| Spacing scale | 4 · 8 · 12 · 16 · 24 · 32 · 48 | `Theme.Space.s/m/l…` |
| Corner radius | 12 (chips) · 20 (cards) · 28 (hero buttons) | `.continuous` rounded rectangles |
| Typography | System **SF Pro Rounded** via `.fontDesign(.rounded)` for headings; text styles only (`.largeTitle`, `.title2`, `.body`…), never fixed sizes | Everything scales with Dynamic Type |
| Scanner palette | System backgrounds; accent **teal**; quality colours: red → orange → yellow → green, always paired with an icon + word | Never colour alone (WCAG 1.4.1) |
| Navigator palette | **Dark by default** (`.preferredColorScheme(.dark)` on the navigator flow only): near-black background, white text, accent **yellow** (`#FFD60A`-like system yellow) for the primary action, red only for STOP | ≥ 7:1 contrast for low-vision users (WCAG AAA); saves battery during a walk |
| Materials | `.ultraThinMaterial` HUD over the camera; `.regularMaterial` bottom sheets | Falls back to solid with Reduce Transparency (system does this) |
| Motion | Short spring animations; all wrapped in `withAnimation(reduceMotion ? nil : .spring)` | `@Environment(\.accessibilityReduceMotion)` |
| Touch targets | Scanner ≥ 44×44 pt; **Navigator ≥ 88 pt tall, full width**; the Start/guiding surfaces are whole-screen | Apple HIG + motor accessibility |

### 5.2 Components (`Waypoint/UI/DesignSystem/`)

| Component | Use |
|---|---|
| `HeroButton` | Full-width, 88+ pt, icon + title + optional subtitle; combines into one VoiceOver element with a hint |
| `CardRow` | List row for maps/destinations: icon, title, detail, chevron; one VoiceOver element |
| `StatusPill` | Small capsule (icon + word) for HUD values: "Tracking OK", "Mapped" |
| `QualityRing` | Circular progress of mapping quality with the word inside; VoiceOver: "Mapping quality: extending, 60 percent" |
| `Banner` | Top warning (icon, text, optional action); announced to VoiceOver when it appears |
| `TagPalette` | Grid of large tag buttons (Room, Door, Stairs, Elevator, Junction) with SF Symbols |
| `PlanView` | `Canvas` drawing of nodes/edges from `PlanLayout`; destinations labelled; stairs edges dashed orange; VoiceOver exposes it as a list of places instead of a picture |
| `HoldToConfirmButton` | Press-and-hold 1 s with a filling ring (Stop, Discard); VoiceOver gets an equivalent custom action with a confirmation |
| `MockBadge` | "Demo data" capsule shown on every screen fed by a mock, so nobody mistakes mock output for real data |

Every component gets `#Preview`s in light, dark, and `.dynamicTypeSize(.accessibility3)`.

---

## 6. Workflow 1 — Scanner (sighted volunteer)

Navigation: a `NavigationStack` driven by `ScanFlow`. Light/dark follows the system.

### S1 · My scans (`ScanLibraryView`)
- Large title "Scans". Cards for each local map (`app.maps`): name, nodes count, destinations count, version,
  badges: `Demo` (no world map), `Shared` (cloud). Swipe actions: Share (opens existing `SyncView` sheet),
  Delete (`MapStore.delete` after a confirmation dialog — the only destructive action, always confirmed).
- Primary `HeroButton` "New scan". Secondary "Extend a map" → shows a "Coming soon (U1.10)" sheet in this
  phase; slot is ready.
- Empty state: illustration (SF Symbol `viewfinder` large), one sentence, the button.

### S2 · Setup (`ScanSetupView`)
- Fields: Map name (required), Building, Floor (optional; combined into `BuildingMap.name`, e.g.
  "Rice Hall · Floor 1" — no contract change).
- Device check card: "LiDAR available ✓" or "No LiDAR — demo scan only" (non-LiDAR phones are routed to Mock).
- "Before you start" tips (3 short rows with icons): walk slowly · sweep walls and floor · tag doors as you pass.
- Optional "Scan start marker" row → "Coming soon (U1.7)" for now.
- Button "Start scanning".

### S3 · Live scan (`ScanningView`) — the hero screen

```
┌──────────────────────────────────────┐
│ [● Tracking OK] [Nodes 12] [Demo]  ✕ │  ← glass status pills; ✕ = discard (hold to confirm)
│                                      │
│        LIVE CAMERA + MESH            │  ← LiveScanView (live) / animated grid placeholder (mock)
│        (green bounding box)          │
│                                      │
│ ⚠ Moving too fast — slow down        │  ← Banner, only when tracking is limited
│ ┌──────────────────────────────────┐ │
│ │ ◔ Mapping: extending   1.2k tris │ │  ← QualityRing + stats
│ │ 💡 "Room 204" detected  [Add]    │ │  ← suggestion chip (OCR slot, U2.7)
│ │ Label: [ Room 204          ]     │ │
│ │ [Room][Door][Stairs][Lift][Junc] │ │  ← TagPalette
│ │ Box  –  1.0 m  +                 │ │
│ │ [ Pause ]      [  Finish ✓  ]    │ │  ← Finish enabled by ScanFlow gating
│ └──────────────────────────────────┘ │
└──────────────────────────────────────┘
```

- Bottom sheet is collapsible (drag or tap the grabber) to see more camera.
- Tagging gives `.sensoryFeedback(.success)` + a toast "Door tagged" + VoiceOver announcement; the "recent tags"
  strip shows the last 3 with Undo (Undo removes from the local list only in mock; live undo needs U1, §11).
- Finish disabled state always explains why ("Keep walking until mapping is complete" / "Tag at least one
  room or door").
- Screen stays awake while scanning (`isIdleTimerDisabled`, restored on exit).

### S4 · Review (`ScanReviewView`)
- `PlanView` of the saved map (north-up), destinations labelled, pinch to zoom.
- `MapHealth` warnings as a list with fixes ("2 rooms have no label → Add labels").
- "Places" list: each tagged node with kind icon + label; tap to rename (writes `label` and re-saves JSON via
  `MapStore.save`; world map untouched). Delete a place is **not** offered (would need graph surgery; out of scope).
- 3D preview card: "3D model coming soon (U3.8)".
- Buttons: "Save & share" → S5, "Done" → S1.

### S5 · Save & share (`ScanShareView`)
- Confirmation: "Saved on this phone ✓".
- Rows: "Share with nearby phones / cloud / AirDrop" → presents the existing **`SyncView`** sheet unchanged (R5).
- "Try it now" → jumps to the Navigator flow with this map preselected, in Simulated mode.

---

## 7. Workflow 2 — Navigator (blind user)

Design principles (from Architecture §8, WCAG 2.2, Apple HIG accessibility):
1. **Eyes-free first.** Every step is completable with VoiceOver, and the guiding phase needs no screen at all.
2. **One thing per screen, one big action.** Huge targets; no small toolbar buttons in this flow.
3. **Always say where you are and what to do next.** Each screen's first VoiceOver element is a heading that
   states the step; state changes are announced; every error is spoken with a next action.
4. **Safety over progress.** When position is lost or an obstacle is at STOP, the beacon is silent (already
   enforced by `FeedbackPlanner`); the UI mirrors that and never shows "keep going".
5. **No accidental exits.** Stopping a route needs a hold or a confirmed custom action.
6. **One voice at a time.** In Live/Simulated mode `SpeechGuide` speaks guidance; the UI must not post the
   same text as a VoiceOver announcement (`speaksForItself`). The UI only announces screen changes.
7. **Haptic language is reserved.** One tap = left, two taps = right (D-011). The navigator UI therefore uses
   **no** decorative haptics while guiding, so a button tap can never be mistaken for a turn cue. Before
   guiding, only the system's selection feedback is used.

Dark, high-contrast theme for the whole flow. Exit from the flow is a large "Exit" row at the bottom of
pre-navigation screens (plus the VoiceOver escape gesture), never a tiny corner button.

### N1 · Building (`BuildingPickerView`)
- Skipped automatically when only one map exists (announced: "Using map Rice Hall, floor 1").
- Otherwise a list of `CardRow`s, 88 pt tall, sorted by most recently used.

### N2 · Destination (`DestinationPickerView`)
- Heading "Where to?". Search field (VoiceOver-friendly, keyboard dictation works out of the box) filtering
  `map.destinations` via `WaypointGraph.nodes(matchingLabel:)`.
- "Recent" section (stored in `@AppStorage`, per map).
- Microphone `HeroButton` "Say a destination" → in this phase returns a canned "Room 204" with a `MockBadge`;
  slot for `SFSpeechRecognizer` (U2.11).
- Each row's VoiceOver label includes the distance summary ("Room 204, about 25 metres, no stairs").

### N3 · Confirm (`RouteConfirmView`)

```
┌──────────────────────────────────────┐
│  Room 204                            │  ← heading (focused first)
│  About 25 m · 2 turns · no stairs    │  ← RouteSummary
│                                      │
│  🎧 Headphones connected ✓           │  ← AVAudioSession route check (read-only)
│  📱 Hold the phone upright at chest   │
│     height, camera facing forward.    │
│                                      │
│ ┌──────────────────────────────────┐ │
│ │                                  │ │
│ │         START GUIDANCE           │ │  ← fills ~50% of the screen, yellow
│ │                                  │ │
│ └──────────────────────────────────┘ │
│  Change destination                  │
└──────────────────────────────────────┘
```
- Headphone check reads `AVAudioSession.sharedInstance().currentRoute` (no audio session changes); if none:
  "Spatial audio works best with headphones" — informational, never blocking.
- Stairs on route → spoken warning row (from `RouteSummary`).
- Magic tap (two-finger double tap) = Start.

### N4 · Finding position (`LocalizingView`)
- Large pulsing (static if Reduce Motion) location icon; heading "Finding your position".
- Spoken hints every ~8 s, not more (avoid chatter): "Slowly turn left and right."
- After 20 s (live) offer: "Try again" · "Use the start marker" (slot, U1.7) · "Ask your escort for help".
- Mock: succeeds after 3 s; escort panel can force failure.

### N5 · Guiding (`GuidingView`) — the screen the user never needs to see

```
┌──────────────────────────────────────┐
│ ▸ Room 204 · 18 m left               │  ← small header
│                                      │
│          ↱                           │  ← huge arrow glyph (rotates with instruction)
│     TURN RIGHT                       │  ← largeTitle, heavy
│      in 3 metres                     │
│                                      │
│  ⚠ OBSTACLE AHEAD   (red, when set)  │
│                                      │
│  tap anywhere: repeat                │
│ ┌──────────────────────────────────┐ │
│ │   HOLD TO STOP  ◯                │ │  ← HoldToConfirmButton, 1 s
│ └──────────────────────────────────┘ │
│  ⋯ Escort                            │  ← hidden in VoiceOver; opens escort panel
└──────────────────────────────────────┘
```
- The whole upper area is one accessibility element: label = current instruction + distance; activating it
  (single tap without VoiceOver, double tap with) = **repeat instruction**.
- Magic tap = pause/resume guidance (spoken "Guidance paused").
- VoiceOver custom actions on the main element: "Repeat", "Distance remaining", "Pause", "Stop navigation"
  (asks "Stop navigation? Double tap to confirm").
- States: `lost` → full-screen "Position lost. Hold still." (no arrow); `obstacleStop` → full red "STOP";
  both clear automatically.
- Screen kept awake; brightness untouched.
- **Escort panel** (sheet, for the sighted helper/judge; hidden from VoiceOver order with
  `.accessibilityHidden(true)` on the opener and reachable by a visible small button): data source, inject
  obstacle, force lost, raw status text from the controller, skip to arrived (mock only).

### N6 · Arrived (`ArrivedView`)
- Heading "You have arrived at Room 204" (announced). Distinct arrival haptic already comes from `HapticsGuide`
  in live mode.
- `HeroButton`s: "Guide me back to the start" (reverse route via `NavigateFlow`), "New destination", "Done".

### 7.1 Accessibility checklist (applies to both flows; navigator must pass all)

| Area | Implementation |
|---|---|
| VoiceOver labels/hints | Every control has `accessibilityLabel` + `accessibilityHint` written as plain speech; icons are `accessibilityHidden` when text already says it |
| Grouping | Cards and rows use `.accessibilityElement(children: .combine)`; HUD is one element per pill |
| Headings | Screen titles `.accessibilityAddTraits(.isHeader)` so the rotor's Headings jump works |
| Initial focus | `@AccessibilityFocusState` moves focus to the step heading on appear |
| Announcements | `AccessibilityNotification.Announcement` (iOS 17) for state changes, only when `!service.speaksForItself` for guidance text |
| Gestures | Magic tap, escape (`.accessibilityAction(.escape)`), custom actions — no hidden swipe-only gestures |
| Dynamic Type | Up to `.accessibility5`; layouts switch from horizontal to vertical with `ViewThatFits`; no truncation of instructions (`.minimumScaleFactor` only on the big arrow) |
| Contrast | Navigator ≥ 7:1; scanner ≥ 4.5:1; respects Increase Contrast and Bold Text |
| Colour | Never the only signal; always icon + word |
| Motion | Respects Reduce Motion (no pulsing, no spring) |
| Time | No timeouts that cancel user actions; hints repeat at most every 8 s |
| Errors | Spoken + visible, each with one next action |
| Without VoiceOver | Navigator still works: in Mock mode screen steps are also spoken through a small `UISpeaker` (AVSpeechSynthesizer) when VoiceOver is off, so a blindfolded tester who doesn't use VoiceOver still hears each step. In Live mode guidance speech comes from `SpeechGuide` as today |
| Launch straight into Navigate | Preference "Open in Navigate mode" so a blind user's phone skips the mode picker |
| Testing | Manual VoiceOver run with eyes closed (§10), Xcode Accessibility Inspector audit on each screen (Mac owners) |

---

## 8. The one change to existing code: entry point in `RootView`

`Waypoint/UI/RootView.swift` (owner D/U2): add a preference and branch, nothing else changes.

```swift
@AppStorage("ui.newInterface") private var newInterface = false   // default: Classic

// in the switch:
case .volunteer: if newInterface { ScannerFlowView() } else { VolunteerView() }
case .navigator: if newInterface { NavigatorFlowView() } else { NavigatorView() }
```
plus a small "Interface: Classic / New" picker in a new `SettingsView` (new file) reached from a gear button in
the toolbar. The classic picker, Share maps sheet and both classic screens remain exactly as they are.
Later, once the team agrees, the default flips to New; classic screens are deleted only by team decision.

---

## 9. Files

New files only (all headers per AGENTS.md §4: File, Owner `U3 (UI flows)`, Purpose, Status):

```
Package/WaypointCore/Sources/WaypointCore/Flows/
    ScanFlow.swift  NavigateFlow.swift  RouteSummary.swift  MapHealth.swift  PlanLayout.swift  SpokenText.swift
Package/WaypointCore/Tests/WaypointCoreTests/
    FlowTests.swift
Waypoint/Services/
    ScanService.swift          (protocol + ScanSnapshot/ScanTracking/ScanQuality)
    GuidanceService.swift      (protocol + GuidanceSnapshot/GuidancePhase)
    MockScanService.swift  MockGuidanceService.swift
    LiveScanService.swift  LiveGuidanceService.swift      (observe-only adapters, R3)
    ServiceFactory.swift       (Mock / Simulated / Live selection, LiDAR check)
    UISpeaker.swift            (screen-step speech when VoiceOver is off, mock mode only)
Waypoint/UI/DesignSystem/
    Theme.swift  HeroButton.swift  CardRow.swift  StatusPill.swift  QualityRing.swift  Banner.swift
    TagPalette.swift  PlanView.swift  HoldToConfirmButton.swift  MockBadge.swift
Waypoint/UI/Scanner/
    ScannerFlowView.swift  ScanSessionModel.swift
    ScanLibraryView.swift  ScanSetupView.swift  ScanningView.swift  ScanReviewView.swift  ScanShareView.swift
    MockCameraView.swift       (animated grid placeholder for mock / non-LiDAR)
Waypoint/UI/Navigator/
    NavigatorFlowView.swift  NavigatorModel.swift
    BuildingPickerView.swift  DestinationPickerView.swift  RouteConfirmView.swift
    LocalizingView.swift  GuidingView.swift  ArrivedView.swift  EscortPanel.swift
Waypoint/UI/SettingsView.swift
docs/UI_PLAN.md               (this file)
```

Edited: `Waypoint/UI/RootView.swift` (§8 only). Docs appended (never rewritten, AGENTS rule 11):
`docs/WORKLOG.md` (entry per block), `docs/MODULES.md` (new rows), `docs/TESTING.md` (new section).

Name check: the new `ScanningView` must not clash with the existing `private struct ScanningView` in
`VolunteerView.swift` — it is `private`, so no clash at module level, but to avoid confusion the new one is
named **`LiveScanScreen`**. Same rule for every new type: `grep` the app target before naming.

`project.yml` needs **no change**: XcodeGen picks up new files under `Waypoint/` and the package automatically.

---

## 10. Phases, tasks, and done-when

Estimates assume one person on Windows with CI; Swift is verified by CI (INF-2) and by a Mac owner pulling the
branch. Everything touching device APIs is logged **UNVERIFIED ON DEVICE** until run on a phone.

| # | Task | Est. | Done when |
|---|---|---|---|
| **P0** | | | |
| 0.1 | Pull `origin/main` into this branch; agree §12 questions with U2 and U1 | 0.5h | answers recorded in WORKLOG |
| 0.2 | **CI (INF-2)**: `.github/workflows/ci.yml` running `make test` + `make typecheck` on a macOS runner on every push/PR | 1h | green check on this branch — this is how Windows work gets compiled |
| **P1 — foundations (pure + seams)** | | | |
| 1.1 | `Flows/*` + `FlowTests` | 3h | CI `make test` green with new tests |
| 1.2 | `Services/*` protocols, mocks, `ServiceFactory` | 2.5h | CI `make typecheck` green |
| 1.3 | `DesignSystem/*` with previews | 2.5h | typecheck green; a Mac owner screenshots previews (light/dark/AX3) |
| **P2 — Scanner flow** | | | |
| 2.1 | S1 Library, S2 Setup | 2h | flows in preview with mock data |
| 2.2 | S3 Live scan screen (mock camera + live `LiveScanView` branch) | 3h | mock run shows quality progression, warning, suggestion, finish gating |
| 2.3 | S4 Review (PlanView, health, rename), S5 Share (opens `SyncView`) | 2.5h | sample map renders; rename persists after relaunch |
| **P3 — Navigator flow** | | | |
| 3.1 | N1–N3 (picker, destination search/recents, confirm + RouteSummary) | 2.5h | VoiceOver reads each screen top-to-bottom sensibly |
| 3.2 | N4–N6 (localizing, guiding, arrived) + escort panel + hold-to-stop | 3h | mock walk completes; stop requires hold/confirm |
| 3.3 | Accessibility pass §7.1 (focus, announcements, custom actions, Dynamic Type AX5, contrast) | 2h | checklist ticked; eyes-closed run by a teammate |
| **P4 — integration** | | | |
| 4.1 | `RootView` switch + `SettingsView` (§8) | 0.5h | Classic default unchanged; New reachable |
| 4.2 | Live adapters (`LiveScanService`, `LiveGuidanceService`) | 2h | typecheck green; U1/U2 review the mapping |
| 4.3 | On-device test with U1/U2: Simulated mode through new Navigator; Live scan through new Scanner | 1.5h | TESTING rows pass on a phone; regression: Classic mode still passes TESTING 2.x/3.x |
| 4.4 | Docs: WORKLOG entries, MODULES rows, TESTING section | 0.5h | appended per rule 11 |

**Regression guard (every phase):** with the preference on Classic, the app must behave exactly as before.
CI runs the existing 50 tests unchanged; the only existing file touched is `RootView.swift`.

### On-device test script (to add to TESTING.md)
1. Classic mode: run existing TESTING 2.x rows → unchanged results.
2. New + Mock: Scanner end to end; Finish gated; demo map appears in Navigate with `Demo` badge.
3. New + Mock: Navigator end to end with **VoiceOver on and eyes closed**; reach Arrived without looking.
4. New + Simulated: Navigator with headphones; cues come from the real engine, UI does not double-speak.
5. New + Live (Pro iPhone): scan a hallway, Review, rename a room, navigate it.
6. Regular iPhone (U4): Scanner falls back to Mock with banner; no crash.
7. Dynamic Type AX5, Dark/Light, Reduce Motion, Increase Contrast: no clipped instructions.

---

## 11. Optional requests to other owners (additive only, never required for this plan)

| To | Request | Benefit |
|---|---|---|
| U2 (`NavigationController`) | `@Published phase` enum; `distanceRemaining`; `repeatInstruction()` that re-speaks via `SpeechGuide` | Removes string matching in `LiveGuidanceService`; better "N m left" and repeat |
| U1 (`CaptureController`) | `pause()/resume()` that keep the map; `undoLastTag()` | Real Pause and Undo in the scanner |
| U2 (U2.7) | Expose confirmed sign reads as a publisher | Fills the suggestion chip / "Room 204 on your right" |
| U2 (U2.11) | Voice destination | Fills the microphone button |
| U3 (U3.8) | USDZ export | Fills the 3D preview card |

---

## 12. Open questions (answer before P1, record in WORKLOG)

1. **U2:** OK for U3 to build `Waypoint/UI/Navigator/` and the accessibility layer, with U2 reviewing? Or does
   U2 want to own the Navigator screens and U3 do only the Scanner + design system?
2. **U1:** OK with the one-line `RootView` switch and default **Classic** until sign-off?
3. Branch name: keep `app-ui-workflows` or rename to `u3/app-ui-workflows` to match ROADMAP §6?
4. Should "Open in Navigate mode" be on by default on the demo's navigator phone?
5. Demo maps from the mock scanner: save them to the phone (useful for Simulate demos) or keep them in memory
   only (keeps the map list clean)? Plan assumes save + `· demo` suffix + `Demo` badge.

---

## 13. Implementation status (Update 2026-10-17, U3 with Claude)

All of §2–§9 is implemented on branch `app-ui-workflows`, written on Windows and **not compiled yet**: the first
Mac build (`make test && make typecheck`) is the next step. Everything device-facing is UNVERIFIED ON DEVICE.

Differences from the plan above (the plan text is kept as written):
- **Extra core file** `Flows/GuidanceState.swift` holds `GuidancePhase` / `GuidanceSnapshot` and the observe-only
  parsing of NavigationController's `statusText` / `instructionText` (so that mapping is unit-tested).
- ~~`UISpeaker.swift`~~ → `Services/Announcer.swift`: one helper for VoiceOver announcements and spoken prompts
  (`say`, `prompt`, `voiceOverOnly`), plus `AudioRoute.headphonesConnected`.
- ~~`ServiceFactory.swift`~~ → `Services/ServiceMode.swift` (settings keys, `ServiceMode`, LiDAR check, factory).
- Previews use `PreviewProvider` instead of the `#Preview` macro, because `make typecheck` runs plain `swiftc`.
- §8: the gear button sits in the top-left of the home screen (where "Home" appears on other screens).
- §4: live scanner Pause only stops accepting tags (ARKit keeps running); live guidance has no pause, forced
  failure or distance remaining. Requests in §11 still stand.
- The navigator renders nothing until its model has loaded the maps, so a wrong first screen is never announced.
- CI (task 0.2 / INF-2) is **not** added in this change; it still needs a decision on runner minutes (ROADMAP §9 Q2).

