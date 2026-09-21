# Původ — WebBLE polyfill

Soubory v tomhle adresáři (`WBManager.swift`, `WBDevice.swift`,
`WBTransaction.swift`, `JSHandlerCompatible.swift`) a JS polyfill
v `../Resources/WB*.js` pocházejí z projektu
**[daphtdazz/WebBLE](https://github.com/daphtdazz/WebBLE)** (`WBCore/` a
`WBCore/Polyfill/`), commit `86502ef` (2026-09-22, HEAD `main` v době
klonování).

**Licence: Apache License 2.0** — viz `LICENSE` v tomhle adresáři (kopie
originálního `LICENSE` z repa). Copyright 2016–2020 Paul Theriault a David
Park (viz hlavičky jednotlivých souborů).

## Co je beze změny

- `WBDevice.swift`, `WBTransaction.swift`, `JSHandlerCompatible.swift` —
  1:1 kopie.
- Všech 8 JS polyfill souborů (`WBUtils.js`, `WBEventTarget.js`,
  `WBBluetoothUUID.js`, `WBDevice.js`, `WBBluetoothRemoteGATTServer.js`,
  `WBBluetoothRemoteGATTService.js`,
  `WBBluetoothRemoteGATTCharacteristic.js`, `WBPolyfill.js`) — 1:1 kopie,
  musí se injektovat do `WKUserContentController` přesně v tomhle pořadí
  (viz `App/WebViewContainer.swift`).

## Co je upraveno

- **`WBManager.swift`**: vypuštěna konformace na `WBPopUpPickerViewDelegate`
  (`UIPickerViewDataSource`/`UIPickerViewDelegate` pro storyboardový picker
  z originálního WebBLE) a její tři metody (`pickerView(titleForRow:)`,
  `numberOfComponents`, `pickerView(numberOfRowsInComponent:)`) + pomocná
  `_pv()`. Appka je SwiftUI, ne storyboard — výběr zařízení řeší nová
  `WBDevicePicker.swift` (SwiftUI sheet), přes stejné
  `WBPicker`/`selectDeviceAt`/`cancelDeviceSearch` API, beze změny zbytku
  souboru. Změna je označená komentářem přímo v souboru.

## Co je nové (naše, ne z upstream)

- `WBDevicePicker.swift` — SwiftUI implementace `WBPicker` + sheet se
  seznamem nalezených zařízení (nahrazuje `WBPopUpPickerController` +
  `WBPopUpPickerView` z originálu, které jsme nekopírovali).
- `WBConsoleLogger.swift` — handler `"logger"`, který `WBUtils.js`
  (upstream, beze změny) potřebuje, aby `console.log/warn/error` nespadlo
  na chybějící `window.webkit.messageHandlers.logger` — místo originální
  `WBLogManager`/UI konzole routuje rovnou do `Core/Log.swift` (stejný
  diagnostický log jako zbytek appky).
- Zapojení do `WKWebViewConfiguration` v `App/WebViewContainer.swift`
  (injektování 8 JS souborů jako `WKUserScript` při `.atDocumentStart`,
  registrace `WBManager` jako `WKScriptMessageHandlerWithReply` na jméno
  `"bluetooth"` v content world `.page`, `WBConsoleLogger` na jméno
  `"logger"`, a volání `window.iOSNativeAPI.enableBluetooth()` po
  `didFinish` navigaci) — psáno na míru, inspirováno (ne kopírováno)
  originálním `WBWebView.swift`, který jsme nekopírovali (naše appka
  používá vlastní `WKWebView` přes `WebViewContainer`, ne WebBLE
  storyboardovou obrazovku).

## Co jsme NEkopírovali (a proč)

`WBWebView.swift`, `WBWebViewController.swift`,
`WBWebViewContainerController.swift`, `WBPopUpPickerController.swift`,
`WBPopUpPickerView.swift`, `Segues.swift`, `Animations.swift`,
`ErrorViewController.swift`, `WBLog.swift`, `WBLogManager.swift` — všechno
je storyboard/UIKit obalová vrstva pro samostatnou appku WebBLE (vlastní
prohlížeč s adresním řádkem, konzolí v UI, atd.). Tabule na zápěstí
cockpit načítá do vlastního `WKWebView` (`App/WebViewContainer.swift`,
SwiftUI), takže potřebuje jen jádro (`WBManager`/`WBDevice`/`WBTransaction`
+ JS polyfill), ne celou obalovou appku.

## Známé omezení — dlouhé zápisy (⚠️ DŮLEŽITÉ pro přenos souboru)

`WBDevice.swift` (`writeCharacteristicValue`, případ `.never` = write
without response) dělá **jediné** `peripheral.writeValue(view.data, for:
char, type: .withoutResponse)` na každé volání z JS — **žádné dělení podle
`peripheral.maximumWriteValueLength(for:)`**. JS strana
(`WBBluetoothRemoteGATTCharacteristic.js`, `writeValue`) dávkuje po
**1024 B** (`WRITE_BATCH_SIZE`) přes most JS→native, ale to je jen limit
zprávy mezi JS a Swiftem, ne limit BLE ATT vrstvy — reálný negociovaný MTU
(u hodinek 515 B, tj. ~512 B užitečného obsahu na jeden zápis, F13) je
menší. **Write Without Response (Write Command) v BLE nemá na úrovni ATT
žádný mechanismus na fragmentaci** — jediný zápis nad limit MTU se
nespolehlivě zkrátí/zahodí, ne pošle po částech.

**Důsledek pro `web/hodinky.js`:** stejně jako nativní `BLEManager.posli()`
(Swift), i tahle JS cesta posílá celý FunDo rámec (u přenosu souboru až
12 288+17 B na blok, F13) jako **jeden** `writeValueWithoutResponse()`
volání — to **není u žádné z obou cest ověřené na hardwaru** (README appky
to u nativní cesty přiznává výslovně). Než se ověří na skutečných
hodinkách, ber přenos velkých bloků (cokoliv nad ~512 B) přes BLE write
without response u **obou** implementací jako rizikové, ne jako hotové.
Když se to na hardwaru ukáže jako nefunkční, řešení je rozdělit i
aplikační „blok" (12 288 B) na dílčí BLE zápisy ≤ negociovaný
`maximumWriteValueLength`, s vlastním sekvenčním číslováním na téhle nižší
úrovni — to `web/hodinky.js` ani `BLEManager.swift` dnes nedělá.

MTU samotné (negociace ≥ 512 B) není polyfillem nijak ovlivněné — jede na
stejném CoreBluetooth jako nativní cesta, takže se negociuje stejně
(hodinky dřív vyjednaly 515 B, F13).
