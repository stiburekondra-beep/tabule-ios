import XCTest
@testable import Tabule

final class CRCTests: XCTestCase {

    /// Tělo `05 00 50 00 00` (vibrace) z rámce ověřeného na živých hodinkách
    /// (F10-ovladani.md): `ba 21 00 05 6c 95 08 f0 05 00 50 00 00`.
    func testCrc16Vibrace() {
        let telo: [UInt8] = [0x05, 0x00, 0x50, 0x00, 0x00]
        XCTAssertEqual(CRC.crc16(telo), 0x6c95)
    }

    /// Druhý nezávislý rámec z F6-fundo-ramec.md:
    /// `ba 21 00 05 26 42 bb 02 | 02 00 42 00 00`.
    func testCrc16DruhyRamec() {
        let telo: [UInt8] = [0x02, 0x00, 0x42, 0x00, 0x00]
        XCTAssertEqual(CRC.crc16(telo), 0x2642)
    }

    func testCrc16PrazdnaData() {
        // Init 0xFFFF, žádná data → CRC beze změny (sanity check algoritmu).
        XCTAssertEqual(CRC.crc16([]), 0xFFFF)
    }

    /// Nezávislý oracle: Python `zlib.crc32(bytes(range(256)) + [1,2,3,4,5])`.
    func testCrc32NezavislyOracle256() {
        var data = Array(0...255).map { UInt8($0) }
        data.append(contentsOf: [1, 2, 3, 4, 5])
        XCTAssertEqual(CRC.crc32(data), 0x1c7b5768)
    }

    /// Nezávislý oracle: Python `zlib.crc32(bytes([0,1,2,0xFF,0xFE,0x10,0x20,0x30]))`.
    func testCrc32NezavislyOracleKratky() {
        let data: [UInt8] = [0x00, 0x01, 0x02, 0xFF, 0xFE, 0x10, 0x20, 0x30]
        XCTAssertEqual(CRC.crc32(data), 0x8d3b64b0)
    }

    func testCrc32PrazdnaData() {
        XCTAssertEqual(CRC.crc32([]), 0x00000000)
    }
}
