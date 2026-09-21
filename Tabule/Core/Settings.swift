import Foundation

/// Nastavení appky — URL Hubu, token a URL cockpitu. Žádné tajemství není
/// natvrdo v kódu, všechno jde do UserDefaults (zadání: „Žádná tajemství
/// v kódu"). Výchozí hodnoty jsou prázdné/neutrální, Ondra si je vyplní
/// v panelu Nastavení.
@MainActor
final class Nastaveni: ObservableObject {
    static let shared = Nastaveni()

    private enum Klic {
        static let hubURL = "hubURL"
        static let hubToken = "hubToken"
        static let cockpitURL = "cockpitURL"
        static let setrit = "rezimSetrit"
        static let posledniSlot = "posledniNahranySlotCiferniku"
    }

    @Published var hubURL: String {
        didSet { UserDefaults.standard.set(hubURL, forKey: Klic.hubURL) }
    }
    @Published var hubToken: String {
        didSet { UserDefaults.standard.set(hubToken, forKey: Klic.hubToken) }
    }
    /// URL cockpitu, který se načítá do WKWebView. Prázdné ve výchozím
    /// stavu — appka pak rovnou ukáže nouzovou obrazovku. Ondrova hodnota
    /// (např. `https://<tvuj-cockpit>/`) se sem zadává v appce,
    /// ne v kódu.
    @Published var cockpitURL: String {
        didSet { UserDefaults.standard.set(cockpitURL, forKey: Klic.cockpitURL) }
    }

    /// Režim „Šetřit" (Ondra, doplnění kvůli baterii): vypne tichou audio
    /// session (tedy i tlačítka z hodinek přes MPRemoteCommandCenter) a
    /// long-poll na Hub. Appka se pak probouzí jen z BLE notify od hodinek
    /// (~20 s) a v tu chvíli udělá jeden GET na Hub. Viz README, sekce
    /// „Baterie a dva režimy".
    @Published var setrit: Bool {
        didSet { UserDefaults.standard.set(setrit, forKey: Klic.setrit) }
    }

    /// Slot (0/1), do kterého appka naposledy nahrála a přepnula ciferník
    /// — **odhad/domněnka appky**, ne fakt ověřený dotazem na hodinky
    /// (dotaz existuje, `BLEManager.dotazNaCifernikSeznamNeboStav`, ale
    /// appka jeho odpověď neumí rozebrat, viz README „Dva sloty
    /// ciferníku"). `-1` = appka ještě nikdy nenahrávala / neví.
    @Published var posledniNahranySlot: Int {
        didSet { UserDefaults.standard.set(posledniNahranySlot, forKey: Klic.posledniSlot) }
    }

    private init() {
        let d = UserDefaults.standard
        hubURL = d.string(forKey: Klic.hubURL) ?? ""
        hubToken = d.string(forKey: Klic.hubToken) ?? ""
        cockpitURL = d.string(forKey: Klic.cockpitURL) ?? ""
        setrit = d.bool(forKey: Klic.setrit)
        posledniNahranySlot = d.object(forKey: Klic.posledniSlot) != nil ? d.integer(forKey: Klic.posledniSlot) : -1
    }
}
