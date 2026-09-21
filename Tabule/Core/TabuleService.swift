import Foundation

/// Centrální logika appky — spojuje BLE, vykreslení tabule, přenos souboru
/// a dotazy na Hub. Používá ji jak nouzová SwiftUI obrazovka, tak
/// `WebBridge` (most do WKWebView s cockpitem) a probouzecí smyčka.
@MainActor
final class TabuleService: ObservableObject {
    let ble: BLEManager

    @Published private(set) var probihaPrenos = false
    @Published private(set) var prubeh: Double = 0
    @Published private(set) var prubehText = ""
    @Published private(set) var posledniObsah: TabuleObsah = .prazdny
    @Published private(set) var posledniChyba: String?
    /// `true`, když jiná appka (Spotify apod.) právě hraje a AVRCP tlačítka
    /// z hodinek dostává ona, ne Tabule (doplněk k zadání, viz
    /// `NowPlayingController`). Neplatí v režimu „Šetřit" — tam appka
    /// o vzdálené ovládání vůbec nežádá.
    @Published private(set) var jinaHudbaHraje = false

    /// Zavolá se po každém úspěšném stisku tlačítka z hodinek (přes
    /// NowPlayingController) — ANO/NE/POKRAČUJ/POZDĚJI — ať to WebBridge
    /// může předat do cockpitu.
    var naStiskTlacitka: ((String) -> Void)?

    private var znameCekajiciNazvy: Set<String> = []
    private var posledniKontrolaHubu: Date = .distantPast
    private let minIntervalKontrolyS: TimeInterval = 20
    private var dlouhyPollTask: Task<Void, Never>?
    /// Jméno, pod kterým se appka hlásí Hubu v `/api/poll?machine=`
    /// (stejný mechanismus jako bridge stroje typu zan-bot). Natvrdo, není
    /// to tajemství — jen identifikátor kanálu.
    private static let jmenoStroje = "hodinky"

    init(ble: BLEManager) {
        self.ble = ble
        ble.naNotifikaci = { [weak self] in self?.probuditPriNotifikaci() }
        NowPlayingController.shared.naZmenuJinehoZvuku = { [weak self] hraje in self?.jinaHudbaHraje = hraje }
        // Stisk z MPRemoteCommandCenter (play/previous/next/pause) → zpracujStiskTlacitka
        // → POST /api/smer na Hub + naStiskTlacitka (WebBridge → cockpit).
        NowPlayingController.shared.naStisk = { [weak self] akce in self?.zpracujStiskTlacitka(akce) }
    }

    // MARK: - Připojení

    func pripojit() {
        ble.hledejAPripoj()
    }

    // MARK: - Režim „Normální" / „Šetřit" (baterie)

    /// Zavolat po startu appky a po každé změně `Nastaveni.setrit`.
    /// **Normální režim:** tichý zvuk + MPRemoteCommandCenter (tlačítka
    /// z hodinek fungují) + dlouhý poll na Hub (`/api/poll`, probouzí se
    /// z reakce Hubu, ne z pravidelného GETu).
    /// **Šetřit:** obojí vypnuto — appka se probouzí jen z BLE notify
    /// hodinek (~20 s) a v tu chvíli udělá jeden lehký GET `/api/sessions`.
    /// Viz README „Baterie a dva režimy" (odhad spotřeby, neměřeno).
    func aktualizujRezim() {
        if Nastaveni.shared.setrit {
            Log.sdilene.zapis(.info, "režim: Šetřit — vypínám MPRemoteCommandCenter a dlouhý poll")
            NowPlayingController.shared.zastav()
            dlouhyPollTask?.cancel()
            dlouhyPollTask = nil
        } else {
            Log.sdilene.zapis(.info, "režim: Normální — zapínám MPRemoteCommandCenter a dlouhý poll")
            NowPlayingController.shared.nastavSePriStartu()
            guard dlouhyPollTask == nil else { return }
            dlouhyPollTask = Task { [weak self] in
                await self?.dlouhePollovaniSmycka()
            }
        }
    }

    /// Jedno visící spojení na `/api/poll` (server ho drží až 50 s), hned
    /// po odpovědi/timeoutu další — žádný krátký interval, rádio spí mezi
    /// tím. Při chybě (Hub nedostupný) ustoupí na obyčejný GET
    /// `/api/sessions` max 1× za 60 s, s exponenciálním čekáním (do 5 min).
    private func dlouhePollovaniSmycka() async {
        var cekaniPriChybeS: Double = 60
        while !Task.isCancelled {
            guard !Nastaveni.shared.setrit else { return }
            let n = Nastaveni.shared
            guard !n.hubURL.isEmpty else {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                continue
            }
            let hub = HubClient(baseURL: n.hubURL, token: n.hubToken)
            do {
                try await hub.dlouhyPoll(machine: Self.jmenoStroje, waitS: 45)
                cekaniPriChybeS = 60
                await zkontrolujHubAPripadneOznam()
            } catch {
                await zkontrolujHubAPripadneOznam()
                try? await Task.sleep(nanoseconds: UInt64(cekaniPriChybeS * 1_000_000_000))
                cekaniPriChybeS = min(cekaniPriChybeS * 2, 300)
            }
        }
    }

    // MARK: - Přímé akce (zadání, bod 3–4)

    func poslatVibraci() async {
        do {
            try await ble.vibrace()
            posledniChyba = nil
        } catch {
            posledniChyba = error.localizedDescription
        }
    }

    @discardableResult
    func nacistBaterii() async -> Int? {
        do {
            let pct = try await ble.nactiBaterii()
            posledniChyba = nil
            return pct
        } catch {
            posledniChyba = error.localizedDescription
            return nil
        }
    }

    func poslatZelenou() async {
        await odeslatObraz(RGB565.plna(RGB565.zelena, pocetBodu: DialGeometry.sirka * DialGeometry.vyska), popis: "zkouška: zelená")
    }

    /// Vykreslí a odešle tabuli podle dodaného obsahu (buď z Hubu, nebo
    /// od cockpitu přes WebBridge).
    func poslatTabuli(_ obsah: TabuleObsah) async {
        posledniObsah = obsah
        let rgb565 = DialRenderer.vykresliRGB565(obsah)
        await odeslatObraz(rgb565, popis: "tabule")
    }

    /// Stáhne sessions z Hubu (`GET /api/sessions`) a pošle tabuli. Když
    /// Hub nedostupný, pošle se „bez spojení" (zadání bod 5).
    func nacistZHubuAPoslat() async {
        let n = Nastaveni.shared
        guard !n.hubURL.isEmpty else {
            posledniChyba = "Hub není nastavený"
            Log.sdilene.zapis(.chyba, "nacistZHubuAPoslat: Hub není nastavený")
            await poslatTabuli(.bezSpojeniStav)
            return
        }
        let hub = HubClient(baseURL: n.hubURL, token: n.hubToken)
        do {
            let sessions = try await hub.nactiSessions()
            posledniChyba = nil
            await poslatTabuli(TabuleObsah(bezSpojeni: false, sessions: sessions))
        } catch {
            posledniChyba = error.localizedDescription
            await poslatTabuli(.bezSpojeniStav)
        }
    }

    private func odeslatObraz(_ rgb565: [UInt8], popis: String) async {
        probihaPrenos = true
        prubeh = 0
        prubehText = "\(popis): připravuji šablonu…"
        Log.sdilene.zapis(.info, "\(popis): start")
        defer { probihaPrenos = false }
        do {
            let sablona = try DialFile.nactiSablonu()
            let soubor = DialFile.sestav(sablona: sablona, obrazData: rgb565)
            // Dva sloty (⚠️ NEOVĚŘENO, viz README): střídáme, do kterého
            // slotu příště "nahrajeme" — appka jen POSÍLÁ tenhle slot dál
            // (`cilovySlot`), ale `posliSoubor` ho zatím nikam nezapisuje
            // (neznámý offset). Po nahrání se best-effort pošle "přepni
            // ciferník" na ten samý slot — nefatální, když neodpoví.
            let cil = UInt8((Nastaveni.shared.posledniNahranySlot + 1) & 1)
            try await ble.posliSoubor(soubor, cilovySlot: cil) { [weak self] p, text in
                self?.prubeh = p
                self?.prubehText = text
            }
            posledniChyba = nil
            Log.sdilene.zapis(.info, "\(popis): hotovo, přepínám na slot \(cil)")
            do {
                try await ble.prepniCifernik(dialId: cil)
                Nastaveni.shared.posledniNahranySlot = Int(cil)
            } catch {
                // Nefatální — "přepni ciferník" je odhad, hodinky ho možná
                // neznají nebo mlčí. Obrázek už je nahraný, jen se možná
                // nezobrazil samo (viz README).
                Log.sdilene.zapis(.chyba, "\(popis): přepnutí ciferníku selhalo (nefatální): \(error.localizedDescription)")
            }
        } catch {
            posledniChyba = error.localizedDescription
            Log.sdilene.zapis(.chyba, "\(popis): selhalo — \(error.localizedDescription)")
        }
    }

    // MARK: - Ruční ladění slotů ciferníku (⚠️ NEOVĚŘENO)

    /// Syrová odpověď na „seznam/stav ciferníků" jako hex string pro
    /// zobrazení v UI/logu — appka formát odpovědi nezná, neparsuje ho.
    func nactiSurovyStavCiferniku() async -> String {
        do {
            let data = try await ble.dotazNaCifernikSeznamNeboStav()
            return data.map { String(format: "%02x", $0) }.joined(separator: " ")
        } catch {
            return "chyba: \(error.localizedDescription)"
        }
    }

    // MARK: - Tlačítka z hodinek (přehrávač, zadání bod 6)

    /// Zavolá NowPlayingController po stisku play/pause/next/previous.
    /// Pošle POST na Hub `/api/smer` a předá akci dál (WebBridge → cockpit).
    func zpracujStiskTlacitka(_ akce: String) {
        Log.sdilene.zapis(.info, "zpracovávám stisk: \(akce)")
        naStiskTlacitka?(akce)
        let n = Nastaveni.shared
        guard !n.hubURL.isEmpty else { return }
        Task {
            let hub = HubClient(baseURL: n.hubURL, token: n.hubToken)
            try? await hub.posliSmer(text: akce)
        }
    }

    // MARK: - Probouzení (zadání bod 7)

    /// Volá se z BLE notify handleru (rámce chodí ~každých 20 s, F17).
    /// Hub se ptá max 1× za 20 s; při nové čekající session přegeneruje
    /// tabuli, nahraje a zavibruje.
    private func probuditPriNotifikaci() {
        let ted = Date()
        guard ted.timeIntervalSince(posledniKontrolaHubu) >= minIntervalKontrolyS else { return }
        posledniKontrolaHubu = ted
        Log.sdilene.zapis(.info, "probuzení z BLE notify — kontroluji Hub")
        Task { await zkontrolujHubAPripadneOznam() }
    }

    private func zkontrolujHubAPripadneOznam() async {
        let n = Nastaveni.shared
        guard !n.hubURL.isEmpty else { return }
        let hub = HubClient(baseURL: n.hubURL, token: n.hubToken)
        guard let sessions = try? await hub.nactiSessions() else { return }
        let cekajiciNazvy = Set(sessions.filter { $0.waiting }.map { $0.title })
        let noveCekajici = !cekajiciNazvy.subtracting(znameCekajiciNazvy).isEmpty
        znameCekajiciNazvy = cekajiciNazvy
        guard noveCekajici else { return }
        Log.sdilene.zapis(.info, "nová čekající session — přegeneruji tabuli a zavibruju")
        await poslatTabuli(TabuleObsah(bezSpojeni: false, sessions: sessions))
        try? await ble.vibrace()
    }
}
