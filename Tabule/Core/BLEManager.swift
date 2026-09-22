import CoreBluetooth
import Foundation
import os.log

/// Central pro BLE spojení s hodinkami Niceboy Watch 5 Lite.
///
/// Služba `4cdabaa0-…`, zápis `4cdabaa1-…` (write without response),
/// notify `4cdabaa2-…` (viz README a `F6-fundo-ramec.md`). Appka si
/// pamatuje identifier posledních spárovaných hodinek a po startu
/// (i na pozadí, díky `bluetooth-central` background módu a state
/// restoration) se sama pokusí připojit.
@MainActor
final class BLEManager: NSObject, ObservableObject {

    static let sluzbaUUID = CBUUID(string: "4cdabaa0-2cea-c0c1-b38d-a0481ae60a97")
    static let zapisUUID = CBUUID(string: "4cdabaa1-2cea-c0c1-b38d-a0481ae60a97")
    static let notifyUUID = CBUUID(string: "4cdabaa2-2cea-c0c1-b38d-a0481ae60a97")
    private static let restoreID = "cz.baklazan.tabule.ble"
    private static let ulozenyIdentifierKlic = "hodinkyPeripheralID"

    enum Stav: Equatable {
        case odpojeno
        case hledam
        case pripojuji
        case pripojeno(nazev: String)
        case chyba(String)
    }

    /// Zařízení nalezené při skenování bez filtru na službu (viz
    /// `zahajSken`) — appka to nabídne k ručnímu výběru, když se
    /// automatické rozpoznání podle jména/uloženého ID netrefí.
    struct NalezenePeripheral: Identifiable {
        var id: UUID { peripheral.identifier }
        let peripheral: CBPeripheral
        let rssi: Int
        var nazev: String { peripheral.name ?? peripheral.identifier.uuidString }
    }

    @Published private(set) var stav: Stav = .odpojeno
    @Published private(set) var bateriePct: Int?
    @Published private(set) var posledniNotifikace: Date?
    /// Zařízení nalezená během posledního skenování (bez filtru na
    /// službu) — appka se poprvé pokoušela skenovat JEN s filtrem na
    /// `sluzbaUUID`, ale hodinky ho možná v reklamě neinzerují (běžné
    /// u 128bit custom služeb), takže se nikdy nic nenašlo a tlačítko
    /// „Připojit" jen „problikne". Teď appka skenuje bez filtru a nabídne
    /// seznam k ručnímu výběru, kdyby se auto-match podle jména/ID nepovedl.
    @Published private(set) var nalezenaZarizeni: [NalezenePeripheral] = []

    /// Zavolá se při jakékoli notifikaci z hodinek — appka to použije jako
    /// „budíček" k dotazu na Hub (F17 doplněk, bod 7 zadání). Volá se na
    /// MainActor, max jednou za notifikaci (throttling řeší volající).
    var naNotifikaci: (() -> Void)?

    /// Zavolá se, když z hodinek přijde nerozpoznaný/nepárovaný rámec —
    /// zatím nepoužito (tlačítka jdou přes AVRCP/MPRemoteCommandCenter,
    /// viz NowPlayingController), ale hook je tu pro budoucí rozšíření.
    var naNeparovanyRamec: ((FunDoFrame) -> Void)?

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var zapisChar: CBCharacteristic?
    private var notifyChar: CBCharacteristic?
    private var seq: UInt16 = 0x2000
    private var cekajici: [UInt16: (CheckedContinuation<FunDoBody, Error>, Task<Void, Never>)] = [:]
    /// Čekající continuation pro `peripheralIsReady(toSendWriteWithoutResponse:)`
    /// — viz `pockejNaPripravenost`.
    private var pripravenKZapisu: CheckedContinuation<Void, Never>?
    /// Buffer pro skládání příchozích rámců z notify — viz `slozPrichozi`.
    private var prijimaciBuffer: [UInt8] = []
    /// Pořadové číslo čekání na připravenost k zápisu — aby timeout
    /// nepropustil continuation, která mezitím patří jinému čekání.
    private var cisloCekani: UInt64 = 0
    /// Strop pro deklarovanou délku těla rámce. Největší, co posíláme my,
    /// je datový blok ~12,3 kB; z hodinek nic takového nechodí, ale strop
    /// je tu proti zaseknutí na náhodném `0xBA` uprostřed dat.
    private static let maxDelkaTela = 16384
    private let log = Logger(subsystem: "cz.baklazan.tabule", category: "BLE")
    /// `true`, když appka chtěla hledat (`hledejAPripoj()`), ale Bluetooth
    /// ještě nebyl `.poweredOn` — sken se spustí sám, jakmile
    /// `centralManagerDidUpdateState` nahlásí zapnutí (fronta „naskenuj,
    /// až bude zapnuto", viz Ondrova připomínka o problikávajícím tlačítku).
    private var chceHledat = false
    /// Vzor ve jméně zařízení pro automatické rozpoznání hodinek při
    /// skenu bez filtru na službu — case-insensitive.
    private static let jmenoVzor = "watch 5 lite"

    override init() {
        super.init()
        let opts: [String: Any] = [
            CBCentralManagerOptionRestoreIdentifierKey: Self.restoreID,
            CBCentralManagerOptionShowPowerAlertKey: true,
        ]
        central = CBCentralManager(delegate: self, queue: nil, options: opts)
    }

    // MARK: - Připojení

    func pripojSeUlozenym() {
        guard let idStr = UserDefaults.standard.string(forKey: Self.ulozenyIdentifierKlic),
              let uuid = UUID(uuidString: idStr) else { return }
        guard central.state == .poweredOn else { return }
        let known = central.retrievePeripherals(withIdentifiers: [uuid])
        if let p = known.first {
            Log.sdilene.zapis(.info, "zkouším uložené hodinky: \(p.name ?? uuid.uuidString)")
            pripojK(p)
        }
    }

    /// Zahájí hledání — pokud Bluetooth ještě není zapnutý, jen si to
    /// zapamatuje a spustí sken, jakmile `centralManagerDidUpdateState`
    /// nahlásí `.poweredOn` (dřív appka jen jednorázově zkontrolovala
    /// stav a tiše skončila — proto tlačítko "jen probliklo").
    func hledejAPripoj() {
        guard central.state == .poweredOn else {
            chceHledat = true
            stav = .chyba("čekám na zapnutí Bluetooth (\(Self.popisStavuBluetooth(central.state)))")
            Log.sdilene.zapis(.info, "hledejAPripoj: BT stav \(Self.popisStavuBluetooth(central.state)), naplánováno na zapnutí")
            return
        }
        zahajSken()
    }

    /// Skenuje **bez filtru na service UUID** — hodinky ho v reklamních
    /// datech možná neinzerují (běžné u vlastních 128bit služeb, appka
    /// se filtrem na `sluzbaUUID` dřív nikdy nic nenašla). Automaticky se
    /// připojí, když jméno zařízení obsahuje „watch 5 lite" nebo sedí
    /// uložený identifikátor; ostatní nalezená zařízení jde připojit
    /// ručně přes `nalezenaZarizeni` (UI seznam).
    private func zahajSken() {
        chceHledat = false
        // Už připojeno a služby nalezené → není co hledat. Dřív se tu při
        // každém stisku „Připojit" spustil sken, `connect()` na už
        // připojenou periferii a nové zjišťování služeb — v logu z 22. 9.
        // sedmkrát za 14 s. Obrazovka mezitím blikala mezi „hledám" a
        // „připojeno".
        if let p = peripheral, p.state == .connected, zapisChar != nil {
            Log.sdilene.zapis(.info, "už připojeno k \(p.name ?? "hodinkám"), sken se nespouští")
            stav = .pripojeno(nazev: p.name ?? "hodinky")
            return
        }
        stav = .hledam
        nalezenaZarizeni = []
        Log.sdilene.zapis(.info, "skenování hodinek (bez filtru na službu)…")
        let jizPripojene = central.retrieveConnectedPeripherals(withServices: [Self.sluzbaUUID])
        if let p = jizPripojene.first {
            Log.sdilene.zapis(.info, "hodinky už připojené systémem: \(p.name ?? p.identifier.uuidString)")
            pripojK(p)
            return
        }
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        // Bezpečnostní timeout skenu — nezůstat viset v „hledám" navěky.
        Task {
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            if case .hledam = stav {
                central.stopScan()
                if nalezenaZarizeni.isEmpty {
                    stav = .chyba("hodinky se nenašly")
                    Log.sdilene.zapis(.chyba, "sken vypršel (15 s) — nic v okolí")
                } else {
                    stav = .chyba("automaticky nerozpoznáno — vyber ze seznamu níž")
                    Log.sdilene.zapis(.chyba, "sken vypršel (15 s) — \(nalezenaZarizeni.count) zařízení nalezeno, žádné nesedí jménu/ID")
                }
            }
        }
    }

    /// Ruční připojení k zařízení ze seznamu `nalezenaZarizeni` (UI), pro
    /// případ, že automatické rozpoznání podle jména/ID selže.
    func pripojKRucne(_ zarizeni: NalezenePeripheral) {
        Log.sdilene.zapis(.info, "ruční výběr ze seznamu: \(zarizeni.nazev)")
        pripojK(zarizeni.peripheral)
    }

    private func pripojK(_ p: CBPeripheral) {
        central.stopScan()
        peripheral = p
        p.delegate = self
        stav = .pripojuji
        Log.sdilene.zapis(.info, "připojuji k \(p.name ?? p.identifier.uuidString)…")
        central.connect(p, options: nil)
    }

    func odpoj() {
        if let p = peripheral {
            Log.sdilene.zapis(.info, "odpojuji \(p.name ?? p.identifier.uuidString)")
            central.cancelPeripheralConnection(p)
        }
    }

    // MARK: - Odeslání rámce s čekáním na odpověď (párováno podle seq)

    private func dalsiSeq() -> UInt16 {
        seq = seq &+ 1
        return seq
    }

    /// Pošle rámec a čeká na odpověď se stejným seq. Timeout výchozí 4 s,
    /// pro datové bloky přenosu tabule 15 s (viz zadání, bod 4).
    @discardableResult
    func posli(modul: UInt8, typ: UInt8, cmd: UInt8, data: [UInt8] = [], timeoutS: Double = 4.0) async throws -> FunDoBody {
        guard let zapisChar, let peripheral else {
            Log.sdilene.zapis(.chyba, "\(Self.popisPrikazu(modul: modul, typ: typ, cmd: cmd)): hodinky nejsou připojené, neodesláno")
            throw Chyba.nepripojeno
        }
        let s = dalsiSeq()
        let frame = FunDoFrame(direction: .phoneToWatch, seq: s, body: FunDoBody(modul: modul, typ: typ, cmd: cmd, data: data))
        let bytes = frame.encode()
        Log.sdilene.zapis(.odeslano, "seq \(s) · \(Self.popisPrikazu(modul: modul, typ: typ, cmd: cmd)) · \(bytes.hexPopisKratky())")
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<FunDoBody, Error>) in
            let timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeoutS * 1_000_000_000))
                guard let self else { return }
                if let (c, _) = self.cekajici.removeValue(forKey: s) {
                    Log.sdilene.zapis(.chyba, "seq \(s) · timeout (\(timeoutS) s), bez odpovědi")
                    c.resume(throwing: Chyba.timeout)
                }
            }
            cekajici[s] = (cont, timeoutTask)
            Task { [weak self] in
                await self?.zapisPoKusech(bytes, char: zapisChar, p: peripheral, seq: s)
            }
        }
    }

    // MARK: - Zápis po kusech podle MTU

    /// Rozdělí rámec na kusy podle `maximumWriteValueLength` a pošle je za
    /// sebou.
    ///
    /// **Proč:** datový blok ciferníku má 12 296 B, ale jeden BLE zápis
    /// unese jen tolik, kolik dovolí vyjednané MTU (na iOS typicky
    /// 182–512 B). `writeValue` s delšími daty CoreBluetooth **tiše
    /// zahodí** — nevrátí chybu, jen se nic nestane a čekání na odpověď
    /// skončí timeoutem. To byla příčina „zelená nefunguje" (22. 9.).
    ///
    /// Že se to takhle dělá, potvrzuje i odposlech oficiální appky
    /// (F13-prenos-souboru.md): při skládání souboru se musely brát
    /// i **pokračovací zápisy bez hlavičky `0xBA`** — tedy Android posílá
    /// přesně tohle: první kus s hlavičkou rámce, zbytek jako holá data.
    private func zapisPoKusech(_ bytes: [UInt8], char: CBCharacteristic,
                               p: CBPeripheral, seq s: UInt16) async {
        let mtu = Swift.max(20, p.maximumWriteValueLength(for: .withoutResponse))
        guard bytes.count > mtu else {
            p.writeValue(Data(bytes), for: char, type: .withoutResponse)
            return
        }
        let pocet = (bytes.count + mtu - 1) / mtu
        Log.sdilene.zapis(.info, "seq \(s) · rámec \(bytes.count) B > MTU \(mtu) B — dělím na \(pocet) zápisů")
        var i = 0
        while i < bytes.count {
            await pockejNaPripravenost(p)
            let konec = Swift.min(i + mtu, bytes.count)
            p.writeValue(Data(bytes[i..<konec]), for: char, type: .withoutResponse)
            i = konec
        }
    }

    /// Počká, až je periferie připravená přijmout další write-without-response.
    /// Bez tohohle se při rychlém odeslání 60+ kusů za sebou část zahodí ve
    /// frontě CoreBluetooth. Timeout 2 s, aby se nedalo zaseknout navěky —
    /// když callback nepřijde, pokračujeme a spolehneme se na timeout rámce.
    private func pockejNaPripravenost(_ p: CBPeripheral) async {
        if p.canSendWriteWithoutResponse { return }
        // Předchozí čekání (kdyby nějaké zbylo) propustíme — continuation,
        // která se nikdy neresumne, je v Swiftu chyba za běhu.
        if let stary = pripravenKZapisu {
            pripravenKZapisu = nil
            stary.resume()
        }
        cisloCekani &+= 1
        let moje = cisloCekani
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            pripravenKZapisu = cont
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self, self.cisloCekani == moje, let c = self.pripravenKZapisu else { return }
                self.pripravenKZapisu = nil
                Log.sdilene.zapis(.chyba, "čekání na připravenost k zápisu vypršelo (2 s) — posílám dál")
                c.resume()
            }
        }
    }

    /// Čitelný popis příkazu pro log — známé kombinace modul/typ/cmd
    /// pojmenované, jinak surová čísla v hexu.
    private static func popisPrikazu(modul: UInt8, typ: UInt8, cmd: UInt8) -> String {
        switch (modul, typ, cmd) {
        case (FunDoCommand.vibraceModul, FunDoCommand.vibraceTyp, FunDoCommand.vibraceCmd):
            return "vibrace"
        case (FunDoCommand.bateryModul, FunDoCommand.bateryTyp, FunDoCommand.bateryCmdDotaz):
            return "baterie: dotaz"
        case (FunDoCommand.souborModul, FunDoCommand.souborTyp, FunDoCommand.souborZahajeni):
            return "soubor: zahájení"
        case (FunDoCommand.souborModul, FunDoCommand.souborTyp, FunDoCommand.souborBlok):
            return "soubor: blok"
        case (FunDoCommand.souborModul, FunDoCommand.souborTyp, FunDoCommand.souborZakonceni):
            return "soubor: zakončení"
        case (FunDoCommand.ciferníkModul, FunDoCommand.ciferníkTypZapis, FunDoCommand.ciferníkPrepnoutCmd):
            return "ciferník: přepnout"
        case (FunDoCommand.ciferníkModul, FunDoCommand.ciferníkTypDotaz, FunDoCommand.ciferníkDotazCmd):
            return "ciferník: seznam/stav (odhad)"
        default:
            return String(format: "modul 0x%02x/typ 0x%02x/cmd 0x%02x", modul, typ, cmd)
        }
    }

    enum Chyba: Error, LocalizedError {
        case nepripojeno
        case timeout
        case sablonaChybi

        var errorDescription: String? {
            switch self {
            case .nepripojeno: return "hodinky nejsou připojené"
            case .timeout: return "bez odpovědi (timeout)"
            case .sablonaChybi: return "šablona ciferníku chybí v appce"
            }
        }
    }

    // MARK: - Vysoké API (zadání, bod 3–4)

    func vibrace() async throws {
        _ = try await posli(modul: FunDoCommand.vibraceModul, typ: FunDoCommand.vibraceTyp, cmd: FunDoCommand.vibraceCmd)
    }

    func nactiBaterii() async throws -> Int {
        let odp = try await posli(modul: FunDoCommand.bateryModul, typ: FunDoCommand.bateryTyp, cmd: FunDoCommand.bateryCmdDotaz)
        guard let prvni = odp.data.first else { throw Chyba.timeout }
        let pct = Int(prvni)
        bateriePct = pct
        return pct
    }

    /// Odešle kompletní soubor ciferníku (zahájení → bloky po 12 288 B →
    /// zakončení), s hlášením průběhu. Viz F13-prenos-souboru.md a zadání
    /// bod 4. Blok čeká na odpověď cmd 0xC3, timeout 15 s na blok.
    ///
    /// - Parameter cilovySlot: **NEOVĚŘENO, zatím bez efektu.** Zadání chce
    ///   nahrávat vždy do neaktivního slotu (dva sloty, střídání), ale
    ///   nevíme, KDE v zahájení `0xC0` (prvních 21 B souboru, F13) nebo
    ///   v hlavičce souboru samotné se cílový slot/dialId určuje — všechny
    ///   dosud zachycené soubory mají na offsetu 16 konstantu `0x64`
    ///   (F13: „stejné u všech"), což je jediný dosud neidentifikovaný
    ///   bajt v malém rozsahu a **kandidát** na pole slotu, ale bez
    ///   druhého vzorku na jiném slotu se to nedá potvrdit ani vyvrátit.
    ///   Parametr tu je připravený k zapojení, až se offset najde — teď
    ///   nic nemění a appka nahrává tam, kam hodinky sami rozhodnou
    ///   (typicky aktuálně zobrazený ciferník, se stejným loading barem
    ///   jako přes oficiální appku).
    func posliSoubor(_ soubor: [UInt8], blokB: Int = 12288, cilovySlot: UInt8? = nil,
                      progress: (@MainActor (Double, String) -> Void)? = nil) async throws {
        _ = cilovySlot // TODO: zapojit, až se najde offset cíle v hlavičce/zahájení
        Log.sdilene.zapis(.info, "přenos souboru: start, \(soubor.count) B celkem, blok \(blokB) B")
        await progress?(0, "zahájení…")
        _ = try await posli(modul: FunDoCommand.souborModul, typ: FunDoCommand.souborTyp, cmd: FunDoCommand.souborZahajeni,
                             data: Array(soubor.prefix(21)))
        var off = 21
        var n = 0
        let pocetBloku = Int(ceil(Double(soubor.count - 21) / Double(blokB)))
        while off < soubor.count {
            let konec = min(off + blokB, soubor.count)
            let kus = Array(soubor[off..<konec])
            var data: [UInt8] = []
            let velikost = UInt32(kus.count)
            let offset = UInt32(off)
            data.append(contentsOf: [UInt8((velikost >> 24) & 0xFF), UInt8((velikost >> 16) & 0xFF), UInt8((velikost >> 8) & 0xFF), UInt8(velikost & 0xFF)])
            data.append(contentsOf: [UInt8((offset >> 24) & 0xFF), UInt8((offset >> 16) & 0xFF), UInt8((offset >> 8) & 0xFF), UInt8(offset & 0xFF)])
            data.append(contentsOf: kus)
            n += 1
            do {
                _ = try await posli(modul: FunDoCommand.souborModul, typ: FunDoCommand.souborTyp, cmd: FunDoCommand.souborBlok,
                                     data: data, timeoutS: 15.0)
                Log.sdilene.zapis(.info, "blok \(n)/\(pocetBloku) potvrzen · offset \(off) · \(kus.count) B")
            } catch {
                Log.sdilene.zapis(.chyba, "blok \(n)/\(pocetBloku) selhal · offset \(off) · \(error.localizedDescription)")
                throw error
            }
            off = konec
            await progress?(Double(off) / Double(soubor.count), "blok \(n) · \(off)/\(soubor.count)")
        }
        _ = try await posli(modul: FunDoCommand.souborModul, typ: FunDoCommand.souborTyp, cmd: FunDoCommand.souborZakonceni, data: [0x00])
        Log.sdilene.zapis(.info, "přenos souboru: hotovo (\(n) bloků)")
        await progress?(1, "hotovo")
    }

    // MARK: - Sloty ciferníku — ⚠️ NEOVĚŘENO, viz README „Dva sloty ciferníku"

    /// „Přepni ciferník" (nastavit použitý slot). Modul 0x04, cmd 0x4F,
    /// payload = 1 bajt dialId — **odhad podle F16/cizího rozboru**, nikdy
    /// nezachyceno v našem odposlechu. Vrací syrovou odpověď (nerozebranou,
    /// formát neznámý), ať jde na hodinkách ověřit, co se vlastně stane.
    @discardableResult
    func prepniCifernik(dialId: UInt8) async throws -> FunDoBody {
        try await posli(modul: FunDoCommand.ciferníkModul, typ: FunDoCommand.ciferníkTypZapis,
                         cmd: FunDoCommand.ciferníkPrepnoutCmd, data: [dialId])
    }

    /// „Seznam ciferníků" / „stav ciferníku" — stejný odhadnutý příkaz pro
    /// obojí (viz `FunDoCommand.ciferníkDotazCmd`), appka odpověď nijak
    /// neparsuje (formát neznámý), jen vrátí syrová data.
    @discardableResult
    func dotazNaCifernikSeznamNeboStav() async throws -> [UInt8] {
        let odp = try await posli(modul: FunDoCommand.ciferníkModul, typ: FunDoCommand.ciferníkTypDotaz,
                                   cmd: FunDoCommand.ciferníkDotazCmd, data: [])
        return odp.data
    }

    // MARK: - Displej, ikona v menu, čas — OVĚŘENO na hodinkách (F10)

    /// Rozsvítí displej hodinek. **Ověřeno** (F10). ⚠️ Podle stejného
    /// pozorování spojení po odeslání spadne — appka to bere jako
    /// očekávaný vedlejší účinek (`TabuleService.rozsvitDisplej` chybu
    /// z odpojení nehlásí jako skutečnou chybu) a automaticky se zkusí
    /// znovu připojit (`centralManager(_:didDisconnectPeripheral:error:)`).
    @discardableResult
    func rozsvitDisplej() async throws -> FunDoBody {
        try await posli(modul: FunDoCommand.displejModul, typ: FunDoCommand.displejTyp, cmd: FunDoCommand.displejCmd, data: [0x01])
    }

    /// Zapne/vypne ikonu appky v menu hodinek. **Ověřeno** (F10).
    @discardableResult
    func nastavIkonuVMenu(zapnuto: Bool) async throws -> FunDoBody {
        try await posli(modul: FunDoCommand.ikonaMenuModul, typ: FunDoCommand.ikonaMenuTyp,
                         cmd: FunDoCommand.ikonaMenuCmd, data: [zapnuto ? 0x01 : 0x00])
    }

    /// Nastaví čas na hodinkách, data `[rok-2000, měsíc, den, hodina,
    /// minuta, sekunda, 0]`. **Neověřeno samostatně** (F10 ho zmiňuje jako
    /// součást úvodní sekvence oficiální appky).
    @discardableResult
    func nastavCas(_ datum: Date = Date()) async throws -> FunDoBody {
        let kal = Calendar(identifier: .gregorian)
        let c = kal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: datum)
        let data: [UInt8] = [
            UInt8(clamping: max(0, (c.year ?? 2026) - 2000)),
            UInt8(clamping: c.month ?? 1),
            UInt8(clamping: c.day ?? 1),
            UInt8(clamping: c.hour ?? 0),
            UInt8(clamping: c.minute ?? 0),
            UInt8(clamping: c.second ?? 0),
            0,
        ]
        return try await posli(modul: FunDoCommand.casModul, typ: FunDoCommand.casTyp, cmd: FunDoCommand.casCmd, data: data)
    }

    // MARK: - Volný rámec (ladění bez nového buildu)

    /// Pošle libovolný rámec podle zadaných bajtů a vrátí syrovou
    /// odpověď — ladicí nástroj pro zkoušení neznámých příkazů bez
    /// nutnosti dělat nový build pokaždé.
    @discardableResult
    func posliVolnyRamec(modul: UInt8, typ: UInt8, cmd: UInt8, data: [UInt8]) async throws -> FunDoBody {
        try await posli(modul: modul, typ: typ, cmd: cmd, data: data)
    }
}

// MARK: - CBCentralManagerDelegate

extension BLEManager: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            Log.sdilene.zapis(.info, "BLE stav: \(Self.popisStavuBluetooth(central.state))")
            if central.state == .poweredOn {
                // Nejdřív uložené hodinky; sken jen když se k nim nešlo
                // rovnou připojit (dřív se spouštělo obojí naráz → dva
                // souběžné pokusy o připojení, viz log 22. 9. 10:22:41).
                self.pripojSeUlozenym()
                if self.chceHledat && self.peripheral == nil {
                    self.zahajSken()
                }
                self.chceHledat = false
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        // Systém obnovuje appku na pozadí kvůli BLE — jen zalogovat, connect
        // dojede přes centralManager(_:didConnect:) / didFailToConnect.
        log.debug("BLE state restoration")
        Task { @MainActor in Log.sdilene.zapis(.info, "BLE state restoration — appka probuzená na pozadí") }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                     advertisementData: [String: Any], rssi RSSI: NSNumber) {
        Task { @MainActor in
            self.pridejNalezene(peripheral, rssi: RSSI.intValue)
            let ulozenyId = UserDefaults.standard.string(forKey: Self.ulozenyIdentifierKlic)
            let jeUlozene = ulozenyId == peripheral.identifier.uuidString
            let jmenoSedi = (peripheral.name ?? "").lowercased().contains(Self.jmenoVzor)
            if jeUlozene || jmenoSedi {
                Log.sdilene.zapis(.info, "nalezeno (auto \(jeUlozene ? "podle ID" : "podle jména")): \(peripheral.name ?? peripheral.identifier.uuidString) · RSSI \(RSSI)")
                self.pripojK(peripheral)
            } else {
                Log.sdilene.zapis(.info, "nalezeno: \(peripheral.name ?? peripheral.identifier.uuidString) · RSSI \(RSSI) (do seznamu, jméno/ID nesedí)")
            }
        }
    }

    private func pridejNalezene(_ p: CBPeripheral, rssi: Int) {
        if let idx = nalezenaZarizeni.firstIndex(where: { $0.peripheral.identifier == p.identifier }) {
            nalezenaZarizeni[idx] = NalezenePeripheral(peripheral: p, rssi: rssi)
        } else {
            nalezenaZarizeni.append(NalezenePeripheral(peripheral: p, rssi: rssi))
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            Log.sdilene.zapis(.info, "BLE připojeno: \(peripheral.name ?? peripheral.identifier.uuidString), zjišťuji služby…")
            UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: Self.ulozenyIdentifierKlic)
            peripheral.discoverServices([Self.sluzbaUUID])
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
            let popis = error?.localizedDescription ?? "připojení selhalo"
            Log.sdilene.zapis(.chyba, "připojení selhalo: \(popis)")
            self.stav = .chyba(popis)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
            let duvod = error?.localizedDescription ?? "běžné odpojení, bez chyby"
            Log.sdilene.zapis(error == nil ? .info : .chyba, "odpojeno: \(duvod)")
            self.stav = .odpojeno
            self.zapisChar = nil
            self.notifyChar = nil
            for (_, (cont, timeoutTask)) in self.cekajici {
                timeoutTask.cancel()
                cont.resume(throwing: Chyba.nepripojeno)
            }
            self.cekajici.removeAll()
            // Buffer nesmí přežít odpojení — půlka rámce z minulého spojení
            // by se po reconnectu slepila s novými daty.
            self.prijimaciBuffer.removeAll()
            if let c = self.pripravenKZapisu {
                self.pripravenKZapisu = nil
                c.resume()
            }
            // Automatický reconnect — hodí se hlavně po `rozsvitDisplej()`
            // (cmd 0x42), které podle F10 spojení pokaždé shodí, ale
            // pomůže i po jiném neplánovaném odpojení.
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                self?.pripojSeUlozenym()
            }
        }
    }

    private static func popisStavuBluetooth(_ s: CBManagerState) -> String {
        switch s {
        case .poweredOn: return "zapnutý"
        case .poweredOff: return "vypnutý"
        case .resetting: return "resetuje se"
        case .unauthorized: return "neautorizováno"
        case .unsupported: return "nepodporováno"
        case .unknown: return "neznámý"
        @unknown default: return "neznámý (\(s.rawValue))"
        }
    }
}

// MARK: - CBPeripheralDelegate

extension BLEManager: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services else {
            if let error {
                Task { @MainActor in Log.sdilene.zapis(.chyba, "zjišťování služeb selhalo: \(error.localizedDescription)") }
            }
            return
        }
        for s in services where s.uuid == Self.sluzbaUUID {
            peripheral.discoverCharacteristics([Self.zapisUUID, Self.notifyUUID], for: s)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let chars = service.characteristics else {
            if let error {
                Task { @MainActor in Log.sdilene.zapis(.chyba, "zjišťování charakteristik selhalo: \(error.localizedDescription)") }
            }
            return
        }
        Task { @MainActor in
            for c in chars {
                if c.uuid == Self.zapisUUID { self.zapisChar = c }
                if c.uuid == Self.notifyUUID {
                    self.notifyChar = c
                    peripheral.setNotifyValue(true, for: c)
                }
            }
            if self.zapisChar != nil {
                let mtu = peripheral.maximumWriteValueLength(for: .withoutResponse)
                Log.sdilene.zapis(.info, "charakteristiky nalezeny, notify zapnuto — připojeno (MTU zápisu \(mtu) B)")
                self.stav = .pripojeno(nazev: peripheral.name ?? "hodinky")
            }
        }
    }

    /// CoreBluetooth hlásí, že fronta write-without-response se uvolnila.
    /// Probudí `pockejNaPripravenost` — bez toho by se při odesílání
    /// dlouhého datového bloku část kusů ztratila.
    nonisolated func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        Task { @MainActor in
            if let c = self.pripravenKZapisu {
                self.pripravenKZapisu = nil
                c.resume()
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == Self.notifyUUID, let data = characteristic.value else { return }
        let bytes = [UInt8](data)
        Task { @MainActor in
            self.posledniNotifikace = Date()
            self.naNotifikaci?()
            Log.sdilene.zapis(.prijato, bytes.hexPopisKratky())
            for frame in self.slozPrichozi(bytes) {
                self.zpracujRamec(frame)
            }
        }
    }

    /// Přidá přijaté bajty do skládacího bufferu a vrátí všechny kompletní
    /// rámce, které z něj jdou přečíst.
    ///
    /// **Proč:** odpověď delší než jedno notify (MTU) přijde po částech
    /// a `FunDoFrame.decode` na samotném kusu skončí `lengthMismatch` —
    /// rámec se zahodil a čekající požadavek spadl na timeout. Stejná
    /// chyba jako při rozboru odposlechu (F13: „zahazoval jsem pokračovací
    /// zápisy"), jen ve směru k telefonu.
    ///
    /// Když buffer nezačíná magicem `0xBA`, zahodí se bajty až k nejbližšímu
    /// `0xBA` — jinak by jediný ztracený bajt zasekl příjem natrvalo.
    private func slozPrichozi(_ kus: [UInt8]) -> [FunDoFrame] {
        prijimaciBuffer.append(contentsOf: kus)
        var hotove: [FunDoFrame] = []
        while true {
            guard let zacatek = prijimaciBuffer.firstIndex(of: 0xBA) else {
                prijimaciBuffer.removeAll()
                break
            }
            if zacatek > 0 {
                Log.sdilene.zapis(.chyba, "zahazuji \(zacatek) B před magicem 0xBA (rozsynchronizovaný příjem)")
                prijimaciBuffer.removeFirst(zacatek)
            }
            guard prijimaciBuffer.count >= 8 else { break }
            let delkaTela = Int(prijimaciBuffer[2]) << 8 | Int(prijimaciBuffer[3])
            let celkem = 8 + delkaTela
            guard delkaTela <= Self.maxDelkaTela else {
                Log.sdilene.zapis(.chyba, "nesmyslná délka těla \(delkaTela) B — zahazuji magic a hledám další")
                prijimaciBuffer.removeFirst()
                continue
            }
            guard prijimaciBuffer.count >= celkem else { break } // čekáme na zbytek
            let ramec = Array(prijimaciBuffer[0..<celkem])
            prijimaciBuffer.removeFirst(celkem)
            switch FunDoFrame.decode(ramec) {
            case .success(let f):
                hotove.append(f)
            case .failure(let err):
                Log.sdilene.zapis(.chyba, "nerozpoznaný rámec z hodinek: \(String(describing: err)) · \(ramec.hexPopisKratky())")
            }
        }
        return hotove
    }

    private func zpracujRamec(_ frame: FunDoFrame) {
        if let (cont, timeoutTask) = cekajici.removeValue(forKey: frame.seq) {
            timeoutTask.cancel()
            Log.sdilene.zapis(.info, "seq \(frame.seq) sedí · \(Self.popisPrikazu(modul: frame.body.modul, typ: frame.body.typ, cmd: frame.body.cmd))")
            cont.resume(returning: frame.body)
        } else {
            Log.sdilene.zapis(.info, "seq \(frame.seq) nesedí žádnému čekajícímu požadavku (nepárovaný rámec)")
            naNeparovanyRamec?(frame)
        }
    }
}
