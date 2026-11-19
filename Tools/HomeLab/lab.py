"""Serve the HomeLab demo, verify it from a client, or back up its SQLite data."""
import argparse
from contextlib import closing
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import sqlite3
from tempfile import TemporaryDirectory
from threading import Lock, Thread
from urllib.error import HTTPError
from urllib.parse import urlsplit
from urllib.request import urlopen


GUEST_IP = "192.168.61.20"
PORTAL = """<!doctype html>
<html lang="es">
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>HomeLab Proxmox</title>
<h1>HomeLab Proxmox</h1>
<p>VM 120 · VLAN 20 · Servicios</p>
<ul>
<li><a href="/healthz">Estado de HTTP y SQLite</a></li>
<li><a href="/api/inventory">Inventario persistente</a></li>
<li><a href="/metrics">Métricas</a></li>
</ul>
</html>
"""


def initialize(database):
    database.parent.mkdir(parents=True, exist_ok=True)
    with closing(sqlite3.connect(database)) as connection, connection:
        connection.execute("CREATE TABLE IF NOT EXISTS inventory (name TEXT PRIMARY KEY, role TEXT NOT NULL)")
        connection.executemany("INSERT OR IGNORE INTO inventory VALUES (?, ?)", [
            ("GW-HOME", "Gateway 802.1Q"),
            ("SW-HOME", "Switch de acceso"),
            ("PVE-01", "Proxmox VE"),
            ("NAS-01", "Almacenamiento"),
            ("VM 120", "HTTP, SQLite y métricas"),
        ])


def inventory(database):
    with closing(sqlite3.connect(database.resolve().as_uri() + "?mode=ro", uri=True)) as connection:
        return [{"name": name, "role": role} for name, role in
                connection.execute("SELECT name, role FROM inventory ORDER BY name")]


def backup(database, destination):
    source = database.resolve().as_uri() + "?mode=ro"
    # Publish only the finished SQLite snapshot, without replacing an older copy.
    with TemporaryDirectory(prefix=".homelab-backup-", dir=destination.parent) as temporary:
        snapshot = Path(temporary) / "snapshot.sqlite"
        with closing(sqlite3.connect(source, uri=True)) as existing, closing(sqlite3.connect(snapshot)) as target:
            existing.backup(target)
        os.link(snapshot, destination)


class HomeLabHTTPServer(ThreadingHTTPServer):
    def __init__(self, address, database):
        self.database = database
        self.requests = 0
        self.request_lock = Lock()
        super().__init__(address, HomeLabHandler)


class HomeLabHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        with self.server.request_lock:
            self.server.requests += 1
            requests = self.server.requests
        path = urlsplit(self.path).path
        if path == "/":
            self.reply(HTTPStatus.OK, "text/html; charset=utf-8", PORTAL)
            return
        if path not in {"/healthz", "/api/inventory", "/metrics"}:
            self.json_reply(HTTPStatus.NOT_FOUND, {"error": "Ruta inexistente."})
            return
        try:
            rows = inventory(self.server.database)
        except sqlite3.Error:
            self.json_reply(HTTPStatus.SERVICE_UNAVAILABLE, {"status": "unavailable", "sqlite": "error"})
            return
        if path == "/healthz":
            self.json_reply(HTTPStatus.OK, {"status": "ok", "vm": 120, "sqlite": "ok"})
        elif path == "/api/inventory":
            self.json_reply(HTTPStatus.OK, rows)
        else:
            self.reply(HTTPStatus.OK, "text/plain; version=0.0.4; charset=utf-8",
                       "# TYPE homelab_http_requests_total counter\n"
                       f"homelab_http_requests_total {requests}\n"
                       "# TYPE homelab_inventory_devices gauge\n"
                       f"homelab_inventory_devices {len(rows)}\n")

    def json_reply(self, status, payload):
        self.reply(status, "application/json; charset=utf-8", json.dumps(payload, ensure_ascii=False))

    def reply(self, status, media_type, response):
        body = response.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", media_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        self.wfile.write(body)


def check(url):
    with urlopen(url + "/healthz", timeout=4) as response:
        if json.load(response) != {"status": "ok", "vm": 120, "sqlite": "ok"}:
            raise ValueError("La VM 120 no reporta SQLite operativo.")
    with urlopen(url + "/api/inventory", timeout=4) as response:
        names = {item["name"] for item in json.load(response)}
        if not {"PVE-01", "NAS-01"}.issubset(names):
            raise ValueError("Faltan equipos de referencia en el inventario.")
    with urlopen(url + "/metrics", timeout=4) as response:
        if b"homelab_http_requests_total" not in response.read():
            raise ValueError("El servicio no entrega métricas.")
    print("HTTP 200 · SQLite · inventario · métricas")


def self_test():
    with TemporaryDirectory(prefix="nexus-homelab-") as temporary:
        database = Path(temporary) / "inventory.sqlite"
        snapshot = Path(temporary) / "snapshot.sqlite"
        initialize(database)
        with HomeLabHTTPServer(("127.0.0.1", 0), database) as server:
            worker = Thread(target=server.serve_forever)
            worker.start()
            url = f"http://127.0.0.1:{server.server_port}"
            try:
                check(url)
                with urlopen(url, timeout=4) as response:
                    assert b"HomeLab Proxmox" in response.read()
                backup(database, snapshot)
                assert inventory(database) == inventory(snapshot)
                try:
                    backup(database, snapshot)
                except FileExistsError:
                    pass
                else:
                    raise AssertionError("Se sobrescribió una copia previa.")
                database.rename(database.with_suffix(".offline"))
                try:
                    urlopen(url + "/healthz", timeout=4)
                except HTTPError as failure:
                    assert failure.code == 503
                else:
                    raise AssertionError("Estado incorrecto con la base no disponible.")
                assert inventory(snapshot)
                print("Portal · copia restaurable · protección de copias · HTTP 503 verificados")
            finally:
                server.shutdown()
                worker.join()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    serve = commands.add_parser("serve")
    serve.add_argument("--bind", choices=["127.0.0.1", GUEST_IP], default="127.0.0.1")
    serve.add_argument("--port", type=int, default=8080)
    serve.add_argument("--database", type=Path, default=Path.home() / ".nexus-homelab" / "inventory.sqlite")
    probe = commands.add_parser("check")
    probe.add_argument("--url", default="http://127.0.0.1:8080")
    copy = commands.add_parser("backup")
    copy.add_argument("source", type=Path)
    copy.add_argument("destination", type=Path)
    commands.add_parser("self-test")
    args = parser.parse_args()

    if args.command == "serve":
        initialize(args.database)
        with HomeLabHTTPServer((args.bind, args.port), args.database) as server:
            print(f"VM 120 · http://{args.bind}:{server.server_port}", flush=True)
            try:
                server.serve_forever()
            except KeyboardInterrupt:
                pass
    elif args.command == "check":
        check(args.url.rstrip("/"))
    elif args.command == "backup":
        backup(args.source, args.destination)
        print(args.destination)
    else:
        self_test()


if __name__ == "__main__":
    main()
