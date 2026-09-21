import Foundation

/// Posílá dávkově nové záznamy z `Log.sdilene` na URL z Nastavení („Log
/// server" — výchozí prázdné = neposílat), ať log appky vidí i Claude na
/// notebooku (Ondrova připomínka z F18: „proč tam nemáš nějaký log, ať to
/// vidíš" — potřeba i mimo appku, při ladění z počítače). Přijímač je
/// `ios/logserver/log_server.py`.
///
/// Posílá se každých ~5 s, nebo hned při zápisu chyby (`Log.zapis(.chyba)`
/// volá `odeslatIhned()` napřímo). Selhání je **tiché** — appka nezobrazí
/// žádnou hlášku, neblokuje UI, jen to zkusí znovu příště (fronta v `Log`
/// se maže až po úspěšném POSTu).
///
/// Formát: `POST <logserver>`, tělo
/// `{"zarizeni":"iPhone","cas":"ISO8601","zaznamy":[{"t":"ISO8601","u":"odeslano","z":"text"}]}`.
@MainActor
final class LogUploader {
    static let sdileny = LogUploader()

    /// Kolik záznamů nejvýš v jedné dávce (ať jeden POST nenaroste do MB,
    /// když appka dlouho neměla spojení).
    private let davkaLimit = 200

    private var smycka: Task<Void, Never>?
    private var odesilaPrave = false

    private static let isoFormat: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private init() {}

    /// Zavolat jednou při startu appky — spustí periodickou smyčku (~5 s).
    func spustSmycku() {
        guard smycka == nil else { return }
        smycka = Task { [weak self] in
            while !Task.isCancelled {
                await self?.odeslatIhned()
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    /// Odešle aktuální frontu (pokud je co a je nastavená URL). Bezpečné
    /// volat i souběžně (např. z `Log.zapis(.chyba)` i z periodické smyčky
    /// najednou) — druhé volání se tiše přeskočí.
    func odeslatIhned() async {
        guard !odesilaPrave else { return }
        let urlText = Nastaveni.shared.logServerURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !urlText.isEmpty, let url = URL(string: urlText) else { return }
        let davka = Log.sdilene.nahledFronty(limit: davkaLimit)
        guard !davka.isEmpty else { return }

        odesilaPrave = true
        defer { odesilaPrave = false }

        let zaznamy = davka.map { z in
            ["t": Self.isoFormat.string(from: z.cas), "u": z.uroven.rawValue, "z": z.text]
        }
        let telo: [String: Any] = [
            "zarizeni": "iPhone",
            "cas": Self.isoFormat.string(from: Date()),
            "zaznamy": zaznamy,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: telo) else { return }

        var req = URLRequest(url: url, timeoutInterval: 8)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = data

        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                Log.sdilene.potvrdOdeslani(pocet: davka.count)
            }
            // Jiný stavový kód → tiše necháme frontu, zkusí se znovu příště.
        } catch {
            // Bez spojení / timeout → tiše necháme frontu, zkusí se znovu příště.
        }
    }
}
