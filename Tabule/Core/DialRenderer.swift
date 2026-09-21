import CoreGraphics
import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Vykreslí obsah tabule (240×286) přes CoreGraphics a převede na
/// bajty RGB565 big-endian připravené k vložení do šablony ciferníku.
///
/// Layout kopíruje náhled z `web/tabule.html`: čas nahoře, „ČEKAJÍ NA TEBE",
/// velké číslo, 2–3 řádky sessions (název + krátká věta), dole „běží
/// dalších N". Když appka nemá spojení s Hubem, ukáže „bez spojení"
/// (F15-chovani-tabule.md, bod 5 zadání).
enum DialRenderer {

    /// Vykreslí obsah a vrátí RGB565 BE bajty (240×286×2 B), připravené
    /// pro `DialFile.sestav(sablona:obrazData:)`.
    static func vykresliRGB565(_ obsah: TabuleObsah, cas: Date = Date()) -> [UInt8] {
        let rgba = vykresliRGBA(obsah, cas: cas)
        return RGB565.zeRGBA(rgba)
    }

    /// Vykreslí obsah a vrátí syrová RGBA8888 data (pro náhled v UI).
    static func vykresliRGBA(_ obsah: TabuleObsah, cas: Date = Date()) -> [UInt8] {
        let w = DialGeometry.sirka, h = DialGeometry.vyska
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var buffer = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(
            data: &buffer, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return buffer
        }
        // CoreGraphics má počátek dole vlevo — otočíme, ať (0,0) je vlevo nahoře jako v návrhu.
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)

        // Pozadí — černá (jako v referenčním náhledu).
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))

        #if canImport(UIKit)
        UIGraphicsPushContext(ctx)
        defer { UIGraphicsPopContext() }

        let df = DateFormatter()
        df.dateFormat = "HH:mm"
        let casText = df.string(from: cas)

        func kresli(_ text: String, x: CGFloat, y: CGFloat, size: CGFloat, bold: Bool, color: UIColor) {
            let font = bold ? UIFont.boldSystemFont(ofSize: size) : UIFont.systemFont(ofSize: size)
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            (text as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: attrs)
        }

        if obsah.bezSpojeni {
            kresli(casText, x: 14, y: 20, size: 26, bold: true, color: .white)
            kresli("BEZ SPOJENÍ", x: 14, y: 130, size: 18, bold: true, color: UIColor(red: 1, green: 0.42, blue: 0.42, alpha: 1))
            kresli("Hub nedostupný", x: 14, y: 160, size: 14, bold: false, color: UIColor(white: 0.6, alpha: 1))
        } else {
            kresli(casText, x: 14, y: 18, size: 26, bold: true, color: .white)
            kresli("ČEKAJÍ NA TEBE", x: 14, y: 68, size: 15, bold: true, color: UIColor(red: 1, green: 0.7, blue: 0.25, alpha: 1))
            kresli("\(obsah.cekajici.count)", x: 14, y: 92, size: 44, bold: true, color: .white)

            var y: CGFloat = 148
            for s in obsah.cekajici.prefix(3) {
                let veta = zkrat(s.summary ?? s.status, na: 24)
                kresli("\(zkrat(s.title, na: 10))  \(veta)", x: 14, y: y, size: 14, bold: false, color: .white)
                y += 26
            }
            kresli("běží dalších \(obsah.bezicichDalsich)", x: 14, y: h.cgFloat - 34, size: 12, bold: false, color: UIColor(white: 0.55, alpha: 1))
        }
        #endif

        return buffer
    }

    private static func zkrat(_ s: String, na n: Int) -> String {
        s.count > n ? String(s.prefix(n - 1)) + "…" : s
    }

    #if canImport(UIKit)
    /// Náhled pro SwiftUI (nouzová obrazovka i informativní preview v cockpitu).
    static func nahledUIImage(_ obsah: TabuleObsah, cas: Date = Date()) -> UIImage? {
        let w = DialGeometry.sirka, h = DialGeometry.vyska
        var buffer = vykresliRGBA(obsah, cas: cas)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &buffer, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let cgImage = ctx.makeImage() else { return nil }
        return UIImage(cgImage: cgImage)
    }
    #endif
}

private extension Int {
    var cgFloat: CGFloat { CGFloat(self) }
}
