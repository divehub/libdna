import Foundation

/// Represents a reading from the DNA sensor.
public struct DNASensorReading: Sendable {
    /// The raw sensor voltage in millivolts (mV).
    public let rawVoltage: Double

    /// The filtered sensor voltage in millivolts (mV).
    /// This is the primary value to use for oxygen calculations.
    public let filteredVoltage: Double

    /// The ambient pressure in hectopascals (hPa).
    public let ambientPressure: Double

    /// The timestamp when the reading was received.
    public let timestamp: Date

    public init(
        rawVoltage: Double, filteredVoltage: Double, ambientPressure: Double,
        timestamp: Date = Date()
    ) {
        self.rawVoltage = rawVoltage
        self.filteredVoltage = filteredVoltage
        self.ambientPressure = ambientPressure
        self.timestamp = timestamp
    }

    /// Parses the 8-byte DNA sensor data packet.
    public init?(data: Data, timestamp: Date = Date()) {
        guard data.count == 8 else { return nil }

        // Use manual bit shifting for safety against alignment issues (Little Endian)
        let rawVoltageUInt = UInt16(data[2]) | (UInt16(data[3]) << 8)
        let filteredVoltageUInt = UInt16(data[4]) | (UInt16(data[5]) << 8)
        let pressureUInt = UInt16(data[6]) | (UInt16(data[7]) << 8)

        // Convert to standard units
        // Voltage: 0.01 mV -> mV (divide by 100)
        self.rawVoltage = Double(rawVoltageUInt) / 100.0
        self.filteredVoltage = Double(filteredVoltageUInt) / 100.0

        // Pressure: 0.1 hPa -> hPa (divide by 10)
        self.ambientPressure = Double(pressureUInt) / 10.0

        self.timestamp = timestamp
    }
}

/// Represents the device information.
public struct DNADeviceInfo: Sendable {
    public var manufacturerName: String?
    public var modelNumber: String?
    public var serialNumber: String?
    public var hardwareRevision: String?
    public var firmwareRevision: String?

    public init(
        manufacturerName: String? = nil,
        modelNumber: String? = nil,
        serialNumber: String? = nil,
        hardwareRevision: String? = nil,
        firmwareRevision: String? = nil
    ) {
        self.manufacturerName = manufacturerName
        self.modelNumber = modelNumber
        self.serialNumber = serialNumber
        self.hardwareRevision = hardwareRevision
        self.firmwareRevision = firmwareRevision
    }
}

/// Represents a discovered DNA device.
public struct DNADiscoveredDevice: Sendable, Identifiable, Hashable {
    public let id: UUID
    public let name: String
    public let rssi: Int
}
