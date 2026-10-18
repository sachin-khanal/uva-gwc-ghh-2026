# Security and privacy notes

Written 2026-10-18 (Claude, from a full audit requested by Sachin). Facts only: what the app stores and sends, what protects it, what does NOT, and what is still open.
The repo is **public** on GitHub; keep that in mind for anything you commit.

## 1. What data exists, where it goes

| Data | Where it lives | Leaves the phone? |
|---|---|---|
| Camera frames | RAM only (ARKit); used on the phone by Vision (sign OCR, object names) and ARKit | **No.** Never saved, never uploaded. |
| LiDAR mesh | RAM while scanning; exported as `model.usdz` in the app's `Documents/Maps/<id>/` | Only if a person shares it (the 3D model is not uploaded by the app today). |
| Building map JSON (`map.json`): positions, room labels, `createdBy` device tag | `Documents/Maps/<id>/` | Yes, when a person uploads or sends a map: to Supabase (every signed-in user can read it) or a nearby phone. |
| ARWorldMap scan file (`worldmap-*.arworldmap`) | `Documents/Maps/<id>/` | Same as above. It is Apple's opaque archive of what the camera saw (feature points and related visual data). **We have not inspected its contents**; treat it as information about the inside of a building, possibly including things visible during the scan. |
| Visual fingerprints (`keyframes`, U2) | inside `map.json`, OFF by default | With the map. Stored as a descriptor, not a photo (see `Model/Keyframe.swift`). |
| Spoken sentences, place names | os log (visible over USB / Xcode, not uploaded) | No. |
| Supabase session (anonymous user id + tokens) | iOS Keychain, `AfterFirstUnlockThisDeviceOnly` | Sent only to the Supabase project, over HTTPS. |
| `createdBy` tag, e.g. `iPhone-ab12` | inside each node | With the map. It is the model name plus 4 characters of the vendor id: pseudonymous, not a name. |

No location services, contacts, photos library or microphone are used. Permissions requested: camera, local network (nearby phone sharing).

## 2. What protects it (verified)

- **No secrets in the repo or its git history**: the Supabase anon key is in the git-ignored `Config/Local.xcconfig` only (checked tracked files and every commit, 2026-10-18). `tools/supabase_check.py` and the web viewer refuse a `service_role` key.
- **Transport**: only HTTPS to Supabase; no App Transport Security exceptions; no plain-HTTP URLs.
- **Nearby sharing**: Multipeer sessions require encryption; nothing connects or imports without a person tapping accept.
- **Imports are untrusted input**: `MapBundle.validate()` limits sizes, rejects non-finite numbers, unsafe segment ids (path traversal), shortcut edges, malformed room extents and 3D-surface lists; a merge is validated AFTER merging; cloud downloads need an explicit review tap.
- **Database**: Row Level Security on; `extend_building` is `security definer` with an empty `search_path` and validates every field; `canonical_buildings` cannot be written or deleted directly; migration 0005 refuses bad extents/meshAssets at the table; scan files are readable only by exact path of a listed contributor (migration 0004, tested in a local Postgres).
- **Keychain** item is device-only.
- **CI**: the docs check runs on `pull_request` (not `pull_request_target`), so forks get no secrets.

## 3. Findings and status (audit of 2026-10-18)

| ID | Finding | Severity | Status |
|---|---|---|---|
| S-1 | **Anyone can abuse the cloud.** The anon key is public by design and Anonymous Sign-Ins is on, so anyone can mint accounts, create unlimited buildings, upload unlimited oddly-named files (50 MB each; the free tier has 1 GB), and add nodes/labels to ANY shared building (additive only; e.g. a node labelled like a real room). | Medium-High | **Partly fixed in code, NOT applied**: `0006_abuse_limits.sql` (file name shape, 300 files and 25 buildings per account, 500 buildings total; tested locally). Still needed in the Supabase dashboard: captcha (Turnstile/hCaptcha) on anonymous sign-ins, rate limits, a storage/egress spend alert. Poisoning of existing buildings is only limited by the client's review-before-import tap. |
| S-2 | Personal data in the PUBLIC repo history: Sachin's iPhone device id (2x), Apple ID email (3x), Apple team id, in `docs/WORKLOG.md`; every contributor's personal email in git commit metadata. | Medium (privacy) | Current files redacted. **History still contains them**: removing needs a history rewrite + force-push (disruptive); alternatives: make the repo private after the event, or accept. Use GitHub `noreply` emails for new commits (`git config user.email ID+name@users.noreply.github.com`). |
| S-3 | `UIFileSharingEnabled` + `LSSupportsOpeningDocumentsInPlace` are on in every build, so the whole `Documents/Maps` folder (floor plans, scan files, 3D models) is browsable from the Files app and from a trusted computer. Useful for debugging, wrong for a release. | Medium (privacy) | **Open.** Turn both off for the demo/release build (project.yml `info:`). |
| S-4 | Map and scan files are written with default iOS file protection (readable after first unlock), not `complete`. | Low-Medium | **Open (trade-off).** `complete` protection would stop `devicectl`-based backups and tests while the phone is locked. |
| S-5 | `web/index.html` pre-fills the real Supabase project URL (public repo). The URL alone is not a secret (the key is not there) but it points strangers at the project. | Low | **Open (U3's file):** replace with a placeholder. |
| S-6 | `web/` has no Content-Security-Policy. | Low | **Open (U3).** Add a CSP `<meta>`; the viewer loads no third-party scripts. |
| S-7 | `docs-check.yml` does not limit the token's permissions and interpolates `github.base_ref` into a shell command. | Low | Fixed: `permissions: contents: read`, inputs passed through `env`. |
| S-8 | `.claude/settings.json` runs `scripts/docs-sync.sh session` on every contributor's machine when Claude Code opens the repo (and that script installs a git hook). Anything merged into that script runs on everyone's laptop. | Low-Medium | **Accepted** (review changes to `scripts/` and `.claude/` like code that executes); noted here so it is a conscious choice. |
| S-9 | Launch arguments (`-autoSimulate`, `-autoE2E`, `-e2eCloudWrite`, `-scanExportProbe` ...) and debug logging exist in the app. The cloud-writing one needs an explicit argument. | Low | **Accepted for sideloaded team builds**; strip before any public distribution. |
| S-10 | Cloud uploads place building layouts and world maps where EVERY signed-in (including anonymous) user can read them. | Medium (privacy) | **By design today.** Do not upload scans of private spaces; obtain consent from the building owner. A consent line in the upload UI and an owner-only visibility option are not built. |
| S-11 | `keyframes` (U2) are not checked by the Python validator, `web/router.js` or migration 0005. | Low | **Open** (the app's own `MapBundle.validate()` does limit them). |

## 4. Rules for contributors

1. Never commit `Config/Local.xcconfig`, keys, tokens, device ids, Apple ids or personal emails; run `git diff --cached | grep -iE "eyJ|@|0000[0-9]{4}-"` before pushing docs.
2. Treat every map/bundle that comes from another person as hostile input; validate before merge AND after.
3. Applied SQL migrations are never edited; add a new numbered file and a local test (Docker recipe in `supabase/tests/*.sql`).
4. Anything that uploads data needs a sentence telling the person where it goes and who can read it.
5. When you add a field to the map format, add its limits to Swift, `tools/validate_map.py`, `web/router.js` and a migration in the same change.
