# Log server — přijímač diagnostického logu appky Tabule

`log_server.py` je malý HTTP server (jen stdlib, žádné závislosti — jen
`python3`), který přijímá diagnostický log z appky **Tabule na zápěstí**
(`Core/LogUploader.swift` na iOS) a ukládá ho do textového souboru. Vznikl
kvůli Ondrově připomínce z ostrého běhu appky (F18): *„proč tam nemáš
nějaký log, ať to vidíš"* — log v appce je fajn, ale je potřeba ho vidět
i mimo telefon, typicky z notebooku přes SSH/Tailscale.

## Spuštění na HQ (Hub)

```bash
cd ios/logserver
python3 log_server.py 8899     # port volitelně, výchozí 8899
```

Poběží na popředí (Ctrl+C ukončí). Na trvalý běh na Hubu doporučeno
spustit přes `systemd`/`screen`/`tmux`, případně na pozadí:

```bash
nohup python3 log_server.py 8899 > ~/tabule-log-server.log 2>&1 &
```

Server naslouchá na `0.0.0.0:8899` (dostupný přes Tailscale, stejně jako
zbytek Hubu), CORS je otevřené (`*`), takže appka i prohlížeč z jiné sítě
projdou bez problémů.

## Jak se na log kouknout

- **V appce** — appka má vlastní log přímo v UI (rolovací sekce dole na
  hlavní i nouzové obrazovce), tenhle server je jen kopie navíc.
- **V prohlížeči** — `http://<hq-tailscale-ip>:8899/` — jednoduchá stránka,
  co se sama obnovuje každé 2 s a ukazuje posledních 200 řádků.
- **Z příkazové řádky / Claude na notebooku:**
  ```bash
  curl "http://<hq-tailscale-ip>:8899/log?n=200"
  ```
  (`n` = kolik posledních řádků, výchozí 200, max 5000.)
- **Přímo ze souboru na HQ** (nejspolehlivější, i když server zrovna
  neběží): `~/tabule-log.txt` na stroji, kde server běží — appendovaný
  soubor, jeden řádek na záznam:
  ```
  2026-09-22T10:00:00Z  ODESLANO  [iPhone] seq 8193 · vibrace · ba 21 00 05 00 20 00 01 00 00
  ```

## Nastavení appky

V appce → Nastavení → sekce „Log server" → vyplnit
`http://<hq-tailscale-ip>:8899/log`. Prázdné pole = appka log nikam
neposílá (log v appce samotné funguje pořád, bez ohledu na tohle
nastavení).

## Formát

- `POST /log` — tělo JSON:
  ```json
  {"zarizeni": "iPhone", "cas": "2026-09-22T10:00:00Z",
   "zaznamy": [{"t": "2026-09-22T10:00:00Z", "u": "odeslano", "z": "text"}]}
  ```
  Odpověď: `{"ok": true, "zapsano": <n>}`.
- `GET /log?n=200` — posledních N řádků jako `text/plain`.
- `GET /` — HTML stránka s auto-refreshem.

Log se jen **připojuje** (append), nikdy nemaže — ruční úklid
`~/tabule-log.txt` je na Ondrovi, až přeroste.
