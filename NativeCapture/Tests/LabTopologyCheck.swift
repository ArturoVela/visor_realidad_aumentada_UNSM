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
        precondition(project.layout.placements.filter { $0.kind == .workstation }.count == 3)
        precondition(project.layout.area == 192 && project.room.source.contains("sintética"))
        precondition(project.room.surfaces.filter { $0.kind == .wall }.allSatisfy { $0.dimensions[1] == 3.5 })
        _ = try project.room.jsonData()
        precondition(topology.devices.filter { !$0.modelID.hasPrefix("patch-") }.count == 46)
        precondition(Set(topology.links.compactMap(\.circuitID)).count == 70)
        precondition(topology.links.allSatisfy { topology.circuit(for: $0).count >= 2 })
        for rack in project.layout.placements where rack.kind == .rack {
            var occupied = Set<Int>()
            for device in topology.devices where device.placementID == rack.id {
                let slot = RackMount.slot(device.modelID, near: device.offset.y)
                precondition(device.offset == RackMount.center(device.modelID, rackDepth: rack.size.z, slot: slot))
                precondition(slot >= 0 && slot + RackMount.units(device.modelID) <= 42)
                for unit in slot..<(slot + RackMount.units(device.modelID)) {
                    precondition(occupied.insert(unit).inserted, "Dos equipos ocupan la misma unidad de rack.")
                }
            }
        }
        precondition(connected(topology), "Todos los equipos deben pertenecer al esquema conectado")
        precondition(HardwareCatalog.renderSize("server-c220m5") == SIMD3<Float>(0.429, 0.0432, 0.757))
        precondition(HardwareCatalog.renderSize("rack-r42612") == SIMD3<Float>(0.597, 2.013, 1.266))
        let testPCs = topology.devices.filter { $0.id.hasPrefix("desk-") }
        precondition(testPCs.map(\.ipv4) == ["192.168.20.101", "192.168.20.102", "192.168.20.103"])
        for pc in testPCs {
            let path = topology.switchedPath(from: pc.id, to: LabDemo.labServerID, vlan: 20)
            precondition(path?.first?.id == pc.id && path?.last?.id == LabDemo.labServerID)
            precondition(topology.switchedPath(from: pc.id, to: LabDemo.labServerID, vlan: 40) == nil)
        }
        var cut = topology
        cut.links.removeAll { $0.fromDeviceID == LabDemo.labServerID || $0.toDeviceID == LabDemo.labServerID }
        precondition(cut.switchedPath(from: testPCs[0].id, to: LabDemo.labServerID, vlan: 20) == nil)
        let near = try LabDemo.virtualRoom(width: 16, depth: 12)
        let fitted = try LabDemo.dataCenter(in: (near, LabLayoutPlanner.plan(room: near)))
        precondition(fitted.room.roomID == near.roomID && fitted.layout.facility != nil)
        precondition(fitted.layout.placements.map(\.size) == project.layout.placements.map(\.size))
        let shift = SIMD3<Float>(12.3, -1.4, -8.6)
        var transform = simd_float4x4(simd_quatf(angle: 0.61, axis: SIMD3<Float>(0, 1, 0)))
        transform.columns.3 = SIMD4(shift, 1)
        let rotatedRoom = try RoomStructure(roomID: UUID(), surfaces: near.surfaces.map { surface in
            let m = try transform * LabGeometry.matrix(surface)
            let columns = [m.columns.0, m.columns.1, m.columns.2, m.columns.3]
            return .init(id: surface.id, kind: surface.kind, confidence: surface.confidence,
                         dimensions: surface.dimensions, transformColumnMajor: columns.flatMap { [$0.x, $0.y, $0.z, $0.w] },
                         polygonCorners: surface.polygonCorners, parentID: surface.parentID,
                         doorIsOpen: surface.doorIsOpen, curve: surface.curve)
        })
        let rotated = try LabDemo.dataCenter(in: (rotatedRoom, LabLayoutPlanner.plan(room: rotatedRoom)))
        precondition(simd_distance(rotated.layout.facility!.origin, shift) < 0.001)
        precondition(rotated.layout.placements.map(\.size) == project.layout.placements.map(\.size))
        precondition(rotated.layout.placements.allSatisfy { abs($0.position.y - shift.y) < 0.001 })
        for (width, depth, height): (Float, Float, Float) in [(5, 4, 3.5), (16, 12, 2.9)] {
            let room = try LabDemo.virtualRoom(width: width, depth: depth, height: height)
            let layout = try LabLayoutPlanner.plan(room: room)
            do {
                _ = try LabDemo.dataCenter(in: (room, layout))
                preconditionFailure("Cuarto insuficiente aceptado.")
            } catch is LabLayoutError {}
        }
        precondition(Set(topology.vlans.map(\.id)) == [10, 20, 30, 40, 50, 60, 70])
        precondition(Set(topology.devices.flatMap(\.services)).isSuperset(of: Set(LabSite.nasServices + ["DNS", "HTTPS", "Ollama", "Vaultwarden", "Proxmox Backup Server", "RTSP", "Bloqueos DNS"])))
        precondition(topology.links.contains { $0.medium == .fiber })
        precondition(!topology.links.contains { $0.medium == .powerA || $0.medium == .powerB || $0.medium == .console })
        let firewalls = topology.devices.filter { $0.modelID == "server-firewall" }
        precondition(firewalls.count == 4 && firewalls.allSatisfy { $0.ports.count == 3 })
        precondition(topology.links.filter { $0.id.hasSuffix("-ha") }.count == 2)
        let web = topology.devices.first { $0.id == "rack-web:server-1" }!
        let pc = testPCs[0]
        precondition(topology.testNetwork(from: pc, to: web, tcp: 443, poweredOff: []).contains("Permitido"))
        precondition(topology.testNetwork(from: pc, to: web, tcp: 22, poweredOff: []).contains("Bloqueado"))
        precondition(topology.testNetwork(from: pc, to: web, tcp: 443, poweredOff: [firewalls[0].id]).contains("Permitido"))
        precondition(topology.testNetwork(from: pc, to: web, tcp: 443, poweredOff: ["rack-a:firewall-seg"]).contains("B"))
        precondition(topology.testNetwork(from: pc, to: web, tcp: 443,
                                          poweredOff: ["rack-a:firewall-seg", "rack-b:firewall-seg"]).contains("interrumpido"))
        precondition(topology.resolveSimulatedDNS("velaarturo.com", from: pc, poweredOff: []).contains("192.168.40.10"))
        precondition(topology.resolveSimulatedDNS("velaarturo.com", from: pc,
                                                poweredOff: ["rack-a:filter-a", "rack-b:filter-b"]).contains("Sin respuesta"))
        let tierRouting = try LabCablePlan.make(topology, room: project.room, layout: project.layout)
        precondition(tierRouting.segments.count == topology.links.count, "Cada tramo debe tener un trazo físico.")
        precondition(tierRouting.segments.allSatisfy { $0.length > 0 && $0.bendRadius >= 0.032 })
        precondition(tierRouting.csv(for: topology).components(separatedBy: "\r\n").count == topology.links.count + 2)
        let stopped = LabServerSample(device: web, topology: topology, poweredOff: [web.id])
        precondition(stopped.state == .offline && stopped.receiveMbps == 0 && stopped.cpu == 0)
        let isolated = LabServerSample(device: web, topology: topology, poweredOff: ["rack-web:access-0", "rack-web:access-1"])
        precondition(isolated.state == .isolated && isolated.transmitMbps == 0)
        let sample = LabServerSample(device: web, topology: topology, poweredOff: [])
        precondition(sample.state == .available && sample.receiveMbps > 0)
        let trial = LabFacilityTrial(scenario: .transfer, path: "A", loadKW: 12, availableKW: 14,
                                     transferSeconds: 125, batteryMinutes: 2, note: "")
        precondition(!trial.passed)
        let repeated = try LabDemo.dataCenter()
        precondition(repeated.topology == topology, "Instancias y cableado deben ser deterministas")

        let encoder = JSONEncoder(), decoder = JSONDecoder()
        let data = try encoder.encode(topology)
        let restored = try decoder.decode(LabTopology.self, from: data)
        precondition(restored == topology)
        precondition(restored.devices.allSatisfy { $0.sourceModel == nil && $0.sourcePortNames == nil })
        precondition(restored.siteRoutes["agro.velaarturo.com"] == LabDemo.labServerID && restored.siteRoutes.count == 38)
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

        let scannedLayout = try LabLayoutPlanner.plan(room: project.room)
        let scannedTopology = try LabDemo.roomLab(room: project.room, layout: scannedLayout)
        precondition(scannedTopology.devices.filter { !$0.modelID.hasPrefix("patch-") }.count == 54 && connected(scannedTopology))
        try scannedTopology.validate(layout: scannedLayout)
        let home = try LabDemo.homeLab()
        let scales = LabARScale.allCases
        precondition(scales.map(\.title) == ["1:1", "1:2", "1:5", "1:10", "1:20"])
        for (template, realSize) in [(home, SIMD3<Double>(5.6, 2.6, 4.8)), (project, SIMD3(16, 3.5, 12))] {
            let reference = LabARSpace(virtualRoom: template.room, layout: template.layout)!
            for scale in scales {
                let scaled = reference.scaled(to: scale)
                precondition(simd_distance(scaled.size, realSize * Double(scale.factor)) < 0.00001)
                let expectedArea = realSize.x * realSize.z / pow(Double(scale.rawValue), 2)
                precondition(abs(scaled.floorArea - expectedArea) < 0.00001)
            }
        }
        let monitorDiagonal = hypot(LabMonitorMount.displayWidth, LabMonitorMount.displayHeight)
        precondition(abs(monitorDiagonal / 0.0254 - 14) < 0.02)
        let homeRack = home.layout.placements[0]
        precondition(RackMount.capacity(height: homeRack.size.y) == 18)
        precondition(home.topology.devices.count == 16 && home.topology.links.count == 26)
        precondition(home.topology.devices.first { $0.modelID == "patch-copper" }?.offset.y ==
                     RackMount.center("patch-copper", rackDepth: homeRack.size.z, slot: 17).y)
        for link in home.topology.links where link.id == link.circuitID {
            let circuit = home.topology.circuit(for: link)
            precondition(circuit[0].toDeviceID == circuit[1].fromDeviceID)
            precondition(circuit[0].toPort.dropFirst() == circuit[1].fromPort.dropFirst())
            precondition(circuit[0].toPort.first != circuit[1].fromPort.first)
        }
        let admin = "home-desk-1:pc"
        let adminPath = home.topology.switchedPath(from: admin, to: "home-pve", vlan: 10)
        precondition(adminPath?.map(\.id) == [admin, "home-rack:patch-copper", "home-switch", "home-rack:patch-copper", "home-pve"])
        precondition(home.topology.siteRoutes.count == 38)
        precondition(home.topology.siteRoutes["taller.vealarturo.com"] == "home-web")
        precondition(LabSite.byHost["sphere.velaarturo.com"]?.url?.fragment == "/library")
        let pis = home.topology.devices.filter { $0.modelID == "raspberry-pi5" }
        precondition(pis.count == 2 && Set(pis.compactMap(\.vlan)) == [10, 50])
        precondition(home.topology.switchedPath(from: "home-camera", to: "home-nvr", vlan: 60) != nil)
        precondition(home.topology.switchedPath(from: admin, to: "home-nvr", vlan: 10) == nil)
        var edited = home.topology
        var cli = LabOperationsSession(stationID: admin, targetID: admin)
        precondition(cli.execute("ping PVE-01", on: &edited).contains("SW-HOME"))
        _ = cli.execute("connect SW-HOME", on: &edited)
        _ = cli.execute("interface fastethernet0/1", on: &edited)
        _ = cli.execute("shutdown", on: &edited)
        precondition(edited.switchedPath(from: admin, to: "home-pve", vlan: 10) == nil)
        precondition(cli.execute("show interfaces", on: &edited).contains("FastEthernet0/1 · Deshabilitado"))
        _ = cli.execute("no shutdown", on: &edited)
        precondition(edited.switchedPath(from: admin, to: "home-pve", vlan: 10) != nil)
        _ = cli.execute("connect 192.168.60.10", on: &edited)
        _ = cli.execute("ip address 192.168.60.53", on: &edited)
        precondition(edited == home.topology)
        _ = cli.execute("ip address 192.168.60.11", on: &edited)
        _ = cli.execute("hostname NODO-WEB", on: &edited)
        _ = cli.execute("site move torneo.velaarturo.com home-web", on: &edited)
        try edited.validate(layout: home.layout)
        let changes = LabOperationsOverrides(edited, against: home.topology)
        let persisted = try decoder.decode(LabOperationsOverrides.self, from: encoder.encode(changes))
        precondition(persisted.apply(to: home.topology) == edited)
        precondition(edited.siteRoutes["torneo.velaarturo.com"] == "home-web")
        var unplugged = home.topology
        unplugged.links.removeAll { $0.id == "home-pc-1.p2" }
        precondition(unplugged.switchedPath(from: admin, to: "home-pve", vlan: 10) == nil)
        precondition(home.topology.switchedPath(from: "home-desk-2:pc", to: "home-pve", vlan: 30) == nil)
        let fittedHome = try LabDemo.homeLab(in: (home.room, LabLayoutPlanner.plan(room: home.room)))
        precondition(fittedHome.room.roomID == home.room.roomID)
        precondition(fittedHome.layout.placements.map(\.size) == home.layout.placements.map(\.size))
        let small = try LabDemo.virtualRoom(width: 3, depth: 3, height: 2.6)
        reject("HomeLab en planta insuficiente") { _ = try LabDemo.homeLab(in: (small, LabLayoutPlanner.plan(room: small))) }
        var walk = LabWalkPose.start(in: home.layout)
        let start = walk.position
        for _ in 0..<100 { walk.walk(SIMD2(0, 1), seconds: 0.016, in: home.layout) }
        precondition(walk.position.z > start.z + 0.5 && walk.position.z <= -homeRack.size.z / 2 - 0.14)
        for _ in 0..<40 { walk.walk(SIMD2(1, 0), seconds: 0.016, in: home.layout) }
        precondition(abs(walk.position.x) < 0.30, "El soporte lateral debe bloquear el paso.")
        for _ in 0..<32 { walk.walk(SIMD2(0, -1), seconds: 0.016, in: home.layout) }
        for _ in 0..<150 { walk.walk(SIMD2(1, 0), seconds: 0.016, in: home.layout) }
        precondition(abs(walk.position.x) < 2.66 && abs(walk.position.x) > 2.5)
        let targets = LabFocusTarget.inventory(home.topology, in: home.layout)
        let pve = targets.first { $0.id == "home-pve" }!
        let front = pve.center + SIMD3(0, 0, -1.45)
        precondition(LabFocusTarget.pick(.aim, from: front, direction: SIMD3(0, 0, 1), in: targets)?.id == pve.id)
        precondition(LabFocusTarget.pick(.aim, from: front, direction: SIMD3(0, 1, 0), in: targets) == nil)
        let distant = front - SIMD3(0, 0, 16)
        precondition(LabFocusTarget.pick(.aim, from: distant, direction: SIMD3(0, 0, 1), in: targets) == nil)
        precondition(LabFocusTarget.pick(.aim, from: distant, direction: SIMD3(0, 0, 1), in: targets, maximumDistance: 20)?.id == pve.id)
        precondition(LabFocusTarget.pick(.nearby, from: front, direction: SIMD3(1, 0, 0), in: targets)?.id == pve.id)
        precondition(LabFocusTarget.pick(.nearby, from: SIMD3(20, 1, 20), direction: SIMD3(1, 0, 0), in: targets) == nil)
        let firstTarget = targets[0], lastTarget = targets[targets.count - 1]
        precondition(LabFocusTarget.step(-1, after: firstTarget.id, in: targets)?.id == lastTarget.id)
        precondition(LabFocusTarget.step(1, after: lastTarget.id, in: targets)?.id == firstTarget.id)
        let face = pve.face(toward: front)
        precondition(abs(simd_distance(face, pve.center) - pve.size.z / 2) < 0.0001 && face.z < pve.center.z)
        let aimed = LabWalkPose(position: front, yaw: 0).aimed(at: face)
        precondition(aimed.position == front)
        precondition(simd_distance(aimed.rotation.act(SIMD3(0, 0, -1)), SIMD3(0, 0, 1)) < 0.001)

        let homeFramed = LabWalkPose.start(in: home.layout).framing(pve, in: home.layout)
        precondition(homeFramed.position.z < -homeRack.size.z)
        precondition(LabWalkPose.permits(SIMD2(homeFramed.position.x, homeFramed.position.z), in: home.layout))
        for target in LabFocusTarget.inventory(topology, in: project.layout) where target.placementID.hasPrefix("rack") {
            let pose = LabWalkPose.start(in: project.layout).framing(target, in: project.layout)
            let normal = SIMD3<Float>(-sin(target.yaw), 0, -cos(target.yaw))
            precondition(simd_dot(pose.position - target.center, normal) > 0.6, "Puesta frontal requerida.")
            precondition(LabWalkPose.permits(SIMD2(pose.position.x, pose.position.z), in: project.layout))
        }

        let traffic = LabTrafficRoute([[SIMD3(0, 0, 0), SIMD3(1, 0, 0)], [SIMD3(3, 0, 0), SIMD3(7, 0, 0)]])!
        precondition(traffic.length == 5 && traffic.point(at: 0) == .zero && traffic.point(at: 1).x == 7)
        precondition(abs(traffic.point(at: 0.1).x - 0.5) < 0.0001)
        precondition(abs(traffic.point(at: 0.4).x - 4) < 0.0001)
        precondition(traffic.point(at: 0.19).x < 1 && traffic.point(at: 0.21).x > 3)
        precondition(LabTrafficRoute([[.zero, .zero]]) == nil)
        let switchDestination = LabInspectionDestination(deviceID: "home-switch", port: "GigabitEthernet0/1", linkID: "home-pve-trunk")
        let serverDestination = LabInspectionDestination(deviceID: "home-pve", port: "LOM1", linkID: "home-pve-trunk")
        let startPose = LabWalkPose.start(in: home.layout)
        let frontSpot = switchDestination.spot(in: home.topology, layout: home.layout, observer: startPose.position)!
        let backSpot = serverDestination.spot(in: home.topology, layout: home.layout, observer: startPose.position)!
        let fromFront = startPose.inspecting(frontSpot.point, fromSide: frontSpot.normal, in: home.layout)
        let fromBack = fromFront.inspecting(backSpot.point, fromSide: backSpot.normal, in: home.layout)
        precondition(fromFront.position.z < -homeRack.size.z / 2)
        precondition(fromBack.position.z > homeRack.size.z / 2)
        precondition(simd_dot(simd_normalize(backSpot.point - fromBack.position), fromBack.rotation.act(SIMD3(0, 0, -1))) > 0.999)
        precondition(LabGeometry.contains(SIMD2(fromBack.position.x, fromBack.position.z), polygon: home.layout.floorPolygon))
        let close = LabTrafficRoute.markerRadius(cableRadius: 0.0035, depth: 0.4, projectedPointsAtOneMeter: 350)
        let far = LabTrafficRoute.markerRadius(cableRadius: 0.0035, depth: 7, projectedPointsAtOneMeter: 350)
        precondition(close * 350 / 0.4 <= 1.8001)
        precondition(far <= 0.0035 * 1.55 && far * 350 / 7 < close * 350 / 0.4)
        if CommandLine.arguments.count > 1 {
            decoder.dateDecodingStrategy = .iso8601
            let room = try decoder.decode(RoomStructure.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
            let layout = try LabLayoutPlanner.plan(room: room)
            let local = try LabDemo.roomLab(room: room, layout: layout)
            try local.validate(layout: layout)
            print("Captura real: \(local.devices.count) equipos, \(local.links.count) enlaces")
        }
        print("PASS: Tier IV y HomeLab, escala, montaje, par de puertos, caminos VLAN, navegación, enfoque, saltos a puertos, pulsos, encaje y JSON")
    }
}
