import XCTest

@testable import LibDNA

final class LibDNATests: XCTestCase {

    func testDataParsing() {
        // Example Data:
        // Offset 0: 04 01 (Header) -> 0x0104 = 260
        // Offset 2: 12 00 (Raw Voltage 18) -> 0.18 mV
        // Offset 4: 34 00 (Filtered Voltage 52) -> 0.52 mV
        // Offset 6: 64 27 (Pressure 10084) -> 1008.4 hPa

        // 0x2764 = 10084 (Little Endian for 64 27)

        let header: [UInt8] = [0x04, 0x01]
        let raw: [UInt8] = [0x12, 0x00]  // 18 -> 0.18 mV
        let filtered: [UInt8] = [0x34, 0x00]  // 52 -> 0.52 mV
        let pressure: [UInt8] = [0x64, 0x27]  // 10084 -> 1008.4 hPa

        let bytes = header + raw + filtered + pressure
        let data = Data(bytes)

        guard let reading = DNASensorReading(data: data) else {
            XCTFail("Failed to parse valid data")
            return
        }

        XCTAssertEqual(reading.rawVoltage, 0.18, accuracy: 0.001)
        XCTAssertEqual(reading.filteredVoltage, 0.52, accuracy: 0.001)
        XCTAssertEqual(reading.ambientPressure, 1008.4, accuracy: 0.1)
    }

    func testInvalidData() {
        let shortData = Data([0x00, 0x01, 0x02])
        XCTAssertNil(DNASensorReading(data: shortData))
    }
}
