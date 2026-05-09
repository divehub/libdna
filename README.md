# LibDNA

**LibDNA** is a Swift library for communicating with the **Divesoft DNA** oxygen sensor via Bluetooth Low Energy (BLE). It provides a structured, type-safe API for running the DNA sensor protocol on an already-connected `CBPeripheral`, including oxygen readings and device metadata.

## Features

- **Session-Level DNA Protocol**: Attach to a connected `CBPeripheral` and discover DNA services and characteristics.
- **Real-time Oxygen Readings**: Stream raw voltage, filtered voltage, and ambient pressure.
- **Async/Await Support**: Modern Swift concurrency support with `AsyncStream`.
- **Observation Support**: `@Observable` state for SwiftUI-friendly updates.
- **Device Metadata**: Reads manufacturer, model, serial number, firmware version, and battery level once after connection.
- **Strict Concurrency**: Fully compliant with Swift 6 strict concurrency checks (`Sendable`, `@MainActor`).
- **Included CLI**: A command-line tool `DNAClient` with a tiny scanner that demonstrates how to wire scanning, connection, and the DNA session together.

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
import CoreBluetooth
import LibDNA

@MainActor
class OxygenMonitor {
    private let session = DNASensorSession()

    func didConnectDNADevice(_ peripheral: CBPeripheral) {
        // The app owns CBCentralManager scanning and link connection.
        // LibDNA owns the DNA protocol once the peripheral is connected.
        session.attach(to: peripheral)

        Task {
            for await reading in session.readings {
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

- **`DNASensorSession`**: The DNA protocol session for an already-connected `CBPeripheral`.
- **`DNASensorReading`**: Immutable struct representing a single data packet.
- **`DNADeviceStatus` / `DNADeviceInfo`**: Cached metadata and battery status read after attach.
- **`DNASensorEvent`**: Attachment and device-status updates for app bridges.
- **`DNASensorAdvertisement`**: Public service UUIDs for app-owned scanning.
- **`DNASensorSimulator`**: Demo/test simulator for scanner-style flows.

## License

[MIT License](LICENSE)

## Disclaimer

**DNA** and **DIVESOFT** are trademarks of **DIVESOFT**. This library is an independent project and is not affiliated with, endorsed by, or associated with DIVESOFT in any way.

This software is provided for educational and experimental purposes only. **Use it at your own risk.** The authors assume no liability for any equipment damage, personal injury, or other issues arising from the use of this library.
