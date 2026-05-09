@preconcurrency import CoreBluetooth
import Foundation
import LibDNA

private struct UnsafeTransfer<T>: @unchecked Sendable {
    let value: T
}

private struct CLIDiscoveredDevice {
    let snapshot: CLIDeviceSnapshot
    let peripheral: CBPeripheral
}

private struct CLIDeviceSnapshot {
    let id: UUID
    let name: String
    let rssi: Int
}

@MainActor
final class CalibrationState {
    var voltage: Double?
}

@MainActor
private final class CLIBluetoothScanner: NSObject {
    private let queue = DispatchQueue(label: "ai.divehub.libdna.cli.bluetooth", qos: .userInitiated)
    private var centralManager: CBCentralManager!
    private var scanContinuation: CheckedContinuation<CLIDiscoveredDevice?, Never>?
    private var connectContinuation: CheckedContinuation<Bool, Never>?
    private var scanTimeoutTask: Task<Void, Never>?
    private var connectTimeoutTask: Task<Void, Never>?
    private var pendingConnectID: UUID?
    private var pendingConnectPeripheral: CBPeripheral?
    private var connectedPeripheralID: UUID?
    var onDisconnect: (() -> Void)?

    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: queue)
    }

    func scanFirst(timeout: Duration) async -> CLIDiscoveredDevice? {
        await withCheckedContinuation { continuation in
            stopScan()
            scanContinuation = continuation

            switch centralManager.state {
            case .poweredOn:
                startScan()
            case .unauthorized, .unsupported:
                finishScan(with: nil)
                return
            default:
                break
            }

            scanTimeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: timeout)
                self?.finishScan(with: nil)
            }
        }
    }

    func connect(_ device: CLIDiscoveredDevice, timeout: Duration) async -> Bool {
        await withCheckedContinuation { continuation in
            connectContinuation = continuation
            pendingConnectID = device.peripheral.identifier
            pendingConnectPeripheral = device.peripheral

            let cm = UnsafeTransfer(value: centralManager!)
            let p = UnsafeTransfer(value: device.peripheral)
            queue.async {
                cm.value.connect(p.value, options: nil)
            }

            connectTimeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: timeout)
                self?.finishConnect(succeeded: false, cancelPendingConnection: true)
            }
        }
    }

    func disconnect(_ peripheral: CBPeripheral) {
        let cm = UnsafeTransfer(value: centralManager!)
        let p = UnsafeTransfer(value: peripheral)
        queue.async {
            cm.value.cancelPeripheralConnection(p.value)
        }
    }

    private func startScan() {
        let cm = UnsafeTransfer(value: centralManager!)
        queue.async {
            cm.value.scanForPeripherals(
                withServices: DNASensorAdvertisement.serviceUUIDs,
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
            )
        }
    }

    private func stopScan() {
        let cm = UnsafeTransfer(value: centralManager!)
        queue.async {
            cm.value.stopScan()
        }
        scanTimeoutTask?.cancel()
        scanTimeoutTask = nil
        scanContinuation = nil
    }

    private func finishScan(with device: CLIDiscoveredDevice?) {
        let continuation = scanContinuation
        scanContinuation = nil
        scanTimeoutTask?.cancel()
        scanTimeoutTask = nil

        let cm = UnsafeTransfer(value: centralManager!)
        queue.async {
            cm.value.stopScan()
        }
        continuation?.resume(returning: device)
    }

    private func finishConnect(succeeded: Bool, cancelPendingConnection: Bool = false) {
        let continuation = connectContinuation
        let pendingPeripheral = pendingConnectPeripheral
        connectContinuation = nil
        connectTimeoutTask?.cancel()
        connectTimeoutTask = nil
        connectedPeripheralID = succeeded ? pendingConnectID : nil
        pendingConnectID = nil
        pendingConnectPeripheral = nil
        if cancelPendingConnection, let pendingPeripheral {
            disconnect(pendingPeripheral)
        }
        continuation?.resume(returning: succeeded)
    }
}

extension CLIBluetoothScanner: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let state = central.state
        Task { @MainActor in
            switch state {
            case .poweredOn:
                if self.scanContinuation != nil {
                    self.startScan()
                }
            case .unauthorized, .unsupported:
                self.finishScan(with: nil)
            default:
                break
            }
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let p = UnsafeTransfer(value: peripheral)
        let name = peripheral.name ?? "Unknown"
        let rssiValue = RSSI.intValue

        Task { @MainActor in
            let peripheral = p.value
            self.finishScan(with: CLIDiscoveredDevice(
                snapshot: CLIDeviceSnapshot(
                    id: peripheral.identifier,
                    name: name,
                    rssi: rssiValue
                ),
                peripheral: peripheral
            ))
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didConnect peripheral: CBPeripheral
    ) {
        let identifier = peripheral.identifier
        Task { @MainActor in
            guard self.pendingConnectID == identifier else { return }
            self.finishConnect(succeeded: true)
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        let identifier = peripheral.identifier
        Task { @MainActor in
            guard self.pendingConnectID == identifier else { return }
            self.finishConnect(succeeded: false)
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        let identifier = peripheral.identifier
        Task { @MainActor in
            if self.pendingConnectID == identifier {
                self.finishConnect(succeeded: false)
            }
            guard self.connectedPeripheralID == identifier else { return }
            self.connectedPeripheralID = nil
            self.onDisconnect?()
        }
    }
}

@main
@MainActor
struct DNAClient {
    static func main() async {
        print("Initializing DNA Client...")

        let scanner = CLIBluetoothScanner()
        let dnaManager = DNASensorSession()
        let calibration = CalibrationState()
        scanner.onDisconnect = {
            dnaManager.detach()
        }

        print("Starting scan for 15 seconds...")
        guard let foundDevice = await scanner.scanFirst(timeout: .seconds(15)) else {
            print("\nTimeout reached. No device found.")
            return
        }

        print("\nFound device: \(foundDevice.snapshot.name) (\(foundDevice.snapshot.id))")
        print("Connecting...")

        guard await scanner.connect(foundDevice, timeout: .seconds(10)) else {
            print("\nFailed to connect.")
            return
        }
        dnaManager.attach(to: foundDevice.peripheral)

        print("Connected!")

        // Wait for device info
        try? await Task.sleep(for: .seconds(2))

        let deviceStatus = dnaManager.deviceStatus
        let deviceInfo = deviceStatus.deviceInfo
        print("\n--- Device Info ---")
        print("Manufacturer: \(deviceInfo.manufacturerName ?? "N/A")")
        print("Model: \(deviceInfo.modelNumber ?? "N/A")")
        print("Serial: \(deviceInfo.serialNumber ?? "N/A")")
        print("Hardware: \(deviceInfo.hardwareRevision ?? "N/A")")
        print("Firmware: \(deviceInfo.firmwareRevision ?? "N/A")")
        if let batt = deviceStatus.batteryLevel {
            print("Battery: \(batt)%")
        }
        print("-------------------")

        print("\nPress [Enter] to calibrate with air (21%)...")
        print("(Showing raw voltage readings...)\n")

        // Start reading display task
        let readingTask = Task {
            for await reading in dnaManager.readings {
                if let calVoltage = calibration.voltage {
                    // Calculate O2%
                    let o2Percent = (reading.filteredVoltage / calVoltage) * 21.0
                    let output = String(
                        format: "\rO2: %.1f %% | Volt: %.2f mV | Press: %.1f hPa    ",
                        o2Percent, reading.filteredVoltage, reading.ambientPressure
                    )
                    print(output, terminator: "")
                    fflush(stdout)
                } else {
                    let output = String(
                        format: "\rVolt: %.2f mV | Press: %.1f hPa    ",
                        reading.filteredVoltage, reading.ambientPressure
                    )
                    print(output, terminator: "")
                    fflush(stdout)
                }
            }
        }

        // Wait for Enter key to calibrate
        let inputTask = Task.detached {
            while true {
                _ = Swift.readLine()

                // Get current reading for calibration
                await MainActor.run {
                    if let reading = dnaManager.latestReading {
                        calibration.voltage = reading.filteredVoltage
                        print("\n\nCalibrated at \(String(format: "%.2f", calibration.voltage!)) mV = 21.0%")
                        print("Now showing O2 percentage...\n")
                    }
                }
            }
        }

        // Main loop - check for disconnection
        while dnaManager.isAttached {
            try? await Task.sleep(for: .milliseconds(500))
        }

        print("\n\nDisconnected.")
        scanner.disconnect(foundDevice.peripheral)
        readingTask.cancel()
        inputTask.cancel()
    }
}
