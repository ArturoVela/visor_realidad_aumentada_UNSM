import Foundation
import simd

/// Standalone check: compile with RoomStructure, HardwareCatalog, LabLayout and LabTopology.
@main
struct LabTopologyCheck {
    static func reject(_ label: String, _ operation: () throws -> Void) {
        do { try operation(); preconditionFailure("Dato inválido aceptado: \(label)") } catch {}
    }

    static func connected(_ topology: LabTopology) -> Bool {
        guard let first = topology.devices.first?.id else { return true }
        var visited: Set<String> = [first], queue = [first]
        var index = 0
        while index < queue.count {
            let current = queue[index]
            index += 1
            for link in topology.links {
                let neighbor = link.fromDeviceID == current ? link.toDeviceID : link.toDeviceID == current ? link.fromDeviceID : nil
                if let neighbor, visited.insert(neighbor).inserted { queue.append(neighbor) }
            }
        }
        return visited.count == topology.devices.count
    }

    static func changed(_ base: LabTopology, _ label: String, _ update: (inout LabTopology) -> Void) {
        var value = base
        update(&value)
        reject(label) { try value.validate() }
    }

    static func replacing(_ layout: LabLayout, at index: Int, position: SIMD3<Float>? = nil) -> LabLayout {
        var placements = layout.placements
        let old = placements[index]
        placements[index] = LabPlacement(id: old.id, kind: old.kind, title: old.title,
                                         position: position ?? old.position, yaw: old.yaw, size: old.size)
        return LabLayout(area: layout.area, floorHeight: layout.floorHeight, floorPolygon: layout.floorPolygon,
                         placements: placements, warnings: layout.warnings)
    }

    static func main() throws {
        let project = try LabDemo.dataCenter(), topology = project.topology
        try topology.validate(layout: project.layout)
        precondition(project.layout.placements.filter { $0.kind == .rack }.count == 6)
        precondition(project.layout.placements.filter { $0.kind == .workstation }.count == 2)
        precondition(project.layout.area == 192 && project.room.source.contains("sintética"))
        precondition(project.room.surfaces.filter { $0.kind == .wall }.allSatisfy { $0.dimensions[1] == 3.5 })
        _ = try project.room.jsonData()
        precondition(topology.devices.count == 34 && topology.links.count == 44)
        precondition(connected(topology), "Todos los equipos deben pertenecer al esquema conectado")
        precondition(Set(topology.devices.map(\.modelID)).union(["rack-r42612"]) == Set(HardwareCatalog.items.map(\.id)))
        precondition(Set(topology.vlans.map(\.id)) == [10, 20, 30, 40, 50])
        precondition(Set(topology.devices.flatMap(\.services)).isSuperset(of: ["SMTP", "IMAP", "DNS", "HTTP", "HTTPS", "Aplicaciones", "Backup", "Monitorización"]))
        precondition(topology.links.contains { $0.medium == .fiber })
        precondition(!topology.links.contains { $0.medium == .powerA || $0.medium == .powerB || $0.medium == .console })
        let repeated = try LabDemo.dataCenter()
        precondition(repeated.topology == topology, "Instancias y cableado deben ser deterministas")

        let encoder = JSONEncoder(), decoder = JSONDecoder()
        let data = try encoder.encode(topology)
        let restored = try decoder.decode(LabTopology.self, from: data)
        precondition(restored == topology)
        precondition(restored.devices.allSatisfy { $0.sourceModel == nil && $0.configuration == nil && $0.sourcePortNames == nil })
        var imported = topology
        imported.devices[0].sourceModel = "2960-24TT"
        imported.devices[0].configuration = "hostname switch-a\ninterface FastEthernet0/1\n"
        imported.devices[0].sourcePortNames = ["FastEthernet0/1": "FastEthernet0/1"]
        let restoredImported = try decoder.decode(LabTopology.self, from: encoder.encode(imported))
        precondition(restoredImported == imported)
        imported.notes = Array(repeating: String(repeating: "x", count: 1024), count: 256)
        try imported.validate()

        changed(topology, "ID equipo duplicado") { $0.devices.append($0.devices[0]) }
        changed(topology, "ID enlace duplicado") { $0.links.append($0.links[0]) }
        changed(topology, "extremo ausente") { $0.links[0].toDeviceID = "missing" }
        changed(topology, "puerto ausente") { $0.links[0].toPort = "FastEthernet0/99" }
        changed(topology, "puerto usado dos veces") {
            var link = $0.links[0]; link.id = "reused-port"; $0.links.append(link)
        }
        changed(topology, "lazo sobre el mismo equipo") { $0.links[0].toDeviceID = $0.links[0].fromDeviceID }
        changed(topology, "fibra sobre puerto de cobre") { $0.links[0].medium = .fiber }
        changed(topology, "energía no documentada") { $0.links[0].medium = .powerA }
        changed(topology, "consola sin host documentado") { $0.links[0].medium = .console }
        changed(topology, "modelo no documentado") { $0.devices[0].modelID = "unknown" }
        changed(topology, "gabinete pasivo como equipo activo") { $0.devices[0].modelID = "rack-r42612"; $0.devices[0].ports = [] }
        changed(topology, "puerto inventado") { $0.devices[0].ports.append("Ethernet9000") }
        changed(topology, "mapeo de puerto inventado") { $0.devices[0].sourcePortNames = ["Ethernet9000": "FastEthernet0"] }
        changed(topology, "coordenada no finita") { $0.devices[0].offset.x = .nan }
        for address in ["300.1.2.3", "192.168.1", "01.2.3.4", "1.2.3.4/24", "1..2.3"] {
            changed(topology, "IPv4 \(address)") { $0.devices[0].ipv4 = address }
        }
        changed(topology, "VLAN fuera de rango") { $0.vlans[0].id = 4095 }
        changed(topology, "subred con bits de host") { $0.vlans[0].subnet = "192.168.10.2/24" }
        changed(topology, "VLAN de enlace ausente") { $0.links[0].vlanIDs = [999] }
        changed(topology, "VLAN de equipo ausente") { $0.devices[0].vlan = 999 }
        changed(topology, "configuración excesiva en UTF8") { $0.devices[0].configuration = String(repeating: "á", count: 32769) }
        changed(topology, "demasiadas notas") { $0.notes = Array(repeating: "nota", count: 257) }
        var missingPlacement = topology
        missingPlacement.devices[0].placementID = "missing"
        reject("colocación ausente") { try missingPlacement.validate(layout: project.layout) }
        missingPlacement = topology
        missingPlacement.devices[0].offset.y = 5
        reject("centro fuera de soporte") { try missingPlacement.validate(layout: project.layout) }
        reject("colocación fuera del suelo") { try topology.validate(layout: replacing(project.layout, at: 0, position: SIMD3(100, 0, 0))) }
        reject("colocación elevada") { try topology.validate(layout: replacing(project.layout, at: 0, position: SIMD3(-4, 1, -3))) }
        reject("colocaciones solapadas") { try topology.validate(layout: replacing(project.layout, at: 0, position: project.layout.placements[1].position)) }
        reject("dimensión negativa") { _ = try LabDemo.virtualRoom(width: -1, depth: 12) }
        reject("dimensión no finita") { _ = try LabDemo.virtualRoom(width: .nan, depth: 12) }

        let roomTopology = try LabDemo.roomLab(room: project.room, layout: project.layout)
        precondition(roomTopology.devices.count == 54 && connected(roomTopology))
        precondition(roomTopology.devices.allSatisfy { device in project.layout.placements.contains { $0.id == device.placementID } })
        let scannedLayout = try LabLayoutPlanner.plan(room: project.room)
        let scannedTopology = try LabDemo.roomLab(room: project.room, layout: scannedLayout)
        try scannedTopology.validate(layout: scannedLayout)
        if CommandLine.arguments.count > 1 {
            decoder.dateDecodingStrategy = .iso8601
            let room = try decoder.decode(RoomStructure.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
            let layout = try LabLayoutPlanner.plan(room: room)
            let local = try LabDemo.roomLab(room: room, layout: layout)
            try local.validate(layout: layout)
            print("Captura real: \(local.devices.count) equipos, \(local.links.count) enlaces")
        }
        print("PASS: demo 6 racks/2 puestos, 34 equipos/44 enlaces, 10 modelos, puertos, medios, VLAN, IPv4, contención, JSON y determinismo")
    }
}
