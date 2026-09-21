import Combine
import SwiftUI
import WebKit

/// Karta „Cockpit" appky (architektura podle Ondrovy opravy 22. 9.):
/// **Ovládání (`NouzovaObrazovka`) je hlavní obrazovka appky, cockpit je
/// přepínatelná karta vedle ní, ne overlay, co ovládání zakrývá** — když
/// se cockpit nenačte, ovládání to vůbec neovlivní (viz `ContentView`).
/// WKWebView načte cockpit z URL v Nastavení a JS most `WebBridge`
/// (handler `hodinky`) ho propojí s hodinkami.
///
/// `ContentView` drží tenhle view vždycky namountovaný (přepíná se
/// viditelností/`allowsHitTesting`, ne podmíněným vytvářením) — SwiftUI by
/// jinak `WKWebView` rušilo a znovu vytvářelo při každém přepnutí karty,
/// což je typický zdroj `-999` (NSURLErrorCancelled): rozdělaná navigace
/// se zruší, protože zanikne view, který ji spustil.
struct WebViewContainer: UIViewRepresentable {
    let urlString: String
    let sluzba: TabuleService
    /// Sdílené s `ContentView`, které nad tímhle view ukáže sheet s
    /// nalezenými zařízeními, když stránka zavolá
    /// `navigator.bluetooth.requestDevice()` (viz `WebBLE/WBDevicePicker.swift`).
    @ObservedObject var devicePicker: WBDevicePicker
    let onChyba: (String?) -> Void

    /// Pořadí injektování WebBLE polyfillu je **závazné** — pozdější
    /// soubory (hlavně `WBPolyfill.js`) používají typy definované
    /// v dřívějších (viz upstream `WBWebView.swift`, `WebBLE/ATTRIBUTION.md`).
    private static let polyfillPoradi = [
        "WBUtils", "WBEventTarget", "WBBluetoothUUID", "WBDevice",
        "WBBluetoothRemoteGATTServer", "WBBluetoothRemoteGATTService",
        "WBBluetoothRemoteGATTCharacteristic", "WBPolyfill",
    ]

    func makeCoordinator() -> Coordinator {
        Coordinator(onChyba: onChyba, devicePicker: devicePicker)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let bridge = WebBridge(sluzba: sluzba)
        config.userContentController.add(bridge, name: WebBridge.nazevHandleru)

        // WebBLE polyfill (viz Tabule/WebBLE/ATTRIBUTION.md) — dá stránce
        // `navigator.bluetooth`, ať logika hodinek jde psát v JS
        // (web/hodinky.js) místo nativního Swiftu a nepotřebuje nový
        // build appky při každé změně (Ondrovo omezení: free Apple ID,
        // limitovaný počet App ID týdně).
        let wbManager = WBManager(devicePicker: context.coordinator.devicePicker)
        context.coordinator.devicePicker.manager = wbManager
        context.coordinator.wbManager = wbManager
        config.userContentController.addScriptMessageHandler(wbManager, contentWorld: .page, name: "bluetooth")
        // "logger" — WBUtils.js přepisuje window.console na tohle jméno,
        // bez handleru by první console.log/warn/error shodilo skript.
        config.userContentController.add(WBConsoleLogger(), name: "logger")

        for jsName in Self.polyfillPoradi {
            guard let url = Bundle.main.url(forResource: jsName, withExtension: "js"),
                  let source = try? String(contentsOf: url, encoding: .utf8) else {
                Log.sdilene.zapis(.chyba, "WebBLE polyfill: \(jsName).js chybí v bundle")
                continue
            }
            let script = WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false)
            config.userContentController.addUserScript(script)
        }

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
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "logger")
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "bluetooth", contentWorld: .page)
        coordinator.zruseSledovani()
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        var bridge: WebBridge?
        weak var webView: WKWebView?
        var wbManager: WBManager?
        let devicePicker: WBDevicePicker
        private let onChyba: (String?) -> Void
        private var naposledyNactenaURL: String?
        private var pozorovatele: [Any] = []

        init(onChyba: @escaping (String?) -> Void, devicePicker: WBDevicePicker) {
            self.onChyba = onChyba
            self.devicePicker = devicePicker
        }

        func nacti(urlString: String) {
            guard !urlString.isEmpty, urlString != naposledyNactenaURL, let url = URL(string: urlString) else { return }
            naposledyNactenaURL = urlString
            Log.sdilene.zapis(.info, "WebView: načítám \(urlString)")
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
            logChybu(error, faze: "provisional")
            onChyba(error.localizedDescription)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            logChybu(error, faze: "navigace")
            onChyba(error.localizedDescription)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Log.sdilene.zapis(.info, "WebView načten: \(naposledyNactenaURL ?? "?")")
            // WBPolyfill.js se sám zapne při vložení (.atDocumentStart), ale
            // originální WebBLE tohle volá i tady jako pojistku (viz
            // WebBLE/ATTRIBUTION.md) — neškodí, idempotentní.
            webView.evaluateJavaScript("window.iOSNativeAPI && window.iOSNativeAPI.enableBluetooth()") { _, error in
                if let error {
                    Log.sdilene.zapis(.chyba, "WebBLE enableBluetooth selhalo: \(error.localizedDescription)")
                }
            }
            onChyba(nil)
            bridge?.oznamStav()
        }

        /// Zaloguje HTTP status odpovědi (i chybové 4xx/5xx by jinak prošly
        /// bez povšimnutí — `didFail`/`didFailProvisionalNavigation` se
        /// volají jen při síťové/transportní chybě, ne při HTTP chybě).
        func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                     decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            if let http = navigationResponse.response as? HTTPURLResponse {
                let uroven: Log.Uroven = (200..<400).contains(http.statusCode) ? .info : .chyba
                Log.sdilene.zapis(uroven, "WebView odpověď: HTTP \(http.statusCode) · \(http.url?.absoluteString ?? "?")")
            }
            decisionHandler(.allow)
        }

        /// Zaloguje chybu WebView i s URL, na kterou se sahalo (i klasický
        /// `-999` „cancelled" z F18 — ať je vidět, o jakou URL šlo).
        private func logChybu(_ error: Error, faze: String) {
            let url = (error as NSError).userInfo[NSURLErrorFailingURLStringErrorKey] as? String ?? naposledyNactenaURL ?? "?"
            Log.sdilene.zapis(.chyba, "WebView chyba (\(faze)): \(error.localizedDescription) · URL: \(url)")
        }
    }
}
