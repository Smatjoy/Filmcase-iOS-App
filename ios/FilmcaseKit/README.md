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
