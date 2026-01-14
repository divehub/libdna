@preconcurrency import CoreBluetooth
import Foundation
import os

/// Helper to pass non-Sendable values across isolation boundaries when we know it's safe (e.g. same thread).
private struct UnsafeTransfer<T>: @unchecked Sendable {
    let value: T
}

public enum DNAScanError: Error {
    case unauthorized
    case unsupported
}

@MainActor
@Observable
public class DNASensorManager: NSObject {
    // MARK: - Published Properties

    /// The current connection state of the sensor.
    public private(set) var isConnected: Bool = false

    /// The current scanning state.
    public private(set) var isScanning: Bool = false

    /// The connection in progress state.
    public private(set) var isConnecting: Bool = false

    /// The latest reading received from the sensor.
    public private(set) var latestReading: DNASensorReading?

    /// The device information.
    public private(set) var deviceInfo: DNADeviceInfo = DNADeviceInfo()

    /// The battery level (0-100).
    public private(set) var batteryLevel: Int?

    /// The list of discovered devices.
    public private(set) var discoveredDevices: [DNADiscoveredDevice] = []

    /// The current Bluetooth state.
    public private(set) var bluetoothState: CBManagerState = .unknown

    // MARK: - Async Streams

    /// Async stream of readings for modern concurrency consumption.
    public var readings: AsyncStream<DNASensorReading> {
        let (stream, continuation) = AsyncStream<DNASensorReading>.makeStream()

        // Simple manual observation loop since we removed Combine
        // Note: For a strictly correct AsyncStream from @Observable, we'd standardly use
        // an AsyncSequence of the property. For now, we'll keep this simple or relying on consumers observing the property directly.
        // However, to maintain API compatibility with existing AsyncStream consumers, we need to bridge it.
        // Since @Observable doesn't easily emit values to a stream without a task watching it:
        // We will add a private listener mechanism or update the continuation in the didUpdateValue logic.

        // BETTER APPROACH: Add a private publisher or continuation handling just for this stream
        // But since we are overhauling, let's keep it clean.
        // Let's attach this continuation to a list of active listeners.

        let id = UUID()
        readingContinuations[id] = continuation

        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in
                self?.readingContinuations.removeValue(forKey: id)
            }
        }

        return stream
    }

    /// Async stream of Bluetooth state updates.
    public var bluetoothStateUpdates: AsyncStream<CBManagerState> {
        let (stream, continuation) = AsyncStream<CBManagerState>.makeStream()

        let id = UUID()
        bluetoothStateContinuations[id] = continuation
        continuation.yield(bluetoothState)

        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in
                self?.bluetoothStateContinuations.removeValue(forKey: id)
            }
        }

        return stream
    }

    // Internal continuations for the async stream
    private var readingContinuations: [UUID: AsyncStream<DNASensorReading>.Continuation] = [:]
    private var bluetoothStateContinuations: [UUID: AsyncStream<CBManagerState>.Continuation] = [:]
    private var scanContinuation: AsyncThrowingStream<DNADiscoveredDevice, Error>.Continuation?
    private var scanTimeoutTask: Task<Void, Never>?
    private var activeScanID: UUID?

    // MARK: - Internal Properties
    private var centralManager: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var discoveredPeripherals: [UUID: CBPeripheral] = [:]
    private var shouldScanWhenPoweredOn = false
    private let logger = Logger(subsystem: "ai.divehub.libdna", category: "BLE")

    // Dedicated serial queue for Bluetooth operations to prevent Main Thread blocking
    private let bleQueue = DispatchQueue(label: "ai.divehub.libdna.ble", qos: .userInitiated)

    // MARK: - Initialization

    public override init() {
        super.init()
        // Initialize CBCentralManager on a background queue
        self.centralManager = CBCentralManager(delegate: self, queue: bleQueue)
    }

    // MARK: - Public API

    /// Scans for DNA sensors and yields discoveries as they arrive.
    public func scan(timeout: Duration = .seconds(10))
        -> AsyncThrowingStream<DNADiscoveredDevice, Error>
    {
        AsyncThrowingStream { continuation in
            stopScan()

            let scanID = UUID()
            activeScanID = scanID
            scanContinuation = continuation

            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.activeScanID == scanID else { return }
                    self.stopScan()
                }
            }

            for device in discoveredDevices {
                continuation.yield(device)
            }

            guard activeScanID == scanID else { return }

            let state = centralManager.state
            switch state {
            case .poweredOn:
                startScanningInternal()
            case .unauthorized:
                finishScan(throwing: DNAScanError.unauthorized)
                return
            case .unsupported:
                finishScan(throwing: DNAScanError.unsupported)
                return
            default:
                logger.info(
                    "Bluetooth not ready yet (state: \(state.rawValue)). Queuing scan...")
                shouldScanWhenPoweredOn = true
            }

            if timeout != .zero {
                scanTimeoutTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: timeout)
                    guard let self, self.activeScanID == scanID else { return }
                    self.stopScan()
                }
            }
        }
    }

    /// Starts scanning for the DNA sensor.
    @available(*, deprecated, message: "Use scan(timeout:)")
    public func startScanning() {
        stopScan()

        let state = centralManager.state
        if state == .poweredOn {
            startScanningInternal()
        } else {
            logger.info("Bluetooth not ready yet (state: \(state.rawValue)). Queuing scan...")
            shouldScanWhenPoweredOn = true
        }
    }

    private func startScanningInternal() {
        logger.info("Starting scan for DNA Sensor service")

        // Reset discovery list
        discoveredDevices.removeAll()
        discoveredPeripherals.removeAll()

        // Perform scan on the BLE queue
        let cm = UnsafeTransfer(value: centralManager!)
        bleQueue.async {
            cm.value.scanForPeripherals(
                withServices: [DNAUUIDs.dnaAdvertisedService, DNAUUIDs.dnaSensorService],
                options: nil)
        }

        isScanning = true
        shouldScanWhenPoweredOn = false
    }

    /// Stops scanning.
    public func stopScan() {
        let cm = UnsafeTransfer(value: centralManager!)
        bleQueue.async {
            cm.value.stopScan()
        }
        isScanning = false
        finishScan()
    }

    private func finishScan(throwing error: Error? = nil) {
        scanTimeoutTask?.cancel()
        scanTimeoutTask = nil
        shouldScanWhenPoweredOn = false
        activeScanID = nil

        guard let continuation = scanContinuation else { return }
        scanContinuation = nil

        if let error {
            continuation.finish(throwing: error)
        } else {
            continuation.finish()
        }
    }

    /// Disconnects from the current sensor.
    public func disconnect() {
        if let peripheral = peripheral {
            let p = UnsafeTransfer(value: peripheral)
            let cm = UnsafeTransfer(value: centralManager!)
            bleQueue.async {
                cm.value.cancelPeripheralConnection(p.value)
            }
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
        stopScan()

        isConnecting = true
        self.peripheral = peripheral
        self.peripheral?.delegate = self

        let p = UnsafeTransfer(value: peripheral)
        let cm = UnsafeTransfer(value: centralManager!)

        bleQueue.async {
            cm.value.connect(p.value, options: nil)
        }
    }
}

extension DNASensorManager: BluetoothScanningManaging {}

// MARK: - CBCentralManagerDelegate
extension DNASensorManager: CBCentralManagerDelegate {
    public nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let state = central.state
        Task { @MainActor in
            self.bluetoothState = state
            for continuation in self.bluetoothStateContinuations.values {
                continuation.yield(state)
            }

            switch state {
            case .poweredOn:
                self.logger.info("Bluetooth powered on.")
                if self.shouldScanWhenPoweredOn {
                    self.startScanningInternal()
                }
            case .unauthorized:
                self.logger.info("Bluetooth unauthorized.")
                self.isScanning = false
                self.finishScan(throwing: DNAScanError.unauthorized)
            case .unsupported:
                self.logger.info("Bluetooth unsupported.")
                self.isScanning = false
                self.finishScan(throwing: DNAScanError.unsupported)
            default:
                self.logger.info("Bluetooth state changed: \(state.rawValue)")
                // Only stop scanning if Bluetooth is not powered on
                // Don't disconnect - let the peripheral delegate handle actual disconnections
                self.isScanning = false
            }
        }
    }

    public nonisolated func centralManager(
        _ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any], rssi RSSI: NSNumber
    ) {
        // Capture data to pass to MainActor
        let identifier = peripheral.identifier

        // Wrap peripheral in UnsafeTransfer to pass to MainActor
        let p = UnsafeTransfer(value: peripheral)
        let name = peripheral.name ?? "Unknown"
        let rssiValue = RSSI.intValue

        Task { @MainActor in
            let peripheral = p.value

            // Store peripheral (must keep reference)
            self.discoveredPeripherals[identifier] = peripheral

            // Update visible list
            let device = DNADiscoveredDevice(id: identifier, name: name, rssi: rssiValue)

            if let index = self.discoveredDevices.firstIndex(where: { $0.id == device.id }) {
                self.discoveredDevices[index] = device
            } else {
                self.logger.debug("Discovered peripheral: \(name)")
                self.discoveredDevices.append(device)
            }

            self.scanContinuation?.yield(device)
        }
    }

    public nonisolated func centralManager(
        _ central: CBCentralManager, didConnect peripheral: CBPeripheral
    ) {
        let p = UnsafeTransfer(value: peripheral)
        Task { @MainActor in
            let peripheral = p.value
            self.logger.info("Connected to \(peripheral.name ?? "Unknown")")
            self.isConnected = true
            self.isConnecting = false

            // Discover services on background queue
            let p2 = UnsafeTransfer(value: peripheral)
            self.bleQueue.async {
                p2.value.discoverServices([
                    DNAUUIDs.dnaSensorService,
                    DNAUUIDs.deviceInformationService,
                    DNAUUIDs.batteryService,
                ])
            }
        }
    }

    public nonisolated func centralManager(
        _ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?
    ) {
        let p = UnsafeTransfer(value: peripheral)
        Task { @MainActor in
            self.logger.info("Disconnected from \(p.value.name ?? "Unknown")")
            self.isConnected = false
            self.peripheral = nil
        }
    }

    public nonisolated func centralManager(
        _ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?
    ) {
        let errDesc = error?.localizedDescription ?? "Unknown error"
        Task { @MainActor in
            self.logger.error("Failed to connect: \(errDesc)")
            self.isConnected = false
            self.isConnecting = false
            self.peripheral = nil
        }
    }
}

// MARK: - CBPeripheralDelegate
extension DNASensorManager: CBPeripheralDelegate {
    public nonisolated func peripheral(
        _ peripheral: CBPeripheral, didDiscoverServices error: Error?
    ) {
        guard let services = peripheral.services, error == nil else { return }

        // Process services
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
        guard let data = characteristic.value, error == nil else { return }

        let uuid = characteristic.uuid
        let stringValue = String(data: data, encoding: .utf8)

        // Needed for service check inside Task
        let isDNAService = characteristic.service?.uuid == DNAUUIDs.dnaSensorService

        // Use UnsafeTransfer for UUID to switch on it, or just use unsafe transfer for the char if needed.
        // Or simpler: Just dispatch. CBUUID is technically not Sendable but immutable.
        // Let's use UnsafeTransfer for the UUID to satisfy compiler.
        let u = UnsafeTransfer(value: uuid)

        Task { @MainActor in
            switch u.value {
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
                if isDNAService {
                    if let reading = DNASensorReading(data: data) {
                        self.latestReading = reading
                        // Notify streams
                        for continuation in self.readingContinuations.values {
                            continuation.yield(reading)
                        }
                    }
                }
            }
        }
    }
}
