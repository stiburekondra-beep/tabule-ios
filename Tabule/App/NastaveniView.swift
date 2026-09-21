import SwiftUI

/// Panel Nastavení — URL cockpitu, URL Hubu a token. Nic z toho není
/// natvrdo v kódu (UserDefaults přes `Nastaveni`), ať appka jde bezpečně
/// dát i do budoucího veřejného repa.
struct NastaveniView: View {
    @ObservedObject var nastaveni = Nastaveni.shared
    @EnvironmentObject var sluzba: TabuleService
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationView {
            Form {
                Section("Baterie") {
                    Toggle("Šetřit", isOn: Binding(
                        get: { nastaveni.setrit },
                        set: { novy in
                            nastaveni.setrit = novy
                            sluzba.aktualizujRezim()
                        }
                    ))
                    Text(nastaveni.setrit
                         ? "Vypnuto: tlačítka z hodinek (ANO/NE/POKRAČUJ/POZDĚJI) a dlouhý poll na Hub. Appka se probouzí jen z BLE notify hodinek (~20 s) a v tu chvíli udělá jeden GET na Hub."
                         : "Tlačítka z hodinek fungují a appka drží dlouhé spojení na Hub (probouzí se z reakce Hubu, ne z pravidelného dotazování) — víc drží baterii i rádio v pohotovosti.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Cockpit") {
                    TextField("https://…tailnet…/", text: $nastaveni.cockpitURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Text("Appka je obal kolem cockpitu — hlavní obrazovka je WKWebView na tuhle URL. Appka respektuje systémovou Tailscale VPN.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Žán Hub") {
                    TextField("https://…/", text: $nastaveni.hubURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("token", text: $nastaveni.hubToken)
                    Text("Používá se pro GET /api/sessions a POST /api/smer (Authorization: Bearer <token>).")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Log server") {
                    TextField("http://…:8899/log (prázdné = neposílat)", text: $nastaveni.logServerURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Text("Appka sem posílá diagnostický log (BLE, rámce, HTTP, chyby) každých ~5 s, ať ho jde sledovat i na notebooku — viz ios/logserver/log_server.py. Log v appce (dole na hlavní i nouzové obrazovce) funguje vždy, bez ohledu na tohle pole.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Nastavení")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Hotovo") { dismiss() }
                }
            }
        }
    }
}
