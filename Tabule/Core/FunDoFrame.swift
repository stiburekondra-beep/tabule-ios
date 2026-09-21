import Foundation

/// Rámec protokolu FunDo (BLE, Niceboy Watch 5 Lite).
///
/// Zdroj pravdy: `F6-fundo-ramec.md` s opravou z `F16-cizi-reseni.md`
/// (délka dat v těle je 2 bajty big-endian, ne 1 bajt) a referenční
/// implementace `web/tabule.html`, ze které je tenhle soubor přepsán 1:1.
///
/// ```
/// [0]     0xBA                magic
/// [1]     0x21 telefon→hodinky / 0x31 hodinky→telefon
/// [2:4]   délka těla, big-endian      (= modul..data)
/// [4:6]   CRC16 těla, big-endian
/// [6:8]   sekvence, big-endian
/// [8:]    tělo: modul(1) typ(1) cmd(1) délka_dat BE(2) data(n)
/// ```
enum FunDoDirection: UInt8 {
    case phoneToWatch = 0x21
    case watchToPhone = 0x31
}

struct FunDoBody: Equatable {
    var modul: UInt8
    var typ: UInt8
    var cmd: UInt8
    var data: [UInt8]

    /// Zakóduje tělo rámce: modul(1) typ(1) cmd(1) délka_dat BE(2) data.
    func encode() -> [UInt8] {
        var out: [UInt8] = [modul, typ, cmd]
        let len = UInt16(data.count)
        out.append(UInt8((len >> 8) & 0xFF))
        out.append(UInt8(len & 0xFF))
        out.append(contentsOf: data)
        return out
    }

    /// Dekóduje tělo rámce. Vrátí nil, když je kratší než 5 bajtů hlavičky
    /// těla, nebo když deklarovaná délka dat neodpovídá skutečnosti.
    static func decode(_ bytes: [UInt8]) -> FunDoBody? {
        guard bytes.count >= 5 else { return nil }
        let modul = bytes[0], typ = bytes[1], cmd = bytes[2]
        let len = Int(bytes[3]) << 8 | Int(bytes[4])
        guard bytes.count - 5 == len else { return nil }
        let data = Array(bytes[5...])
        return FunDoBody(modul: modul, typ: typ, cmd: cmd, data: data)
    }
}

struct FunDoFrame: Equatable {
    var direction: FunDoDirection
    var seq: UInt16
    var body: FunDoBody

    /// Postaví kompletní bajty rámce (vnější hlavička + tělo), včetně CRC16.
    func encode() -> [UInt8] {
        let t = body.encode()
        let crc = CRC.crc16(t)
        var out: [UInt8] = [0xBA, direction.rawValue]
        let len = UInt16(t.count)
        out.append(UInt8((len >> 8) & 0xFF))
        out.append(UInt8(len & 0xFF))
        out.append(UInt8((crc >> 8) & 0xFF))
        out.append(UInt8(crc & 0xFF))
        out.append(UInt8((seq >> 8) & 0xFF))
        out.append(UInt8(seq & 0xFF))
        out.append(contentsOf: t)
        return out
    }

    enum ParseError: Error, Equatable {
        case tooShort
        case badMagic
        case badDirection
        case lengthMismatch
        case crcMismatch
        case badBody
    }

    /// Rozebere přijaté bajty (typicky z notify charakteristiky) na rámec.
    /// Ověřuje magic, deklarovanou délku těla i CRC16 — vrací chybu, když
    /// cokoli nesedí, aby se náhodou nezpracoval torzo rámce.
    static func decode(_ bytes: [UInt8]) -> Result<FunDoFrame, ParseError> {
        guard bytes.count >= 8 else { return .failure(.tooShort) }
        guard bytes[0] == 0xBA else { return .failure(.badMagic) }
        guard let direction = FunDoDirection(rawValue: bytes[1]) else { return .failure(.badDirection) }
        let bodyLen = Int(bytes[2]) << 8 | Int(bytes[3])
        let crcField = UInt16(bytes[4]) << 8 | UInt16(bytes[5])
        let seq = UInt16(bytes[6]) << 8 | UInt16(bytes[7])
        guard bytes.count - 8 == bodyLen else { return .failure(.lengthMismatch) }
        let t = Array(bytes[8...])
        guard CRC.crc16(t) == crcField else { return .failure(.crcMismatch) }
        guard let body = FunDoBody.decode(t) else { return .failure(.badBody) }
        return .success(FunDoFrame(direction: direction, seq: seq, body: body))
    }
}

/// Známé moduly/příkazy — jen ty, co jsou ověřené v F10/F14, viz README.
enum FunDoCommand {
    /// modul 0x05, typ 0x00, cmd 0x50, bez dat. Ověřeno na hodinkách (F10).
    static let vibraceModul: UInt8 = 0x05
    static let vibraceTyp: UInt8 = 0x00
    static let vibraceCmd: UInt8 = 0x50

    /// modul 0x04, typ 0x00, cmd 0x40 → odpověď cmd 0x41, data[0] = % (F10).
    static let bateryModul: UInt8 = 0x04
    static let bateryTyp: UInt8 = 0x00
    static let bateryCmdDotaz: UInt8 = 0x40
    static let bateryCmdOdpoved: UInt8 = 0x41

    /// modul 0x01, typ 0x01 — přenos souboru ciferníku (F13).
    static let souborModul: UInt8 = 0x01
    static let souborTyp: UInt8 = 0x01
    static let souborZahajeni: UInt8 = 0xC0
    static let souborBlok: UInt8 = 0xC2
    static let souborPotvrzeni: UInt8 = 0xC3
    static let souborZakonceni: UInt8 = 0xC5

    // MARK: - Sloty ciferníku — ⚠️ NEOVĚŘENO, viz README „Dva sloty ciferníku"

    /// F16-cizi-reseni.md cituje cizí rozbor (05-status-and-todo.md,
    /// vietnamsky): „đổi mặt đồng hồ (4/78-79)" = „změna ciferníku, modul 4,
    /// cmd 78–79". Přesný payload nikde stažený (`RequestBuilder.java`
    /// s vysokoúrovňovým API není v `cizi/make-watcher-alive/` k dispozici,
    /// jen název fičury a dvojice čísel příkazů) — čísla **jsou** z cizího
    /// zdroje, ale který dělá co (dotaz vs. zápis) a jaký má payload, je
    /// **odhad**, ne ověřený fakt.
    static let ciferníkModul: UInt8 = 0x04
    static let ciferníkTypDotaz: UInt8 = 0x00
    static let ciferníkTypZapis: UInt8 = 0x01

    /// ODHAD: „seznam ciferníků" / „stav ciferníku" — F5 zmiňuje čtyři
    /// samostatné operace (kompatibilita, seznam, stav, nastavit použitý),
    /// ale cizí zdroj dává jen dvě čísla (78, 79) pro „změnu ciferníku"
    /// jako celek. Bez druhého odposlechu nejde rozlišit, jestli 0x4E je
    /// „seznam" nebo „stav" — appka posílá tenhle příkaz pro OBOJÍ a nechává
    /// syrovou odpověď zobrazit v UI/logu k ruční inspekci (žádný parser,
    /// dokud formát není známý).
    static let ciferníkDotazCmd: UInt8 = 0x4E // 78

    /// ODHAD: „nastavit použitý ciferník" (přepnutí slotu). Payload podle
    /// nás = 1 bajt dialId — ale `CustomClockDialItem.dialId` je v Javě
    /// `int` (4 B), takže drátový formát může být širší. Dokud se neověří
    /// na hodinkách, appka posílá 1 bajt a chybu (žádnou odpověď/timeout)
    /// ošetřuje jako nefatální.
    static let ciferníkPrepnoutCmd: UInt8 = 0x4F // 79
}
