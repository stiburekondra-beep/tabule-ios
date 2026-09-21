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

    @Published private(set) var stav: Stav = .odpojeno
    @Published private(set) var bateriePct: Int?
    @Published private(set) var posledniNotifikace: Date?

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
    private let log = Logger(subsystem: "cz.baklazan.tabule", category: "BLE")

    override init() {
        super.init()
        let opts: [String: Any] = [CBCentralManagerOptionRestoreIdentifierKey: Self.restoreID]
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

    func hledejAPripoj() {
        guard central.state == .poweredOn else {
            stav = .chyba("Bluetooth není zapnutý")
            Log.sdilene.zapis(.chyba, "hledejAPripoj: Bluetooth není zapnutý")
            return
        }
        stav = .hledam
        Log.sdilene.zapis(.info, "skenování hodinek…")
        let jizPripojene = central.retrieveConnectedPeripherals(withServices: [Self.sluzbaUUID])
        if let p = jizPripojene.first {
            Log.sdilene.zapis(.info, "hodinky už připojené systémem: \(p.name ?? p.identifier.uuidString)")
            pripojK(p)
            return
        }
        central.scanForPeripherals(withServices: [Self.sluzbaUUID], options: nil)
        // Bezpečnostní timeout skenu — nezůstat viset v „hledám" navěky.
        Task {
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            if case .hledam = stav {
                central.stopScan()
                stav = .chyba("hodinky se nenašly")
                Log.sdilene.zapis(.chyba, "sken vypršel (15 s) — hodinky se nenašly")
            }
        }
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
        Log.sdilene.zapis(.odeslano, "seq \(s) · \(Self.popisPrikazu(modul: modul, typ: typ, cmd: cmd)) · \(bytes.hexPopis)")
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
            peripheral.writeValue(Data(bytes), for: zapisChar, type: .withoutResponse)
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
}

// MARK: - CBCentralManagerDelegate

extension BLEManager: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            Log.sdilene.zapis(.info, "BLE stav: \(Self.popisStavuBluetooth(central.state))")
            if central.state == .poweredOn {
                self.pripojSeUlozenym()
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
            Log.sdilene.zapis(.info, "nalezeno: \(peripheral.name ?? peripheral.identifier.uuidString) · RSSI \(RSSI)")
            self.pripojK(peripheral)
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
                Log.sdilene.zapis(.info, "charakteristiky nalezeny, notify zapnuto — připojeno")
                self.stav = .pripojeno(nazev: peripheral.name ?? "hodinky")
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == Self.notifyUUID, let data = characteristic.value else { return }
        let bytes = [UInt8](data)
        Task { @MainActor in
            self.posledniNotifikace = Date()
            self.naNotifikaci?()
            Log.sdilene.zapis(.prijato, bytes.hexPopis)
            switch FunDoFrame.decode(bytes) {
            case .success(let frame):
                if let (cont, timeoutTask) = self.cekajici.removeValue(forKey: frame.seq) {
                    timeoutTask.cancel()
                    Log.sdilene.zapis(.info, "seq \(frame.seq) sedí · \(Self.popisPrikazu(modul: frame.body.modul, typ: frame.body.typ, cmd: frame.body.cmd))")
                    cont.resume(returning: frame.body)
                } else {
                    Log.sdilene.zapis(.info, "seq \(frame.seq) nesedí žádnému čekajícímu požadavku (nepárovaný rámec)")
                    self.naNeparovanyRamec?(frame)
                }
            case .failure(let err):
                Log.sdilene.zapis(.chyba, "nerozpoznaný rámec z hodinek: \(String(describing: err))")
                self.log.debug("nerozpoznaný rámec z hodinek: \(String(describing: err))")
            }
        }
    }
}
