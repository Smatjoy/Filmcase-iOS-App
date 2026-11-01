# USBSpike (spike S1)

Throwaway SwiftUI app that retires the USB risks for the Fujifilm X-T50 over ImageCaptureCore.
**Unverified on macOS**: it was written on Linux and has never been compiled. Expect to fix a few
compile errors first; the `// API:` comments in `ICCameraBridge.swift` name every ImageCaptureCore symbol to check.

## Run

1. Optional: put `DEVELOPMENT_TEAM = YOURTEAMID` in `ios/Local.xcconfig` (git-ignored). Otherwise set the team in Xcode, Signing & Capabilities.
2. `cd ios && xcodegen generate && open Filmcase.xcodeproj` (install with `brew install xcodegen`).
3. Scheme **USBSpike**, destination: your iPhone (not a simulator; ImageCaptureCore needs real USB).
4. X-T50: Connection setting -> **USB RAW CONV./BACKUP RESTORE**, direct USB-C to USB-C cable, camera on.
5. In the app, in order:
   - **Authorize** (accept the prompt). If the status stays `notDetermined`, also try **Authorize contents (fallback)**.
   - **Open session**.
   - **Read slots** (C1-C7 names and film sim values).
   - **Write C7 name** (writes `FCTEST`, reads back, restores the original, reads back).
   - **Stall drill** (20 reads; timeouts trigger close, reopen, restore cursor).
6. **Command framing** defaults to *Bare data out*, which works on the X-T50 (see
   `docs/ios_usb_spike.md`). *Full container* gets OK replies but the camera ignores the written
   value, so every slot reads as C1. The log shows raw hex either way.
7. **Prepare log file**, then the share button; AirDrop or paste the file.

## What to paste back

- The whole exported log (it includes raw hex of every command, response and in-data).
- For each framing you tried: did Read slots work (yes/no)?
- The authorization status lines before/after Authorize, and your iOS version.
- Any red line, especially `-21249`, and whether the device capabilities list included
  `ICCameraDeviceCanAcceptPTPCommands`.
- The stall drill summary line.
- Any compile errors you had to fix (file and message), so the next spike code is corrected.
