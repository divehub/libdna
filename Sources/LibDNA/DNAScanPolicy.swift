import Foundation

enum DNAScanPolicy {
    @discardableResult
    static func recordDiscovery(
        id: UUID,
        name: String,
        rssi: Int,
        in devices: inout [DNASimulatedDevice]
    ) -> DNASimulatedDevice {
        let device = DNASimulatedDevice(id: id, name: name, rssi: rssi)

        if let index = devices.firstIndex(where: { $0.id == id }) {
            devices[index] = device
        } else {
            devices.append(device)
        }

        return device
    }
}
