import Foundation

/// HTTP klient k Žán Hubu — `GET /api/sessions` a `POST /api/smer`
/// (formát podle `projects/baklazan/zan-hub/hub/hub.py`, řádek ~951 a
/// ~1155). URL i token se čtou z `Nastaveni` (UserDefaults), nikde
/// natvrdo. Neblokuje UI — volá se z Tasku, výsledek přijde přes async/await.
struct HubClient {
    var baseURL: String
    var token: String

    enum Chyba: Error, LocalizedError {
        case spatnaURL
        case httpChyba(Int)
        case bezSpojeni(Error)

        var errorDescription: String? {
            switch self {
            case .spatnaURL: return "neplatná URL Hubu"
            case .httpChyba(let kod): return "Hub odpověděl HTTP \(kod)"
            case .bezSpojeni(let e): return "bez spojení (\(e.localizedDescription))"
            }
        }
    }

    /// `GET {baseURL}/api/sessions` s `Authorization: Bearer <token>`.
    /// Vrací pole sessions přes pole `title`, `summary`, `status`, `waiting`.
    func nactiSessions() async throws -> [TabuleSession] {
        guard var comps = URLComponents(string: baseURL.trimmingCharacters(in: .init(charactersIn: "/"))) else {
            throw Chyba.spatnaURL
        }
        comps.path += "/api/sessions"
        guard let url = comps.url else { throw Chyba.spatnaURL }
        var req = URLRequest(url: url, timeoutInterval: 8)
        if !token.isEmpty {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let kod = (resp as? HTTPURLResponse)?.statusCode ?? -1
                throw Chyba.httpChyba(kod)
            }
            return try JSONDecoder().decode([TabuleSession].self, from: data)
        } catch let e as Chyba {
            throw e
        } catch {
            throw Chyba.bezSpojeni(error)
        }
    }

    /// `GET {baseURL}/api/poll?machine=<jméno>&wait=<s>` — long-poll (`hub.py`
    /// `_poll`, ~řádek 1094). Zaregistruje appku jako „bridge stroj" (jako
    /// zan-bot, viz docstring `_poll`: „kanál session, nebo bridge stroje
    /// (machine=)") a čeká na Hubu až `waitS` sekund (server ho stejně
    /// ořízne na 50 s), než odpoví — buď s frontou příkazů pro tenhle
    /// stroj, nebo prázdně po timeoutu. Appka obsah příkazů nevyužívá,
    /// jen samotné vrácení/timeout jako „probuď se a mrkni na sessions" —
    /// **odhad použití, neověřeno**, `_poll` je psaný primárně pro doručování
    /// příkazů konkrétnímu cíli, ne jako obecný „něco se změnilo" kanál.
    /// Díky tomu appka drží jedno visící spojení místo pollingu po pár
    /// sekundách — rádio (Wi-Fi/mobil) mezi tím spí.
    func dlouhyPoll(machine: String, waitS: Double) async throws {
        guard var comps = URLComponents(string: baseURL.trimmingCharacters(in: .init(charactersIn: "/"))) else {
            throw Chyba.spatnaURL
        }
        comps.path += "/api/poll"
        comps.queryItems = [
            URLQueryItem(name: "machine", value: machine),
            URLQueryItem(name: "wait", value: String(Int(waitS))),
        ]
        guard let url = comps.url else { throw Chyba.spatnaURL }
        // Timeout požadavku musí být delší než `wait`, ať ho neuřízne dřív než Hub.
        var req = URLRequest(url: url, timeoutInterval: waitS + 15)
        if !token.isEmpty {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let kod = (resp as? HTTPURLResponse)?.statusCode ?? -1
                throw Chyba.httpChyba(kod)
            }
        } catch let e as Chyba {
            throw e
        } catch {
            throw Chyba.bezSpojeni(error)
        }
    }

    /// `POST {baseURL}/api/smer`, tělo `{"text": "...", "zdroj": "hodinky"}`.
    ///
    /// POZNÁMKA (neověřeno, viz README): `/api/smer` v `hub.py` (řádek
    /// ~1155) jen ROZHODUJE, kam by zpráva patřila (vrací `{cil, jistota,
    /// label, zan}`) — nenašel jsem v `hub.py` navazující krok, který by
    /// text i doručil (to typicky dělá `/api/events` s `role: reply`,
    /// který volá jiný klient, ne hodinky). Než se ověří skutečné doručovací
    /// API, posílá se sem podle zadání aspoň `{"text":..., "zdroj":"hodinky"}`
    /// — routing se spočítá, ale samotné doručení zprávy nejspíš (zatím)
    /// nikam nedojde. Nutno ověřit na běžícím Hubu.
    @discardableResult
    func posliSmer(text: String) async throws -> Data {
        guard var comps = URLComponents(string: baseURL.trimmingCharacters(in: .init(charactersIn: "/"))) else {
            throw Chyba.spatnaURL
        }
        comps.path += "/api/smer"
        guard let url = comps.url else { throw Chyba.spatnaURL }
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !token.isEmpty {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let telo: [String: String] = ["text": text, "zdroj": "hodinky"]
        req.httpBody = try JSONSerialization.data(withJSONObject: telo)
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let kod = (resp as? HTTPURLResponse)?.statusCode ?? -1
                throw Chyba.httpChyba(kod)
            }
            return data
        } catch let e as Chyba {
            throw e
        } catch {
            throw Chyba.bezSpojeni(error)
        }
    }
}
