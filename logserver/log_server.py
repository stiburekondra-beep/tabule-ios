#!/usr/bin/env python3
"""Malý přijímač diagnostického logu appky "Tabule na zápěstí" (iOS).

Jen stdlib, žádné závislosti. Appka (`Core/LogUploader.swift`) sem
dávkově posílá záznamy z `Core/Log.swift`, ať je log vidět i mimo
telefon -- typicky na Hubu (HQ), ať do něj může koukat Claude na
notebooku přes SSH/Tailscale (viz F18-appka-na-telefonu.md, Ondrova
připomínka o logu).

Endpointy:
  POST /log        tělo JSON {"zarizeni":..., "cas":..., "zaznamy":[{"t","u","z"}, ...]}
                    -> připojí řádky do ~/tabule-log.txt, vrátí {"ok": true}
  GET  /log?n=200   posledních N řádků logu jako text/plain
  GET  /            jednoduchá HTML stránka, co se sama obnovuje (2 s)
                     a ukazuje posledních 200 řádků

Spuštění:
  python3 log_server.py [port]      # výchozí port 8899, bind 0.0.0.0

Soubor s logem: ~/tabule-log.txt (jeden řádek na záznam,
"ISO8601  UROVEN  text"), appendovaný -- appka i server ho jen rozšiřují,
nikdy nemažou (ruční úklid je na Ondrovi).
"""
from __future__ import annotations

import json
import sys
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse, parse_qs

LOG_SOUBOR = Path.home() / "tabule-log.txt"
VYCHOZI_PORT = 8899


def _ted_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def _pripoj_zaznamy(zarizeni: str, zaznamy: list) -> int:
    """Připojí záznamy do LOG_SOUBOR, vrátí počet zapsaných řádků."""
    radky = []
    for z in zaznamy:
        if not isinstance(z, dict):
            continue
        t = str(z.get("t") or _ted_iso())
        u = str(z.get("u") or "info").upper()
        text = str(z.get("z") or "")
        radky.append(f"{t}  {u}  [{zarizeni}] {text}")
    if not radky:
        return 0
    with LOG_SOUBOR.open("a", encoding="utf-8") as f:
        f.write("\n".join(radky) + "\n")
    return len(radky)


def _posledni_radky(n: int) -> list[str]:
    if not LOG_SOUBOR.exists():
        return []
    with LOG_SOUBOR.open("r", encoding="utf-8", errors="replace") as f:
        radky = f.readlines()
    return [r.rstrip("\n") for r in radky[-n:]]


HTML_STRANKA = """<!DOCTYPE html>
<html lang="cs">
<head>
<meta charset="utf-8">
<title>Tabule na zápěstí -- log</title>
<meta http-equiv="refresh" content="2">
<style>
  body {{ background:#111; color:#ddd; font-family: ui-monospace, Menlo, Consolas, monospace;
          font-size: 12px; margin: 0; padding: 12px; white-space: pre-wrap; word-break: break-word; }}
  h1 {{ font-size: 14px; color: #8ab4f8; margin: 0 0 8px; }}
</style>
</head>
<body>
<h1>Tabule na zápěstí -- posledních {n} řádků (obnova každé 2 s)</h1>
<div>{obsah}</div>
</body>
</html>
"""


class Handler(BaseHTTPRequestHandler):
    server_version = "TabuleLogServer/1.0"

    def _cors(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type, Authorization")

    def do_OPTIONS(self):
        self.send_response(204)
        self._cors()
        self.end_headers()

    def do_POST(self):
        parsed = urlparse(self.path)
        if parsed.path != "/log":
            self.send_response(404)
            self._cors()
            self.end_headers()
            return
        delka = int(self.headers.get("Content-Length") or 0)
        surova = self.rfile.read(delka) if delka > 0 else b"{}"
        try:
            telo = json.loads(surova.decode("utf-8"))
        except (json.JSONDecodeError, UnicodeDecodeError):
            telo = {}
        zarizeni = str(telo.get("zarizeni") or "?")
        zaznamy = telo.get("zaznamy") or []
        pocet = _pripoj_zaznamy(zarizeni, zaznamy)

        odpoved = json.dumps({"ok": True, "zapsano": pocet}).encode("utf-8")
        self.send_response(200)
        self._cors()
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(odpoved)))
        self.end_headers()
        self.wfile.write(odpoved)

    def do_GET(self):
        parsed = urlparse(self.path)
        if parsed.path == "/log":
            qs = parse_qs(parsed.query)
            try:
                n = int(qs.get("n", ["200"])[0])
            except ValueError:
                n = 200
            n = max(1, min(n, 5000))
            obsah = "\n".join(_posledni_radky(n)) + "\n"
            data = obsah.encode("utf-8")
            self.send_response(200)
            self._cors()
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return

        if parsed.path == "/":
            n = 200
            radky = _posledni_radky(n)
            import html as _html
            obsah = "\n".join(_html.escape(r) for r in radky) if radky else "(zatím žádný log)"
            stranka = HTML_STRANKA.format(n=n, obsah=obsah)
            data = stranka.encode("utf-8")
            self.send_response(200)
            self._cors()
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return

        self.send_response(404)
        self._cors()
        self.end_headers()

    def log_message(self, format, *args):  # méně žvatlání do konzole
        sys.stderr.write("%s - %s\n" % (self.address_string(), format % args))


def main():
    port = VYCHOZI_PORT
    if len(sys.argv) > 1:
        try:
            port = int(sys.argv[1])
        except ValueError:
            pass
    server = ThreadingHTTPServer(("0.0.0.0", port), Handler)
    print(f"log_server: naslouchám na 0.0.0.0:{port}, log -> {LOG_SOUBOR}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
