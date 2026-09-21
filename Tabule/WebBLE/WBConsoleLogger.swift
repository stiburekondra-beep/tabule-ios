import Foundation
import WebKit

/// `WBUtils.js` (upstream WebBLE polyfill) přepisuje `window.console` tak,
/// aby každé `console.log/warn/error` (i vlastní `nslog` volání uvnitř
/// polyfillu) posílalo `window.webkit.messageHandlers.logger.postMessage(...)`
/// — bez zaregistrovaného handleru `"logger"` by první `console.*` volání
/// vyhodilo JS chybu (`undefined is not an object`) a spadl by celý běh
/// stránky. Originální WebBLE má na tohle vlastní `WBWebViewController.WBLogger`
/// (posílá do jejich `WBLogManager`/konzole v UI) — my místo toho routujeme
/// rovnou do našeho `Core/Log.swift`, ať JS log z cockpitu/polyfillu jde
/// vidět na stejném místě (appka i log server) jako zbytek diagnostiky.
///
/// Není součást upstream WebBLE repa — naše vlastní přizpůsobení, viz
/// `ATTRIBUTION.md`.
@MainActor
final class WBConsoleLogger: NSObject, WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else {
            Log.sdilene.zapis(.info, "JS console: \(message.body)")
            return
        }
        let level = (body["level"] as? String) ?? "log"
        let text = (body["message"] as? String) ?? ""
        let uroven: Log.Uroven = (level == "error" || level == "warn") ? .chyba : .info
        Log.sdilene.zapis(uroven, "JS[\(level)]: \(text)")
    }
}
