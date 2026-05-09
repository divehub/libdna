@preconcurrency import CoreBluetooth
import Foundation
import os

/// Helper to pass non-Sendable values across isolation boundaries when we know the
/// CoreBluetooth object stays under the protocol session's control.
private struct UnsafeTransfer<T>: @unchecked Sendable {
    let value: T
}

@MainActor
@Observable
public final class DNASensorSession {
    // MARK: - Published Properties

    /// Whether the DNA protocol session is attached to a peripheral.
    public private(set) var isAttached: Bool = false

    /// The latest reading received from the sensor.
    public private(set) var latestReading: DNASensorReading?

    /// Latest cached device status read from the peripheral.
    public private(set) var deviceStatus = DNADeviceStatus.empty

    // MARK: - Async Streams

    /// Async stream of readings for modern concurrency consumption.
    public var readings: AsyncStream<DNASensorReading> {
        let (stream, continuation) = AsyncStream<DNASensorReading>.makeStream()

        let id = UUID()
        readingContinuations[id] = continuation

        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in
                self?.readingContinuations.removeValue(forKey: id)
            }
        }

        return stream
    }

    /// Async stream of session lifecycle and device status updates.
    public var events: AsyncStream<DNASensorEvent> {
        let (stream, continuation) = AsyncStream<DNASensorEvent>.makeStream()

        let id = UUID()
        eventContinuations[id] = continuation

        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in
                self?.eventContinuations.removeValue(forKey: id)
            }
        }

        return stream
    }

    private var readingContinuations: [UUID: AsyncStream<DNASensorReading>.Continuation] = [:]
    private var eventContinuations: [UUID: AsyncStream<DNASensorEvent>.Continuation] = [:]
    private var peripheral: CBPeripheral?
    private var activeSessionID: UUID?
    private var peripheralDelegate: DNASensorPeripheralDelegate?
    private var pendingServiceDiscoverySessionID: UUID?
    private var pendingCharacteristicDiscoverySessions: [CBUUID: UUID] = [:]
    private var pendingReadCounts: [ObjectIdentifier: Int] = [:]
    private var notifyingCharacteristics: Set<ObjectIdentifier> = []
    private var attachTask: Task<Void, Never>?
    private var lastDetachedPeripheralID: UUID?
    private let samePeripheralReattachDelay: Duration = .milliseconds(500)
    private let logger = Logger(subsystem: "ai.divehub.libdna", category: "BLE")

    // Dedicated serial queue for sensor protocol operations to avoid issuing a
    // burst of CoreBluetooth requests from the main actor.
    private let bleQueue = DispatchQueue(label: "ai.divehub.libdna.ble", qos: .userInitiated)

    // MARK: - Initialization

    public init() {}

    // MARK: - Public API

    /// Attaches the DNA protocol session to an already-connected peripheral.
    public func attach(to peripheral: CBPeripheral) {
        attachTask?.cancel()
        attachTask = nil

        if let existingPeripheral = self.peripheral {
            existingPeripheral.delegate = nil
            lastDetachedPeripheralID = existingPeripheral.identifier
        }

        clearSessionOperations()
        latestReading = nil
        clearCachedMetadata()
        logger.info("Attaching DNA session to \(peripheral.name ?? "Unknown") (\(peripheral.identifier))")
        let sessionID = UUID()
        let delegate = DNASensorPeripheralDelegate(manager: self, sessionID: sessionID)
        activeSessionID = sessionID
        peripheralDelegate = delegate
        self.peripheral = peripheral
        setAttachmentState(isAttached: true)

        if lastDetachedPeripheralID == peripheral.identifier {
            peripheral.delegate = nil
            let p = UnsafeTransfer(value: peripheral)
            let d = UnsafeTransfer(value: delegate)
            attachTask = Task { @MainActor [weak self] in
                guard let self else { return }
                try? await Task.sleep(for: samePeripheralReattachDelay)
                guard !Task.isCancelled else { return }
                self.startSessionDiscovery(
                    peripheral: p.value,
                    delegate: d.value,
                    sessionID: sessionID
                )
            }
        } else {
            startSessionDiscovery(
                peripheral: peripheral,
                delegate: delegate,
                sessionID: sessionID
            )
        }
    }

    /// Detaches the protocol session from the current peripheral.
    ///
    /// The app-level central manager remains responsible for cancelling the BLE
    /// link. This method only updates DNA session state and releases the
    /// `CBPeripheralDelegate` ownership.
    public func detach() {
        attachTask?.cancel()
        attachTask = nil

        if let peripheral {
            peripheral.delegate = nil
            lastDetachedPeripheralID = peripheral.identifier
        }
        peripheral = nil
        activeSessionID = nil
        peripheralDelegate = nil
        clearSessionOperations()
        setAttachmentState(isAttached: false)
        latestReading = nil
        clearCachedMetadata()
    }
}

// MARK: - CBPeripheralDelegate
private final class DNASensorPeripheralDelegate: NSObject, CBPeripheralDelegate {
    private weak var manager: DNASensorSession?
    private let sessionID: UUID

    init(manager: DNASensorSession, sessionID: UUID) {
        self.manager = manager
        self.sessionID = sessionID
        super.init()
    }

    public nonisolated func peripheral(
        _ peripheral: CBPeripheral, didDiscoverServices error: Error?
    ) {
        let p = UnsafeTransfer(value: peripheral)
        let sessionID = sessionID

        Task { @MainActor [weak manager] in
            guard let manager else { return }
            let peripheral = p.value
            guard manager.consumeServiceDiscovery(peripheral, sessionID: sessionID),
                  let services = peripheral.services,
                  error == nil else { return }

            for service in services {
                guard manager.markCharacteristicDiscoveryPending(
                    peripheral,
                    serviceUUID: service.uuid,
                    sessionID: sessionID
                ) else { return }

                if service.uuid == DNAUUIDs.dnaSensorService {
                    peripheral.discoverCharacteristics(nil, for: service)
                } else if service.uuid == DNAUUIDs.deviceInformationService {
                    peripheral.discoverCharacteristics(nil, for: service)
                } else if service.uuid == DNAUUIDs.batteryService {
                    peripheral.discoverCharacteristics([DNAUUIDs.batteryLevel], for: service)
                }
            }
        }
    }

    public nonisolated func peripheral(
        _ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?
    ) {
        let p = UnsafeTransfer(value: peripheral)
        let s = UnsafeTransfer(value: service)
        let sessionID = sessionID

        Task { @MainActor [weak manager] in
            guard let manager else { return }
            let peripheral = p.value
            let service = s.value
            guard manager.consumeCharacteristicDiscovery(
                peripheral,
                serviceUUID: service.uuid,
                sessionID: sessionID
            ),
                  let characteristics = service.characteristics,
                  error == nil else { return }

            for characteristic in characteristics {
                guard manager.isCurrentSession(peripheral, sessionID: sessionID) else { return }

                if service.uuid == DNAUUIDs.dnaSensorService {
                    if characteristic.properties.contains(.notify) {
                        guard await manager.enableNotifications(
                            for: characteristic,
                            on: peripheral,
                            sessionID: sessionID
                        ) else { return }
                    } else if characteristic.properties.contains(.read) {
                        guard await manager.readCharacteristic(
                            characteristic,
                            on: peripheral,
                            sessionID: sessionID
                        ) else { return }
                    }
                }

                if service.uuid == DNAUUIDs.deviceInformationService,
                   characteristic.properties.contains(.read) {
                    guard await manager.readCharacteristic(
                        characteristic,
                        on: peripheral,
                        sessionID: sessionID
                    ) else { return }
                }

                if characteristic.uuid == DNAUUIDs.batteryLevel,
                   characteristic.properties.contains(.read) {
                    guard await manager.readCharacteristic(
                        characteristic,
                        on: peripheral,
                        sessionID: sessionID
                    ) else { return }
                }
            }
        }
    }

    public nonisolated func peripheral(
        _ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard let data = characteristic.value, error == nil else { return }

        let uuid = characteristic.uuid
        let isDNAService = characteristic.service?.uuid == DNAUUIDs.dnaSensorService
        let p = UnsafeTransfer(value: peripheral)
        let u = UnsafeTransfer(value: uuid)
        let characteristicID = ObjectIdentifier(characteristic)
        let sessionID = sessionID

        Task { @MainActor [weak manager] in
            guard let manager else { return }
            manager.applyCharacteristicValue(
                uuid: u.value,
                data: data,
                isDNAService: isDNAService,
                isCurrentPeripheral: manager.isCurrentPeripheral(p.value),
                isCurrentSessionToken: manager.isCurrentSessionToken(sessionID),
                isExpectedUpdate: manager.consumeExpectedValueUpdate(
                    characteristicID: characteristicID,
                    isDNAService: isDNAService,
                    sessionID: sessionID
                )
            )
        }
    }
}

extension DNASensorSession {
    func applyCharacteristicValue(
        uuid: CBUUID,
        data: Data,
        isDNAService: Bool,
        isCurrentPeripheral: Bool,
        isCurrentSessionToken: Bool,
        isExpectedUpdate: Bool
    ) {
        guard isCurrentPeripheral, isCurrentSessionToken, isExpectedUpdate else { return }

        let stringValue = String(data: data, encoding: .utf8)

        switch uuid {
        case DNAUUIDs.manufacturerNameString:
            updateDeviceInfo { $0.manufacturerName = stringValue }

        case DNAUUIDs.modelNumberString:
            updateDeviceInfo { $0.modelNumber = stringValue }

        case DNAUUIDs.serialNumberString:
            updateDeviceInfo { $0.serialNumber = stringValue }

        case DNAUUIDs.hardwareRevisionString:
            updateDeviceInfo { $0.hardwareRevision = stringValue }

        case DNAUUIDs.firmwareRevisionString:
            updateDeviceInfo { $0.firmwareRevision = stringValue }

        case DNAUUIDs.batteryLevel:
            if let level = data.first {
                setDeviceStatus(DNADeviceStatus(
                    deviceInfo: deviceStatus.deviceInfo,
                    batteryLevel: Int(level)
                ))
            }

        default:
            if isDNAService, let reading = DNASensorReading(data: data) {
                latestReading = reading
                for continuation in readingContinuations.values {
                    continuation.yield(reading)
                }
            }
        }
    }
}

private extension DNASensorSession {
    func enableNotifications(
        for characteristic: CBCharacteristic,
        on peripheral: CBPeripheral,
        sessionID: UUID?
    ) async -> Bool {
        guard isCurrentSession(peripheral, sessionID: sessionID) else { return false }
        peripheral.setNotifyValue(true, for: characteristic)
        markNotificationEnabled(
            peripheral,
            characteristic: characteristic,
            sessionID: sessionID
        )
        return await pauseAfterBLEOperation(peripheral, sessionID: sessionID)
    }

    func readCharacteristic(
        _ characteristic: CBCharacteristic,
        on peripheral: CBPeripheral,
        sessionID: UUID?
    ) async -> Bool {
        guard isCurrentSession(peripheral, sessionID: sessionID) else { return false }
        markReadPending(
            peripheral,
            characteristic: characteristic,
            sessionID: sessionID
        )
        peripheral.readValue(for: characteristic)
        return await pauseAfterBLEOperation(peripheral, sessionID: sessionID)
    }

    func pauseAfterBLEOperation(_ peripheral: CBPeripheral, sessionID: UUID?) async -> Bool {
        try? await Task.sleep(nanoseconds: 200 * 1_000_000)
        return isCurrentSession(peripheral, sessionID: sessionID)
    }

    func startSessionDiscovery(
        peripheral: CBPeripheral,
        delegate: DNASensorPeripheralDelegate,
        sessionID: UUID
    ) {
        guard isCurrentSession(peripheral, sessionID: sessionID),
              peripheralDelegate === delegate else { return }

        peripheral.delegate = delegate
        lastDetachedPeripheralID = nil
        attachTask = nil
        markServiceDiscoveryPending(sessionID: sessionID)

        let p = UnsafeTransfer(value: peripheral)
        bleQueue.async {
            p.value.discoverServices([
                DNAUUIDs.dnaSensorService,
                DNAUUIDs.deviceInformationService,
                DNAUUIDs.batteryService,
            ])
        }
    }

    func isCurrentPeripheral(_ peripheral: CBPeripheral) -> Bool {
        self.peripheral === peripheral
    }

    func isCurrentSession(_ peripheral: CBPeripheral, sessionID: UUID?) -> Bool {
        isCurrentPeripheral(peripheral) && isCurrentSessionToken(sessionID)
    }

    func isCurrentSessionToken(_ sessionID: UUID?) -> Bool {
        guard let sessionID else { return false }
        return activeSessionID == sessionID
    }

    func markServiceDiscoveryPending(sessionID: UUID) {
        guard isCurrentSessionToken(sessionID) else { return }
        pendingServiceDiscoverySessionID = sessionID
    }

    func consumeServiceDiscovery(_ peripheral: CBPeripheral, sessionID: UUID?) -> Bool {
        guard isCurrentSession(peripheral, sessionID: sessionID),
              pendingServiceDiscoverySessionID == sessionID else { return false }
        pendingServiceDiscoverySessionID = nil
        return true
    }

    func markCharacteristicDiscoveryPending(
        _ peripheral: CBPeripheral,
        serviceUUID: CBUUID,
        sessionID: UUID?
    ) -> Bool {
        guard isCurrentSession(peripheral, sessionID: sessionID),
              let sessionID else { return false }
        pendingCharacteristicDiscoverySessions[serviceUUID] = sessionID
        return true
    }

    func consumeCharacteristicDiscovery(
        _ peripheral: CBPeripheral,
        serviceUUID: CBUUID,
        sessionID: UUID?
    ) -> Bool {
        guard isCurrentSession(peripheral, sessionID: sessionID),
              pendingCharacteristicDiscoverySessions[serviceUUID] == sessionID else { return false }
        pendingCharacteristicDiscoverySessions[serviceUUID] = nil
        return true
    }

    func markReadPending(
        _ peripheral: CBPeripheral,
        characteristic: CBCharacteristic,
        sessionID: UUID?
    ) {
        guard isCurrentSession(peripheral, sessionID: sessionID) else { return }
        pendingReadCounts[ObjectIdentifier(characteristic), default: 0] += 1
    }

    func markNotificationEnabled(
        _ peripheral: CBPeripheral,
        characteristic: CBCharacteristic,
        sessionID: UUID?
    ) {
        guard isCurrentSession(peripheral, sessionID: sessionID) else { return }
        notifyingCharacteristics.insert(ObjectIdentifier(characteristic))
    }

    func consumeExpectedValueUpdate(
        characteristicID: ObjectIdentifier,
        isDNAService: Bool,
        sessionID: UUID?
    ) -> Bool {
        guard isCurrentSessionToken(sessionID) else { return false }

        if let count = pendingReadCounts[characteristicID], count > 0 {
            if count == 1 {
                pendingReadCounts[characteristicID] = nil
            } else {
                pendingReadCounts[characteristicID] = count - 1
            }
            return true
        }

        return isDNAService && notifyingCharacteristics.contains(characteristicID)
    }

    func clearSessionOperations() {
        pendingServiceDiscoverySessionID = nil
        pendingCharacteristicDiscoverySessions.removeAll()
        pendingReadCounts.removeAll()
        notifyingCharacteristics.removeAll()
    }

    func setAttachmentState(isAttached newIsAttached: Bool) {
        guard isAttached != newIsAttached else { return }
        isAttached = newIsAttached
        emitEvent(.attachmentChanged(isAttached: newIsAttached))
    }

    func updateDeviceInfo(_ update: (inout DNADeviceInfo) -> Void) {
        var deviceInfo = deviceStatus.deviceInfo
        update(&deviceInfo)
        setDeviceStatus(DNADeviceStatus(
            deviceInfo: deviceInfo,
            batteryLevel: deviceStatus.batteryLevel
        ))
    }

    func setDeviceStatus(_ newValue: DNADeviceStatus) {
        guard deviceStatus != newValue else { return }
        deviceStatus = newValue
        emitDeviceStatus()
    }

    func emitDeviceStatus() {
        emitEvent(.deviceStatusChanged(deviceStatus))
    }

    func clearCachedMetadata() {
        setDeviceStatus(.empty)
    }

    func emitEvent(_ event: DNASensorEvent) {
        for continuation in eventContinuations.values {
            continuation.yield(event)
        }
    }
}
