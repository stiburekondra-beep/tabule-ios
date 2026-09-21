import Foundation

/// Kontrolní součty používané protokolem FunDo (Niceboy Watch 5 Lite).
///
/// Zdroj pravdy: `F6-fundo-ramec.md` (CRC16, opraveno v `F16-cizi-reseni.md`)
/// a `F13-prenos-souboru.md` (CRC32 souboru ciferníku). Referenční
/// implementace v JavaScriptu je `web/tabule.html` — tenhle soubor je její
/// 1:1 přepis do Swiftu.
enum CRC {

    /// CRC16/CCITT-FALSE — polynom 0x1021, init 0xFFFF, bez reflexe, xorout 0.
    /// Počítá se z těla rámce (kategorie…data), NE z vnější hlavičky.
    /// Ověřeno byte-exaktně na `ba 21 00 05 6c 95 08 f0 05 00 50 00 00` (F10).
    static func crc16(_ data: [UInt8]) -> UInt16 {
        var c: UInt32 = 0xFFFF
        for b in data {
            c ^= UInt32(b) << 8
            for _ in 0..<8 {
                if c & 0x8000 != 0 {
                    c = ((c << 1) ^ 0x1021) & 0xFFFF
                } else {
                    c = (c << 1) & 0xFFFF
                }
            }
        }
        return UInt16(c)
    }

    /// CRC32 (zlib/IEEE 802.3), poly 0xEDB88320, init/xorout 0xFFFFFFFF.
    /// Používá se pro kontrolní hodnotu souboru ciferníku (F13), počítá se
    /// z bajtů `[21:]` souboru a ukládá little-endian do `[8:12]`.
    static let crc32Table: [UInt32] = {
        var table = [UInt32](repeating: 0, count: 256)
        for n in 0..<256 {
            var c = UInt32(n)
            for _ in 0..<8 {
                c = (c & 1 != 0) ? (0xEDB88320 ^ (c >> 1)) : (c >> 1)
            }
            table[n] = c
        }
        return table
    }()

    static func crc32(_ data: some Sequence<UInt8>) -> UInt32 {
        var c: UInt32 = 0xFFFFFFFF
        for b in data {
            let idx = Int((c ^ UInt32(b)) & 0xFF)
            c = crc32Table[idx] ^ (c >> 8)
        }
        return c ^ 0xFFFFFFFF
    }
}
