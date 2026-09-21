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
                WebViewContainer(urlString: nastaveni.cockpitURL, sluzba: sluzba) { chyba in
                    chybaNacteni = chyba
                }
                .ignoresSafeArea()
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
