import SwiftUI

/// Nouzová obrazovka — když cockpit nejde načíst (nebo URL není
/// nastavená). Přímé ovládání hodinek pro ladění: stav spojení, baterie,
/// náhled tabule, Připojit / Poslat tabuli / Zkouška zelená / Vibrace.
struct NouzovaObrazovka: View {
    @EnvironmentObject var sluzba: TabuleService
    let duvod: String?
    var zkusitZnovu: (() -> Void)? = nil
    @ObservedObject private var nastaveni = Nastaveni.shared
    @State private var surovaOdpovedCiferniku: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Tabule na zápěstí")
                    .font(.title2).bold()
                Text("Niceboy Watch 5 Lite · protokol FunDo")
                    .font(.footnote).foregroundStyle(.secondary)

                if let duvod {
                    Text("Cockpit se nenačetl: \(duvod)")
                        .font(.footnote).foregroundStyle(.orange)
                    if let zkusitZnovu {
                        Button("Zkusit znovu", action: zkusitZnovu)
                            .buttonStyle(.bordered)
                    }
                } else {
                    Text("Cockpit není nastavený — vyplň ho v Nastavení (ozubené kolo vpravo nahoře).")
                        .font(.footnote).foregroundStyle(.secondary)
                }

                stavPanel

                if Nastaveni.shared.setrit {
                    Text("Režim Šetřit: tlačítka z hodinek a dlouhý poll na Hub jsou vypnuté.")
                        .font(.footnote).foregroundStyle(.orange)
                }
                if sluzba.jinaHudbaHraje {
                    Text("Hraje jiná appka (např. Spotify) — tlačítka na hodinkách teď ovládají ji, ne Tabuli. Hlasový asistent (F14) funguje pořád.")
                        .font(.footnote).foregroundStyle(.orange)
                }

                Image(uiImage: DialRenderer.nahledUIImage(sluzba.posledniObsah) ?? UIImage())
                    .resizable()
                    .interpolation(.none)
                    .aspectRatio(CGFloat(DialGeometry.sirka) / CGFloat(DialGeometry.vyska), contentMode: .fit)
                    .frame(maxWidth: 240)
                    .background(Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .frame(maxWidth: .infinity)

                if sluzba.probihaPrenos {
                    ProgressView(value: sluzba.prubeh) { Text(sluzba.prubehText).font(.caption) }
                }
                if let chyba = sluzba.posledniChyba {
                    Text("Chyba: \(chyba)").font(.footnote).foregroundStyle(.red)
                }

                VStack(spacing: 8) {
                    Button("Připojit hodinky") { sluzba.pripojit() }
                        .buttonStyle(.borderedProminent)
                    Button("Poslat tabuli (z Hubu)") { Task { await sluzba.nacistZHubuAPoslat() } }
                        .buttonStyle(.bordered)
                        .disabled(!jePripojeno || sluzba.probihaPrenos)
                    Button("Zkouška: zelená") { Task { await sluzba.poslatZelenou() } }
                        .buttonStyle(.bordered)
                        .disabled(!jePripojeno || sluzba.probihaPrenos)
                    Button("Vibrace") { Task { await sluzba.poslatVibraci() } }
                        .buttonStyle(.bordered)
                        .disabled(!jePripojeno)
                }
                .frame(maxWidth: .infinity)

                slotyPanel

                LogView()
            }
            .padding()
        }
    }

    /// Ladicí panel pro dva sloty ciferníku — vše ⚠️ NEOVĚŘENO (viz README
    /// „Dva sloty ciferníku"). „Poslední použitý slot" je jen domněnka
    /// appky (co si sama poslední pamatuje, že poslala), ne fakt ověřený
    /// z hodinek.
    private var slotyPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Sloty ciferníku (odhad, neověřeno)").font(.footnote).bold()
            Text("poslední použitý slot: \(nastaveni.posledniNahranySlot == -1 ? "neznámý" : String(nastaveni.posledniNahranySlot))")
                .font(.footnote).foregroundStyle(.secondary)
            Button("Dotaz: seznam/stav ciferníků (syrová odpověď)") {
                Task { surovaOdpovedCiferniku = await sluzba.nactiSurovyStavCiferniku() }
            }
            .buttonStyle(.bordered)
            .disabled(!jePripojeno)
            if let surovaOdpovedCiferniku {
                Text(surovaOdpovedCiferniku)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var jePripojeno: Bool {
        if case .pripojeno = sluzba.ble.stav { return true }
        return false
    }

    private var stavPanel: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Circle().fill(barvaStavu).frame(width: 10, height: 10)
                Text(popisStavu)
            }
            if let bat = sluzba.ble.bateriePct {
                Text("baterie: \(bat) %").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var popisStavu: String {
        switch sluzba.ble.stav {
        case .odpojeno: return "odpojeno"
        case .hledam: return "hledám hodinky…"
        case .pripojuji: return "připojuji…"
        case .pripojeno(let nazev): return "připojeno: \(nazev)"
        case .chyba(let z): return "chyba: \(z)"
        }
    }

    private var barvaStavu: Color {
        switch sluzba.ble.stav {
        case .pripojeno: return .green
        case .chyba: return .red
        case .hledam, .pripojuji: return .orange
        case .odpojeno: return .gray
        }
    }
}
