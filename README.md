# Tabule na zápěstí — iOS appka

Appka pro **Niceboy Watch 5 Lite** (protokol FunDo přes BLE), postavená
kolem cockpitu Baklažánu. Architektura, protokol a formát obrázku vychází
z výzkumu v `lab/hodinky-niceboy/` (soubory `F*.md`) a z referenční
implementace `web/tabule.html`, ze které je většina Core logiky
přepsaná 1:1 do Swiftu.

## Architektura (aktuální, po opravě 21. 9. 2026)

Appka **není samostatná obrazovka pro hodinky — je to obal kolem
cockpitu**:

1. Hlavní UI = `WKWebView` (`Tabule/App/WebViewContainer.swift`) na celou
   obrazovku, načítá cockpit z URL v Nastavení (výchozí prázdná — appka
   pak rovnou ukáže nouzovou obrazovku). Appka respektuje systémovou
   Tailscale VPN (na rozdíl od Bluefy, viz F17).
2. **JavaScript most** — `WKScriptMessageHandler` s názvem `hodinky`
   (`Tabule/Core/WebBridge.swift`). Cockpit volá:
   ```js
   window.webkit.messageHandlers.hodinky.postMessage({akce: "tabule", sessions: [...]})
   window.webkit.messageHandlers.hodinky.postMessage({akce: "vibrace"})
   window.webkit.messageHandlers.hodinky.postMessage({akce: "zelena"})
   window.webkit.messageHandlers.hodinky.postMessage({akce: "stav"})
   ```
   `sessions` u akce `tabule` je pole objektů `{title, summary, status, waiting}`
   (stejný tvar jako `/api/sessions` z Hubu).

   Appka odpovídá voláním JS funkcí v cockpitu (když existují):
   ```js
   window.hodinkyStav({pripojeno, nazev, baterie, prenosProbiha, prubeh, prubehText, posledniChyba})
   window.hodinkyTlacitko('ANO' | 'NE' | 'POKRAČUJ' | 'POZDĚJI')
   ```
   `hodinkyStav` se volá po každé změně stavu BLE/přenosu (bez vyžádání)
   i jako odpověď na `{akce:"stav"}`.
3. Vlastní SwiftUI (`Tabule/App/NouzovaObrazovka.swift` +
   `NastaveniView.swift`) je jen **malý panel Nastavení** (ozubené kolo
   vpravo nahoře — místo gesta, spolehlivější) a **nouzová obrazovka**,
   která se ukáže, když cockpit není nastavený nebo se nenačte: stav BLE,
   baterie, náhled tabule, tlačítka Připojit / Poslat tabuli (z Hubu) /
   Zkouška zelená / Vibrace.
4. BLE na pozadí, FunDo protokol, tabule, přehrávač pro tlačítka,
   probouzení a polling Hubu jedou pořád, nezávisle na tom, jestli je
   vidět cockpit nebo nouzová obrazovka — všechno visí na jediné instanci
   `TabuleService` (`Tabule/Core/TabuleService.swift`).

## Co je hotové

| vrstva | soubor | poznámka |
|---|---|---|
| CRC16/CCITT-FALSE, CRC32 (zlib) | `Core/CRC.swift` | testy s reálnými rámci |
| FunDo rámec (stavba/rozbor, F6+F16 oprava) | `Core/FunDoFrame.swift` | byte-exaktní testy |
| BLE central, párování odpovědí podle seq, reconnect | `Core/BLEManager.swift` | **neověřeno na hardwaru** |
| RGB565 BE převod, zelená zkouška | `Core/DialImage.swift` | testy na červená/modrá/bílá |
| vykreslení tabule (CoreGraphics) | `Core/DialRenderer.swift` | layout podle `tabule.html` |
| sestavení souboru ciferníku + CRC32 | `Core/DialImage.swift` (`DialFile`) | testy na offsetech a CRC |
| přenos po blocích (0xC0→0xC2→0xC5, timeout 15 s/blok) | `Core/BLEManager.swift` (`posliSoubor`) | **neověřeno na hardwaru** |
| Hub klient (`/api/sessions`, `/api/smer`, `/api/poll`) | `Core/HubClient.swift` | `/api/poll` a `/api/smer` viz poznámky níže |
| dva sloty ciferníku (přepnutí, dotaz, střídání) | `Core/FunDoFrame.swift`, `Core/BLEManager.swift`, `Core/TabuleService.swift` | **celé neověřeno**, viz „Dva sloty ciferníku" níže |
| MPRemoteCommandCenter (ANO/NE/POKRAČUJ/POZDĚJI) | `Core/NowPlayingController.swift` | **neověřeno na hardwaru** |
| probouzení z notify (max 1×/20 s dotaz na Hub) | `Core/TabuleService.swift` | **neověřeno na hardwaru** |
| WebView + JS most | `App/WebViewContainer.swift`, `Core/WebBridge.swift` | — |
| nouzová obrazovka + nastavení | `App/NouzovaObrazovka.swift`, `App/NastaveniView.swift` | — |
| diagnostický log (kruhový buffer 500, UI panel, upload na server) | `Core/Log.swift`, `Core/LogUploader.swift`, `App/LogView.swift` | přidáno po F18 (Ondrova připomínka „proč tam nemáš nějaký log"), **neověřeno na hardwaru** |
| log server (Python, stdlib) | `logserver/log_server.py` | běží na Hubu, appka na něj POSTuje, viz `logserver/README.md` |
| XcodeGen projekt | `project.yml` | negenerováno lokálně (Mac tu není) |
| CI (test + archiv + .ipa) | `.github/workflows/build-ios.yml` | **nespuštěno** — zatím jen v `ios/`, ne v kořeni repa |

## Diagnostický log

Appka drží kruhový buffer posledních **500** záznamů (`Core/Log.swift`,
`Log.sdilene`, `@MainActor` singleton) — čas, úroveň (`info` / `odeslano` /
`prijato` / `chyba`) a text. Loguje se skoro všechno: stav BLE (zapnutý/
vypnutý, sken, nalezeno, připojeno/odpojeno + důvod), **každý odeslaný
rámec v hexu i s popisem** (`seq 8193 · vibrace · ba 21 00 05 …`), **každá
přijatá odpověď v hexu**, párování podle seq (sedí/nesedí/timeout), průběh
přenosu souboru (číslo bloku, offset, potvrzeno/timeout), HTTP dotazy na
Hub (URL, status, chyba), chyby WebView (i URL, na kterou se sahalo — i
klasický `-999` z F18), stisky tlačítek z přehrávače a změny režimu
(Normální/Šetřit).

**V appce**: rolovací sekce „Log" dole na hlavní i nouzové obrazovce
(`App/LogView.swift`) — sbalená ukazuje jen počet záznamů, rozbalená
monospace/malé písmo, nejnovější dole, auto-scroll, tlačítka Kopírovat
a Odeslat na server.

**Na notebooku**: `Core/LogUploader.swift` posílá dávkově (~5 s, nebo hned
při chybě) nové záznamy na URL z Nastavení („Log server" — prázdné =
neposílat) na `ios/logserver/log_server.py` (jen stdlib, běží na Hubu,
`POST /log`, `GET /log?n=200`, auto-refreshující `GET /`). Selhání
uploadu je tiché — appka nic nehlásí, jen to zkusí znovu příště. Viz
`logserver/README.md`.

Vzniklo po F18 (appka poprvé na telefonu, 21.–22. 9. 2026) — Ondrova
připomínka: *„proč tam nemáš nějaký log, ať to vidíš"*.

## Baterie a dva režimy

Appka umí dva režimy (přepínač v Nastavení → sekce „Baterie", ukládá se do
UserDefaults, appka aktuální režim ukazuje v UI i cockpitu přes
`window.hodinkyStav({setrit: …})`):

| | **Normální** | **Šetřit** |
|---|---|---|
| tichá audio session + `MPRemoteCommandCenter` (tlačítka ANO/NE/POKRAČUJ/POZDĚJI) | zapnuto | **vypnuto** |
| dotazování Hubu | dlouhý poll `/api/poll?machine=hodinky&wait=45` (`Core/HubClient.swift`, `dlouhyPoll`) — appku probudí odpověď/timeout Hubu, ne pravidelný interval | **žádné** — jen po BLE notify z hodinek |
| probuzení z BLE notify hodinek (~20 s, F17) | běží navíc jako záloha (bod 7 zadání) | jediný zdroj probuzení, pak 1 GET `/api/sessions` |
| když Hub nedostupný | ustoupí na obyčejný `GET /api/sessions` max 1×/60 s s exponenciálním čekáním (do 5 min) | beze změny (stejně se ptá jen po BLE probuzení) |
| odhad dopadu na baterii | víc drží rádio v pohotovosti (dlouhý poll = 1 visící HTTP spojení) a stálou (byť tichou) audio session | výrazně méně — appka většinu času nedělá nic, dokud ji nevzbudí BLE |

**Čísla jsou odhad, ne měření** — appka se dnes nespustila na skutečném
zařízení. Skutečnou spotřebu obou režimů je potřeba změřit v provozu.

### Tichý zvuk

`NowPlayingController` generuje **skutečné ticho** — 0,25 s PCM buffer
samých nul při 8 kHz mono (`AVAudioPCMBuffer`), smyčkovaný přes
`AVAudioPlayerNode` s `.loops`. Žádný soubor v bundle, žádná hudba,
minimální paměť i CPU. Kategorie `AVAudioSession(.playback)` s
`.mixWithOthers`, aby appka nepřerušila hudbu ani hovor (zadání, doplněk
o baterii).

### Když hraje jiná appka (Spotify apod.)

`NowPlayingController` sleduje `AVAudioSession.interruptionNotification`
(skutečné přerušení, např. appka bez `mixWithOthers`, telefonát) i
`AVAudioSession.silenceSecondaryAudioHintNotification` (typický případ
`mixWithOthers` appky vedle sebe — obě běží, ale iOS pošle AVRCP tlačítka
z hodinek tomu, koho považuje za „now playing" appku, obvykle tomu
druhému). Appka se to **nesnaží přebírat** — jen nastaví
`jinaHudbaHraje = true`, což se projeví v `NouzovaObrazovka` (žlutá
hláška) i v cockpitu (`window.hodinkyStav({jinaHudbaHraje: true})`). Až
cizí zvuk/přerušení skončí, appka si znovu vezme now-playing (obnoví
tiché ticho i `MPRemoteCommandCenter`).

**Ťuk na hodinkách (ANO/NE/POKRAČUJ/POZDĚJI) tedy funguje, jen když nehraje
jiná appka. Hlasový asistent (F14, `AT+BVRA` přes HFP) funguje vždycky —
jede úplně jinou cestou, ne přes AVRCP/MPRemoteCommandCenter.**

## Dva sloty ciferníku (⚠️ celé NEOVĚŘENO)

Ondra nechce vidět loading bar ~20–30 s, který hodinky kreslí při nahrávání
**aktivního** ciferníku. Nápad: nahrávat vždy do slotu, který zrovna NENÍ
zobrazený, a po dokončení přepnout — přepnutí by mělo být okamžité, bez
loading baru.

**Co appka umí dnes:**
- `BLEManager.prepniCifernik(dialId:)` — pošle modul `0x04`, cmd `0x4F`
  (79), payload 1 bajt dialId. Číslo cmd je z cizího rozboru
  (`cizi/make-watcher-alive/05-status-and-todo.md`: „đổi mặt đồng hồ
  (4/78-79)" = „změna ciferníku"), ale **přesný payload nikde
  nestažený** (`RequestBuilder.java` s vysokoúrovňovým API v repu není) —
  1 bajt je odhad, `dialId` je v dekompilovaném `CustomClockDialItem.java`
  Java `int` (4 B), takže drátový formát může být širší.
- `BLEManager.dotazNaCifernikSeznamNeboStav()` — stejné odhadnuté cmd
  `0x4E` (78) pro „seznam ciferníků" i „stav ciferníku" (F5 zmiňuje čtyři
  oddělené operace — kompatibilita/seznam/stav/nastavit použitý — ale
  cizí zdroj dal jen dvě čísla pro celou fičuru „změna ciferníku"). Appka
  odpověď **neparsuje** (formát neznámý), jen ji ukáže jako hex v
  nouzové obrazovce (tlačítko „Dotaz: seznam/stav ciferníků").
- `TabuleService` po každém úspěšném nahrání střídá `posledniNahranySlot`
  (0/1, v `Nastaveni`/UserDefaults) a **best-effort** pošle
  `prepniCifernik` na nově „aktivní" slot — nefatální, když neodpoví.

**Co appka NEumí (a proč loading bar dnes pořád bude):** `BLEManager.posliSoubor`
má parametr `cilovySlot`, ale **nikam ho nezapisuje** — nevíme, kde přesně
v zahájení `0xC0` (prvních 21 B souboru, F13) nebo v hlavičce souboru se
cílový slot/dialId určuje. Jediný podezřelý kandidát je konstanta `0x64`
na offsetu 16 hlavičky souboru (F13: „stejné u všech" — ve všech dosavadních
vzorcích, ale ty všechny mířily na stejný/jediný slot, takže se to nedá
potvrdit ani vyvrátit). **Dokud se offset nenajde (živým odposlechem druhého
slotu), appka nahrává tam, kam hodinky samy rozhodnou — typicky aktuálně
zobrazený ciferník, se stejným loading barem jako přes oficiální appku.**
Přepnutí po nahrání navíc přepne na slot, do kterého jsme fakticky
nenahráli (protože jsme neuměli cílit) — tedy pravděpodobně ukáže starý/
prázdný obsah, ne čerstvou tabuli. **Tahle část je připravená konstrukce,
ne hotová funkce — potřebuje ověření na hardwaru.**

## Co je odhad / neověřené

- **Nic se dnes nepřipojovalo k hodinkám ani na Hub** — appka je napsaná
  podle zadání a podkladů `F*.md`, ale běžet mohla jen v hlavě, ne na
  simulátoru ani zařízení (Swift tady nejde spustit, Mac tu není).
- **`/api/smer`**: v `hub.py` (~řádek 1155) tenhle endpoint jen
  **rozhoduje**, kam by Ondrova zpráva patřila (vrací
  `{cil, jistota, label, zan}`), ale nenašel jsem v kódu navazující krok,
  který by text i **doručil** (to obvykle dělá `/api/events` s
  `role: reply`, který volá jiný klient). `HubClient.posliSmer` proto
  posílá `{"text": <ANO/NE/POKRAČUJ/POZDĚJI>, "zdroj": "hodinky"}`, jak
  zadání předepisuje jako fallback — ale nejspíš to jen spočítá routing
  a nikam to reálně nedoručí. **Nutno ověřit na běžícím Hubu a případně
  najít/doplnit skutečné doručovací API.**
- **`/api/poll?machine=hodinky`**: `_poll` v `hub.py` (~1094) je psaný na
  doručování `commands` konkrétnímu cíli (session/machine), ne jako obecné
  „něco se ve sessions změnilo" hlášení. Appka ho používá jen jako
  probouzecí mechanismus (visící spojení místo krátkého intervalu) — obsah
  případné fronty příkazů nijak nezpracovává. Funguje to, i kdyby appce
  nikdy žádný `command` nepřišel (Hub appku jen zaregistruje jako „stroj"
  a po timeoutu odpoví prázdně) — ale je to **odhad použití existujícího
  API**, ne ověřený navržený kontrakt.
- **Detekce cizí hudby** (`AVAudioSession.interruptionNotification`,
  `silenceSecondaryAudioHintNotification`) je napsaná podle dokumentace
  AVFoundation, ne vyzkoušená se skutečnou appkou typu Spotify na
  skutečném zařízení.
- **Layout tabule** (`DialRenderer`) je odhad podle `tabule.html` — barvy,
  velikosti písma a rozestupy nikdo neviděl na skutečném displeji 240×286.
- **MPRemoteCommandCenter na pozadí**: tichý smyčkovaný `AVAudioPlayerNode`
  buffer by měl držet audio session živou, ale jestli to na free Apple ID
  appce (bez push) skutečně stačí k doručení tlačítek i po uzamčení
  telefonu, je potřeba vyzkoušet na zařízení (F17 to zmiňuje jako otevřené).
- **BLE state restoration**: `CBCentralManagerOptionRestoreIdentifierKey`
  je nastavený, ale skutečné probuzení appky na pozadí kvůli BLE eventu
  (rámec z hodinek ~každých 20 s) je potřeba ověřit na zařízení — bez
  toho probouzecí smyčka (bod 7 zadání) neběží.
- **Kruhový náhled v souboru ciferníku** (druhý obrázek, ~80 kB za
  hlavním obrazem, viz F7) appka nepřepisuje — nechává ho tak, jak je
  v šabloně `cifernik_bily.bin`. Pokud by se ukázalo, že se kreslí přes
  hlavní obraz nebo naopak, bude potřeba i jeho vykreslení.

## Rozhraní `Core/TabuleService.swift`

Jediné místo, kam sahá jak `WebBridge`, tak nouzová obrazovka, tak
probouzecí smyčka — takže BLE/Hub logika existuje jen jednou:

- `pripojit()` — najde a připojí hodinky (nebo se pokusí o uložené id).
- `poslatVibraci()`, `nacistBaterii()`, `poslatZelenou()`.
- `poslatTabuli(_ obsah: TabuleObsah)` — vykreslí a nahraje podle
  dodaných sessions.
- `nacistZHubuAPoslat()` — `GET /api/sessions` → `poslatTabuli`, při
  chybě pošle „bez spojení".
- `zpracujStiskTlacitka(_ akce: String)` — volá se z
  `NowPlayingController`, pošle `/api/smer` a předá akci do `WebBridge`
  (→ `window.hodinkyTlacitko`).

## Jak spustit testy

Bez Macu tady nejde nic spustit — testy (`TabuleTests/`) jsou napsané
a projdou přes `xcodebuild test` v CI. Testovací pokrytí:

- `CRCTests.swift` — CRC16 na dvou nezávislých reálných rámcích
  (`F10-ovladani.md`, `F6-fundo-ramec.md`), CRC32 proti nezávislému
  Python `zlib.crc32` oraclu.
- `FunDoFrameTests.swift` — byte-exaktní dekódování/enkódování rámce
  `ba 21 00 05 6c 95 08 f0 05 00 50 00 00` (vibrace, ověřeno na živých
  hodinkách), párování odpovědi podle seq, ošetření krátkého rámce,
  špatného CRC a špatné délky.
- `DialFileTests.swift` — RGB565 BE převod (červená/modrá/bílá podle
  F7), sestavení souboru ciferníku (offset 100, CRC32 do `[8:12]` LE,
  ostatní bajty beze změny), dekódování JSON sessions z Hubu (`waiting`
  jako bool i jako int).

Lokálně (na Macu, který tu není):
```
cd ios
xcodegen generate
xcodebuild -project Tabule.xcodeproj -scheme Tabule \
  -destination 'platform=iOS Simulator,name=iPhone 15' test
```

## Jak se buildí (CI)

`.github/workflows/build-ios.yml` je připravený k přesunu do kořene
budoucího veřejného repa (musí být na `.github/workflows/...` od kořene,
jinak ho GitHub Actions nenajde). Dokud zůstává v `ios/`, nic sám od
sebe nespustí. Kroky: `brew install xcodegen` → `xcodegen generate` →
testy na simulátoru → nepodepsaný archiv (`CODE_SIGNING_ALLOWED=NO`) →
`Payload/Tabule.app` zabalený do `.ipa` → `actions/upload-artifact`.

## Jak nahrát přes AltStore

1. Windows PC s **AltServer** (běžící, na Wi-Fi — obnovuje podpis každých
   7 dní) + iTunes/iCloud stažené z webu Apple (ne z MS Store).
2. Obyčejné Apple ID, na iPhonu zapnutý Developer Mode.
3. `.ipa` z GitHub Actions artefaktu (nepodepsaná — AltServer ji podepíše
   free Apple ID při instalaci).
4. V AltStore: **My Apps → + → vyber staženou `.ipa`**.
5. První spuštění: Nastavení → Obecné → VPN a správa zařízení → důvěřovat
   vývojářskému profilu.

Limity free Apple ID (F17): max 3 appky, podpis platí 7 dní (AltServer ho
obnoví sám, pokud PC běží a je na Wi-Fi), **žádný push** — appka se
nedá probudit ze systému, jen z vlastního BLE eventu.

## Kde nastavit Hub a cockpit

V appce: ozubené kolo vpravo nahoře → **Nastavení**:
- **Cockpit** — URL cockpitu (např. `https://<tvuj-cockpit>/`, ale v appce natvrdo není, zadává se tady).
- **Žán Hub** — URL Hubu a token pro `Authorization: Bearer`.

Nic z toho není v kódu (UserDefaults přes `Core/Settings.swift`) — appka
je bezpečná pro budoucí veřejné repo.

## Vzniklé soubory

```
ios/project.yml
ios/README.md
ios/.github/workflows/build-ios.yml
ios/Tabule/App/TabuleApp.swift
ios/Tabule/App/ContentView.swift
ios/Tabule/App/WebViewContainer.swift
ios/Tabule/App/NouzovaObrazovka.swift
ios/Tabule/App/NastaveniView.swift
ios/Tabule/Core/CRC.swift
ios/Tabule/Core/FunDoFrame.swift
ios/Tabule/Core/DialImage.swift
ios/Tabule/Core/DialRenderer.swift
ios/Tabule/Core/TabuleModel.swift
ios/Tabule/Core/BLEManager.swift
ios/Tabule/Core/HubClient.swift
ios/Tabule/Core/Settings.swift
ios/Tabule/Core/NowPlayingController.swift
ios/Tabule/Core/WebBridge.swift
ios/Tabule/Core/TabuleService.swift
ios/Tabule/Resources/cifernik_bily.bin
ios/TabuleTests/CRCTests.swift
ios/TabuleTests/FunDoFrameTests.swift
ios/TabuleTests/DialFileTests.swift
```

## Co NENÍ v téhle appce

- Nic kolem firmwaru/OTA.
- Appka se dnes k ničemu nepřipojovala a nic neposílala — postavený je
  jen kód a testy, které běží bez hardwaru.
