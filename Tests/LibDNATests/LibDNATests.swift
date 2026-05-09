import XCTest
import CoreBluetooth

@testable import LibDNA

final class LibDNATests: XCTestCase {

    @MainActor
    func testDNASensorSessionExposesPeripheralSessionAPI() {
        let manager = DNASensorSession()

        XCTAssertFalse(manager.isAttached)
        XCTAssertNil(manager.latestReading)
        XCTAssertEqual(manager.deviceStatus, DNADeviceStatus(
            deviceInfo: DNADeviceInfo(),
            batteryLevel: nil
        ))
    }

    @MainActor
    func testDNASensorSessionDisconnectClearsCachedMetadata() async {
        let manager = DNASensorSession()
        manager.applyCharacteristicValue(
            uuid: DNAUUIDs.manufacturerNameString,
            data: Data("DiveHub".utf8),
            isDNAService: false,
            isCurrentPeripheral: true,
            isCurrentSessionToken: true,
            isExpectedUpdate: true
        )
        manager.applyCharacteristicValue(
            uuid: DNAUUIDs.modelNumberString,
            data: Data("DNA".utf8),
            isDNAService: false,
            isCurrentPeripheral: true,
            isCurrentSessionToken: true,
            isExpectedUpdate: true
        )
        manager.applyCharacteristicValue(
            uuid: DNAUUIDs.serialNumberString,
            data: Data("SN-1".utf8),
            isDNAService: false,
            isCurrentPeripheral: true,
            isCurrentSessionToken: true,
            isExpectedUpdate: true
        )
        manager.applyCharacteristicValue(
            uuid: DNAUUIDs.hardwareRevisionString,
            data: Data("1.0".utf8),
            isDNAService: false,
            isCurrentPeripheral: true,
            isCurrentSessionToken: true,
            isExpectedUpdate: true
        )
        manager.applyCharacteristicValue(
            uuid: DNAUUIDs.firmwareRevisionString,
            data: Data("2.0".utf8),
            isDNAService: false,
            isCurrentPeripheral: true,
            isCurrentSessionToken: true,
            isExpectedUpdate: true
        )
        manager.applyCharacteristicValue(
            uuid: DNAUUIDs.batteryLevel,
            data: Data([88]),
            isDNAService: false,
            isCurrentPeripheral: true,
            isCurrentSessionToken: true,
            isExpectedUpdate: true
        )
        let recorder = ManagerEventRecorder(manager.events)

        manager.detach()

        let status = await recorder.nextEvent { event in
            event == DNASensorEvent.deviceStatusChanged(DNADeviceStatus(
                deviceInfo: DNADeviceInfo(),
                batteryLevel: nil
            ))
        }

        XCTAssertEqual(manager.deviceStatus, DNADeviceStatus(
            deviceInfo: DNADeviceInfo(),
            batteryLevel: nil
        ))
        XCTAssertNotNil(status)
    }

    @MainActor
    func testDNASensorSessionIgnoresStaleCharacteristicUpdatesAfterDetach() {
        let manager = DNASensorSession()

        manager.applyCharacteristicValue(
            uuid: DNAUUIDs.modelNumberString,
            data: Data("STALE-DNA".utf8),
            isDNAService: false,
            isCurrentPeripheral: false,
            isCurrentSessionToken: true,
            isExpectedUpdate: true
        )

        XCTAssertEqual(manager.deviceStatus.deviceInfo, DNADeviceInfo())
        XCTAssertNil(manager.latestReading)
    }

    @MainActor
    func testDNASensorSessionIgnoresStaleCharacteristicUpdatesFromOlderSession() {
        let manager = DNASensorSession()

        manager.applyCharacteristicValue(
            uuid: DNAUUIDs.modelNumberString,
            data: Data("STALE-DNA".utf8),
            isDNAService: false,
            isCurrentPeripheral: true,
            isCurrentSessionToken: false,
            isExpectedUpdate: true
        )

        XCTAssertEqual(manager.deviceStatus.deviceInfo, DNADeviceInfo())
        XCTAssertNil(manager.latestReading)
    }

    @MainActor
    func testDNASensorSessionIgnoresUnexpectedCharacteristicUpdatesInCurrentSession() {
        let manager = DNASensorSession()

        manager.applyCharacteristicValue(
            uuid: DNAUUIDs.modelNumberString,
            data: Data("STALE-DNA".utf8),
            isDNAService: false,
            isCurrentPeripheral: true,
            isCurrentSessionToken: true,
            isExpectedUpdate: false
        )

        XCTAssertEqual(manager.deviceStatus.deviceInfo, DNADeviceInfo())
        XCTAssertNil(manager.latestReading)
    }

    func testDataParsing() {
        // Example Data:
        // Offset 0: 04 01 (Header) -> 0x0104 = 260
        // Offset 2: 12 00 (Raw Voltage 18) -> 0.18 mV
        // Offset 4: 34 00 (Filtered Voltage 52) -> 0.52 mV
        // Offset 6: 64 27 (Pressure 10084) -> 1008.4 hPa

        // 0x2764 = 10084 (Little Endian for 64 27)

        let header: [UInt8] = [0x04, 0x01]
        let raw: [UInt8] = [0x12, 0x00]  // 18 -> 0.18 mV
        let filtered: [UInt8] = [0x34, 0x00]  // 52 -> 0.52 mV
        let pressure: [UInt8] = [0x64, 0x27]  // 10084 -> 1008.4 hPa

        let bytes = header + raw + filtered + pressure
        let data = Data(bytes)

        guard let reading = DNASensorReading(data: data) else {
            XCTFail("Failed to parse valid data")
            return
        }

        XCTAssertEqual(reading.rawVoltage, 0.18, accuracy: 0.001)
        XCTAssertEqual(reading.filteredVoltage, 0.52, accuracy: 0.001)
        XCTAssertEqual(reading.ambientPressure, 1008.4, accuracy: 0.1)
    }

    func testInvalidData() {
        let shortData = Data([0x00, 0x01, 0x02])
        XCTAssertNil(DNASensorReading(data: shortData))
    }

    func testDiscoveryRecorderUpdatesRSSIForDuplicateDevice() {
        let id = UUID()
        var devices: [DNASimulatedDevice] = []

        _ = DNAScanPolicy.recordDiscovery(
            id: id,
            name: "DNA",
            rssi: -50,
            in: &devices
        )
        let updatedDevice = DNAScanPolicy.recordDiscovery(
            id: id,
            name: "DNA",
            rssi: -64,
            in: &devices
        )

        XCTAssertEqual(updatedDevice.rssi, -64)
        XCTAssertEqual(devices, [updatedDevice])
    }

    @MainActor
    func testSimulatedScanYieldsRepeatedSameDeviceDiscoveriesWithChangingRSSI() async throws {
        let manager = DNASensorSimulator(
            scanInitialDelay: .zero,
            scanUpdateInterval: .milliseconds(1),
            scanRSSIValues: [-50, -58, -46],
            includeFlakyDevice: false
        )

        var discoveries: [DNASimulatedDevice] = []
        for try await discovery in manager.scan(timeout: .seconds(1)) {
            discoveries.append(discovery)
            if discoveries.count == 3 {
                manager.stopScan()
                break
            }
        }

        XCTAssertEqual(discoveries.map(\.rssi), [-50, -58, -46])
        XCTAssertEqual(Set(discoveries.map(\.id)).count, 1)
        XCTAssertEqual(manager.discoveredDevices.count, 1)
        XCTAssertEqual(manager.discoveredDevices.first?.rssi, -46)
    }

    @MainActor
    func testSimulatorEventsReportAttachmentAndDeviceStatus() async throws {
        let manager = DNASensorSimulator(
            scanInitialDelay: .zero,
            scanUpdateInterval: .milliseconds(1),
            includeFlakyDevice: false
        )
        let recorder = ManagerEventRecorder(manager.events)

        guard let device = await firstDiscovery(
            in: manager.scan(timeout: .seconds(1)),
            within: .seconds(1)
        ) else {
            XCTFail("Expected simulated discovery")
            return
        }

        manager.connect(to: device.id)

        let connected = await recorder.nextEvent { event in
            event == .attachmentChanged(isAttached: true)
        }
        let status = await recorder.nextEvent { event in
            if case .deviceStatusChanged = event {
                return true
            }
            return false
        }

        XCTAssertNotNil(connected)
        guard case let .deviceStatusChanged(snapshot) = status else {
            XCTFail("Expected device status event")
            return
        }
        XCTAssertEqual(snapshot.deviceInfo.manufacturerName, "DiveHub")
        XCTAssertEqual(snapshot.deviceInfo.modelNumber, "DNA Simulator")
        XCTAssertEqual(snapshot.deviceInfo.serialNumber, "SIM-DNA-001")
        XCTAssertEqual(snapshot.batteryLevel, 50)
    }

    @MainActor
    func testSimulatedScanDoesNotReplayStaleDevicesWhenRestarted() async throws {
        let manager = DNASensorSimulator(
            scanInitialDelay: .milliseconds(50),
            scanUpdateInterval: .milliseconds(50),
            scanRSSIValues: [-50]
        )

        let first = await firstDiscovery(
            in: manager.scan(timeout: .seconds(1)),
            within: .seconds(1)
        )
        XCTAssertNotNil(first)
        manager.stopScan()

        let staleDiscovery = await firstDiscovery(
            in: manager.scan(timeout: .seconds(1)),
            within: .milliseconds(10)
        )
        XCTAssertNil(staleDiscovery)
        manager.stopScan()
    }

    @MainActor
    func testDisconnectCancelsPendingSimulatedConnect() async throws {
        let manager = DNASensorSimulator(
            scanInitialDelay: .zero,
            scanUpdateInterval: .milliseconds(1),
            includeFlakyDevice: false
        )

        guard let device = await firstDiscovery(
            in: manager.scan(timeout: .seconds(1)),
            within: .seconds(1)
        ) else {
            XCTFail("Expected simulated discovery")
            return
        }

        manager.connect(to: device.id)
        XCTAssertTrue(manager.isConnecting)

        manager.disconnect()
        XCTAssertFalse(manager.isConnecting)

        try await Task.sleep(for: .milliseconds(350))
        XCTAssertFalse(manager.isConnected)
        XCTAssertNil(manager.latestReading)
    }

    @MainActor
    func testSimulatorDisconnectClearsCachedDeviceStatus() async throws {
        let manager = DNASensorSimulator(
            scanInitialDelay: .zero,
            scanUpdateInterval: .milliseconds(1),
            includeFlakyDevice: false
        )
        let recorder = ManagerEventRecorder(manager.events)

        guard let device = await firstDiscovery(
            in: manager.scan(timeout: .seconds(1)),
            within: .seconds(1)
        ) else {
            XCTFail("Expected simulated discovery")
            return
        }

        manager.connect(to: device.id)
        let status = await recorder.nextEvent { event in
            if case .deviceStatusChanged = event {
                return true
            }
            return false
        }
        XCTAssertNotNil(status)

        manager.disconnect()

        let cleared = await recorder.nextEvent { event in
            event == .deviceStatusChanged(DNADeviceStatus(
                deviceInfo: DNADeviceInfo(),
                batteryLevel: nil
            ))
        }

        XCTAssertEqual(manager.deviceStatus, DNADeviceStatus(
            deviceInfo: DNADeviceInfo(),
            batteryLevel: nil
        ))
        XCTAssertNotNil(cleared)
    }

    @MainActor
    func testDefaultSimulatedScanRSSISpansSignalStrengthBuckets() async throws {
        let manager = DNASensorSimulator(
            scanInitialDelay: .zero,
            scanUpdateInterval: .milliseconds(1),
            includeFlakyDevice: false
        )

        var discoveries: [DNASimulatedDevice] = []
        for try await discovery in manager.scan(timeout: .seconds(1)) {
            discoveries.append(discovery)
            if discoveries.count == 4 {
                manager.stopScan()
                break
            }
        }

        XCTAssertEqual(discoveries.map(\.rssi), [-50, -65, -75, -85])
    }

    @MainActor
    func testDefaultSimulatedScanIncludesFlakyDevice() async throws {
        let manager = DNASensorSimulator(
            scanInitialDelay: .zero,
            scanUpdateInterval: .milliseconds(1)
        )

        var discoveries: [DNASimulatedDevice] = []
        for try await discovery in manager.scan(timeout: .seconds(1)) {
            discoveries.append(discovery)
            if discoveries.contains(where: { $0.name == "Flaky Simulated DNA Sensor" }) {
                manager.stopScan()
                break
            }
        }

        XCTAssertTrue(discoveries.contains(where: { $0.name == "Simulated DNA Sensor" }))
        XCTAssertTrue(discoveries.contains(where: { $0.name == "Flaky Simulated DNA Sensor" }))
    }

    @MainActor
    func testFlakySimulatedDeviceDisconnectsAfterConfiguredInterval() async throws {
        let manager = DNASensorSimulator(
            scanInitialDelay: .zero,
            scanUpdateInterval: .milliseconds(1),
            flakyDisconnectInterval: .milliseconds(20)
        )
        let recorder = ManagerEventRecorder(manager.events)

        let flakyDevice = await firstDiscovery(
            in: manager.scan(timeout: .seconds(1)),
            within: .seconds(1),
            where: { $0.name == "Flaky Simulated DNA Sensor" }
        )
        guard let flakyDevice else {
            XCTFail("Expected flaky simulated discovery")
            return
        }

        manager.connect(to: flakyDevice.id)
        let didConnect = await waitUntil { manager.isConnected }
        XCTAssertTrue(didConnect)

        try await Task.sleep(for: .milliseconds(50))

        XCTAssertFalse(manager.isConnected)
        XCTAssertFalse(manager.isConnecting)
        XCTAssertNil(manager.latestReading)

        let disconnected = await recorder.nextEvent { event in
            event == .attachmentChanged(isAttached: false)
        }
        XCTAssertNotNil(disconnected)
    }

}

@MainActor
private final class ManagerEventRecorder {
    private var events: [DNASensorEvent] = []
    private var task: Task<Void, Never>?

    init(_ stream: AsyncStream<DNASensorEvent>) {
        task = Task { @MainActor in
            for await event in stream {
                events.append(event)
            }
        }
    }

    deinit {
        task?.cancel()
    }

    func nextEvent(
        _ predicate: (DNASensorEvent) -> Bool,
        attempts: Int = 100,
        interval: Duration = .milliseconds(10)
    ) async -> DNASensorEvent? {
        for _ in 0..<attempts {
            if let index = events.firstIndex(where: predicate) {
                return events.remove(at: index)
            }
            try? await Task.sleep(for: interval)
        }
        return nil
    }
}

private func firstDiscovery(
    in stream: AsyncThrowingStream<DNASimulatedDevice, Error>,
    within timeout: Duration,
    where predicate: @escaping @Sendable (DNASimulatedDevice) -> Bool = { _ in true }
) async -> DNASimulatedDevice? {
    await withTaskGroup(of: DNASimulatedDevice?.self) { group in
        group.addTask {
            var iterator = stream.makeAsyncIterator()
            while let discovery = try? await iterator.next() {
                if predicate(discovery) {
                    return discovery
                }
            }
            return nil
        }
        group.addTask {
            try? await Task.sleep(for: timeout)
            return nil
        }

        let result = await group.next() ?? nil
        group.cancelAll()
        return result
    }
}

private func waitUntil(
    _ condition: @escaping @MainActor () -> Bool,
    attempts: Int = 100,
    interval: Duration = .milliseconds(10)
) async -> Bool {
    for _ in 0..<attempts {
        if await condition() {
            return true
        }
        try? await Task.sleep(for: interval)
    }
    return false
}
