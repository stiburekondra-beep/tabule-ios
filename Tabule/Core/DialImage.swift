import CoreGraphics
import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Rozměry tabule (F7-format-obrazku.md).
enum DialGeometry {
    static let sirka = 240
    static let vyska = 286
}

/// Převod obrázku na formát bodu, který čekají hodinky.
enum RGB565 {
    /// RGBA8888 (4 B/bod, jak ho vrátí CGContext) → RGB565 **big-endian**
    /// (2 B/bod). Ověřeno testovacím obrazcem červená/modrá, F7 doplněk.
    static func zeRGBA(_ rgba: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: (rgba.count / 4) * 2)
        var j = 0
        var i = 0
        while i + 3 < rgba.count {
            let r = rgba[i], g = rgba[i + 1], b = rgba[i + 2]
            let v: UInt16 = (UInt16(r & 0xF8) << 8) | (UInt16(g & 0xFC) << 3) | UInt16(b >> 3)
            out[j] = UInt8((v >> 8) & 0xFF)
            out[j + 1] = UInt8(v & 0xFF)
            i += 4
            j += 2
        }
        return out
    }

    /// Celá plocha jednou barvou RGB565 (big-endian). Zelená 0x07E0 pro
    /// „Zkoušku: zelená".
    static func plna(_ hodnota: UInt16, pocetBodu: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: pocetBodu * 2)
        let hi = UInt8((hodnota >> 8) & 0xFF)
        let lo = UInt8(hodnota & 0xFF)
        for i in stride(from: 0, to: out.count, by: 2) {
            out[i] = hi
            out[i + 1] = lo
        }
        return out
    }

    static let zelena: UInt16 = 0x07E0

    #if canImport(UIKit)
    /// Převede libovolný `UIImage` (např. z fotek) na RGB565 BE bajty
    /// tabule (240×286) — ořízne na výplň (aspect-fill), vystředěné.
    /// Stejné vykreslovací parametry jako `DialRenderer` (RGBA8888,
    /// premultipliedLast), ať jde bajty rovnou přes `zeRGBA`.
    static func zObrazku(_ image: UIImage) -> [UInt8] {
        let w = DialGeometry.sirka, h = DialGeometry.vyska
        let pocetBodu = w * h
        guard let cgImage = image.cgImage else {
            return plna(0, pocetBodu: pocetBodu) // černá — obrázek se nepodařilo přečíst
        }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var buffer = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(
            data: &buffer, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return plna(0, pocetBodu: pocetBodu)
        }
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        let imgW = CGFloat(cgImage.width), imgH = CGFloat(cgImage.height)
        guard imgW > 0, imgH > 0 else { return plna(0, pocetBodu: pocetBodu) }
        let meritko = max(CGFloat(w) / imgW, CGFloat(h) / imgH)
        let kresliW = imgW * meritko, kresliH = imgH * meritko
        let x = (CGFloat(w) - kresliW) / 2
        let y = (CGFloat(h) - kresliH) / 2
        ctx.draw(cgImage, in: CGRect(x: x, y: y, width: kresliW, height: kresliH))
        return zeRGBA(buffer)
    }
    #endif
}

/// Sestavení souboru ciferníku ze šablony — 1:1 podle `web/tabule.html`
/// a receptu v `F13-prenos-souboru.md`.
enum DialFile {
    enum Chyba: Error {
        case sablonaChybi
        case sablonaProKratka
    }

    /// Vloží obrazová data (RGB565 BE) do šablony od offsetu 100 a přepočítá
    /// CRC32 (zlib/IEEE) z bajtů `[21:]` do konce, zapsané little-endian
    /// do `[8:12]`. Vrátí kompletní bajty souboru, připravené k přenosu.
    static func sestav(sablona: [UInt8], obrazData: [UInt8]) -> [UInt8] {
        var s = sablona
        let volneMisto = max(0, s.count - 100)
        let kolikVlozit = min(obrazData.count, volneMisto)
        if kolikVlozit > 0 {
            s.replaceSubrange(100..<(100 + kolikVlozit), with: obrazData[0..<kolikVlozit])
        }
        let crc = CRC.crc32(s[21...])
        s[8] = UInt8(crc & 0xFF)
        s[9] = UInt8((crc >> 8) & 0xFF)
        s[10] = UInt8((crc >> 16) & 0xFF)
        s[11] = UInt8((crc >> 24) & 0xFF)
        return s
    }

    /// Načte šablonu `cifernik_bily.bin` z dané bundle appky (výchozí
    /// `Bundle.main`; testy si mohou předat vlastní bundle s kopií souboru).
    static func nactiSablonu(bundle: Bundle = .main) throws -> [UInt8] {
        guard let url = bundle.url(forResource: "cifernik_bily", withExtension: "bin") else {
            throw Chyba.sablonaChybi
        }
        let data = try Data(contentsOf: url)
        guard data.count > 100 else { throw Chyba.sablonaProKratka }
        return [UInt8](data)
    }
}
