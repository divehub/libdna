# AGENTS.md

> **Note to AI Agents:** This file provides context, architectural decisions, and development guidelines for working on `LibDNA`. Read this before making changes.

## Project Overview

`LibDNA` is a Swift package for the Divesoft DNA Bluetooth Oxygen Sensor. It wraps `CoreBluetooth` handling into a high-level `DNASensorManager` class.

## Architecture & Patterns

### 1. Concurrency Model (Swift 6)
- **Strict Concurrency** is enabled.
- **`@MainActor`**: `DNASensorManager` is isolated to the Main Actor. This greatly simplifies state management for UI-driven apps (Common case for iOS/macOS).
- **`Sendable`**: All data models (`DNASensorReading`, `DNADeviceInfo`) are `Sendable`.
- **CoreBluetooth Isolation**: 
    - `CBCentralManager` and `CBPeripheral` delegates are `nonisolated`.
    - We use `Twostraws/UnsafeTransfer` pattern (or similar) to carefully move `CBPeripheral` and `CBService` objects back to the `@MainActor` domain within `Task { @MainActor in ... }` blocks. 
    - **Reasoning**: CoreBluetooth objects are not marked `Sendable` by Apple yet (as of Xcode 16/Swift 6), but we know they are safe if handled correctly.

### 2. Async/Await vs Combine
- The library supports **BOTH**.
- **Combine**: Used for state properties (`$isConnected`, `$deviceInfo`) because they represent continuous state.
- **Async/Await**: Used for the stream of sensor readings (`readings: AsyncStream<DNASensorReading>`) because it feels more modern and natural for handling a "stream of events".

### 3. File Structure
### 3. File Structure
- **`DNASensorManager.swift`**: The brain. Handles scanning, manual connection (`connect(to:)`), service discovery, and notification setup.
- **`DNASensorData.swift`**: Data models (`DNASensorReading`, `DNADeviceInfo`, `DNADiscoveredDevice`) and byte parsing logic. Parsing is done safely with bit-shifting.
- **`DNAUUIDs.swift`**: All UUID constants. computed properties are used to satisfy Sendable requirements for static globals.

## Key Implementation Details

### Sensor Data Parsing
The sensor sends 8 bytes of data:
- Bytes 2-3: Raw Voltage (UInt16 LE) -> divide by 100.0 for mV.
- Bytes 4-5: Filtered Voltage (UInt16 LE) -> divide by 100.0 for mV.
- Bytes 6-7: Pressure (UInt16 LE) -> divide by 10.0 for hPa.

### BLE Stability
- A **200ms delay** (`Task.sleep`) is inserted between `readValue` and `setNotifyValue` calls during the discovery phase.
- **Reason**: The Divesoft DNA sensor's BLE stack can get overwhelmed if multiple requests are fired instantly, causing it to disconnect or ignore commands.

## Common Pitfalls

- **"Bluetooth is not powered on"**: `startScanning()` checks for `.poweredOn`. If not ready, it sets a flag `shouldScanWhenPoweredOn`. The delegate `centralManagerDidUpdateState` picks this up.
- **"N/A" Device Info**: `DNAClient` uses a debounce logic because device info characteristics arrive asynchronously and potentially out of order.
- **Permissions**: Code running on macOS needs `Privacy - Bluetooth Always Usage Description` in `Info.plist` (app) or terminal permissions (CLI).

## Verification
Always verify changes by running the CLI:
```bash
swift run DNAClient
```
It should:
1. Scan and find the device.
2. Connect.
3. Print full device info (No N/A).
4. Prompt for calibration (showing live `Volt` and `Press` readings).
5. Stream readable PO2/Voltage values after calibration.

**Note**: The CLI implements "Auto-Connect" logic by automatically picking the first discovered device. The Library itself does NOT auto-connect.
