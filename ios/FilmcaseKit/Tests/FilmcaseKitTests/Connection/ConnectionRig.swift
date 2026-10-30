// A CameraConnection over a FakeCameraTransport, with a TestClock driving the operation
// timeout. Shared by the connection and workflow tests.

import Foundation
@testable import FilmcaseKit

struct ConnectionRig {
    static let cameraName = "X-T50"

    let device: FakePTPDevice
    let transport: FakeCameraTransport
    let clock: TestClock
    let connection: CameraConnection

    init(
        intValues: [UInt16: Int] = [:], stringValues: [UInt16: String] = [:],
        authorizationStatus: CameraAuthorizationStatus = .notDetermined,
        grantsAuthorization: Bool = true, attached: Bool = true,
        stallOnCalls: Set<Int> = [], unplugOnCall: Int? = nil, failOpens: Set<Int> = []
    ) throws {
        device = FakePTPDevice(intValues: intValues, stringValues: stringValues, cameraName: Self.cameraName)
        transport = FakeCameraTransport(
            device: device, authorizationStatus: authorizationStatus, grantsAuthorization: grantsAuthorization,
            attached: attached, stallOnCalls: stallOnCalls, unplugOnCall: unplugOnCall, failOpens: failOpens)
        clock = TestClock()
        connection = CameraConnection(
            transport: transport, config: try TestSupport.makeConfig(), clock: clock, operationTimeout: .seconds(30))
    }

    /// Connect and wait for a ready session.
    func connectAndWaitUntilReady() async {
        await connection.connect()
        await waitUntil { await connection.current == .ready(cameraName: Self.cameraName) }
    }
}

/// Poll until *condition* holds. Bounded (about 5 s) so a bug fails the test instead of hanging it.
func waitUntil(_ condition: () async -> Bool) async {
    for _ in 0..<5_000 {
        if await condition() { return }
        try? await Task.sleep(for: .milliseconds(1))
    }
}
