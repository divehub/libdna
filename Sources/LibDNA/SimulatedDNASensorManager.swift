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

    // MARK: - Simulation Properties

    private var simulationStartTime: Date?
    private var simulationTask: Task<Void, Never>?
    private let simulatedDeviceID = UUID()

    // MARK: - Initialization

    public override init() {
        super.init()
    }

    // MARK: - Public API

    /// Starts scanning for the DNA sensor (simulated).
    public func startScanning() {
        guard !isScanning else { return }

        isScanning = true
        discoveredDevices.removeAll()

        // Simulate discovery delay
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard isScanning else { return }

            let mockDevice = DNADiscoveredDevice(
                id: simulatedDeviceID,
                name: "Simulated DNA Sensor",
                rssi: -50
            )
            discoveredDevices = [mockDevice]
        }
    }

    /// Stops scanning.
    public func stopScanning() {
        isScanning = false
    }

    /// Disconnects from the current sensor.
    public func disconnect() {
        simulationTask?.cancel()
        simulationTask = nil
        isConnected = false
        latestReading = nil
    }

    /// Connects to a specific discovered device.
    /// - Parameter deviceID: The UUID of the device to connect to.
    public func connect(to deviceID: UUID) {
        guard discoveredDevices.contains(where: { $0.id == deviceID }) else {
            return
        }

        stopScanning()
        isConnecting = true

        Task {
            // Simulate connection delay
            try? await Task.sleep(for: .milliseconds(300))

            isConnecting = false
            isConnected = true

            // Set mock device info
            deviceInfo = DNADeviceInfo(
                manufacturerName: "DiveHub",
                modelNumber: "DNA Simulator",
                serialNumber: "SIM-DNA-001",
                hardwareRevision: "1.0",
                firmwareRevision: "1.0-SIM"
            )
            batteryLevel = 50

            startSimulation()
        }
    }

    // MARK: - Simulation

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
