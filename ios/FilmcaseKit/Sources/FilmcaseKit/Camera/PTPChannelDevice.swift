// The PTPDevice used on iOS: property reads and writes framed for ImageCaptureCore's
// requestSendPTPCommand, as measured on an X-T50 in spike S1 (docs/ios_usb_spike.md):
//   - the command goes out as a full PTP command container;
//   - data out is the bare payload (ImageCaptureCore adds the data container header; a full
//     container is acknowledged with 0x2001 and silently ignored);
//   - data in arrives as the bare payload;
//   - the response is a full PTP response container whose transaction id is
//     ImageCaptureCore's own, so it is never matched against ours.
// The app's adapter only moves bytes (PTPCommandChannel); every decision about them is here.

import Foundation

/// What one PTP transaction returned.
public struct PTPExchange: Equatable, Sendable {
    /// The data-in phase, without a container header (empty when there was none).
    public let dataIn: [UInt8]
    /// The PTP response container.
    public let response: [UInt8]

    public init(dataIn: [UInt8], response: [UInt8]) {
        self.dataIn = dataIn
        self.response = response
    }
}

/// Sends one PTP transaction. Implemented over ImageCaptureCore by the app.
public protocol PTPCommandChannel: Sendable {
    /// - Parameters:
    ///   - command: A full PTP command container.
    ///   - dataOut: The data-out payload without a container header, or nil for none.
    /// - Throws: `CameraConnectionError` when the transaction fails in transport.
    func send(command: [UInt8], dataOut: [UInt8]?) async throws -> PTPExchange
}

/// A `PTPDevice` over a `PTPCommandChannel`. An actor, so one transaction runs at a time.
public actor PTPChannelDevice: PTPDevice {
    public nonisolated let cameraName: String
    private let channel: any PTPCommandChannel
    private var nextTx: UInt32 = 1

    public init(cameraName: String, channel: any PTPCommandChannel) {
        self.cameraName = cameraName
        self.channel = channel
    }

    /// JS `getPropertyInt`: int32 when four bytes came back, uint16 for two, a byte for one.
    public func getInt(_ code: UInt16) async throws -> Int {
        let data = try await getProp(code)
        if data.count >= 4 { return Int(try readInt32LE(data, 0)) }
        if data.count >= 2 { return Int(try readUInt16LE(data, 0)) }
        return Int(data[0])
    }

    public func getString(_ code: UInt16) async throws -> String {
        try decodePtpString(try await getProp(code), 0).value
    }

    public func setInt(_ code: UInt16, _ value: Int) async throws -> Int {
        try await setProp(code, packInt32LE(Int32(truncatingIfNeeded: value)))
    }

    public func setUInt16(_ code: UInt16, _ value: Int) async throws -> Int {
        try await setProp(code, packUInt16LE(UInt16(truncatingIfNeeded: value)))
    }

    public func setString(_ code: UInt16, _ value: String) async throws -> Int {
        try await setProp(code, try encodePtpString(value))
    }

    /// Read a property value. A refusal, or an OK with no value, is a `CameraConnectionError`
    /// (JS `_getPropWithRetry`): an empty payload would otherwise decode to a plausible 0.
    private func getProp(_ code: UInt16) async throws -> [UInt8] {
        let exchange = try await transact(ocGetDevicePropValue, code, dataOut: nil)
        let rc = try responseCode(exchange)
        guard rc == rcOk else {
            throw CameraConnectionError("GetDevicePropValue(\(formatCode(code))) failed: rc=\(formatRc(Int(rc)))")
        }
        guard !exchange.dataIn.isEmpty else {
            throw CameraConnectionError("Camera answered \(formatCode(code)) with no value (rc=\(formatRc(Int(rc))))")
        }
        return exchange.dataIn
    }

    /// Write a property. Returns 0 on OK, otherwise the camera's response code.
    private func setProp(_ code: UInt16, _ payload: [UInt8]) async throws -> Int {
        let rc = try responseCode(try await transact(ocSetDevicePropValue, code, dataOut: payload))
        return rc == rcOk ? 0 : Int(rc)
    }

    private func transact(_ op: UInt16, _ code: UInt16, dataOut: [UInt8]?) async throws -> PTPExchange {
        let tx = nextTx
        nextTx &+= 1
        let command = commandPacket(code: op, txId: tx, params: [UInt32(code)])
        return try await channel.send(command: command, dataOut: dataOut)
    }

    private func responseCode(_ exchange: PTPExchange) throws -> UInt16 {
        do {
            return try parseResponse(exchange.response).code
        } catch {
            throw CameraConnectionError("Camera sent no usable response (\(exchange.response.count) bytes)")
        }
    }
}
