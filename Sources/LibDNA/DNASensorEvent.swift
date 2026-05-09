import Foundation

public struct DNADeviceStatus: Sendable, Equatable {
    public static let empty = DNADeviceStatus(
        deviceInfo: DNADeviceInfo(),
        batteryLevel: nil
    )

    public let deviceInfo: DNADeviceInfo
    public let batteryLevel: Int?

    public init(deviceInfo: DNADeviceInfo, batteryLevel: Int?) {
        self.deviceInfo = deviceInfo
        self.batteryLevel = batteryLevel
    }
}

public enum DNASensorEvent: Sendable, Equatable {
    case attachmentChanged(isAttached: Bool)
    case deviceStatusChanged(DNADeviceStatus)
}
