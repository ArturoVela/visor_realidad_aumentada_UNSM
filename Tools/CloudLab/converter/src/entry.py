import json
import os
from urllib.parse import unquote

from workers import Response, WorkerEntrypoint

from export_pkt import MAX_INPUT, MAX_OUTPUT, ExportError, PacketTracerError, read_lab_bytes, to_topology

# The portable backend works in the Worker runtime without native libgcrypt.
os.environ["PKT_CORE_BACKEND"] = "pure"


def convert(raw: bytes, selector: str) -> tuple[bytes, str]:
    topology = to_topology(read_lab_bytes(raw), "Práctica Packet Tracer")
    matches = [device for device in topology["devices"] if selector in (device["id"], device["name"])]
    if len(matches) != 1:
        raise ExportError("El equipo indicado debe existir una sola vez en Packet Tracer. Usa su ID si hay nombres repetidos.")
    device = matches[0]
    if len(device["id"]) > 64 or not device["id"].isascii():
        raise ExportError("El identificador de Packet Tracer del equipo no es compatible.")
    for item in topology["devices"]:
        item.pop("configuration", None)
        if details := item.get("packetTracer"):
            details["description"] = ""
            for interface in details["interfaces"]:
                interface.pop("description", None)
    topology["notes"] = []
    if "logicalPlan" in topology:
        topology["logicalPlan"]["labels"] = []
    topology["name"] = device["name"]
    data = json.dumps(topology, ensure_ascii=False, separators=(",", ":"), allow_nan=False).encode()
    if len(data) > MAX_OUTPUT - 1024:
        raise ExportError("La publicación supera 8 MiB. Divide el laboratorio.")
    return data, device["id"]


class Default(WorkerEntrypoint):
    async def fetch(self, request):
        if request.method != "POST":
            return Response("Método inválido.", status=405)
        selector = unquote(request.headers.get("X-Nexus-Device", ""))
        if not 1 <= len(selector) <= 160:
            return Response("Indica el equipo de Packet Tracer.", status=422)
        try:
            raw = bytes(await request.bytes())
            if not 1 <= len(raw) <= MAX_INPUT:
                raise ExportError("El .pkt está vacío o supera 16 MiB.")
            data, identifier = convert(raw, selector)
        except ExportError as error:
            return Response(str(error)[:300], status=422)
        except (PacketTracerError, ValueError, OSError, RecursionError):
            return Response("El archivo no es un laboratorio .pkt compatible.", status=422)
        return Response(data.decode(), headers={"Content-Type": "application/json", "X-Nexus-Device-ID": identifier})
