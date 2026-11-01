// PTPChannelDevice against bytes recorded from an X-T50 over ImageCaptureCore (spike S1,
// docs/ios_usb_spike.md).

import Foundation
import Synchronization
import Testing
@testable import FilmcaseKit

/// Replays scripted exchanges and records what was sent.
private final class ScriptedChannel: PTPCommandChannel {
    struct Sent: Equatable {
        let command: [UInt8]
        let dataOut: [UInt8]?
    }

    private let script: Mutex<[Result<PTPExchange, CameraConnectionError>]>
    private let log = Mutex<[Sent]>([])

    init(_ script: [Result<PTPExchange, CameraConnectionError>]) {
        self.script = Mutex(script)
    }

    var sent: [Sent] { log.withLock { $0 } }

    func send(command: [UInt8], dataOut: [UInt8]?) async throws -> PTPExchange {
        log.withLock { $0.append(Sent(command: command, dataOut: dataOut)) }
        let next = script.withLock { $0.isEmpty ? nil : $0.removeFirst() }
        guard let next else { throw CameraConnectionError("script exhausted") }
        return try next.get()
    }
}

/// A response container as the X-T50 sent it, with ImageCaptureCore's transaction id.
private func response(_ code: UInt16, tx: UInt32 = 6) -> [UInt8] {
    packUInt32LE(12) + packUInt16LE(ptpResponse) + packUInt16LE(code) + packUInt32LE(tx)
}

private func ok(_ dataIn: [UInt8] = [], tx: UInt32 = 6) -> Result<PTPExchange, CameraConnectionError> {
    .success(PTPExchange(dataIn: dataIn, response: response(rcOk, tx: tx)))
}

@Suite("PTPChannelDevice")
struct PTPChannelDeviceTests {
    // Recorded: GetDevicePropValue(0xD18D) on C7 returned "Neon Bloom".
    static let neonBloom: [UInt8] = [
        0x0b, 0x4e, 0x00, 0x65, 0x00, 0x6f, 0x00, 0x6e, 0x00, 0x20, 0x00,
        0x42, 0x00, 0x6c, 0x00, 0x6f, 0x00, 0x6f, 0x00, 0x6d, 0x00, 0x00, 0x00,
    ]

    @Test("a cursor write sends a full command container and the bare value")
    func cursorWriteFraming() async throws {
        let channel = ScriptedChannel([ok()])
        let device = PTPChannelDevice(cameraName: "X-T50", channel: channel)

        let rc = try await device.setUInt16(0xD18C, 7)

        #expect(rc == 0)
        #expect(channel.sent == [ScriptedChannel.Sent(
            command: [0x10, 0, 0, 0, 0x01, 0x00, 0x16, 0x10, 0x01, 0, 0, 0, 0x8c, 0xd1, 0, 0],
            dataOut: [0x07, 0x00]
        )])
    }

    @Test("a read sends no data and decodes the bare payload")
    func stringRead() async throws {
        let channel = ScriptedChannel([ok(Self.neonBloom)])
        let device = PTPChannelDevice(cameraName: "X-T50", channel: channel)

        #expect(try await device.getString(0xD18D) == "Neon Bloom")
        #expect(channel.sent.first?.dataOut == nil)
        #expect(Array(channel.sent.first?.command[6...7] ?? []) == [0x15, 0x10])
    }

    @Test("the response's transaction id is ImageCaptureCore's and is not checked")
    func foreignTransactionIds() async throws {
        let channel = ScriptedChannel([ok([0x0b, 0x00], tx: 0x20), ok([0x13, 0x00], tx: 1)])
        let device = PTPChannelDevice(cameraName: "X-T50", channel: channel)

        #expect(try await device.getInt(0xD192) == 11)
        #expect(try await device.getInt(0xD192) == 19)
    }

    @Test("ints decode as JS getPropertyInt does", arguments: [
        ([0x0b, 0x00] as [UInt8], 11),
        ([0xf6, 0xff, 0xff, 0xff], -10),
        ([0xf6, 0xff, 0x00, 0x00], 65526),
        ([0x05], 5),
    ])
    func intDecoding(_ payload: [UInt8], _ expected: Int) async throws {
        let device = PTPChannelDevice(cameraName: "X-T50", channel: ScriptedChannel([ok(payload)]))
        #expect(try await device.getInt(0x1000) == expected)
    }

    @Test("ints and strings are written as JS writes them")
    func writePayloads() async throws {
        let channel = ScriptedChannel([ok(), ok()])
        let device = PTPChannelDevice(cameraName: "X-T50", channel: channel)

        _ = try await device.setInt(0xD19C, -10)
        _ = try await device.setString(0xD18D, "FCTEST")

        #expect(channel.sent.map(\.dataOut) == [
            [0xf6, 0xff, 0xff, 0xff],
            [0x07, 0x46, 0, 0x43, 0, 0x54, 0, 0x45, 0, 0x53, 0, 0x54, 0, 0, 0],
        ])
    }

    @Test("transaction ids count up from 1")
    func ourTransactionIds() async throws {
        let channel = ScriptedChannel([ok(), ok()])
        let device = PTPChannelDevice(cameraName: "X-T50", channel: channel)

        _ = try await device.setUInt16(0xD18C, 1)
        _ = try await device.setUInt16(0xD18C, 2)

        #expect(channel.sent.map { Array($0.command[8...11]) } == [[1, 0, 0, 0], [2, 0, 0, 0]])
    }

    @Test("a refused write returns the camera's response code")
    func refusedWrite() async throws {
        let channel = ScriptedChannel([.success(PTPExchange(dataIn: [], response: response(0x201C)))])
        let device = PTPChannelDevice(cameraName: "X-T50", channel: channel)

        #expect(try await device.setInt(0xD192, 99) == 0x201C)
    }

    @Test("a refused read is a connection error")
    func refusedRead() async {
        let channel = ScriptedChannel([.success(PTPExchange(dataIn: [], response: response(0x2005)))])
        let device = PTPChannelDevice(cameraName: "X-T50", channel: channel)

        await #expect(throws: CameraConnectionError.self) { try await device.getInt(0xD192) }
    }

    @Test("an OK read with no value is a connection error, not a zero")
    func emptyRead() async {
        let device = PTPChannelDevice(cameraName: "X-T50", channel: ScriptedChannel([ok([])]))

        await #expect(throws: CameraConnectionError.self) { try await device.getInt(0xD192) }
    }

    @Test("a missing or short response is a connection error")
    func shortResponse() async {
        let channel = ScriptedChannel([.success(PTPExchange(dataIn: [], response: []))])
        let device = PTPChannelDevice(cameraName: "X-T50", channel: channel)

        await #expect(throws: CameraConnectionError.self) { try await device.setUInt16(0xD18C, 1) }
    }

    @Test("a transport failure propagates")
    func transportFailure() async {
        let channel = ScriptedChannel([.failure(CameraConnectionError("unplugged"))])
        let device = PTPChannelDevice(cameraName: "X-T50", channel: channel)

        await #expect(throws: CameraConnectionError("unplugged")) { try await device.getString(0xD18D) }
    }
}
