import CoreBluetooth
import Foundation

@MainActor
@Observable
public class SimulatedDNASensorManager: NSObject {
    // MARK: - Published Properties (matches DNASensorManager API)

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

    /// The current Bluetooth state (always poweredOn for simulation).
    public private(set) var bluetoothState: CBManagerState = .poweredOn

    // MARK: - Async Streams

    /// Async stream of readings for modern concurrency consumption.
    public var readings: AsyncStream<DNASensorReading> {
        let (stream, continuation) = AsyncStream<DNASensorReading>.makeStream()

        let id = UUID()
        readingContinuations[id] = continuation

        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in
                self?.readingContinuations.removeValue(forKey: id)
            }
        }

        return stream
    }

    // Internal continuations for the async stream
    private var readingContinuations: [UUID: AsyncStream<DNASensorReading>.Continuation] = [:]
    private var bluetoothStateContinuations: [UUID: AsyncStream<CBManagerState>.Continuation] = [:]
    private var scanContinuation: AsyncThrowingStream<DNADiscoveredDevice, Error>.Continuation?
    private var scanTimeoutTask: Task<Void, Never>?
    private var scanTask: Task<Void, Never>?
    private var activeScanID: UUID?

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

    // MARK: - Simulation Properties

    private var simulationStartTime: Date?
    private var simulationTask: Task<Void, Never>?
    private var connectionTask: Task<Void, Never>?
    private let simulatedDeviceID = UUID()
    private let scanInitialDelay: Duration
    private let scanUpdateInterval: Duration
    private let scanRSSIValues: [Int]

    // MARK: - Initialization

    public override init() {
        self.scanInitialDelay = .milliseconds(500)
        self.scanUpdateInterval = .milliseconds(750)
        self.scanRSSIValues = [-50, -65, -75, -85]
        super.init()
    }

    init(
        scanInitialDelay: Duration = .milliseconds(500),
        scanUpdateInterval: Duration = .milliseconds(750),
        scanRSSIValues: [Int] = [-50, -65, -75, -85]
    ) {
        self.scanInitialDelay = scanInitialDelay
        self.scanUpdateInterval = scanUpdateInterval
        self.scanRSSIValues = scanRSSIValues.isEmpty ? [-50] : scanRSSIValues
        super.init()
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

            guard activeScanID == scanID else { return }

            startScanningInternal(scanID: scanID)

            if timeout != .zero {
                scanTimeoutTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: timeout)
                    guard let self, self.activeScanID == scanID else { return }
                    self.stopScan()
                }
            }
        }
    }

    /// Starts scanning for the DNA sensor (simulated).
    @available(*, deprecated, message: "Use scan(timeout:)")
    public func startScanning() {
        stopScan()
        let scanID = UUID()
        activeScanID = scanID
        startScanningInternal(scanID: scanID)
    }

    /// Stops scanning.
    public func stopScan() {
        scanTask?.cancel()
        scanTask = nil
        isScanning = false
        finishScan()
    }

    /// Disconnects from the current sensor.
    public func disconnect() {
        connectionTask?.cancel()
        connectionTask = nil
        simulationTask?.cancel()
        simulationTask = nil
        isConnecting = false
        isConnected = false
        latestReading = nil
    }

    /// Connects to a specific discovered device.
    /// - Parameter deviceID: The UUID of the device to connect to.
    public func connect(to deviceID: UUID) {
        guard discoveredDevices.contains(where: { $0.id == deviceID }) else {
            return
        }

        stopScan()
        connectionTask?.cancel()
        connectionTask = nil
        isConnecting = true

        connectionTask = Task { @MainActor [weak self] in
            // Simulate connection delay
            do {
                try await Task.sleep(for: .milliseconds(300))
            } catch {
                return
            }

            guard let self, !Task.isCancelled else { return }

            self.connectionTask = nil
            self.isConnecting = false
            self.isConnected = true

            // Set mock device info
            self.deviceInfo = DNADeviceInfo(
                manufacturerName: "DiveHub",
                modelNumber: "DNA Simulator",
                serialNumber: "SIM-DNA-001",
                hardwareRevision: "1.0",
                firmwareRevision: "1.0-SIM"
            )
            self.batteryLevel = 50

            self.startSimulation()
        }
    }

    // MARK: - Simulation

    private func startScanningInternal(scanID: UUID) {
        guard !isScanning else { return }

        isScanning = true
        discoveredDevices.removeAll()

        scanTask?.cancel()
        scanTask = Task { @MainActor [weak self] in
            guard let self, self.activeScanID == scanID else { return }
            var rssiIndex = 0

            while !Task.isCancelled {
                let delay = rssiIndex == 0 ? self.scanInitialDelay : self.scanUpdateInterval
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    return
                }

                guard self.activeScanID == scanID, self.isScanning else { return }

                let rssi = self.scanRSSIValues[rssiIndex % self.scanRSSIValues.count]
                let mockDevice = DNAScanPolicy.recordDiscovery(
                    id: self.simulatedDeviceID,
                    name: "Simulated DNA Sensor",
                    rssi: rssi,
                    in: &self.discoveredDevices
                )
                self.scanContinuation?.yield(mockDevice)
                rssiIndex += 1
            }
        }
    }

    private func finishScan(throwing error: Error? = nil) {
        scanTimeoutTask?.cancel()
        scanTimeoutTask = nil
        activeScanID = nil

        guard let continuation = scanContinuation else { return }
        scanContinuation = nil

        if let error {
            continuation.finish(throwing: error)
        } else {
            continuation.finish()
        }
    }

    private func startSimulation() {
        simulationStartTime = Date()

        simulationTask = Task {
            while !Task.isCancelled {
                let reading = generateReading()
                latestReading = reading

                // Notify async stream listeners
                for continuation in readingContinuations.values {
                    continuation.yield(reading)
                }

                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    /// Generates a sine wave reading.
    /// Average: 10mV, Period: 2s, Amplitude: ±2mV
    private func generateReading() -> DNASensorReading {
        let elapsed = Date().timeIntervalSince(simulationStartTime ?? Date())
        // voltage = 10 + 2 * sin(π * t)
        // Period = 2π / π = 2 seconds
        let voltage = 10.0 + 2.0 * sin(.pi * elapsed)

        return DNASensorReading(
            rawVoltage: voltage,
            filteredVoltage: voltage,
            ambientPressure: 1013.25,  // Standard atmosphere in hPa
            timestamp: Date()
        )
    }
}

extension SimulatedDNASensorManager: BluetoothScanningManaging {}
