import Combine
import SwiftUI
import WebKit

/// Hlavní obrazovka appky (architektura podle Ondrovy opravy 21. 9.):
/// appka je **obal kolem cockpitu**. WKWebView načte cockpit z URL
/// v Nastavení a JS most `WebBridge` (handler `hodinky`) ho propojí
/// s hodinkami. Když cockpit není nastavený nebo se nenačte, appka
/// ukáže `NouzovaObrazovka` s přímým ovládáním.
struct WebViewContainer: UIViewRepresentable {
    let urlString: String
    let sluzba: TabuleService
    let onChyba: (String?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onChyba: onChyba)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let bridge = WebBridge(sluzba: sluzba)
        config.userContentController.add(bridge, name: WebBridge.nazevHandleru)
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        bridge.webView = webView
        context.coordinator.bridge = bridge
        context.coordinator.webView = webView
        context.coordinator.nacti(urlString: urlString)
        // Stav appky posíláme cockpitu i bez vyžádání — po připojení/odpojení
        // hodinek a po skončení přenosu (viz WebBridge.oznamStav).
        context.coordinator.sledujZmeny(sluzba)
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        context.coordinator.nacti(urlString: urlString)
    }

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: WebBridge.nazevHandleru)
        coordinator.zruseSledovani()
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        var bridge: WebBridge?
        weak var webView: WKWebView?
        private let onChyba: (String?) -> Void
        private var naposledyNactenaURL: String?
        private var pozorovatele: [Any] = []

        init(onChyba: @escaping (String?) -> Void) {
            self.onChyba = onChyba
        }

        func nacti(urlString: String) {
            guard !urlString.isEmpty, urlString != naposledyNactenaURL, let url = URL(string: urlString) else { return }
            naposledyNactenaURL = urlString
            webView?.load(URLRequest(url: url, timeoutInterval: 10))
        }

        func sledujZmeny(_ sluzba: TabuleService) {
            let c1 = sluzba.ble.$stav.sink { [weak self] _ in self?.bridge?.oznamStav() }
            let c2 = sluzba.$probihaPrenos.sink { [weak self] _ in self?.bridge?.oznamStav() }
            let c3 = sluzba.ble.$bateriePct.sink { [weak self] _ in self?.bridge?.oznamStav() }
            pozorovatele = [c1, c2, c3]
        }

        func zruseSledovani() {
            pozorovatele.removeAll()
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            onChyba(error.localizedDescription)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            onChyba(error.localizedDescription)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            onChyba(nil)
            bridge?.oznamStav()
        }
    }
}
