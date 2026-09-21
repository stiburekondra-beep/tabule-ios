import Foundation

/// Diagnostický log appky — kruhový buffer posledních 500 záznamů.
///
/// Vznikl kvůli Ondrově připomínce z ostrého běhu (F18): *„proč tam nemáš
/// nějaký log, ať to vidíš"* — appka dřív ukazovala jen poslední stav, co
/// proběhlo a zmizelo, nešlo dohledat. Loguje se sem BLE (stav, sken,
/// nalezeno, připojeno/odpojeno + důvod), každý odeslaný i přijatý rámec
/// v hexu, párování odpovědí podle seq, průběh přenosu souboru, HTTP
/// dotazy na Hub, chyby WebView (i URL, na kterou se sahalo) a stisky
/// tlačítek z přehrávače.
///
/// Vidět je jak v appce (rolovací sekce `App/LogView.swift` na hlavní i
/// nouzové obrazovce), tak na notebooku přes `LogUploader` →
/// `ios/logserver/log_server.py`.
@MainActor
final class Log: ObservableObject {
    static let sdilene = Log()

    enum Uroven: String, Codable {
        case info, odeslano, prijato, chyba
    }

    struct Zaznam: Identifiable {
        let id = UUID()
        let cas: Date
        let uroven: Uroven
        let text: String

        /// Jeden řádek pro zobrazení v appce — `HH:mm:ss.SSS  UROVEN  text`.
        var zformatovano: String {
            "\(Self.casFormat.string(from: cas))  \(uroven.rawValue.uppercased())  \(text)"
        }

        private static let casFormat: DateFormatter = {
            let f = DateFormatter()
            f.dateFormat = "HH:mm:ss.SSS"
            f.locale = Locale(identifier: "en_US_POSIX")
            return f
        }()
    }

    private static let maxZaznamu = 500
    /// Fronta k odeslání na server (`LogUploader`) — oddělená od `zaznamy`,
    /// ať odesílání nezávisí na tom, kolik toho appka právě zobrazuje.
    /// Omezena taky, ať při dlouhodobě nedostupném serveru neroste bez konce.
    private static let maxFronta = 1000

    /// Co appka aktuálně ukazuje v UI (kruhový buffer, nejnovější na konci).
    @Published private(set) var zaznamy: [Zaznam] = []
    private var fronta: [Zaznam] = []

    private init() {}

    func zapis(_ uroven: Uroven, _ text: String) {
        let z = Zaznam(cas: Date(), uroven: uroven, text: text)
        zaznamy.append(z)
        if zaznamy.count > Self.maxZaznamu {
            zaznamy.removeFirst(zaznamy.count - Self.maxZaznamu)
        }
        fronta.append(z)
        if fronta.count > Self.maxFronta {
            fronta.removeFirst(fronta.count - Self.maxFronta)
        }
        if uroven == .chyba {
            // Chyba se posílá na server hned, ne až za ~5 s (LogUploader).
            Task { await LogUploader.sdileny.odeslatIhned() }
        }
    }

    /// Nahlédne do fronty k odeslání (nemaže) — `LogUploader` po úspěšném
    /// POSTu zavolá `potvrdOdeslani`, aby se odeslané záznamy odstranily.
    func nahledFronty(limit: Int) -> [Zaznam] {
        Array(fronta.prefix(limit))
    }

    func potvrdOdeslani(pocet: Int) {
        fronta.removeFirst(min(pocet, fronta.count))
    }

    /// Celý viditelný log jako text — pro tlačítko „Kopírovat".
    var jakoText: String {
        zaznamy.map(\.zformatovano).joined(separator: "\n")
    }
}

extension Array where Element == UInt8 {
    /// Hex dump `ba 21 00 05 …` pro logování rámců.
    var hexPopis: String {
        map { String(format: "%02x", $0) }.joined(separator: " ")
    }
}
