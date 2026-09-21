import Combine
import SwiftUI

/// Naše vlastní implementace `WBPicker` (protokol z `WBManager.swift`,
/// originální WebBLE ho používá se storyboardovým `WBPopUpPickerController`
/// — appka je SwiftUI, tak místo něj SwiftUI sheet). Nic z tohohle souboru
/// není z upstream WebBLE repa, viz `ATTRIBUTION.md`.
///
/// Kdykoli stránka zavolá `navigator.bluetooth.requestDevice(...)`,
/// `WBManager.devicePicker.showPicker()` nastaví `zobrazit = true` a appka
/// ukáže sheet se seznamem nalezených zařízení (`WBManager.pickerDevices`,
/// obnovováno přes `updatePicker()` při každém novém nálezu). Výběr/zrušení
/// jde zpátky přes `manager.selectDeviceAt(_:)` / `manager.cancelDeviceSearch()`.
@MainActor
final class WBDevicePicker: NSObject, ObservableObject, WBPicker {
    weak var manager: WBManager?
    @Published var zobrazit = false
    @Published private(set) var zarizeni: [WBDevice] = []

    // MARK: - WBPicker
    func showPicker() {
        zobrazit = true
        zarizeni = manager?.pickerDevices ?? []
    }

    func updatePicker() {
        zarizeni = manager?.pickerDevices ?? []
    }

    func vyber(_ index: Int) {
        Log.sdilene.zapis(.info, "WebBLE: vybráno zařízení #\(index)")
        manager?.selectDeviceAt(index)
        zobrazit = false
    }

    func zrusit() {
        Log.sdilene.zapis(.info, "WebBLE: výběr zařízení zrušen")
        manager?.cancelDeviceSearch()
        zobrazit = false
    }
}

/// Sheet se seznamem zařízení pro `navigator.bluetooth.requestDevice()`.
struct WBDevicePickerView: View {
    @ObservedObject var picker: WBDevicePicker

    var body: some View {
        NavigationView {
            List {
                if picker.zarizeni.isEmpty {
                    Text("hledám zařízení…").foregroundStyle(.secondary)
                }
                ForEach(Array(picker.zarizeni.enumerated()), id: \.offset) { index, zar in
                    Button {
                        picker.vyber(index)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(zar.name ?? "(bez jména)")
                            Text(zar.internalUUID.uuidString)
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Vyber zařízení")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Zrušit") { picker.zrusit() }
                }
            }
        }
    }
}
