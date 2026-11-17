#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Convert a local Packet Tracer lab to Nexus topology JSON, entirely offline."""
from __future__ import annotations

import argparse
import importlib.metadata
import ipaddress
import json
import os
from pathlib import Path
import re
import sys
import tempfile
import zlib

from pkt_core import decode
from pkt_core.codec import container as codec
from pkt_core.errors import PacketTracerError
from pkt_core.models import Lab
from pkt_core.models.lab import RunningConfig

MAX_INPUT = 16 * 1024 * 1024
MAX_XML = 32 * 1024 * 1024
MAX_OUTPUT = 8 * 1024 * 1024
MODEL_IDS = {
    "2960-24tt": "switch-2960", "2960-24tt-l": "switch-2960",
    "3560-24ps": "switch-3560", "1941": "router-1941", "2911": "router-2911",
    "5505": "firewall-asa5505", "asa5505": "firewall-asa5505",
    "7960": "phone-7960", "7960g": "phone-7960", "server-pt": "server-c220m5",
    "pc-pt": "pc-optiplex7010", "laptop-pt": "laptop-latitude5420",
}
MEDIA = {"eCopper": "copper", "eStraightThrough": "copper", "eCrossOver": "copper",
         "eFiber": "fiber", "eConsole": "console"}
CANONICAL_PORTS = {
    "switch-2960": {f"FastEthernet0/{n}" for n in range(1, 25)} | {"GigabitEthernet0/1", "GigabitEthernet0/2"},
    "switch-3560": {f"FastEthernet0/{n}" for n in range(1, 25)} | {"GigabitEthernet0/1", "GigabitEthernet0/2"},
    "router-1941": {"GigabitEthernet0/0", "GigabitEthernet0/1", "Console"},
    "router-2911": {"GigabitEthernet0/0", "GigabitEthernet0/1", "GigabitEthernet0/2", "Console"},
    "firewall-asa5505": {f"Ethernet0/{n}" for n in range(8)}, "server-c220m5": {"LOM1", "LOM2"},
    "phone-7960": {"SW", "PC"}, "pc-optiplex7010": {"Ethernet"}, "laptop-latitude5420": {"Ethernet"},
}


class ExportError(ValueError):
    pass


def bounded_inflate(payload: bytes) -> bytes:
    """Bound both Qt's declared size and actual zlib output before XML parsing."""
    if len(payload) < 4 or int.from_bytes(payload[:4], "big") > MAX_XML:
        raise ExportError("El XML descomprimido supera el límite de 32 MiB o está truncado.")
    stream = zlib.decompressobj()
    data = stream.decompress(payload[4:], MAX_XML + 1)
    if len(data) > MAX_XML or stream.unconsumed_tail:
        raise ExportError("El XML descomprimido supera el límite permitido.")
    if not stream.eof or stream.unused_data or len(data) != int.from_bytes(payload[:4], "big"):
        raise ExportError("Compresión truncada, tamaño inconsistente o datos adicionales.")
    return data


def read_lab(path: Path) -> Lab:
    if path.suffix.lower() != ".pkt":
        raise ExportError("Sólo se aceptan laboratorios .pkt; actividades .pka no se exportan.")
    if importlib.metadata.version("packet-tracer-pkt-format") != "0.4.1":
        raise ExportError("Este exportador requiere packet-tracer-pkt-format==0.4.1.")
    with path.open("rb") as source:
        raw = source.read(MAX_INPUT + 1)
    if len(raw) > MAX_INPUT:
        raise ExportError("El archivo supera 16 MiB.")
    # ponytail: 0.4.1 lacks an inflate limit; this local hook is single-threaded until upstream adds one.
    original = codec.quncompress
    codec.quncompress = bounded_inflate
    try:
        # Decode a bounded snapshot; never reread a concurrently growing input file.
        with tempfile.NamedTemporaryFile(suffix=".pkt") as snapshot:
            snapshot.write(raw)
            snapshot.flush()
            container = decode(snapshot.name)
    finally:
        codec.quncompress = original
    if container.format_name not in {"pkt", "legacy"}:
        raise ExportError("Contenedor no admitido como laboratorio .pkt.")
    lab = Lab.from_bytes(container.xml)
    if lab.is_activity or lab.activity_sections or lab.scoring_tree:
        raise ExportError("Se detectó una actividad o evaluación; no se exporta su contenido.")
    if lab.network is None:
        raise ExportError("El documento no contiene una red de laboratorio.")
    return lab


def vlan_id(value: str) -> int:
    if not value.isdecimal() or not 1 <= int(value) <= 4094:
        raise ExportError(f"VLAN no admitida: {value!r}.")
    return int(value)


def vlan_property(vlans: dict, identifier: int, key: str, value: str) -> None:
    record = vlans.setdefault(identifier, {})
    if key in record and record[key] != value:
        raise ExportError(f"VLAN {identifier} contiene {key} incompatibles entre dispositivos; no se elegirá uno silenciosamente.")
    record[key] = value


def canonical_port(model_id: str, original: str, port_count: int) -> str | None:
    if model_id in {"pc-optiplex7010", "laptop-latitude5420"}:
        return "Ethernet" if original in {"FastEthernet0", "GigabitEthernet0", "Ethernet"} else None
    if model_id == "server-c220m5":
        if original in {"FastEthernet0", "GigabitEthernet0", "LOM1"}:
            return "LOM1"
        if port_count >= 2 and original in {"FastEthernet1", "GigabitEthernet1", "LOM2"}:
            return "LOM2"
        return None
    if model_id == "phone-7960" and original == "Switch":
        return "SW"
    return original if original in CANONICAL_PORTS[model_id] else None


def port_medium(model_id: str, port: str) -> str:
    if port == "Console":
        return "console"
    return "fiber" if model_id == "switch-3560" and port.startswith("GigabitEthernet") else "copper"


def config_data(device, vlans: dict) -> tuple[str, list[str], dict[str, set[int]], list[dict]]:
    node = device.engine.find("RUNNINGCONFIG")
    ios = "\n".join(line.decode("utf-8", "strict") for line in RunningConfig.from_element(node).lines) if node else ""
    ports, by_port, profiles = [], {}, []
    current_port = current_vlan = None
    for raw_line in ios.splitlines():
        line = raw_line.strip()
        if line.startswith("interface "):
            current_port = None if line.startswith("interface range ") else line.split(maxsplit=1)[1]
            if current_port:
                ports.append(current_port)
            current_vlan = None
            match = re.fullmatch(r"Vlan(\d+)", current_port or "", re.IGNORECASE)
            if match:
                current_vlan = vlan_id(match[1])
        elif line.startswith("vlan "):
            current_port = None
            match = re.fullmatch(r"vlan (\d+)", line)
            current_vlan = vlan_id(match[1]) if match else None
        elif current_vlan is not None and line.startswith("name "):
            vlan_property(vlans, current_vlan, "name", line[5:])
        elif current_port and (match := re.fullmatch(r"(?:switchport access vlan|encapsulation dot1Q) (\d+)(?: native)?", line, re.IGNORECASE)):
            identifier = vlan_id(match[1])
            by_port.setdefault(current_port, set()).add(identifier)
            vlans.setdefault(identifier, {})
            if line.lower().startswith("encapsulation"):
                current_vlan = identifier
        elif current_port and (match := re.fullmatch(r"ip address (\S+) (\S+)", line)):
            ipaddress.IPv4Address(match[1])
            network = str(ipaddress.IPv4Network(f"{match[1]}/{match[2]}", strict=False))
            profiles.append(dict(port=current_port, ipv4=match[1], mask=match[2], gateway="", dns="",
                                 dhcp=None, vlan=str(current_vlan) if current_vlan else ""))
            if current_vlan is not None:
                vlan_property(vlans, current_vlan, "subnet", network)
        if current_vlan is not None:
            vlans.setdefault(current_vlan, {})
        if line in {"!", "exit", "end"}:
            current_port = current_vlan = None
    for config in device.port_configs:
        profile = {"port": config.port_name, "ipv4": config.ip_address, "mask": config.subnet_mask,
                   "gateway": config.gateway, "dns": config.dns, "dhcp": config.dhcp_enabled, "vlan": config.vlan}
        if config.port_name:
            ports.append(config.port_name)
        if config.vlan:
            identifier = vlan_id(config.vlan)
            vlans.setdefault(identifier, {})
            if config.port_name:
                by_port.setdefault(config.port_name, set()).add(identifier)
        if config.ip_address not in {"", "0.0.0.0"}:
            ipaddress.IPv4Address(config.ip_address)
        profiles.append(profile)
    return ios, ports, by_port, profiles


def service_data(device) -> tuple[list[str], dict]:
    services, records = [], {}
    for tag, label in [("HTTP_SERVER", "HTTP"), ("HTTPS_SERVER", "HTTPS"), ("DNS_SERVER", "DNS"),
                       ("FTP_SERVER", "FTP"), ("TFTP_SERVER", "TFTP"), ("NTP_SERVER", "NTP"),
                       ("SYSLOG_SERVER", "SYSLOG"), ("ACS_SERVER", "AAA")]:
        node = device.engine.find(tag)
        enabled = node.find("ENABLED") if node is not None else None
        if enabled is not None and enabled.text.strip().lower() in {"true", "1"}:
            services.append(label)
    if device.services:
        for field, label in [("dhcp_pools", "DHCP"), ("dns_records", "DNS"), ("aaa_clients", "AAA clientes"),
                             ("aaa_users", "AAA usuarios"), ("ftp_accounts", "FTP cuentas")]:
            values = getattr(device.services, field)
            if values:
                records[field] = [value.to_xml().decode("utf-8", "strict") for value in values]
                services.append(f"{label}: {len(values)} registro(s) guardado(s)")
    return services, records


def to_topology(lab: Lab, name: str) -> dict:
    source_devices, source_links = lab.devices, lab.links
    if not 1 <= len(source_devices) <= 96 or len(source_links) > 192:
        raise ExportError("Se admiten entre 1 y 96 equipos y hasta 192 enlaces.")
    if not name.strip() or len(name) > 160 or any(ord(c) < 32 for c in name):
        raise ExportError("Nombre de laboratorio vacío, excesivo o con caracteres de control.")
    devices, addresses, port_vlans, vlans, port_counts, visual_models = [], {}, {}, {}, {}, set()
    notes = ["Importación de datos Packet Tracer; no ejecuta IOS ni valida conectividad.",
             "Los puertos conservan nombres explícitos de cables/configuración; no se inventan puertos sin nombre.",
             "VLAN de enlaces: valores explícitos access/dot1Q; configuraciones trunk completas quedan como texto.",
             "Puertos lógicos o sin conector representable se conservan como configuración; no se añaden conectores físicos."]
    for source in source_devices:
        model_id = MODEL_IDS.get(source.model.casefold())
        if model_id is None:
            raise ExportError(f"Modelo no admitido: {source.model!r} ({source.name!r}). No se sustituirá automáticamente.")
        address = source.dev_addr
        if not address or len(address) > 128 or address in addresses:
            raise ExportError("Dirección interna dev_addr ausente o duplicada; no se adivinan extremos por nombre.")
        if len(source.name) > 160 or any(ord(c) < 32 or ord(c) == 127 for c in source.name + address):
            raise ExportError("Nombre o identificador con longitud o caracteres no admitidos.")
        identifier = f"pt-{address}"
        ios, ports, port_map, profiles = config_data(source, vlans)
        services, records = service_data(source)
        metadata = {"interfaces": profiles, "serviceRecords": records}
        configuration = ios
        if profiles or records:
            configuration += "\n\n# Metadatos Packet Tracer (no comandos IOS)\n" + json.dumps(metadata, ensure_ascii=False)
        if len(configuration.encode("utf-8")) > 65536:
            raise ExportError(f"Configuración excesiva en {source.name}; límite de 64 KiB por equipo.")
        if len(services) > 32 or any(len(service) > 120 for service in services):
            raise ExportError("Servicios fuera de los límites de importación.")
        actual_port_count = len(source.ports)
        original_ports = {}
        for original in ports:
            canonical = canonical_port(model_id, original, actual_port_count)
            if canonical:
                original_ports.setdefault(canonical, original)
        item = dict(id=identifier, name=source.name or source.model, modelID=model_id, placementID="unplaced",
                    offset=[0, 0, 0], services=services, ports=list(original_ports), sourceModel=source.model,
                    sourcePortNames=original_ports)
        if configuration:
            item["configuration"] = configuration
        ips = [p["ipv4"] for p in profiles if p["ipv4"] not in {"", "0.0.0.0"}]
        if ips:
            item["ipv4"] = ips[0]
        explicit_vlans = {vlan_id(p["vlan"]) for p in profiles if p["vlan"]}
        if len(explicit_vlans) == 1:
            item["vlan"] = next(iter(explicit_vlans))
        if source.model.casefold() in {"server-pt", "pc-pt", "laptop-pt"} and source.model.casefold() not in visual_models:
            notes.append(f"{source.model} usa {model_id} sólo como referencia visual; no es su hardware original.")
            visual_models.add(source.model.casefold())
        devices.append(item)
        addresses[address] = item
        port_vlans[identifier] = port_map
        port_counts[identifier] = actual_port_count
    links, occupied = [], set()
    for index, source in enumerate(source_links, 1):
        cable = source.cable
        if cable is None or len(cable.ports) != 2:
            raise ExportError("Enlace sin cable o sin dos puertos explícitos; no se infiere conectividad.")
        a, b = addresses.get(cable.from_device_addr), addresses.get(cable.to_device_addr)
        if a is None or b is None or a["id"] == b["id"]:
            raise ExportError("Extremo de enlace inválido: dev_addr no coincide con un dispositivo único.")
        medium = MEDIA.get(cable.cable_type) if cable.cable_type else MEDIA.get(source.type)
        if medium is None:
            raise ExportError(f"Medio de cable no admitido: {source.type}/{cable.cable_type}.")
        if medium == "console":
            raise ExportError("Consola no importable: el catálogo actual no incluye un host serie documentado; no se inventará RS232 en Dell.")
        canonical = []
        for item, original in zip((a, b), cable.ports):
            port = canonical_port(item["modelID"], original, port_counts[item["id"]])
            if port is None:
                raise ExportError(f"Puerto {original!r} no representable en {item['modelID']}; original conservado en el .pkt.")
            if len(original) > 128 or any(ord(c) < 32 or ord(c) == 127 for c in original) or (item["id"], port) in occupied:
                raise ExportError("Puerto vacío, excesivo o utilizado por más de un cable.")
            if port_medium(item["modelID"], port) != medium:
                raise ExportError(f"Medio {medium} incompatible con {item['modelID']}:{port} del catálogo visual.")
            occupied.add((item["id"], port))
            if port not in item["ports"]:
                item["ports"].append(port)
            item["sourcePortNames"][port] = original
            canonical.append(port)
        vlan_ids = port_vlans[a["id"]].get(cable.ports[0], set()) | port_vlans[b["id"]].get(cable.ports[1], set())
        links.append(dict(id=f"pt-link-{index}", fromDeviceID=a["id"], fromPort=canonical[0],
                          toDeviceID=b["id"], toPort=canonical[1], medium=medium, vlanIDs=sorted(vlan_ids)))
    if len(vlans) > 64:
        raise ExportError("La topología supera 64 VLAN.")
    if any(len(data.get("name", "")) > 120 for data in vlans.values()):
        raise ExportError("Nombre de VLAN excesivo.")
    if len(notes) > 64 or any(len(note) > 1000 for note in notes):
        raise ExportError("Notas fuera de los límites de importación.")
    return dict(name=name, devices=devices, links=links, notes=notes,
                vlans=[dict(id=n, name=data.get("name", f"VLAN {n} (sin nombre documentado)"),
                            subnet=data.get("subnet", "")) for n, data in sorted(vlans.items())])


def export_file(source: Path, output: Path, *, force: bool = False) -> dict:
    if not output.name.lower().endswith(".nexus.json"):
        raise ExportError("La salida debe terminar en .nexus.json.")
    if output.exists() and not force:
        raise ExportError("Salida existente; usa --force sólo si quieres sustituirla.")
    topology = to_topology(read_lab(source), source.stem)
    data = (json.dumps(topology, ensure_ascii=False, indent=2) + "\n").encode("utf-8")
    if len(data) > MAX_OUTPUT:
        raise ExportError("La salida supera 8 MiB; divide el laboratorio.")
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(dir=output.parent, prefix=f".{output.name}.", delete=False) as target:
            temporary = Path(target.name)
            target.write(data)
            target.flush()
            os.fsync(target.fileno())
        if force:
            os.replace(temporary, output)
        else:
            os.link(temporary, output)  # Atomic creation: an existing destination is never overwritten.
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)
    return topology


def main() -> int:
    parser = argparse.ArgumentParser(description="Convierte un .pkt local a .nexus.json, sin acceder a redes.")
    parser.add_argument("input", type=Path)
    parser.add_argument("-o", "--output", type=Path, required=True)
    parser.add_argument("--force", action="store_true", help="Sustituir explícitamente una salida existente")
    args = parser.parse_args()
    try:
        result = export_file(args.input, args.output, force=args.force)
    except (ExportError, PacketTracerError, OSError, UnicodeError, zlib.error, ValueError, RecursionError) as error:
        print(f"Error: {error}", file=sys.stderr)
        return 1
    print(f"Exportado: {args.output} ({len(result['devices'])} equipos, {len(result['links'])} enlaces)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
