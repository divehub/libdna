@preconcurrency import CoreBluetooth
import Foundation

enum DNAScanPolicy {
    static var coreBluetoothScanOptions: [String: Any] {
        [CBCentralManagerScanOptionAllowDuplicatesKey: true]
    }

    @discardableResult
    static func recordDiscovery(
        id: UUID,
        name: String,
        rssi: Int,
        in devices: inout [DNADiscoveredDevice]
    ) -> DNADiscoveredDevice {
        let device = DNADiscoveredDevice(id: id, name: name, rssi: rssi)

        if let index = devices.firstIndex(where: { $0.id == id }) {
            devices[index] = device
        } else {
            devices.append(device)
        }

        return device
    }
}
