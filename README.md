# LibDNA

**LibDNA** is a Swift library for communicating with the **Divesoft DNA** oxygen sensor via Bluetooth Low Energy (BLE). It provides a structured, type-safe API for scanning, connecting, and reading oxygen sensor data, including support for calibration and device metadata.

## Features

- **Manual Connection Control**: Scan, discover, and choose which device to connect to.
- **Real-time Oxygen Readings**: Stream raw voltage, filtered voltage, and ambient pressure.
- **Async/Await Support**: Modern Swift concurrency support with `AsyncStream`.
- **Combine Support**: Reactive publishers for device state and data.
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
import Combine

@MainActor
class OxygenMonitor {
    private let scanner = DNASensorManager()
    private var cancellables = Set<AnyCancellable>()
    
    func start() {
        // 1. Start scanning
        scanner.startScanning()
        
        // 2. Observe discovered devices and connect
        scanner.$discoveredDevices
            .compactMap { $0.first } // For this example, just pick the first one
            .sink { [weak self] device in
                print("Found \(device.name), connecting...")
                self?.scanner.connect(to: device.id)
            }
            .store(in: &cancellables)
        
        // 3. Listen for readings using AsyncStream
        Task {
            for await reading in scanner.readings {
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
