# Filmcase for iOS — Implementation Plan

**Status**: Draft, revision 2 (cloud-first) · **Date**: 2026-10-30 · **First target body**: Fujifilm X-T50 (X-Trans V, 7 custom slots, firmware 1.32)

A native SwiftUI client for a self-hosted (Docker) Filmcase server. Its main job is to
**move a recipe from the library into a C1–C7 slot on the camera**, over USB-C first and
Bluetooth second. Browsing and light editing come along, but the transfer path is the
product.

---

## 1. What the repo already gives us

| Asset | Where | What it means for iOS |
|---|---|---|
| Per-property PTP write algorithm | `src/domain/camera/strategies.py` (`PerPropertyStrategy`), mirrored in `static/js/camera/domain/strategies.js` | Third port, in Swift. Module names mirror one-for-one (ADR 016 rule). |
| PTP framing + USB transport | `src/domain/camera/ptp_usb_device.py`, `static/js/camera/vendor/ptp_usb_device.js` | Framing ports directly; the **transport** is replaced by ImageCaptureCore on iOS. |
| Encodings + timing served as JSON | `GET /camera/client-config.json` (`CameraClientConfig`) | iOS fetches the same tables. No hard-coded copy except an offline snapshot. |
| Recipe in camera-write shape | `GET /recipes/<id>/camera-payload.json` (`RecipeCameraPayload`) | Already usable by the app. |
| Golden fixtures | `tests/fixtures/camera/{ptp_vectors,recipe_ptp_vectors,push_vectors}.json` | **The acceptance tests for every Swift camera module.** Python, JS and Swift all assert the same bytes and the same push sequence. |
| Strategy / profile seam | ADR 021, `src/domain/camera/profiles.py` | X-T50 = `PER_PROPERTY` interface. We add an explicit X-T50 profile and keep the fallback. |
| Slot counts, sensor map | `src/data/camera/constants.py` (`"X-T50": 7`, `"X-Trans V"`) | Already correct. |

**Gaps on the server side**

1. **No JSON API for browsing.** Every other view returns HTML/HTMX. The app needs a read API for recipes, collections, cover thumbnails and filters.
2. **No authentication.** `django.contrib.auth` is installed but nothing is protected. Fine on a LAN browser, not fine for a phone that might reach the server through a tunnel.
3. **Self-signed HTTPS** in Docker (`docs/docker.md`). The app needs trust-on-first-use certificate pinning.

---

## 2. Transport research — what is and is not known

### USB-C (primary, high confidence)

- `ICCameraDevice.requestSendPTPCommand(_:outData:completion:)` is public on iOS (15.2+). Apple says every PTP camera supports it.
- Several shipping iPhone apps (Fuji Frame, FujiShare, Simu, the Fuji X Weekly app) already write C1–C7 over USB-C. That means the custom-slot property codes are reachable through ImageCaptureCore on iPhone.
- Camera must be in **USB RAW CONV. / BACKUP RESTORE** mode, same as the desktop path. The X-T50 needs a direct USB-C to USB-C cable.
- **Risks to retire in spike S1:**
  - An older forum report shows error `-21249` (not authorized) on iPadOS 13. We need `ICDeviceBrowser.requestControlAuthorization` before opening a session.
  - ImageCaptureCore owns the PTP session. We must **not** send our own `OpenSession`/`CloseSession`. We use `requestOpenSession` and send only Get/SetDevicePropValue containers, so the Python session code does not port.
  - A Sony report describes timeouts on commands with a data phase (SetDevicePropValue *is* data-out). Measure on the X-T50.
  - The browser's stall-recovery path (ADR 016: Cancel Request, Device Reset) has no direct ImageCaptureCore equivalent. Recovery becomes "close session, reopen, restore slot cursor".

### Bluetooth LE (secondary, low confidence; research first)

- Fujifilm's BLE protocol is **undocumented**. `petabyt/libfuji` (MIT) implements legacy and secure BLE pairing and the XApp wireless mode, but does not document a recipe write.
- A third-party iPhone app (Color X) reportedly sends recipes to C1–C7 over Bluetooth, tested on an X-E5. The X-E5 is the same generation as the X-T50, so it **is** possible on this body family. How it works is not public.
- X-T50 firmware 1.32 dropped support for the legacy Camera Remote app over Bluetooth, so only the newer XApp-style pairing should be expected to work.
- One BLE connection at a time: XApp must be disconnected first.
- Two plausible mechanisms. Spike S2 decides which one:
  - **(a)** BLE carries the property writes itself.
  - **(b)** BLE only pairs and wakes the camera, then hands off to **Wi-Fi PTP/IP** (TCP 55740), where the same Get/SetDevicePropValue containers apply.
  - If it is (b), we build a `PTPIPTransport` on `Network.framework` and reuse 100% of the PTP layer.
- **The plan treats BLE as feature-flagged** until S2 produces a capture-backed protocol note (`docs/ble_protocol.md`). We do not ship guesses at undocumented writes to a camera.

---

## 3. Architecture

**Principle: logic lives in FilmcaseKit, Apple frameworks are thin adapters.** Anything that can be expressed without ImageCaptureCore, CoreBluetooth, SwiftUI or SwiftData goes in the platform-neutral package and is tested with `swift test` on Linux, in the cloud. The Apple-only targets translate framework callbacks into FilmcaseKit protocols and render FilmcaseKit state, and nothing else. The goal is that a Mac build failure is a compile error or an API mismatch, never a logic bug.

```
FilmcaseKit (SwiftPM, Swift 6 strict concurrency, Foundation + Observation only, tested on Linux)
├─ Camera/        PTP framing (P1) · PerPropertyStrategy · PushRecipe · GetCameraSlots
│                 protocol PTPDevice { getInt/getString/setInt/setUInt16/setString }
│                 FakePTPDevice (recorded calls + sleeps, also used by the app's demo flavor)
├─ Domain/        Recipe · CameraProfile.xt50 · Validation · RecipePTPValues (write order)
├─ Connection/    CameraConnection state machine (idle → authorizing → opening → ready →
│                 busy → recovering → lost), recovery = reopen session + restore slot cursor
│                 protocol CameraTransport { authorize · open · close · device: PTPDevice }
├─ Workflows/     SlotBackup (read target slot → store → push → verify; one-tap restore)
│                 CollectionPush (recipe → C1–C7 assignment, ordering, inter-slot delay,
│                 partial-failure report)
│                 protocol BackupStore (SwiftData adapter in the app, in-memory in tests)
├─ API/           FilmcaseClient (async URLSession) · DTOs · ClientConfig
│                 ServerEndpoints: ordered [LAN, Tailscale] with health probe + automatic
│                 failover, per-host TOFU pin, token in a KeychainStore protocol
├─ Clock/         protocol Clock (injected everywhere; TestClock records sleeps)
└─ ViewModels/    @MainActor @Observable: LibraryModel · RecipeDetailModel · CollectionsModel ·
                  CameraModel (slot grid, push progress) · PushSheetModel · OnboardingModel ·
                  SettingsModel. Depend only on FilmcaseKit protocols.

Apple-only (written in the cloud, compiled on macOS: CI or the Mac)
├─ Transports/    ICCameraTransport (ImageCaptureCore → CameraTransport/PTPDevice)
│                 BLEPairing (CoreBluetooth, feature flag) · PTPIPTransport (Network.framework, if S2 says so)
├─ Persistence/   SwiftData models + SwiftDataBackupStore / RecipeCache (adapters only)
├─ Platform/      KeychainStore · URLSession TOFU delegate (SecTrust) · NWPathMonitor reachability feed
└─ App/           SwiftUI views (render view-model state, forward intents), Liquid Glass chrome,
                  App Intents / Live Activity (P9). Project generated by XcodeGen (ios/project.yml).
```

Rules carried over from the repo's ADRs:

- **Layering mirrors the JS client** (`interfaces → application → domain → vendor`). Transports are vendor.
- **Encodings are served, not duplicated** (ADR 016). The app fetches `/api/v1/camera/client-config.json` on connect and caches it. A bundled snapshot is used only offline, and a test asserts the snapshot equals `recipe_ptp_vectors.json["encodings"]`.
- **Write order, delays, retries, grain-off sentinel, and WB-temperature-before-shifts** all come from the shared push vectors, not from memory.
- **Never write without validation.** The X-T50 profile rejects values before the first write. Every push ends in *verified*, *partially failed (named properties)*, or *connection lost*.
- **Back up before overwriting.** `SlotBackup` reads the target slot into the `BackupStore` before every push, and offers one-tap restore.
- **Backups keep their history, and the oldest one is the original** (decided after a real X-T50 incident: three pushes of the same collection buried the originals under Filmcase's own recipes, and "Restore all" only reached the latest run). Every restore backs up first too, so nothing is ever overwritten without a copy. The Camera tab shows every backup per slot, newest first. The oldest backup per camera and slot is labelled **Before Filmcase**: Filmcase always backs up before its first write, so the oldest copy is what the slot held before Filmcase touched it. This needs no migration. Collection push offers **Undo this push** (the run's own backups) and **Restore originals** (the oldest backup of each slot, after a confirmation). Deferred: skipping a backup when the slot still holds what Filmcase last wrote, and pruning old backups.
- **Adapters carry no decisions.** If an adapter needs an `if`, that branch moves into FilmcaseKit behind a protocol, with a test.

**Server reachability (LAN ↔ Tailscale).** `ServerEndpoints` holds an ordered list (e.g. `https://filmcase.lan`, `https://filmcase.tailnet.ts.net`). On launch and on every path change (fed by `NWPathMonitor` through a protocol), it probes each endpoint's `/api/v1/` with a short timeout and uses the first healthy one. A request that fails with a transport error retries once on the next endpoint. Each host has its own pin, because the LAN and Tailscale hostnames may present different certificates. A host is pinned only when the user approves its fingerprint, either in onboarding or when a not-yet-pinned host first answers. Nothing is pinned silently, because failover reaches hosts without the user watching. An unpinned host or a mismatched pin stops the request and never fails over. One token is used for both. All of this is tested on Linux with a `URLProtocol` stub and a fake path monitor.

---

## 4. UX direction (Axiom + Swift iOS skills)

- **Tab bar with Liquid Glass**: Recipes · Collections · Camera · Settings. The Camera tab shows a persistent connection pill (USB / BLE / none).
- **Recipe detail**: hero cover image, film-sim swatch (reuse the existing `static/images/<film-sim>.png` tiles as assets), settings as a dense, monospaced spec sheet. Space Mono and Archivo are already in `static/fonts` under OFL, so the brand carries over.
- **Send to camera**: a sheet with a 7-slot grid (C1–C7) showing the current slot names read live. Tap a slot, confirm the overwrite, then see per-property progress, a haptic on success, and a diff view on partial failure.
- **Collection push**: drag-reorder recipes onto C1–C7 and push all of them, using `CAMERA_INTER_SLOT_DELAY_S`.
- **Later**: Live Activity during a long collection push. An App Intent, "Send recipe X to C3", for Shortcuts.
- Accessibility: Dynamic Type through the spec sheet, VoiceOver labels on slots ("C3, Kodak Portra 400, Classic Negative"), and reduced-motion fallbacks.

Skills to load per phase. Axiom now ships as router skills (`axiom-swiftui`, `axiom-design`, `axiom-uikit`, `axiom-build`, `axiom-shipping`, …) whose sub-skills carry the names below:

| Phase | Skills |
|---|---|
| App shell, navigation | `axiom-app-composition`, `axiom-ios-ui`, `axiom-swiftui-layout` |
| Visual polish | `axiom-liquid-glass`, `axiom-design`, `axiom-swiftui-performance` |
| Bridging (ImageCaptureCore delegates) | `axiom-uikit-bridging` |
| Build/debug on device | `axiom-xcode-debugging` |
| Release | `axiom-shipping` |

The Swift iOS skills (concurrency, Swift Testing, SwiftData) apply throughout.

---

## 5. Phases

Each phase lists its **acceptance gate**. Nothing merges until the gate is green. "Cloud" means written **and** gated in this session. "Cloud → macOS" means written in this session, then compiled and tested on macOS (CI, or the Mac over Remote Control, or you pasting errors back). ✅ = merged with its gate green; ✍️ = written, not yet compiled on macOS; 🔨 = builds and its simulator tests pass on macOS (Xcode 27.2, iPhone 17 / iOS 26.5), hardware check pending.

| # | Phase | Written | Gated | Gate |
|---|---|---|---|---|
| **P0** ✅ | **Server JSON API + token auth** (Django). `/api/v1/` recipes, collections, thumbnails, mirrored camera JSON; optional bearer `FILMCASE_API_TOKEN` (open when unset, amended 2026-11-01); ADR 022. | Cloud | Cloud | Full `pytest`, import-linter, mypy. |
| **P1** ✅ | **FilmcaseKit: PTP framing.** | Cloud | Cloud | `ptp_vectors.json` byte-for-byte (42 cases). |
| **P2** ✅ | **Domain**: `Recipe`, `CameraProfile.xt50`, `Validation`, `RecipePTPValues`. | Cloud | Cloud | `recipe_ptp_vectors.json`. |
| **P3** ✅ | **Strategy + use cases**, `Clock`, `FakePTPDevice`. | Cloud | Cloud | `push_vectors.json` replays exactly. |
| **P4** ✅ | **API client**: DTOs, `FilmcaseClient`, `ServerEndpoints` (LAN ↔ Tailscale failover), pin *decision* logic (explicit approval, never silent), `HTTPTransport`, `TokenStore`/`PinStore` protocols. | Cloud | Cloud | `URLProtocol` stub tests against JSON recorded from P0; failover and pin-mismatch scenarios. |
| **P4b** ✅ | **Connection + workflows**: `CameraConnection` state machine, `SlotBackup` (backup → push → verify → restore), `CollectionPush` (ordering, inter-slot delay, partial failure). | Cloud | Cloud | Table-driven transition tests; workflow tests against `FakePTPDevice` + `TestClock`, including stall → recover → cursor restored. |
| **P4c** ✅ | **View models** (`@MainActor @Observable`), all features. | Cloud | Cloud | Swift Testing on Linux: state for loading/empty/error/offline, intents, push progress, backup prompt. |
| **S1** ✅ | **Spike app: ImageCaptureCore on X-T50.** Minimal SwiftUI target in `ios/Spikes/USBSpike`: authorize, browse, open session, read `0xD18C`/`0xD18D`/`0xD192` for C1–C7, write C7's name, read it back, time every call, export a log. | Cloud | Mac + camera | Results in `docs/ios_usb_spike.md`: go (2026-11-01, X-T50, iOS 27.2). |
| **P5** ✅ | **ICCameraTransport** (adapter over `CameraTransport`/`PTPDevice`) + `PTPChannelDevice` (framing from S1). | Mac | Mac + manual | Manual push to C7 verified on the X-T50, 2026-11-01 (iOS 27.2, homelab server). |
| **P6** 🔨 | **App shell + library UI**, XcodeGen `ios/project.yml`, SwiftData adapters, onboarding (server URLs → pin → token). | Cloud → macOS | CI | CI: `xcodegen` + `xcodebuild test` (unit + one UI test on the demo flavor: add server → list → detail). |
| **P7** 🔨 | **Camera UI**: slot grid, push sheet, backup/restore, collection push. | Cloud → macOS | CI + manual | CI UI test on the `FakePTPDevice` demo flavor; manual full C1–C7 push (checklist §9). |
| **S2** ⏸ | **Spike: BLE protocol.** Parked as a todo (2026-11-02). | Cloud (capture scripts + notes template) | Mac + camera | `docs/ble_protocol.md` with captured evidence, or a recorded **no-go**. |
| **P8** | **BLE / PTP-IP transport** (only if S2 is a go). Protocol logic in FilmcaseKit, socket/CB adapter thin. | Cloud → macOS | Cloud + CI + manual | Push vectors pass through the new transport's fake on Linux; manual verified push. |
| **P9** 🔨 (TestFlight deferred) | Polish: Live Activity, App Intents, accessibility audit, TestFlight. | Cloud → macOS | CI + manual | `axiom-shipping` checklist; TestFlight checklist §9. |

Wave order: **P0 ∥ P1** → **P2 ∥ P4** → **P3 ∥ S1-code** → **P4b ∥ P6-scaffold** (project.yml + CI) → **P4c ∥ P5** → **P7** → S2/P8 → P9.

---

**P7 manual check, 2026-11-02 (X-T50, iOS 27.2, homelab server):** a 7-recipe collection pushed to C1–C7 with six slots Verified. C2 (Provia 16, the only difference from the verified Provia 18 being DR400) reported 2 settings not applied, with the camera on Auto ISO (max 3200). On the X-T50, DR400 needs ISO 500 or higher and DR200 needs 250 or higher; with Auto ISO the camera judges by the Auto minimum. A later push verified C2. Still open: the setting names were not visible (fix in P9: show them on screen). **Restore all after repeated runs lost the way back to the originals:** the collection was pushed three times (20:31, 20:35, 20:36), each run backed up what was in the slots, and Restore all restores only the last run's backups, i.e. the collection itself. The originals (C1 California Hues … C7 Neon Bloom) are intact as the first seven records in the on-device backup store, but the UI only offers the latest backup per slot. Needs backup history and a "restore originals" decision before P7 can close.

## 6. Orchestration (Opus lead → Sonnet workers)

- The lead decomposes each phase into briefs. Workers are spawned with **`model: "sonnet"`** pinned on every Agent call.
- **At most 2 workers at once**, each in its own git worktree (`isolation: "worktree"`), on non-overlapping paths: FilmcaseKit phases own `ios/FilmcaseKit/**`, Apple-only phases own `ios/App/**`, `ios/Spikes/**`, `ios/project.yml`, and server phases own `src/**` + `tests/**` (not `tests/fixtures/**`).
- Every brief contains: goal, allowed paths, forbidden paths, the gate, and the return schema below. A worker that cannot make the gate pass reports `status: blocked`. It does not loosen the test. Regenerating a golden fixture is forbidden.
- **Apple-only briefs** cannot be gated on Linux. Their gate is: FilmcaseKit still passes `swift test`; the adapter contains no branching logic that is not covered by a FilmcaseKit test; and, once CI is enabled, the macOS workflow is green. Until then the lead marks them `unverified-on-macOS` and they are compiled on the Mac.
- The lead reviews the diff, reruns the gate itself, then merges into the working branch (`claude/sweet-darwin-5zpsl8`).

Worker return schema (fixed):

```json
{
  "phase": "P1",
  "status": "done | blocked",
  "files_changed": ["…"],
  "gate_command": "swift test --filter PTPVectorTests",
  "gate_result": "42 passed, 0 failed",
  "open_questions": ["…"],
  "deviations_from_brief": []
}
```

---

## 7. macOS build feedback without the Mac

Three routes, in order of preference:

1. **Remote Control.** If the Mac is connected to this session, the lead runs `xcodegen`, `xcodebuild build`/`test` and simulator tests there directly, reads the errors, fixes them in the cloud, pulls and re-runs. Requirements on the Mac: the repo cloned in a normal folder (not inside a hidden directory under `~` or `~/Library`), that folder added to Remote Control in the Claude desktop app (Settings → Claude Code → Remote Control), the app up to date, Xcode 26 and `brew install xcodegen`. Camera and BLE steps still need your hands.
2. **GitHub Actions (`.github/workflows/ios.yml`).** On `macos-26` (Xcode 26.x, iOS 26 simulator): `brew install xcodegen` → `xcodegen` → `swift test` for FilmcaseKit → `xcodebuild test` for the app scheme (unit tests + the demo-flavor UI test) on an iOS 26 simulator. Path-filtered to `ios/**`, `concurrency` cancels superseded runs, and the `.xcresult` bundle is uploaded on failure. Approved and pushed 2026-11-02. The repository is public, so macOS minutes are free.
3. **Paste-back.** Build on the Mac, paste the errors, and the lead fixes them.

---

## 8. Prerequisites and open decisions

1. **Swift on Linux**: done. Swift 6.4.2 from the download.swift.org tarball (swiftly's release lookup gets a 403). The setup script needs the corrected install lines plus Postgres.
2. **Skills**: Axiom installed into this session's `~/.claude/skills` (27 router skills). To make it persistent, add the `CharlesWiltgen/Axiom` marketplace on claude.ai. The "Swift iOS skills" source is still to be confirmed.
3. **Xcode project**: XcodeGen (`ios/project.yml`), so the project is reviewable text written in the cloud.
4. **Minimum iOS**: **iOS 26** (decided).
5. **Remote access**: **LAN + Tailscale with automatic switching** (decided). Token auth optional; the API is open when the token is unset, like the HTML UI (amended 2026-11-01). The HTML UI stays unauthenticated (ADR 022, deferred).
6. **Upstream**: P0 is a natural upstream PR to `gosku/filmcase`. The iOS app lives in `ios/` in this fork.
7. **Actions spend**: approved 2026-11-02; `ios.yml` runs on pushes to `main` and `claude/**` that touch `ios/`.

---

## 9. Mac-only checklists

Each is meant to take minutes, not an afternoon. Everything not listed here is done in the cloud.

### S1 — USB spike (≈15 min)
- [ ] `git pull`, then `cd ios && xcodegen generate && open Filmcase.xcodeproj`, select **USBSpike** scheme and your iPhone. Optionally put `DEVELOPMENT_TEAM = …` in `ios/Local.xcconfig`, or set the team in Xcode. Full steps: `ios/Spikes/README.md`.
- [ ] Note your iOS version (an iOS 26.1 beta report says camera authorization stays *not determined*).
- [ ] X-T50: **Connection setting → USB RAW CONV./BACKUP RESTORE**, direct USB-C ↔ USB-C cable, camera on.
- [ ] Run, tap **Authorize**, accept the prompt. Tap **Read slots**: C1–C7 names should appear.
- [ ] If reads fail or time out, flip **Command framing** to *Command only* and repeat.
- [ ] Tap **Write C7 name** (writes `FCTEST`, reads back, restores the original).
- [ ] Tap **Stall drill** (20 reads, then recovery if any time out).
- [ ] Tap **Export log** and paste it into the chat (or AirDrop the file). Note any error codes, especially −21249.

### P6 — first launch against your server (≈5 min)
- [ ] Run the **Filmcase** scheme. Onboarding: enter LAN URL, Tailscale URL and the `FILMCASE_API_TOKEN` value.
- [ ] Expect **Trust this certificate?** with a fingerprint; compare it with `openssl x509 -in <server cert> -noout -fingerprint -sha256` on the server, then Trust.
- [ ] Expect the local-network permission prompt on the first LAN request.
- [ ] If the connection fails with an ATS / TLS error instead of the trust prompt, paste it: the fix is an ATS exception key in Info.plist.
- [ ] Turn Wi-Fi off (Tailscale on cellular): the Tailscale host asks for its own trust once, then the library still loads.

### P5 — first real push (≈10 min)
- [ ] Same camera setup. Run the **Filmcase** scheme on the phone.
- [ ] Camera tab → connection pill shows **USB**. Slot grid shows C1–C7.
- [ ] Pick a recipe → **Send to camera** → **C7** → confirm (a backup is taken automatically).
- [ ] Expect **Verified**. On the camera, check C7's film sim, WB and name. Shoot one frame.
- [ ] Tap **Restore C7** and confirm the original is back, **including Grain Effect when the original had grain Off** (restore writes raw read-back values; if grain is wrong, report it and the lead adds a grain special case). Paste the push log if anything differs.

### P7 — full collection push (≈15 min)
- [ ] Pick a collection with 7 recipes → **Push to camera**, drag to reorder C1–C7, push.
- [ ] Expect 7 × **Verified**. Spot-check C1, C4 and C7 on the camera.
- [ ] Unplug mid-push once and confirm the app reports **connection lost** with the named slots, then reconnect and resume.
- [ ] **Restore all**, and confirm the originals are back.

### S2 — BLE captures (≈30 min, only if we pursue BLE)
- [ ] Install Apple's **Bluetooth logging profile** on the iPhone and **PacketLogger** (Additional Tools for Xcode) on the Mac.
- [ ] Disconnect XApp. Pair XApp fresh while capturing, then send one recipe to C7 with a third-party BLE app if you have one (e.g. Color X), still capturing.
- [ ] Note if Wi-Fi turns on during the send (that points to BLE → PTP/IP handoff).
- [ ] Share the `.pklg` file. The lead writes `docs/ble_protocol.md` from it.

### P9 — Shortcuts and Live Activity (≈15 min)
- [ ] Build with your bundle id (`ios/README.md`: one override, `FILMCASE_BUNDLE_ID`), install on the phone, camera in USB RAW CONV./BACKUP RESTORE mode.
- [ ] Shortcuts app -> **Filmcase**: run **Read Camera Slots**. The app opens and the result lists C1-C7.
- [ ] Run **Send Recipe to Camera Slot**: pick a recipe (suggestions are favourites first), slot 3. Expect the overwrite question, then "Sent ... and checked it". Check C3 on the camera.
- [ ] Ask Siri: "Send a recipe to my camera with Filmcase" and "Read my camera slots in Filmcase".
- [ ] Start a collection push, lock the phone: the Live Activity shows on the Lock Screen with a progress bar and C1-C7 marks; on a Dynamic Island phone check compact, minimal (start another activity) and expanded (long press).
- [ ] Unplug mid-push: the activity shows the connection-lost state and lingers; a clean push disappears after about 10 seconds.
- [ ] VoiceOver on the activity: it reads one sentence (title, progress, slot states), not each icon.

### P9 — TestFlight (≈20 min, once)
- [ ] App Store Connect: create the app record (bundle id from `project.yml`).
- [ ] Xcode → **Product → Archive** → **Distribute → TestFlight**. Or approve an Actions upload job, which needs an App Store Connect API key added as repo secrets.
- [ ] Answer export compliance (no non-exempt encryption) and fill the privacy-manifest prompts.
- [ ] Install from TestFlight and repeat the P5 check once.
