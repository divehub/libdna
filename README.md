# LibDNA

**LibDNA** is a Swift library for communicating with the **Divesoft DNA** oxygen sensor via Bluetooth Low Energy (BLE). It provides a structured, type-safe API for scanning, connecting, and reading oxygen sensor data, including support for calibration and device metadata.

## Features

- **Manual Connection Control**: Scan, discover, and choose which device to connect to.
- **Real-time Oxygen Readings**: Stream raw voltage, filtered voltage, and ambient pressure.
- **Async/Await Support**: Modern Swift concurrency support with `AsyncStream`.
- **Observation Support**: `@Observable` state for SwiftUI-friendly updates.
- **Device Metadata**: Reads manufacturer, model, serial number, firmware version, and battery level.
- **Strict Concurrency**: Fully compliant with Swift 6 strict concurrency checks (`Sendable`, `@MainActor`).
- **Included CLI**: A command-line tool `DNAClient` for testing and demonstration.

## Requirements

- iOS 15.0+ / macOS 12.0+
- Swift 5.10+ (Swift 6 ready)
- Bluetooth Low Energy (BLE) hardware

## Installation

### Swift Package Manager

Add `LibDNA` to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/divehub.ai/libdna.git", branch: "main")
]
```

## Usage

### Basic Setup

```swift
import LibDNA

@MainActor
class OxygenMonitor {
    private let manager = DNASensorManager()
    private var scanTask: Task<Void, Never>?

    func start() {
        // 1. Start scanning and connect to the first device found
        scanTask = Task {
            do {
                for try await device in manager.scan(timeout: .seconds(10)) {
                    print("Found \(device.name), connecting...")
                    manager.connect(to: device.id)
                    break
                }
            } catch {
                print("Scan failed: \(error)")
            }
        }

        // 2. Listen for readings using AsyncStream
        Task {
            for await reading in manager.readings {
                print("O2: \(reading.filteredVoltage) mV, Pressure: \(reading.ambientPressure) hPa")
            }
        }
    }
}
```

### Calibration

The library provides raw sensor voltage. To get a Percentage Oxygen (PO2) reading, you must calibrate against a known source (e.g., Air at 21%).

```swift
let currentVoltage = reading.filteredVoltage
let calibrationVoltage = 10.5 // example: stored calibration value for 21%

// Calculate PO2
let po2 = (currentVoltage / calibrationVoltage) * 21.0
```

## CLI Tool

This package includes an executable `DNAClient` to verify functionality on macOS.

```bash
# Run the CLI tool
swift run DNAClient
```

**Note**: On macOS, you may need to grant Bluetooth permissions to your terminal application.

## Architecture

- **`DNASensorManager`**: The core controller managing `CBCentralManager` and `CBPeripheral`.
- **`DNASensorReading`**: Immutable struct representing a single data packet.
- **`DNADeviceInfo`**: Metadata about the connected hardare.
- **`DNAUUIDs`**: Centralized storage for BLE UUIDs.

## License

[MIT License](LICENSE)

## Disclaimer

**DNA** and **DIVESOFT** are trademarks of **DIVESOFT**. This library is an independent project and is not affiliated with, endorsed by, or associated with DIVESOFT in any way.

This software is provided for educational and experimental purposes only. **Use it at your own risk.** The authors assume no liability for any equipment damage, personal injury, or other issues arising from the use of this library.
