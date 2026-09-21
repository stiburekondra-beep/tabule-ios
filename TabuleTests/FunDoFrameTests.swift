import XCTest
@testable import Tabule

final class FunDoFrameTests: XCTestCase {

    /// Reálný rámec z F10-ovladani.md, odeslaný a ověřený na živých
    /// hodinkách 21. 9. 2026 („brní — ikona hodinek"):
    /// `ba 21 00 05 6c 95 08 f0 05 00 50 00 00`
    /// = vibrace (modul 0x05, typ 0x00, cmd 0x50, bez dat), seq 0x08f0.
    func testDekodovaniVibraceRamce() {
        let bytes: [UInt8] = [0xba, 0x21, 0x00, 0x05, 0x6c, 0x95, 0x08, 0xf0, 0x05, 0x00, 0x50, 0x00, 0x00]
        switch FunDoFrame.decode(bytes) {
        case .success(let frame):
            XCTAssertEqual(frame.direction, .phoneToWatch)
            XCTAssertEqual(frame.seq, 0x08f0)
            XCTAssertEqual(frame.body.modul, 0x05)
            XCTAssertEqual(frame.body.typ, 0x00)
            XCTAssertEqual(frame.body.cmd, 0x50)
            XCTAssertEqual(frame.body.data, [])
        case .failure(let e):
            XCTFail("dekódování selhalo: \(e)")
        }
    }

    /// Byte-exaktní stavba stejného rámce — vlastní enkodér musí dát
    /// identické bajty jako ten ověřený na hodinkách.
    func testEnkodovaniVibraceRamceJeByteExaktni() {
        let ocekavane: [UInt8] = [0xba, 0x21, 0x00, 0x05, 0x6c, 0x95, 0x08, 0xf0, 0x05, 0x00, 0x50, 0x00, 0x00]
        let frame = FunDoFrame(direction: .phoneToWatch, seq: 0x08f0,
                                body: FunDoBody(modul: 0x05, typ: 0x00, cmd: 0x50, data: []))
        XCTAssertEqual(frame.encode(), ocekavane)
    }

    /// Druhý nezávislý rámec z F6-fundo-ramec.md (dotaz na název hodinek):
    /// `ba 21 00 05 26 42 bb 02 | 02 00 42 00 00`.
    func testDruhyRamecZF6() {
        let bytes: [UInt8] = [0xba, 0x21, 0x00, 0x05, 0x26, 0x42, 0xbb, 0x02, 0x02, 0x00, 0x42, 0x00, 0x00]
        switch FunDoFrame.decode(bytes) {
        case .success(let frame):
            XCTAssertEqual(frame.seq, 0xbb02)
            XCTAssertEqual(frame.body.modul, 0x02)
            XCTAssertEqual(frame.body.cmd, 0x42)
            XCTAssertEqual(frame.body.data.count, 0)
        case .failure(let e):
            XCTFail("dekódování selhalo: \(e)")
        }
        let frame = FunDoFrame(direction: .phoneToWatch, seq: 0xbb02,
                                body: FunDoBody(modul: 0x02, typ: 0x00, cmd: 0x42, data: []))
        XCTAssertEqual(frame.encode(), bytes)
    }

    /// Tvar těla pro nastavení času (F16-cizi-reseni.md, cizí knihovna,
    /// jen jako strukturální ověření kódování modul/typ/cmd/délka/data —
    /// NEOVĚŘENO na našich hodinkách, „cíl" tohohle testu je jen formát
    /// hlavičky těla, ne že by appka uměla čas nastavit):
    /// `02 00 20 00 07 1A 09 12 15 0B 1D 00`.
    func testTvarTelaJeShodnySCizimPrikladem() {
        let ocekavane: [UInt8] = [0x02, 0x00, 0x20, 0x00, 0x07, 0x1A, 0x09, 0x12, 0x15, 0x0B, 0x1D, 0x00]
        let telo = FunDoBody(modul: 0x02, typ: 0x00, cmd: 0x20,
                              data: [0x1A, 0x09, 0x12, 0x15, 0x0B, 0x1D, 0x00])
        XCTAssertEqual(telo.encode(), ocekavane)
        XCTAssertEqual(FunDoBody.decode(ocekavane), telo)
    }

    func testOdpovedSeParujePodleSeq() {
        let dotaz = FunDoFrame(direction: .phoneToWatch, seq: 0x1234,
                                body: FunDoBody(modul: FunDoCommand.bateryModul, typ: FunDoCommand.bateryTyp,
                                                 cmd: FunDoCommand.bateryCmdDotaz, data: []))
        let odpoved = FunDoFrame(direction: .watchToPhone, seq: 0x1234,
                                  body: FunDoBody(modul: FunDoCommand.bateryModul, typ: 0x00,
                                                   cmd: FunDoCommand.bateryCmdOdpoved, data: [100, 0]))
        XCTAssertEqual(dotaz.seq, odpoved.seq)

        switch FunDoFrame.decode(odpoved.encode()) {
        case .success(let f):
            XCTAssertEqual(f.body.data.first, 100)
        case .failure(let e):
            XCTFail("\(e)")
        }
    }

    func testKratkyRamecSelze() {
        let bytes: [UInt8] = [0xba, 0x21, 0x00]
        if case .success = FunDoFrame.decode(bytes) { XCTFail("krátký rámec by neměl projít") }
    }

    func testSpatneCrcSelze() {
        var bytes: [UInt8] = [0xba, 0x21, 0x00, 0x05, 0x6c, 0x95, 0x08, 0xf0, 0x05, 0x00, 0x50, 0x00, 0x00]
        bytes[4] = 0x00 // rozbít CRC
        switch FunDoFrame.decode(bytes) {
        case .success: XCTFail("s poškozeným CRC by dekódování mělo selhat")
        case .failure(let e): XCTAssertEqual(e, .crcMismatch)
        }
    }

    func testSpatnaDelkaSelze() {
        var bytes: [UInt8] = [0xba, 0x21, 0x00, 0x05, 0x6c, 0x95, 0x08, 0xf0, 0x05, 0x00, 0x50, 0x00, 0x00]
        bytes[3] = 0x09 // deklarovaná délka neodpovídá skutečné
        switch FunDoFrame.decode(bytes) {
        case .success: XCTFail("se špatnou délkou by dekódování mělo selhat")
        case .failure(let e): XCTAssertEqual(e, .lengthMismatch)
        }
    }

    func testKazdyRamecMaJinouSekvenciAlespoNvRadeRyzichVolani() {
        // Round-trip: postav rámec s libovolnými daty, dekóduj, ověř shodu.
        let telo = FunDoBody(modul: 0x01, typ: 0x01, cmd: 0xC2, data: Array(repeating: 0xAB, count: 300))
        let frame = FunDoFrame(direction: .phoneToWatch, seq: 0xFFFE, body: telo)
        let bytes = frame.encode()
        // délka těla musí být 5 + 300 = 305, tedy pole [2:4] = 0x0131
        XCTAssertEqual(bytes[2], 0x01)
        XCTAssertEqual(bytes[3], 0x31)
        switch FunDoFrame.decode(bytes) {
        case .success(let f): XCTAssertEqual(f, frame)
        case .failure(let e): XCTFail("\(e)")
        }
    }
}
