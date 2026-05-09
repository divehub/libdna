import CoreBluetooth

public enum DNASensorAdvertisement {
    /// Service UUIDs an app can use when scanning for DNA sensors.
    public static var serviceUUIDs: [CBUUID] {
        [advertisedServiceUUID, sensorServiceUUID]
    }

    /// The primary advertised DNA service UUID.
    public static var advertisedServiceUUID: CBUUID {
        DNAUUIDs.dnaAdvertisedService
    }

    /// The DNA sensor protocol service UUID.
    public static var sensorServiceUUID: CBUUID {
        DNAUUIDs.dnaSensorService
    }
}

enum DNAUUIDs {
    /// The main service UUID for the DNA sensor.
    static var dnaSensorService: CBUUID {
        CBUUID(string: "0bcb0001-0be0-4c5a-8f2b-ccb9e8cdbb1f")
    }

    /// The advertised service UUID (used for scanning).
    static var dnaAdvertisedService: CBUUID {
        CBUUID(string: "0000fcef-0000-1000-8000-00805f9b34fb")
    }

    // Standard GATT Services
    static var deviceInformationService: CBUUID { CBUUID(string: "180A") }
    static var batteryService: CBUUID { CBUUID(string: "180F") }

    // Standard GATT Characteristics
    static var manufacturerNameString: CBUUID { CBUUID(string: "2A29") }
    static var modelNumberString: CBUUID { CBUUID(string: "2A24") }
    static var serialNumberString: CBUUID { CBUUID(string: "2A25") }
    static var hardwareRevisionString: CBUUID { CBUUID(string: "2A27") }
    static var firmwareRevisionString: CBUUID { CBUUID(string: "2A26") }
    static var batteryLevel: CBUUID { CBUUID(string: "2A19") }
}
