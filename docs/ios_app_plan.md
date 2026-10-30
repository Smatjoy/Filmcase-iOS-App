# Filmcase for iOS — Implementation Plan

**Status**: Draft · **Date**: 2026-10-30 · **First target body**: Fujifilm X-T50 (X-Trans V, 7 custom slots, firmware 1.32)

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

```
FilmcaseApp (SwiftUI, iOS 26, Swift 6 strict concurrency)
├─ Features/            Library · RecipeDetail · Collections · Camera (slots, push) · Settings
│   (@Observable view models, NavigationStack/TabView, Liquid Glass chrome)
├─ FilmcaseKit (SwiftPM, platform-neutral, builds and tests on Linux)
│   ├─ Domain/          Recipe, CameraProfile (X-T50), Validation, RecipePTPValues
│   ├─ Camera/          PTPContainer framing, PerPropertyStrategy, PushRecipe, GetCameraSlots
│   │                   protocol PTPDevice { getInt/getString/setInt/setUInt16/setString }
│   └─ API/             FilmcaseClient (async URLSession), DTOs, ClientConfig
├─ Transports (Apple-only targets)
│   ├─ ICCameraTransport   ImageCaptureCore → PTPDevice
│   ├─ BLEPairing          CoreBluetooth (behind a feature flag)
│   └─ PTPIPTransport      Network.framework (only if S2 says BLE→Wi-Fi)
└─ Persistence          SwiftData cache of recipes + last-known slots (offline use in the field)
```

Rules carried over from the repo's ADRs:

- **Layering mirrors the JS client** (`interfaces → application → domain → vendor`). Transports are vendor.
- **Encodings are served, not duplicated** (ADR 016). The app fetches `client-config.json` on connect and caches it. A bundled snapshot is used only offline, and a test asserts the snapshot equals `recipe_ptp_vectors.json["encodings"]`.
- **Write order, delays, retries, grain-off sentinel, and WB-temperature-before-shifts** all come from the shared push vectors, not from memory.
- **Never write without validation.** The X-T50 profile rejects values before the first write. Every push ends in *verified*, *partially failed (named properties)*, or *connection lost*.
- **Back up before overwriting.** Read the target slot into SwiftData before every push, and offer one-tap restore.

---

## 4. UX direction (Axiom + Swift iOS skills)

- **Tab bar with Liquid Glass**: Recipes · Collections · Camera · Settings. The Camera tab shows a persistent connection pill (USB / BLE / none).
- **Recipe detail**: hero cover image, film-sim swatch (reuse the existing `static/images/<film-sim>.png` tiles as assets), settings as a dense, monospaced spec sheet. Space Mono and Archivo are already in `static/fonts` under OFL, so the brand carries over.
- **Send to camera**: a sheet with a 7-slot grid (C1–C7) showing the current slot names read live. Tap a slot, confirm the overwrite, then see per-property progress, a haptic on success, and a diff view on partial failure.
- **Collection push**: drag-reorder recipes onto C1–C7 and push all of them, using `CAMERA_INTER_SLOT_DELAY_S`.
- **Later**: Live Activity during a long collection push. An App Intent, "Send recipe X to C3", for Shortcuts.
- Accessibility: Dynamic Type through the spec sheet, VoiceOver labels on slots ("C3, Kodak Portra 400, Classic Negative"), and reduced-motion fallbacks.

Skills to load per phase. The Axiom site could not be reached from this cloud session; the names below are confirmed from public skill directories:

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

Each phase lists its **acceptance gate**. Nothing merges until the gate is green.

| # | Phase | Where it runs | Gate |
|---|---|---|---|
| **P0** | **Server JSON API + token auth** (Django, this repo). `/api/v1/recipes/` (paginated, filters mirror the explorer facets), `/api/v1/recipes/<id>/`, `/api/v1/collections/…`, thumbnail URLs; bearer token from `FILMCASE_API_TOKEN`, applied to `/api/` and the two existing camera JSON views. ADR 022. | Linux (here) | `pytest` unit + functional tests for every endpoint, including 401 without token. |
| **P1** | **FilmcaseKit: PTP framing** (`PTPContainer` encode/decode, PTP strings, little-endian ints). | Linux (needs a Swift toolchain in the container) or Mac | `swift test`: every case in `ptp_vectors.json` passes byte-for-byte. |
| **P2** | **FilmcaseKit: domain**. `Recipe`, `CameraProfile.xt50`, `Validation`, `RecipePTPValues` (write order). | Linux/Mac | Every vector and validation case in `recipe_ptp_vectors.json` passes. |
| **P3** | **FilmcaseKit: strategy + use cases**. `PerPropertyStrategy.readSlots/pushRecipe`, retries, verify, `RecipeWriteError`, injected clock. | Linux/Mac | Every scenario in `push_vectors.json` replays exactly, against a `FakePTPDevice` that records calls and sleeps, as the JS suite does. |
| **P4** | **FilmcaseKit: API client**. DTOs, `FilmcaseClient`, TOFU pinning delegate. | Linux/Mac | Tests against recorded JSON from P0 and a `URLProtocol` stub. |
| **S1** | **Spike: ImageCaptureCore on X-T50** (human + Mac + camera). Throwaway app: authorize, open session, read `0xD18C`/`0xD18D`/`0xD192` for C1–C7, write a slot name, read it back. | Mac + device | Written log of results/latencies in `docs/ios_usb_spike.md`; decides recovery strategy. |
| **P5** | **ICCameraTransport** conforming to `PTPDevice`, plus connection state machine. | Mac | Unit tests with a stubbed `ICCameraDevice`. Manual: read 7 slots and push 1 recipe to C7 on the X-T50, verified. |
| **P6** | **App shell + library UI** (tabs, recipe list/detail, collections, SwiftData cache, onboarding: server URL → cert pin → token). | Mac | Snapshot/preview tests; UI test: add server → list recipes → open detail. |
| **P7** | **Camera UI** (slot grid, push sheet, backup/restore, collection push). | Mac + device | UI test against `FakePTPDevice` build flavor. Manual: full collection to C1–C7 on the X-T50. |
| **S2** | **Spike: BLE protocol** (human + Mac + camera). Pair with libfuji's BLE flow as reference; capture XApp traffic with Apple's Bluetooth logging profile / PacketLogger; determine (a) vs (b). | Mac + device | `docs/ble_protocol.md` with captured evidence, or a recorded **no-go**. |
| **P8** | **BLE / PTP-IP transport** (only if S2 is a go). | Mac + device | Same push vectors pass through the new transport's fake. Manual verified push to the X-T50. |
| **P9** | Polish: Live Activity, App Intents, accessibility audit, TestFlight. | Mac | `axiom-shipping` checklist. |

Ordering: P0–P4 run in this cloud session (pure Python and pure Swift). S1, P5–P9 need Xcode, a USB-C iPhone and the X-T50, so they run on your Mac. S1 can start in parallel with P0.

---

## 6. Orchestration (Opus lead → Sonnet workers)

- The lead decomposes each phase into briefs. Workers are spawned with **`model: "sonnet"`** pinned on every Agent call.
- **At most 2 workers at once**, each in its own git worktree (`isolation: "worktree"`), on non-overlapping paths:
  - Wave 1: **P0** (`src/`, `tests/`) ∥ **P1** (`ios/FilmcaseKit/Sources/Camera/PTP*`).
  - Wave 2: **P2** ∥ **P4**.
  - Wave 3: **P3** alone, because it depends on P1 and P2.
- Every brief contains: goal, allowed paths, forbidden paths, the fixture or test that is the gate, and the return schema below. A worker that cannot make the gate pass reports `status: blocked`. It does not loosen the test. Regenerating a golden fixture is forbidden.
- The lead reviews the diff, reruns the gate itself, then merges into `claude/youthful-heisenberg-p0wrs8`.

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

## 7. Prerequisites and open decisions

1. **Swift on Linux for P1–P4 in the cloud.** This container has no `swift` binary. Add the swift.org Linux toolchain to the environment setup script (and allow `download.swift.org`), or run P1–P4 on the Mac instead.
2. **Skills.** The Axiom and Swift iOS skills are not installed in this cloud container, and `charleswiltgen.github.io` is blocked by the network policy. They will be used for the Mac-side phases (P5+), or need to be installed into the environment.
3. **Xcode project generation.** Recommend **XcodeGen** (`ios/project.yml`) so the project file is reviewable text and subagents can edit it without merge noise.
4. **Minimum iOS.** Recommend **iOS 26** for native Liquid Glass. ImageCaptureCore PTP needs only 15.2.
5. **Remote access.** If the phone will reach the homelab off-LAN (Tailscale etc.), P0 token auth is mandatory. On LAN only, it is still recommended.
6. **Upstream.** This repo is a fork of `gosku/filmcase`. P0 (JSON API) is a natural upstream PR. The iOS app lives in `ios/` in this fork.
