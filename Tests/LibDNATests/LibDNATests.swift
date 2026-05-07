import XCTest
import CoreBluetooth

@testable import LibDNA

final class LibDNATests: XCTestCase {

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

    func testScanConfigurationAllowsDuplicateAdvertisementCallbacks() {
        let allowDuplicates = DNAScanPolicy.coreBluetoothScanOptions[
            CBCentralManagerScanOptionAllowDuplicatesKey
        ] as? Bool

        XCTAssertEqual(allowDuplicates, true)
    }

    func testDiscoveryRecorderUpdatesRSSIForDuplicateDevice() {
        let id = UUID()
        var devices: [DNADiscoveredDevice] = []

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
        let manager = SimulatedDNASensorManager(
            scanInitialDelay: .zero,
            scanUpdateInterval: .milliseconds(1),
            scanRSSIValues: [-50, -58, -46]
        )

        var discoveries: [DNADiscoveredDevice] = []
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
    func testSimulatedScanDoesNotReplayStaleDevicesWhenRestarted() async throws {
        let manager = SimulatedDNASensorManager(
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
        let manager = SimulatedDNASensorManager(
            scanInitialDelay: .zero,
            scanUpdateInterval: .milliseconds(1)
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
    func testDefaultSimulatedScanRSSISpansSignalStrengthBuckets() async throws {
        let manager = SimulatedDNASensorManager(
            scanInitialDelay: .zero,
            scanUpdateInterval: .milliseconds(1)
        )

        var discoveries: [DNADiscoveredDevice] = []
        for try await discovery in manager.scan(timeout: .seconds(1)) {
            discoveries.append(discovery)
            if discoveries.count == 4 {
                manager.stopScan()
                break
            }
        }

        XCTAssertEqual(discoveries.map(\.rssi), [-50, -65, -75, -85])
    }

}

private func firstDiscovery(
    in stream: AsyncThrowingStream<DNADiscoveredDevice, Error>,
    within timeout: Duration
) async -> DNADiscoveredDevice? {
    await withTaskGroup(of: DNADiscoveredDevice?.self) { group in
        group.addTask {
            var iterator = stream.makeAsyncIterator()
            return try? await iterator.next()
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
