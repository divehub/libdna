import Combine
import Foundation
import LibDNA

// Helper for synchronous input
func readLine(prompt: String) -> String? {
    print(prompt, terminator: " ")
    return Swift.readLine()
}

@main
@MainActor
class DNAClient {
    private let dnaManager = DNASensorManager()
    private var cancellables = Set<AnyCancellable>()
    private var scanningTimeout = 15.0
    private var foundDevice = false
    private var isCalibrationDone = false
    private var calibrationVoltage: Double?
    private var hasPrintedInfo = false
    private var inputSource: DispatchSourceRead?

    static func main() {
        let client = DNAClient()
        client.start()
        RunLoop.main.run()
    }

    func start() {
        print("Initializing DNA Client...")
        print("Starting scan for 15 seconds...")
        dnaManager.startScanning()

        setupTimeout()
        setupObservers()
        setupInputSource()

        // Consume readings using AsyncStream (New Swift 6 Feature)
        Task {
            for await reading in dnaManager.readings {
                displayReading(reading)
            }
        }
    }

    private func setupTimeout() {
        DispatchQueue.main.asyncAfter(deadline: .now() + scanningTimeout) { [weak self] in
            guard let self = self else { return }
            if !self.foundDevice {
                print("\nTimeout reached. No device found.")
                self.dnaManager.stopScanning()
                exit(0)
            }
        }
    }

    private func setupObservers() {
        // Observer Connection
        dnaManager.$isConnected
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] connected in
                guard let self = self else { return }
                if connected {
                    self.foundDevice = true
                    print("\nConnected!")
                } else if self.foundDevice {
                    print("\nDisconnected.")
                    exit(0)
                }
            }
            .store(in: &cancellables)

        // Observe Discovered Devices (Auto-connect logic for CLI)
        dnaManager.$discoveredDevices
            .compactMap { $0.first }
            .first()  // Take the first one and then finish (avoid repeated connects)
            .receive(on: RunLoop.main)
            .sink { [weak self] device in
                print("\nFound device: \(device.name) (\(device.id))")
                print("Auto-connecting...")
                self?.dnaManager.connect(to: device.id)
            }
            .store(in: &cancellables)

        // Observer Device Info
        dnaManager.$deviceInfo
            .receive(on: RunLoop.main)
            .filter { $0.manufacturerName != nil }
            .debounce(for: .seconds(1.0), scheduler: RunLoop.main)
            .sink { [weak self] info in
                guard let self = self else { return }
                if !self.hasPrintedInfo, let name = info.manufacturerName {
                    print("\n--- Device Info ---")
                    print("Manufacturer: \(name)")
                    print("Model: \(info.modelNumber ?? "N/A")")
                    print("Serial: \(info.serialNumber ?? "N/A")")
                    print("Hardware: \(info.hardwareRevision ?? "N/A")")
                    print("Firmware: \(info.firmwareRevision ?? "N/A")")
                    if let batt = self.dnaManager.batteryLevel {
                        print("Battery: \(batt)%")
                    }
                    print("-------------------")

                    self.hasPrintedInfo = true

                    print("\nPress [Enter] to calibrate with air (21%)...")
                }
            }
            .store(in: &cancellables)
    }

    private func displayReading(_ reading: DNASensorReading) {
        if isCalibrationDone, let calVoltage = calibrationVoltage {
            // Calculate PO2
            // Formula: (Current / Cal) * 21.0
            let po2 = (reading.filteredVoltage / calVoltage) * 21.0

            // Print with \r to overwrite line
            let output = String(
                format: "\rPO2: %.1f %% | Volt: %.2f mV | Press: %.1f hPa    ", po2,
                reading.filteredVoltage, reading.ambientPressure)
            print(output, terminator: "")
            fflush(stdout)
        } else if hasPrintedInfo {
            // Waiting for calibration - Show raw values
            let output = String(
                format: "\rVolt: %.2f mV | Press: %.1f hPa    ",
                reading.filteredVoltage, reading.ambientPressure)
            print(output, terminator: "")
            fflush(stdout)
        }
    }

    private func setupInputSource() {
        // Use DispatchSource to read from STDIN without blocking main thread
        let source = DispatchSource.makeReadSource(
            fileDescriptor: STDIN_FILENO, queue: DispatchQueue.main)

        source.setEventHandler { [weak self] in
            guard let self = self else { return }

            // Read data to clear the buffer
            let data = FileHandle.standardInput.availableData
            _ = data  // consume

            if self.hasPrintedInfo && !self.isCalibrationDone {
                if let reading = self.dnaManager.latestReading {
                    self.calibrationVoltage = reading.filteredVoltage
                    print(
                        "\nCalibrated at \(String(format: "%.2f", self.calibrationVoltage!)) mV = 21.0%"
                    )
                    self.isCalibrationDone = true
                } else {
                    print("Waiting for reading to calibrate...")
                }
            }
        }

        source.resume()
        self.inputSource = source
    }
}
