import CoreBluetooth

public struct DNAUUIDs {
    /// The main service UUID for the DNA sensor.
    public static var dnaSensorService: CBUUID {
        CBUUID(string: "0bcb0001-0be0-4c5a-8f2b-ccb9e8cdbb1f")
    }

    /// The advertised service UUID (used for scanning).
    public static var dnaAdvertisedService: CBUUID {
        CBUUID(string: "0000fcef-0000-1000-8000-00805f9b34fb")
    }

    // Standard GATT Services
    public static var deviceInformationService: CBUUID { CBUUID(string: "180A") }
    public static var batteryService: CBUUID { CBUUID(string: "180F") }

    // Standard GATT Characteristics
    public static var manufacturerNameString: CBUUID { CBUUID(string: "2A29") }
    public static var modelNumberString: CBUUID { CBUUID(string: "2A24") }
    public static var serialNumberString: CBUUID { CBUUID(string: "2A25") }
    public static var hardwareRevisionString: CBUUID { CBUUID(string: "2A27") }
    public static var firmwareRevisionString: CBUUID { CBUUID(string: "2A26") }
    public static var batteryLevel: CBUUID { CBUUID(string: "2A19") }
}
