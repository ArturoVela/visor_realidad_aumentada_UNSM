"""Runnable HTTP reference service and three clients for the Nexus VLAN 20 lab."""
import argparse
from concurrent.futures import ThreadPoolExecutor
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from threading import Thread
from urllib.parse import parse_qs, urlencode, urlsplit
from urllib.request import urlopen


SERVER_IP = "192.168.20.10"
CLIENTS = {f"PC-{number:02}": f"192.168.20.{100 + number}" for number in range(1, 4)}


class LabRequestHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        request = urlsplit(self.path)
        if request.path in ("/", "/healthz"):
            self.reply(HTTPStatus.OK, {"server": "SERVIDOR-LAB", "status": "ok", "vlan": 20})
        elif request.path == "/api/status":
            client, = parse_qs(request.query).get("pc", [""])[:1]
            if client not in CLIENTS:
                self.reply(HTTPStatus.BAD_REQUEST, {"error": "Usa PC-01, PC-02 o PC-03."})
                return
            self.reply(HTTPStatus.OK, {
                "server": "SERVIDOR-LAB",
                "client": client,
                "address_in_plan": CLIENTS[client],
                "remote_address": self.client_address[0],
                "vlan": 20,
            })
        else:
            self.reply(HTTPStatus.NOT_FOUND, {"error": "Ruta inexistente."})

    def reply(self, status, payload):
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)


def check(base_url, clients):
    def probe(pc):
        with urlopen(f"{base_url}/api/status?{urlencode({'pc': pc})}", timeout=4) as response:
            result = json.load(response)
        expected = ("SERVIDOR-LAB", pc, CLIENTS[pc], 20)
        actual = tuple(result.get(key) for key in ("server", "client", "address_in_plan", "vlan"))
        if actual != expected:
            raise ValueError(f"Respuesta del laboratorio inesperada para {pc}")
        return f"{pc} ({CLIENTS[pc]}) → SERVIDOR-LAB · HTTP 200"

    with ThreadPoolExecutor(max_workers=len(clients)) as pool:
        for result in pool.map(probe, clients):
            print(result)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    serve = commands.add_parser("serve")
    serve.add_argument("--bind", choices=["127.0.0.1", SERVER_IP], default="127.0.0.1")
    serve.add_argument("--port", type=int, default=8080)
    probe = commands.add_parser("check")
    probe.add_argument("--url", default="http://127.0.0.1:8080")
    probe.add_argument("--pc", choices=list(CLIENTS))
    commands.add_parser("self-test")
    args = parser.parse_args()

    if args.command == "serve":
        with ThreadingHTTPServer((args.bind, args.port), LabRequestHandler) as server:
            print(f"SERVIDOR-LAB: http://{args.bind}:{server.server_port}", flush=True)
            try:
                server.serve_forever()
            except KeyboardInterrupt:
                pass
    elif args.command == "check":
        check(args.url.rstrip("/"), [args.pc] if args.pc else list(CLIENTS))
    else:
        with ThreadingHTTPServer(("127.0.0.1", 0), LabRequestHandler) as server:
            thread = Thread(target=server.serve_forever)
            thread.start()
            try:
                check(f"http://127.0.0.1:{server.server_port}", list(CLIENTS))
            finally:
                server.shutdown()
                thread.join()


if __name__ == "__main__":
    main()
