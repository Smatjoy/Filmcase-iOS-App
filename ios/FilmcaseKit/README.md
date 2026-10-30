# FilmcaseKit

Platform-neutral Swift package for Filmcase. P1 contains the PTP framing layer, a
one-for-one port of the framing parts of `src/domain/camera/ptp_usb_device.py` and
`src/interfaces/static/js/camera/vendor/ptp_usb_device.js` (ADR 016). No transport or
session handling: ImageCaptureCore owns the session on iOS.

## Tests

```
cd ios/FilmcaseKit
swift build -Xswiftc -warnings-as-errors
swift test
```

Tests read the shared golden vectors straight from `tests/fixtures/camera/ptp_vectors.json`
(resolved from `#filePath`); never copy or edit that fixture here. Builds and tests on Linux
and macOS using Foundation only.

P2 adds `Domain/` (Recipe, CameraProfile, Validation, RecipePTPValues, ClientConfig encodings model), ported from `src/domain/camera/{profiles,validation,queries}.py` and the JS `domain/`; tested against `tests/fixtures/camera/recipe_ptp_vectors.json`.

P3 adds `Camera/` (`PTPDevice`, `CameraSleeper`/`CameraRuntime`, operations with retries, `PerPropertyStrategy` + `getStrategy`, `FakePTPDevice`) and `Application/` (`getCameraSlots`, `pushRecipeToCamera`, `withCamera`), ported from `src/domain/camera/{strategies,operations}.py` and the JS `domain/` + `application/usecases/`. `tests/fixtures/camera/push_vectors.json` replays exactly: same device calls, same sleeps, same outcome. Delays and retry counts come from the served `ClientSettings`, never from constants. Diagnostic event publishing (`vendor/events.js`) is not ported.

## API client (P4)

`Sources/FilmcaseKit/API/` holds the DTOs for `/api/v1/`, `FilmcaseClient`, `ServerEndpoints`
(ordered LAN/Tailscale list, probe, failover, `NetworkPathEvents`), the TOFU decision logic
(`TrustEvaluator`, `PinStore`) and `TokenStore`. Apple adapters (Keychain, SecTrust delegate,
`NWPathMonitor`) implement those protocols later.

Tests serve recorded responses from `Tests/FilmcaseKitTests/API/Fixtures/`. Re-record them
(they are excluded from the SwiftPM target) from the repo root with:

```
RECORD_API_FIXTURES=1 .venv/bin/pytest \
    ios/FilmcaseKit/Tests/FilmcaseKitTests/API/Fixtures/record_api_fixtures.py -p no:cacheprovider
```

## Connection and workflows (P4b)

`Clock/` exposes `FilmcaseClock` (renamed from `Clock` so it no longer shadows `Swift.Clock`);
the camera layer's seconds-based `CameraSleeper` is adapted onto it with `ClockSleeper`.

`Connection/` holds `CameraTransport` (what the ImageCaptureCore adapter implements) and
`CameraConnection`, the state machine `idle → awaitingAuthorization → searching → opening →
ready → busy → recovering → lost` (plus `unauthorized`). The transition table is the pure
`ConnectionState.applying(_:)`. `run(_:_:)` is exclusive and times out through the injected
clock; on a stall it closes and reopens the session, restores the last slot cursor written
(0xD18C) and retries once (ADR 016), and a second stall is `lost`. Operations must be
cancellable, since the timeout race cancels them. `FakeCameraTransport` scripts denied
authorization, stalled calls and unplugging mid-call, and is what the demo flavor uses.

`Workflows/` holds `SlotBackupWorkflow` (read slot, store `SlotBackup`, push, one-tap
restore; results `.verified` / `.partiallyFailed` / `.connectionLost`), `BackupStore` with
`InMemoryBackupStore`, and `CollectionPush` (validated slot assignment, slot order,
`CAMERA_INTER_SLOT_DELAY_S` between slots, progress stream, stop on connection loss, resume).
