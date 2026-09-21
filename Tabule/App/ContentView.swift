import SwiftUI

/// Kořenová obrazovka — **Ovládání je hlavní karta, Cockpit vedlejší**
/// (Ondrova oprava 22. 9.: dřív cockpit celoobrazovkově překrýval appku
/// a při chybě se ustupovalo na nouzovou obrazovku; teď jsou obě pořád
/// dosažitelné přes segmentovaný přepínač nahoře, cockpit nikdy ovládání
/// nezablokuje). Ozubené kolo vpravo nahoře vždy otevře Nastavení.
///
/// Obě karty jsou **pořád namountované** (přepínají se viditelností, ne
/// podmíněným `if`) — `WKWebView` v `WebViewContainer` se tak nevytváří
/// a neruší při každém přepnutí, což by jinak typicky vedlo k `-999`
/// (zrušená navigace), viz komentář ve `WebViewContainer`.
struct ContentView: View {
    @EnvironmentObject var sluzba: TabuleService
    @ObservedObject private var nastaveni = Nastaveni.shared
    @State private var ukazNastaveni = false
    @State private var chybaNacteni: String?
    @State private var karta: Karta = .ovladani
    /// Sheet s nalezenými BLE zařízeními pro WebBLE polyfill v cockpitu
    /// (`navigator.bluetooth.requestDevice()`), viz `WebBLE/WBDevicePicker.swift`.
    @StateObject private var devicePicker = WBDevicePicker()

    private enum Karta: String, CaseIterable, Identifiable {
        case ovladani = "Ovládání"
        case cockpit = "Cockpit"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Karta", selection: $karta) {
                ForEach(Karta.allCases) { k in Text(k.rawValue).tag(k) }
            }
            .pickerStyle(.segmented)
            .padding([.horizontal, .top], 12)
            .padding(.bottom, 4)

            ZStack(alignment: .topTrailing) {
                NouzovaObrazovka(duvod: nil, zkusitZnovu: nil)
                    .opacity(karta == .ovladani ? 1 : 0)
                    .allowsHitTesting(karta == .ovladani)

                cockpitObsah
                    .opacity(karta == .cockpit ? 1 : 0)
                    .allowsHitTesting(karta == .cockpit)

                Button {
                    ukazNastaveni = true
                } label: {
                    Image(systemName: "gearshape.fill")
                        .padding(10)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .padding()
            }
        }
        .sheet(isPresented: $ukazNastaveni) {
            NastaveniView()
        }
        .sheet(isPresented: $devicePicker.zobrazit) {
            WBDevicePickerView(picker: devicePicker)
        }
    }

    @ViewBuilder
    private var cockpitObsah: some View {
        if !nastaveni.cockpitURL.isEmpty {
            VStack(spacing: 0) {
                if let chybaNacteni {
                    Text("Cockpit se nenačetl: \(chybaNacteni)")
                        .font(.footnote).foregroundStyle(.orange)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.ultraThinMaterial)
                }
                WebViewContainer(urlString: nastaveni.cockpitURL, sluzba: sluzba, devicePicker: devicePicker) { chyba in
                    chybaNacteni = chyba
                }
                LogView()
            }
        } else {
            VStack(spacing: 12) {
                Spacer()
                Text("Cockpit není nastavený")
                    .font(.headline)
                Text("Vyplň URL v Nastavení (ozubené kolo vpravo nahoře). Appka mezitím funguje normálně přes kartu Ovládání.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                Spacer()
                LogView()
            }
        }
    }
}
