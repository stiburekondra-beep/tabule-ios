import Foundation
import WebKit

/// JavaScript most mezi cockpitem (WKWebView) a nativní appkou.
///
/// Handler se jmenuje **`hodinky`**. Cockpit volá:
/// ```js
/// window.webkit.messageHandlers.hodinky.postMessage({akce: "tabule", sessions: [...]})
/// window.webkit.messageHandlers.hodinky.postMessage({akce: "vibrace"})
/// window.webkit.messageHandlers.hodinky.postMessage({akce: "zelena"})
/// window.webkit.messageHandlers.hodinky.postMessage({akce: "stav"})
/// ```
/// `sessions` u akce `tabule` je pole objektů `{title, summary, status, waiting}`
/// (stejný tvar jako `/api/sessions` z Hubu).
///
/// Appka odpovídá voláním JS funkcí v cockpitu (když existují):
/// ```js
/// window.hodinkyStav({pripojeno, nazev, baterie, prenosProbiha, prubeh, prubehText,
///                      posledniChyba, setrit, jinaHudbaHraje})
/// window.hodinkyTlacitko('ANO' | 'NE' | 'POKRAČUJ' | 'POZDĚJI')
/// ```
@MainActor
final class WebBridge: NSObject, WKScriptMessageHandler {
    static let nazevHandleru = "hodinky"

    let sluzba: TabuleService
    weak var webView: WKWebView?

    init(sluzba: TabuleService) {
        self.sluzba = sluzba
        super.init()
        sluzba.naStiskTlacitka = { [weak self] akce in self?.oznamStisk(akce) }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == Self.nazevHandleru else { return }
        guard let telo = message.body as? [String: Any], let akce = telo["akce"] as? String else { return }
        switch akce {
        case "tabule":
            let sessions = Self.dekodujSessions(telo["sessions"])
            Task { await sluzba.poslatTabuli(TabuleObsah(bezSpojeni: false, sessions: sessions)) ; oznamStav() }
        case "vibrace":
            Task { await sluzba.poslatVibraci(); oznamStav() }
        case "zelena":
            Task { await sluzba.poslatZelenou(); oznamStav() }
        case "stav":
            oznamStav()
        default:
            break
        }
    }

    private static func dekodujSessions(_ raw: Any?) -> [TabuleSession] {
        guard let pole = raw else { return [] }
        guard JSONSerialization.isValidJSONObject(["x": pole]) || pole is [Any] else { return [] }
        guard let data = try? JSONSerialization.data(withJSONObject: pole) else { return [] }
        return (try? JSONDecoder().decode([TabuleSession].self, from: data)) ?? []
    }

    /// Pošle aktuální stav appky do cockpitu (`window.hodinkyStav(...)`).
    func oznamStav() {
        var stavDict: [String: Any] = [
            "prenosProbiha": sluzba.probihaPrenos,
            "prubeh": sluzba.prubeh,
            "prubehText": sluzba.prubehText,
            "setrit": Nastaveni.shared.setrit,
            "jinaHudbaHraje": sluzba.jinaHudbaHraje,
            "posledniSlotCiferniku": Nastaveni.shared.posledniNahranySlot,
        ]
        switch sluzba.ble.stav {
        case .pripojeno(let nazev):
            stavDict["pripojeno"] = true
            stavDict["nazev"] = nazev
        default:
            stavDict["pripojeno"] = false
        }
        if let bat = sluzba.ble.bateriePct { stavDict["baterie"] = bat }
        if let chyba = sluzba.posledniChyba { stavDict["posledniChyba"] = chyba }

        guard let data = try? JSONSerialization.data(withJSONObject: stavDict),
              let json = String(data: data, encoding: .utf8) else { return }
        volejJS("window.hodinkyStav && window.hodinkyStav(\(json))")
    }

    /// Pošle stisk tlačítka z hodinek do cockpitu (`window.hodinkyTlacitko(...)`).
    private func oznamStisk(_ akce: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: [akce]),
              let json = String(data: data, encoding: .utf8)?.dropFirst().dropLast() else { return }
        volejJS("window.hodinkyTlacitko && window.hodinkyTlacitko(\(json))")
    }

    private func volejJS(_ js: String) {
        webView?.evaluateJavaScript(js, completionHandler: nil)
    }
}
