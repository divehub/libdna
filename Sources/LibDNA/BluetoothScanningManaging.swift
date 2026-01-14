@preconcurrency import CoreBluetooth
import Foundation

@MainActor
public protocol BluetoothScanningManaging: AnyObject {
    var isConnected: Bool { get }
    var isScanning: Bool { get }
    var isConnecting: Bool { get }
    var latestReading: DNASensorReading? { get }
    var deviceInfo: DNADeviceInfo { get }
    var batteryLevel: Int? { get }
    var discoveredDevices: [DNADiscoveredDevice] { get }
    var bluetoothState: CBManagerState { get }
    var bluetoothStateUpdates: AsyncStream<CBManagerState> { get }
    var readings: AsyncStream<DNASensorReading> { get }

    func scan(timeout: Duration) -> AsyncThrowingStream<DNADiscoveredDevice, Error>
    func stopScan()
    func connect(to deviceID: UUID)
    func disconnect()
}
