# Testing — what is proven, and the device test plan

Three levels. Always run level 1 before handing off; levels 2-3 are for people with a phone.

## Level 1 — automated, no phone (`make test`, `make typecheck`, `make check`)

`make test` runs 45 XCTest cases in `Package/WaypointCore/Tests/` in about a second. They prove:
data model + JSON + merge + validation (hostile maps), routing (A*, stairs), bearings, the feedback rules,
obstacle hysteresis, room-number parsing, the scan bounding box, export budget, the simulated walker
(an END-TO-END walk to Room 204 that must end in "You have arrived"), and the whole Supabase client
(request shapes, sign-in/refresh/401 retry, push order, hostile downloads) against a MOCK server.
`make typecheck` / `make check` prove the iOS app compiles. NONE of this proves AR/audio/haptics/cloud
behave correctly on real hardware or against a real Supabase project.

## Level 2 — on a phone, but no scan needed (any iPhone; headphones for audio)

Run after SETUP.md §3 (`DEVICE=<id> make run`). Owner B/D. Mark each result in docs/WORKLOG.md.

| # | Check | Pass looks like |
|---|---|---|
| 2.1 | App launches; Camera + Local Network prompts appear; Home shows "1 map(s)" (seeded sample) | no crash, prompts answered |
| 2.2 | Navigate -> pick the sample map -> "Simulate walk to Room 204" | status "Simulating walk"; spoken "Navigating to Room 204…", then "Continue straight." |
| 2.3 | Wear headphones; listen during 2.2 | a ping that sits ahead/centre while walking, swings to the RIGHT during the last leg |
| 2.4 | Same run: haptics | right turn into Room 204 = two sharp taps; arrival = rising pattern |
| 2.5 | "Inject obstacle" toggle during a simulation | immediate "Stop. Obstacle ahead." + long buzz; ping goes silent; toggling off resumes |
| 2.6 | "Simulate, starting facing the wrong way" | hears "Turn around." first |
| 2.7 | Share maps with two phones nearby | "Connect to <phone>?" alert on the other phone; Send -> "Import this map?" alert; map appears after Import |
| 2.8 | Share maps -> Export (AirDrop) | share sheet opens with a `.waypointmap` file |
| 2.9 | Cloud (needs Supabase set up, see SETUP.md) | status "Cloud ready"; Upload then Refresh shows the map; a second phone can Download the shared one after an Import tap |

## Level 3 — Pro iPhone with LiDAR in a real hallway (owner A/C)

| # | Check | Pass looks like |
|---|---|---|
| 3.1 | Scan a building -> Start scanning | mesh overlay grows over the camera as you walk; green box appears and tracks the space; HUD shows triangles + box size |
| 3.2 | Box margin +/- | box grows/shrinks immediately |
| 3.3 | Tag Room / Door / Stairs while walking | node count rises; nothing crashes |
| 3.4 | Walk until "Mapping: mapped" -> Save map | "Saved N nodes"; map listed on Home |
| 3.5 | **Relocalization:** kill the app, relaunch, Navigate on the saved map, stand where you started | status reaches "Navigating" within ~30 s, in >= 4 of 5 tries. If not: marker fallback (docs/ROADMAP.md stream 2) |
| 3.6 | Walk the route with headphones | ping direction matches reality; turns announced at the right places |
| 3.7 | Walk toward a wall / a person | caution at ~1.2 m, stop at ~0.6 m (tune thresholds in ObstacleClassifier/Detector) |
| 3.8 | Point the camera at a door sign | (SignReader is not wired into a screen yet) check the console for "confirmed room number" once wired |
| 3.9 | Dress rehearsal | blindfolded teammate + escort reaches the target room |

## Reading logs from the phone

`DEVICE=<id> make launch` streams `os.Logger` output (subsystem ~~`edu.virginia.waypoint`~~ **Update 2026-10-17:** `io.github.sachin-khanal.waypoint`, categories:
app, capture, reloc, nav, guidance, vision, sync). Include relevant lines when reporting a bug.

## Reporting a result

Add to docs/WORKLOG.md: which check number, phone model + iOS version, pass/fail, console excerpt. A check
is only "verified" once someone has done it on a device and written it down.
