import XCTest
@testable import Tabule

final class DialFileTests: XCTestCase {

    // MARK: - RGB565, big-endian (F7-format-obrazku.md, oprava 20:15)

    func testCervenaJeF800BigEndian() {
        let rgba: [UInt8] = [255, 0, 0, 255] // R,G,B,A
        let out = RGB565.zeRGBA(rgba)
        XCTAssertEqual(out, [0xF8, 0x00])
    }

    func testModraJe001FBigEndian() {
        let rgba: [UInt8] = [0, 0, 255, 255]
        let out = RGB565.zeRGBA(rgba)
        XCTAssertEqual(out, [0x00, 0x1F])
    }

    func testBilaJeFFFF() {
        let rgba: [UInt8] = [255, 255, 255, 255]
        let out = RGB565.zeRGBA(rgba)
        XCTAssertEqual(out, [0xFF, 0xFF])
    }

    func testPlnaZelenaVyplniCelouPlochu() {
        let out = RGB565.plna(RGB565.zelena, pocetBodu: 5)
        XCTAssertEqual(out, [0x07, 0xE0, 0x07, 0xE0, 0x07, 0xE0, 0x07, 0xE0, 0x07, 0xE0])
    }

    // MARK: - Sestavení souboru ciferníku (F13-prenos-souboru.md)

    /// Syntetická šablona (žádný skutečný .bin soubor) — ověřuje, že
    /// `sestav` vloží obraz na offset 100, přepočítá CRC32 z `[21:]`
    /// a zapíše ho little-endian do `[8:12]`, beze změny bajtů `[0:8]`
    /// mimo CRC pole a beze změny bajtů `[12:21]`.
    func testSestaveniSouboruVlozeniAOffsetyACrc() {
        var sablona = [UInt8](repeating: 0xAA, count: 200)
        // Nastav rozeznatelnou "hlavičku" [0:21], kterou sestav nemá měnit
        // (kromě CRC pole [8:12]).
        for i in 0..<21 { sablona[i] = UInt8(i) }
        let puvodniHlavickaMimoCrc = Array(sablona[12..<21])

        let obraz: [UInt8] = Array(repeating: 0x77, count: 30)
        let vysledek = DialFile.sestav(sablona: sablona, obrazData: obraz)

        XCTAssertEqual(vysledek.count, sablona.count)
        // obraz je na offsetu 100..130
        XCTAssertEqual(Array(vysledek[100..<130]), obraz)
        // zbytek šablony za obrazem je nedotčený
        XCTAssertEqual(vysledek[130], 0xAA)
        // bajty [12:21] beze změny
        XCTAssertEqual(Array(vysledek[12..<21]), puvodniHlavickaMimoCrc)
        // bajty [0:8] beze změny (magic + délka hlavičky + verze)
        XCTAssertEqual(Array(vysledek[0..<8]), Array(0..<8).map(UInt8.init))

        let ocekavaneCrc = CRC.crc32(vysledek[21...])
        let zapsanaCrc = UInt32(vysledek[8]) | (UInt32(vysledek[9]) << 8) | (UInt32(vysledek[10]) << 16) | (UInt32(vysledek[11]) << 24)
        XCTAssertEqual(zapsanaCrc, ocekavaneCrc)
    }

    func testSestaveniOriznePrilisVelkyObrazAbyNepresahlSablonu() {
        let sablona = [UInt8](repeating: 0, count: 110)
        let obraz = [UInt8](repeating: 0x99, count: 1000) // víc než volné místo (110-100=10)
        let vysledek = DialFile.sestav(sablona: sablona, obrazData: obraz)
        XCTAssertEqual(vysledek.count, 110)
        XCTAssertEqual(Array(vysledek[100..<110]), [UInt8](repeating: 0x99, count: 10))
    }

    // MARK: - TabuleSession dekódování (tvar `/api/sessions`, hub.py ~951)

    func testDekodovaniSessionZJsonu() throws {
        let json = """
        [{"title":"Blaha","summary":"otvory?","status":"WAITING_FOR_USER","waiting":true},
         {"title":"Fermato","summary":"pH 4.1","status":"IDLE","waiting":0}]
        """.data(using: .utf8)!
        let sessions = try JSONDecoder().decode([TabuleSession].self, from: json)
        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(sessions[0].title, "Blaha")
        XCTAssertTrue(sessions[0].waiting)
        XCTAssertFalse(sessions[1].waiting) // waiting: 0 → false, i když je to Int, ne Bool
    }

    func testTabuleObsahPocitaCekajiciABezici() {
        let sessions = [
            TabuleSession(title: "A", status: "WAITING_FOR_USER", waiting: true),
            TabuleSession(title: "B", status: "IDLE", waiting: false),
            TabuleSession(title: "C", status: "WAITING_FOR_USER", waiting: true),
        ]
        let obsah = TabuleObsah(bezSpojeni: false, sessions: sessions)
        XCTAssertEqual(obsah.cekajici.count, 2)
        XCTAssertEqual(obsah.bezicichDalsich, 1)
    }
}
