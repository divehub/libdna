import Foundation
import LibDNA

@MainActor
final class CalibrationState {
    var voltage: Double?
}

@main
@MainActor
struct DNAClient {
    static func main() async {
        print("Initializing DNA Client...")

        let dnaManager = DNASensorManager()
        let calibration = CalibrationState()

        print("Starting scan for 15 seconds...")
        dnaManager.startScanning()

        // Wait for device discovery
        var device: DNADiscoveredDevice?
        let scanDeadline = Date().addingTimeInterval(15)

        while device == nil && Date() < scanDeadline {
            try? await Task.sleep(for: .milliseconds(100))
            if let found = dnaManager.discoveredDevices.first {
                device = found
            }
        }

        guard let foundDevice = device else {
            print("\nTimeout reached. No device found.")
            return
        }

        print("\nFound device: \(foundDevice.name) (\(foundDevice.id))")
        print("Connecting...")
        dnaManager.connect(to: foundDevice.id)

        // Wait for connection
        let connectDeadline = Date().addingTimeInterval(10)
        while !dnaManager.isConnected && Date() < connectDeadline {
            try? await Task.sleep(for: .milliseconds(100))
        }

        guard dnaManager.isConnected else {
            print("\nFailed to connect.")
            return
        }

        print("Connected!")

        // Wait for device info
        try? await Task.sleep(for: .seconds(2))

        print("\n--- Device Info ---")
        print("Manufacturer: \(dnaManager.deviceInfo.manufacturerName ?? "N/A")")
        print("Model: \(dnaManager.deviceInfo.modelNumber ?? "N/A")")
        print("Serial: \(dnaManager.deviceInfo.serialNumber ?? "N/A")")
        print("Hardware: \(dnaManager.deviceInfo.hardwareRevision ?? "N/A")")
        print("Firmware: \(dnaManager.deviceInfo.firmwareRevision ?? "N/A")")
        if let batt = dnaManager.batteryLevel {
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
        while dnaManager.isConnected {
            try? await Task.sleep(for: .milliseconds(500))
        }

        print("\n\nDisconnected.")
        readingTask.cancel()
        inputTask.cancel()
    }
}
