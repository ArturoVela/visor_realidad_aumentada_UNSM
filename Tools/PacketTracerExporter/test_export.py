# SPDX-License-Identifier: GPL-3.0-or-later
"""Original fixture generated locally; no third-party lab or assessment is shipped."""
import copy
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
import zlib

from pkt_core import Lab as Builder, encode_bytes
import export_pkt as exporter


def original_fixture():
    lab = Builder()
    lab.prune_seed_devices()
    pc1 = lab.add_device("PC-PT", "PC-A", pc_ip=("192.168.10.10", "255.255.255.0", "192.168.10.1"))
    pc2 = lab.add_device("PC-PT", "PC-B", pc_ip=("192.168.20.10", "255.255.255.0", "192.168.20.1"))
    switch = lab.add_device("2960-24TT", "SW-EDUCACION", ios_config=[
        "hostname SW-EDUCACION", "vlan 10", " name DOCENCIA", "!", "vlan 20", " name PRUEBAS", "!",
        "interface FastEthernet0/1", " switchport mode access", " switchport access vlan 10", "!",
        "interface FastEthernet0/2", " switchport mode access", " switchport access vlan 20", "!",
        "interface GigabitEthernet0/1", " switchport mode trunk", " switchport trunk allowed vlan 10,20", "end"])
    router = lab.add_device("1941", "R-EDUCACION", ios_config=[
        "hostname R-EDUCACION", "interface GigabitEthernet0/0.10", " encapsulation dot1Q 10",
        " ip address 192.168.10.1 255.255.255.0", "!", "interface GigabitEthernet0/0.20",
        " encapsulation dot1Q 20", " ip address 192.168.20.1 255.255.255.0", "end"])
    server = lab.add_device("Server-PT", "SERVIDOR", pc_ip=("192.168.10.53", "255.255.255.0", "192.168.10.1"))
    lab.link(pc1, "FastEthernet0", switch, "FastEthernet0/1")
    lab.link(pc2, "FastEthernet0", switch, "FastEthernet0/2")
    lab.link(router, "GigabitEthernet0/0", switch, "GigabitEthernet0/1")
    lab.link(server, "FastEthernet0", switch, "FastEthernet0/3")
    # The builder leaves placeholder cable addresses 1/2. Author actual address references in our fixture.
    addresses = {reference: str(73000 + index * 17) for index, reference in enumerate([pc1, pc2, switch, router, server])}
    for device in lab.net.findall("DEVICES/DEVICE"):
        reference = device.findtext("ENGINE/SAVE_REF_ID")
        device.find("WORKSPACE/LOGICAL/DEV_ADDR").text = addresses[reference]
        if reference in {pc1, pc2}:
            ET.SubElement(device.find(".//PORT"), "VLAN").text = "10" if reference == pc1 else "20"
    for cable in lab.net.findall("LINKS/LINK/CABLE"):
        cable.find("FROM_DEVICE_MEM_ADDR").text = addresses[cable.findtext("FROM")]
        cable.find("TO_DEVICE_MEM_ADDR").text = addresses[cable.findtext("TO")]
    return lab.base, addresses


def must_fail(operation, message):
    try:
        operation()
    except exporter.ExportError as error:
        assert message in str(error), str(error)
    else:
        raise AssertionError(f"Se aceptó entrada inválida: {message}")


def main():
    root, addresses = original_fixture()
    xml = ET.tostring(root, encoding="utf-8")
    with tempfile.TemporaryDirectory(prefix="nexus-original-pkt-") as folder:
        directory = Path(folder)
        source, output = directory / "laboratorio-propio.pkt", directory / "laboratorio-propio.nexus.json"
        source.write_bytes(encode_bytes(xml, "pkt"))
        before = source.read_bytes()
        result = exporter.export_file(source, output)
        assert source.read_bytes() == before
        assert len(result["devices"]) == 5 and len(result["links"]) == 4
        assert json.loads(output.read_text()) == result
        by_name = {device["name"]: device for device in result["devices"]}
        assert by_name["PC-A"]["ipv4"] == "192.168.10.10" and by_name["PC-A"]["vlan"] == 10
        assert by_name["PC-B"]["modelID"] == "pc-optiplex7010"
        assert by_name["PC-A"]["ports"] == ["Ethernet"]
        assert by_name["PC-A"]["sourcePortNames"] == {"Ethernet": "FastEthernet0"}
        assert "192.168.10.1" in by_name["PC-A"]["configuration"]
        assert "switchport access vlan 10" in by_name["SW-EDUCACION"]["configuration"]
        assert by_name["SERVIDOR"]["modelID"] == "server-c220m5" and "HTTP" in by_name["SERVIDOR"]["services"]
        assert by_name["SERVIDOR"]["ports"] == ["LOM1"] and "LOM2" not in by_name["SERVIDOR"]["sourcePortNames"]
        assert by_name["R-EDUCACION"]["ipv4"] == "192.168.10.1"
        assert all("." not in port for port in by_name["R-EDUCACION"]["ports"])
        vlans = {vlan["id"]: vlan for vlan in result["vlans"]}
        assert vlans[10]["name"] == "DOCENCIA" and vlans[20]["subnet"] == "192.168.20.0/24"
        for link in result["links"]:
            a = next(device for device in result["devices"] if device["id"] == link["fromDeviceID"])
            b = next(device for device in result["devices"] if device["id"] == link["toDeviceID"])
            assert a["id"][3:] in addresses.values() and b["id"][3:] in addresses.values()
            assert link["fromPort"] in a["ports"] and link["toPort"] in b["ports"]
        assert result["links"][0]["fromDeviceID"] == by_name["PC-A"]["id"]
        assert result["links"][0]["toDeviceID"] == by_name["SW-EDUCACION"]["id"]
        assert result["links"][0]["vlanIDs"] == [10]
        must_fail(lambda: exporter.export_file(source, output), "Salida existente")
        assert output.read_text() == (json.dumps(result, ensure_ascii=False, indent=2) + "\n")
        exporter.export_file(source, output, force=True)
        legacy = directory / "legacy.pkt"
        legacy.write_bytes(encode_bytes(xml, "legacy"))
        assert exporter.export_file(legacy, directory / "legacy.nexus.json")["devices"] == result["devices"]
        for filename, mutate, expected in [
            ("unknown", lambda tree: tree.find("NETWORK/DEVICES/DEVICE/ENGINE/TYPE").set("model", "3290"), "Modelo no admitido"),
            ("double-port", lambda tree: tree.find("NETWORK/LINKS").append(copy.deepcopy(tree.find("NETWORK/LINKS/LINK"))), "más de un cable"),
            ("bad-endpoint", lambda tree: setattr(tree.find("NETWORK/LINKS/LINK/CABLE/FROM_DEVICE_MEM_ADDR"), "text", "1"), "dev_addr"),
            ("activity", lambda tree: setattr(tree, "tag", "PACKETTRACER5_ACTIVITY"), "actividad"),
            ("console", lambda tree: setattr(tree.find("NETWORK/LINKS/LINK/CABLE/TYPE"), "text", "eConsole"), "Consola no importable"),
            ("fiber-copper", lambda tree: setattr(tree.find("NETWORK/LINKS/LINK/CABLE/TYPE"), "text", "eFiber"), "Medio fiber incompatible"),
        ]:
            altered = copy.deepcopy(root)
            mutate(altered)
            packet = directory / f"{filename}.pkt"
            packet.write_bytes(encode_bytes(ET.tostring(altered), "pkt"))
            must_fail(lambda: exporter.export_file(packet, directory / f"{filename}.nexus.json"), expected)
        pka = directory / "assessment.pka"
        pka.write_bytes(before)
        must_fail(lambda: exporter.export_file(pka, directory / "assessment.nexus.json"), ".pka")
        previous_limit = exporter.MAX_XML
        exporter.MAX_XML = 1024
        try:
            bomb = directory / "oversized.pkt"
            bomb.write_bytes(encode_bytes(b"<PACKETTRACER5>" + b"A" * 2048 + b"</PACKETTRACER5>", "pkt"))
            must_fail(lambda: exporter.read_lab(bomb), "límite")
            must_fail(lambda: exporter.bounded_inflate((512).to_bytes(4, "big") + zlib.compress(b"A" * 2048)), "límite")
        finally:
            exporter.MAX_XML = previous_limit
        cli = subprocess.run([sys.executable, "-B", str(Path(exporter.__file__)), str(source), "-o",
                              str(directory / "cli.nexus.json")], capture_output=True, text=True, check=False)
        assert cli.returncode == 0, cli.stderr
    print("PASS: PKT moderno/legacy propio → DTO, dev_addr, puertos, IPv4/VLAN/servicios/config, límites y errores; salida atómica sin sobreescribir")


if __name__ == "__main__":
    main()
