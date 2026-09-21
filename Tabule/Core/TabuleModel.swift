import Foundation

/// Jedna session z Hubu (nebo z cockpitu přes WebBridge), tak jak ji
/// tabule potřebuje zobrazit. Pole odpovídají `/api/sessions` (viz
/// `hub.py` kolem řádku 951 — `title`, `summary`, `status`, `waiting`).
struct TabuleSession: Codable, Equatable, Identifiable {
    var id: String { title + status }
    var title: String
    var summary: String?
    var status: String
    var waiting: Bool

    enum CodingKeys: String, CodingKey {
        case title, summary, status, waiting
    }

    init(title: String, summary: String? = nil, status: String = "", waiting: Bool = false) {
        self.title = title
        self.summary = summary
        self.status = status
        self.waiting = waiting
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = (try? c.decode(String.self, forKey: .title)) ?? "?"
        summary = try? c.decode(String.self, forKey: .summary)
        status = (try? c.decode(String.self, forKey: .status)) ?? ""
        if let b = try? c.decode(Bool.self, forKey: .waiting) {
            waiting = b
        } else if let i = try? c.decode(Int.self, forKey: .waiting) {
            waiting = i != 0
        } else {
            waiting = false
        }
    }
}

/// Obsah, který se má nakreslit na tabuli — buď „bez spojení", nebo přehled
/// čekajících/běžících sessions (F15-chovani-tabule.md).
struct TabuleObsah: Equatable {
    var bezSpojeni: Bool
    var sessions: [TabuleSession]

    /// Sessions, na které Ondra čeká (waiting=true) — jdou nahoru na tabuli.
    var cekajici: [TabuleSession] { sessions.filter { $0.waiting } }
    /// Zbytek, co běží dál na pozadí.
    var bezicichDalsich: Int { max(0, sessions.count - cekajici.count) }

    static let prazdny = TabuleObsah(bezSpojeni: false, sessions: [])
    static let bezSpojeniStav = TabuleObsah(bezSpojeni: true, sessions: [])
}
