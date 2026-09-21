import SwiftUI

/// Kořenová obrazovka: WKWebView s cockpitem, nebo `NouzovaObrazovka`,
/// když cockpit není nastavený / se nenačetl. Ozubené kolo vpravo nahoře
/// vždy otevře Nastavení (gesto podle zadání — tlačítko je jednodušší
/// a spolehlivější než skryté gesto).
struct ContentView: View {
    @EnvironmentObject var sluzba: TabuleService
    @ObservedObject private var nastaveni = Nastaveni.shared
    @State private var ukazNastaveni = false
    @State private var chybaNacteni: String?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if !nastaveni.cockpitURL.isEmpty && chybaNacteni == nil {
                // Cockpit je bonus, ne nutnost — nenačte se, appka spadne
                // zpátky na NouzovaObrazovka (viz else větev), nic tu
                // neblokuje. Log dole je vlastní panel nad WKWebView, ať
                // je vidět i tady, ne jen na nouzové obrazovce (F18).
                VStack(spacing: 0) {
                    WebViewContainer(urlString: nastaveni.cockpitURL, sluzba: sluzba) { chyba in
                        chybaNacteni = chyba
                    }
                    LogView()
                }
                .ignoresSafeArea(edges: .top)
            } else {
                NouzovaObrazovka(duvod: chybaNacteni) { chybaNacteni = nil }
            }

            Button {
                ukazNastaveni = true
            } label: {
                Image(systemName: "gearshape.fill")
                    .padding(10)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .padding()
        }
        .sheet(isPresented: $ukazNastaveni) {
            NastaveniView()
        }
    }
}
