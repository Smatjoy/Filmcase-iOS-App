# S1 — USB spike results (ImageCaptureCore on the X-T50)

Run on 2026-11-01. iPhone 16 Pro Max, iOS 27.2 (24B119), Xcode 27.2, Fujifilm X-T50 in
**USB RAW CONV./BACKUP RESTORE**, direct USB-C cable. App: `ios/Spikes/USBSpike` (commit `99cbd47`).

**Verdict: go.** Authorization, session, slot reads, a slot-name write with read-back and restore,
and 20 back-to-back reads all work over ImageCaptureCore with no errors and no timeouts.

## Results

| Check | Result |
|---|---|
| Authorization | `controlAuthorizationStatus` and `contentsAuthorizationStatus` both `authorized` at launch. No `-21249`. |
| Discovery | X-T50 found, `transport=ICTransportTypeUSB`, capabilities include `ICCameraDeviceCanAcceptPTPCommands`. |
| Open session | OK in 9–31 ms; `didOpenSession`, `deviceDidBecomeReady`, `deviceDidBecomeReady(withCompleteContentCatalog:)` all fire. |
| Read slots C1–C7 | Correct names and film sims (see below). Each call 3–19 ms. |
| Write C7 name | `FCTEST` written and read back, then `Neon Bloom` restored and read back. Each string write ≈ 100 ms. |
| Stall drill | 20/20 OK, 0 timeouts, min/avg/max 2.6 / 5.0 / 15.6 ms, no recovery needed. |
| Close / unplug / replug | Close OK in 24 ms; device removed and re-added; reads work again after replug. |

Slots read: C1 California Hues (sim 1), C2 California Summer (19), C3 Summer Sun (20),
C4 New American Color (1), C5 Texas Sun (11), C6 Pacific Blues (17), C7 Neon Bloom (11).

## What the transport must do (input for P5)

1. **Command: full PTP command container** (12-byte header + params). ImageCaptureCore accepts it.
2. **Data out: bare payload, no container header.** ImageCaptureCore adds the header. Sending a full
   data container gets `0x2001 OK` but the camera ignores the value: every slot then reads as C1.
   This is silent, so the transport must always verify writes by reading them back.
3. **Data in: bare payload.** `in-data-has-header=false` on every read.
4. **Completion argument order is `(dataIn, responseContainer, error)`**, as in the header
   (`responseData`, `ptpResponseData`). The response container is a full 12-byte PTP response.
5. **Transaction ids are rewritten by ImageCaptureCore.** The response carries ImageCaptureCore's own
   id (for example we sent 1, the response said 6; after a replug it restarted at 1). Do not match
   response ids against ours.
6. No settle delay was needed beyond the spike's 100 ms after a cursor write; not tested shorter.

## Not covered yet

- Writing recipe properties other than the name (film sim, WB, grain…): that is the P5 manual push.
- Behaviour when the camera sleeps or the cable is pulled mid-command.
- Raw logs: the three exported logs from this run (full container, then the fixed parse, then
  bare data out) are with the owner.
