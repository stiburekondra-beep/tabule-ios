import SwiftUI
import UIKit

/// Minimální AppDelegate — hlavně proto, aby `BLEManager` (a jeho
/// `CBCentralManager` s restore identifierem) vznikl hned při startu
/// procesu, i když ho iOS spustí na pozadí kvůli Bluetooth eventu
/// (state restoration, viz README a zadání bod 1).
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                      didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        true
    }
}

@main
struct TabuleApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var ble: BLEManager
    @StateObject private var sluzba: TabuleService

    init() {
        let b = BLEManager()
        _ble = StateObject(wrappedValue: b)
        _sluzba = StateObject(wrappedValue: TabuleService(ble: b))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(sluzba)
                .onAppear {
                    sluzba.aktualizujRezim() // spustí NowPlayingController + dlouhý poll, pokud appka není v „Šetřit"
                    sluzba.pripojit()
                }
        }
    }
}
