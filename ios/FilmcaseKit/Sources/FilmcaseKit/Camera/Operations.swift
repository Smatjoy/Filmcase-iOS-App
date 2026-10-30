// Mirrors: src/domain/camera/operations.py and src/interfaces/static/js/camera/domain/operations.js
// (setPropWithRetry, setCursorWithRetry, verifyWrittenProperties).
//
// A transport failure is retried, a rejection is not: if the camera answered at all it
// considered the request and refused it. The two leave by different errors because the push
// sequence abandons the recipe on one and carries on past the other.
// Diagnostic event publishing (vendor/events.js) is not ported; it has no effect on behaviour.

import Foundation

/// Backoff before attempt `attempt` (1-based, > 1): `backoff * 2^(attempt-2)`.
private func backoffSeconds(_ backoff: Double, attempt: Int) -> Double {
    backoff * Double(1 << (attempt - 2))
}

/// Write one property, retrying transport failures with exponential back-off.
public func setPropWithRetry(
    _ device: some PTPDevice, code: UInt16, value: PTPPropertyValue, runtime: CameraRuntime
) async throws {
    let maxRetries = runtime.config.settings.cameraMaxRetries
    let backoff = runtime.config.settings.cameraRetryBackoffS
    let propHex = formatCode(code)
    let shownValue = formatValue(value)

    var connectionFailed = false
    var writeRejected = false
    var failedRc = 0

    var attempt = 1
    while attempt <= maxRetries {
        if attempt > 1 {
            // 0.15 s, then 0.30 s: the sequence matches the transport's 0-based exponent.
            try await runtime.sleep(backoffSeconds(backoff, attempt: attempt))
        }
        connectionFailed = false
        attempt += 1

        let rc: Int
        do {
            switch value {
            case .string(let s): rc = try await device.setString(code, s)
            case .int(let v): rc = try await device.setInt(code, v)
            }
        } catch is CameraConnectionError {
            connectionFailed = true
            continue
        }

        if rc != 0 {
            writeRejected = true
            failedRc = rc
            break
        }
        return
    }

    if connectionFailed {
        throw CameraConnectionError(
            "Camera unreachable after \(maxRetries) attempts writing \(propHex) = \(shownValue)"
        )
    }
    if writeRejected {
        throw CameraWriteError(code: code, value: value, rc: failedRc)
    }
}

/// Point the camera at a custom slot, retrying transport failures. Separate from
/// `setPropWithRetry` because the cursor is a uint16.
public func setCursorWithRetry(
    _ device: some PTPDevice, slotIndex: Int, runtime: CameraRuntime
) async throws {
    let maxRetries = runtime.config.settings.cameraMaxRetries
    let backoff = runtime.config.settings.cameraRetryBackoffS
    let cursorCode = UInt16(truncatingIfNeeded: runtime.config.encodings.propSlotCursor)
    var lastError = CameraConnectionError("no retries attempted")

    var attempt = 1
    while attempt <= maxRetries {
        if attempt > 1 {
            try await runtime.sleep(backoffSeconds(backoff, attempt: attempt))
        }
        attempt += 1
        do {
            let rc = try await device.setUInt16(cursorCode, slotIndex)
            if rc != 0 {
                // A refusal is the camera's decision and asking again will not change it.
                throw CameraWriteError(code: cursorCode, value: .int(slotIndex), rc: rc)
            }
            return
        } catch let error as CameraConnectionError {
            lastError = error
        }
    }
    throw lastError
}

/// Read back each property that reported success and check it took. Returns the codes that
/// did not match, rather than throwing, so the caller can show the whole list.
public func verifyWrittenProperties(
    _ device: some PTPDevice, written: [(code: UInt16, value: PTPPropertyValue)], runtime: CameraRuntime
) async throws -> [UInt16] {
    var mismatched: [UInt16] = []
    for (code, expected) in written {
        try await runtime.sleep(runtime.config.settings.cameraPreWriteDelayS)
        do {
            let matches: Bool
            switch expected {
            case .string(let s):
                matches = try await device.getString(code) == s
            case .int(let v):
                // Compared as sixteen bits: the camera returns a uint16 where the value
                // written was a signed int32, so -40 goes out as 0xFFFFFFD8 and comes back 0xFFD8.
                let actual = try await device.getInt(code)
                matches = (actual & 0xffff) == (v & 0xffff)
            }
            if !matches { mismatched.append(code) }
        } catch is CameraConnectionError {
            mismatched.append(code)
        }
    }
    return mismatched
}
