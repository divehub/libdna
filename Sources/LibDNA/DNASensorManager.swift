import Combine
import CoreBluetooth
import Foundation
import os

/// Helper to allow passing AnyCancellable across concurrency domains safely.
private final class SendableCancellable: @unchecked Sendable {
    private let cancellable: AnyCancellable

    init(_ cancellable: AnyCancellable) {
        self.cancellable = cancellable
    }

    func cancel() {
        cancellable.cancel()
    }
}

/// Helper to pass non-Sendable values across isolation boundaries when we know it's safe (e.g. same thread).
private struct UnsafeTransfer<T>: @unchecked Sendable {
    let value: T
}

@MainActor
public class DNASensorManager: NSObject, ObservableObject {
    // MARK: - Published Properties

    /// The current connection state of the sensor.
    @Published public private(set) var isConnected: Bool = false

    /// The current scanning state.
    @Published public private(set) var isScanning: Bool = false

    /// The latest reading received from the sensor.
    @Published public private(set) var latestReading: DNASensorReading?

    /// The device information.
    @Published public private(set) var deviceInfo: DNADeviceInfo = DNADeviceInfo()

    /// The battery level (0-100).
    @Published public private(set) var batteryLevel: Int?

    /// The list of discovered devices.
    @Published public private(set) var discoveredDevices: [DNADiscoveredDevice] = []

    // MARK: - Async Streams

    /// Async stream of readings for modern concurrency consumption.
    public var readings: AsyncStream<DNASensorReading> {
        let (stream, continuation) = AsyncStream<DNASensorReading>.makeStream()

        let cancellable =
            $latestReading
            .compactMap { $0 }
            .sink { reading in
                continuation.yield(reading)
            }

        // Wrap cancellable in a Sendable box to satisfy strict concurrency checks.
        let wrapper = SendableCancellable(cancellable)

        continuation.onTermination = { _ in
            wrapper.cancel()
        }

        return stream
    }

    // MARK: - Internal Properties
    private var centralManager: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var discoveredPeripherals: [UUID: CBPeripheral] = [:]
    private var shouldScanWhenPoweredOn = false
    private let logger = Logger(subsystem: "ai.divehub.libdna", category: "BLE")

    // MARK: - Initialization

    public override init() {
        super.init()
        // Using a serial queue can help with thread safety for CBCentralManager, but nil means Main Queue which is easier for @MainActor
        self.centralManager = CBCentralManager(delegate: self, queue: nil)
    }

    // MARK: - Public API

    /// Starts scanning for the DNA sensor.
    public func startScanning() {
        if centralManager.state == .poweredOn {
            startScanningInternal()
        } else {
            logger.info(
                "Bluetooth not ready yet (state: \(self.centralManager.state.rawValue)). Queuing scan..."
            )
            shouldScanWhenPoweredOn = true
        }
    }

    private func startScanningInternal() {
        logger.info("Starting scan for DNA Sensor service: \(DNAUUIDs.dnaAdvertisedService)")

        // Reset discovery list
        discoveredDevices.removeAll()
        discoveredPeripherals.removeAll()

        centralManager.scanForPeripherals(
            withServices: [DNAUUIDs.dnaAdvertisedService], options: nil)
        isScanning = true
        shouldScanWhenPoweredOn = false
    }

    /// Stops scanning.
    public func stopScanning() {
        centralManager.stopScan()
        isScanning = false
        shouldScanWhenPoweredOn = false
    }

    /// Disconnects from the current sensor.
    public func disconnect() {
        if let peripheral = peripheral {
            centralManager.cancelPeripheralConnection(peripheral)
        }
    }

    /// Connects to a specific discovered device.
    /// - Parameter deviceID: The UUID of the device to connect to.
    public func connect(to deviceID: UUID) {
        guard let peripheral = discoveredPeripherals[deviceID] else {
            logger.error("Device with ID \(deviceID) not found in discovered list.")
            return
        }

        logger.info("Connecting to \(peripheral.name ?? "Unknown") (\(peripheral.identifier))")

        // Stop scanning before connecting
        stopScanning()

        self.peripheral = peripheral
        self.peripheral?.delegate = self
        self.centralManager.connect(peripheral, options: nil)
    }
}

// MARK: - CBCentralManagerDelegate
extension DNASensorManager: CBCentralManagerDelegate {
    public nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let state = central.state
        Task { @MainActor in
            if state == .poweredOn {
                self.logger.info("Bluetooth powered on.")
                // We need to call startScanningInternal, but that requires access to 'self' which is isolated.
                // We are in MainActor block, so self is available.
                // We need to check shouldScanWhenPoweredOn which is on self.
                if self.shouldScanWhenPoweredOn {
                    self.startScanningInternal()
                }
            } else {
                self.logger.info("Bluetooth state changed: \(state.rawValue)")
                self.isScanning = false
                self.isConnected = false
            }
        }
    }

    public nonisolated func centralManager(
        _ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any], rssi RSSI: NSNumber
    ) {
        let p = UnsafeTransfer(value: peripheral)
        MainActor.assumeIsolated {
            let peripheral = p.value
            let name = peripheral.name ?? "Unknown"
            let rssiValue = RSSI.intValue

            self.logger.debug("Discovered peripheral: \(name)")

            // Store peripheral
            self.discoveredPeripherals[peripheral.identifier] = peripheral

            // Update published list if not already present or just update RSSI
            let device = DNADiscoveredDevice(id: peripheral.identifier, name: name, rssi: rssiValue)

            if let index = self.discoveredDevices.firstIndex(where: { $0.id == device.id }) {
                self.discoveredDevices[index] = device
            } else {
                self.discoveredDevices.append(device)
            }
        }
    }

    public nonisolated func centralManager(
        _ central: CBCentralManager, didConnect peripheral: CBPeripheral
    ) {
        let p = UnsafeTransfer(value: peripheral)
        MainActor.assumeIsolated {
            let peripheral = p.value
            self.logger.info("Connected to \(peripheral.name ?? "Unknown")")
            self.isConnected = true

            // Discover services
            peripheral.discoverServices([
                DNAUUIDs.dnaSensorService,
                DNAUUIDs.deviceInformationService,
                DNAUUIDs.batteryService,
            ])
        }
    }

    public nonisolated func centralManager(
        _ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?
    ) {
        let p = UnsafeTransfer(value: peripheral)
        // let err = error // Unused
        MainActor.assumeIsolated {
            self.logger.info("Disconnected from \(p.value.name ?? "Unknown")")
            self.isConnected = false
            self.peripheral = nil
        }
    }

    public nonisolated func centralManager(
        _ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?
    ) {
        let errDesc = error?.localizedDescription ?? "Unknown error"
        MainActor.assumeIsolated {
            self.logger.error("Failed to connect: \(errDesc)")
            self.isConnected = false
            self.peripheral = nil
        }
    }
}

// MARK: - CBPeripheralDelegate
extension DNASensorManager: CBPeripheralDelegate {
    public nonisolated func peripheral(
        _ peripheral: CBPeripheral, didDiscoverServices error: Error?
    ) {
        let p = UnsafeTransfer(value: peripheral)
        MainActor.assumeIsolated {
            let peripheral = p.value
            guard let services = peripheral.services, error == nil else { return }

            for service in services {
                if service.uuid == DNAUUIDs.dnaSensorService {
                    peripheral.discoverCharacteristics(nil, for: service)
                } else if service.uuid == DNAUUIDs.deviceInformationService {
                    peripheral.discoverCharacteristics(nil, for: service)
                } else if service.uuid == DNAUUIDs.batteryService {
                    peripheral.discoverCharacteristics([DNAUUIDs.batteryLevel], for: service)
                }
            }
        }
    }

    public nonisolated func peripheral(
        _ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?
    ) {
        let p = UnsafeTransfer(value: peripheral)
        let s = UnsafeTransfer(value: service)

        // Spawn a Task to allow sleeping between requests to avoid overwhelming the controller
        Task { @MainActor in
            let peripheral = p.value
            let service = s.value
            guard let characteristics = service.characteristics, error == nil else { return }

            for characteristic in characteristics {
                // Main Sensor Service
                if service.uuid == DNAUUIDs.dnaSensorService {
                    if characteristic.properties.contains(.notify) {
                        peripheral.setNotifyValue(true, for: characteristic)
                        try? await Task.sleep(nanoseconds: 200 * 1_000_000)
                    }
                    if characteristic.properties.contains(.read) {
                        peripheral.readValue(for: characteristic)
                        try? await Task.sleep(nanoseconds: 200 * 1_000_000)
                    }
                }

                // Device Info
                if service.uuid == DNAUUIDs.deviceInformationService {
                    if characteristic.properties.contains(.read) {
                        peripheral.readValue(for: characteristic)
                        try? await Task.sleep(nanoseconds: 200 * 1_000_000)
                    }
                }

                // Battery
                if characteristic.uuid == DNAUUIDs.batteryLevel {
                    if characteristic.properties.contains(.read) {
                        peripheral.readValue(for: characteristic)
                        try? await Task.sleep(nanoseconds: 200 * 1_000_000)
                    }
                    if characteristic.properties.contains(.notify) {
                        peripheral.setNotifyValue(true, for: characteristic)
                        try? await Task.sleep(nanoseconds: 200 * 1_000_000)
                    }
                }
            }
        }
    }

    public nonisolated func peripheral(
        _ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        let c = UnsafeTransfer(value: characteristic)
        MainActor.assumeIsolated {
            let characteristic = c.value
            guard let data = characteristic.value, error == nil else { return }

            // Helper to string
            let stringValue = String(data: data, encoding: .utf8)

            switch characteristic.uuid {
            case DNAUUIDs.manufacturerNameString:
                self.deviceInfo.manufacturerName = stringValue

            case DNAUUIDs.modelNumberString:
                self.deviceInfo.modelNumber = stringValue

            case DNAUUIDs.serialNumberString:
                self.deviceInfo.serialNumber = stringValue

            case DNAUUIDs.hardwareRevisionString:
                self.deviceInfo.hardwareRevision = stringValue

            case DNAUUIDs.firmwareRevisionString:
                self.deviceInfo.firmwareRevision = stringValue

            case DNAUUIDs.batteryLevel:
                if let level = data.first {
                    self.batteryLevel = Int(level)
                }

            default:
                // Check if it belongs to our custom service
                if characteristic.service?.uuid == DNAUUIDs.dnaSensorService {
                    if let reading = DNASensorReading(data: data) {
                        self.latestReading = reading
                    }
                }
            }
        }
    }
}
