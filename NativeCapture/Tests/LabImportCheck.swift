import Foundation
import simd

@main
struct LabImportCheck {
    @MainActor static func main() throws {
        let fixture = makeFixture()
        let data = try JSONEncoder().encode(fixture)
        try checkLibrary(data)
        let project = try LabImport.project(from: data)
        try project.topology.validate(layout: project.layout)
        checkPatchedLinks(project, original: fixture)
        try checkLegacyEditable(project, original: fixture)
        precondition(project.topology.vlans == fixture.vlans)
        precondition(project.topology.notes == fixture.notes)
        precondition(project.layout.placements.count == 3)
        precondition(project.layout.placements.filter { $0.kind == .rack }.count == 1)
        precondition(project.layout.placements.filter { $0.kind == .workstation }.count == 2)
        precondition(project.layout.floorHeight == 0 && project.room.source.contains("sintética"))
        for (before, after) in zip(fixture.devices, project.topology.devices) {
            var expected = before; expected.placementID = after.placementID; expected.offset = after.offset
            precondition(after == expected, "Conservar IP, VLAN, puertos, servicios, sourceModel y configuración.")
            precondition(after.placementID != "unplaced" && after.offset != before.offset, "Ignorar coordenadas importadas.")
        }
        for i in project.layout.placements.indices {
            let a = project.layout.placements[i]
            for x in [-a.size.x / 2, a.size.x / 2] { for z in [-a.size.z / 2, a.size.z / 2] {
                precondition(LabGeometry.contains(SIMD2(a.position.x + x, a.position.z + z), polygon: project.layout.floorPolygon))
            } }
            for j in project.layout.placements.indices where j > i {
                let b = project.layout.placements[j]
                let gap = simd_max(simd_abs(SIMD2(a.position.x - b.position.x, a.position.z - b.position.z))
                    - SIMD2((a.size.x + b.size.x) / 2, (a.size.z + b.size.z) / 2), .zero)
                precondition(simd_length(gap) >= 0.7999, "Huellas separadas al menos 0,8 m.")
            }
        }
        let rack = project.layout.placements.first { $0.kind == .rack }!
        let mounted = project.topology.devices.filter { $0.placementID == rack.id }
        precondition(rack.size == SIMD3<Float>(0.597, 2.013, 1.266))
        for device in mounted {
            let size = HardwareCatalog.renderSize(device.modelID)
            let slot = RackMount.slot(device.modelID, near: device.offset.y)
            precondition(slot >= 0 && slot + RackMount.units(device.modelID) <= 42)
            precondition(device.offset == RackMount.center(device.modelID, rackDepth: rack.size.z, slot: slot))
            precondition(abs(device.offset.x) + size.x / 2 <= rack.size.x / 2)
            precondition(abs(device.offset.z) + size.z / 2 <= rack.size.z / 2)
        }
        let roundtrip = try LabImport.project(from: data)
        precondition(roundtrip.topology == project.topology, "La misma importación conserva los identificadores de panel y cable.")
        precondition(roundtrip.layout.placements == project.layout.placements)
        var dense = fixture
        dense.links = []
        dense.devices = (0..<96).map { index in
            var device = fixture.devices[3]; device.id = "router-\(index)"; device.ipv4 = nil; return device
        }
        let denseProject = try LabImport.project(from: JSONEncoder().encode(dense))
        precondition(denseProject.layout.placements.count <= 12)
        for placement in denseProject.layout.placements {
            let devices = denseProject.topology.devices.filter { $0.placementID == placement.id }.sorted { $0.offset.y < $1.offset.y }
            for pair in zip(devices, devices.dropFirst()) {
                precondition(pair.1.offset.y - pair.0.offset.y > 0.0889, "Separar routers de 2 U.")
            }
        }
        var extraRouter = dense.devices[0]; extraRouter.id = "router-97"
        dense.devices.append(extraRouter)
        reject("Más de 96 dispositivos") { _ = try LabImport.project(from: JSONEncoder().encode(dense)) }

        reject("Archivo mayor de 8 MiB") { _ = try LabImport.project(from: Data(repeating: 32, count: 8 * 1024 * 1024 + 1)) }
        try rejectMutation(fixture, "Modelo desconocido") { $0.devices[0].modelID = "unknown-model" }
        try rejectMutation(fixture, "Rack pasivo no es equipo activo") { $0.devices[0].modelID = "rack-r42612" }
        try rejectMutation(fixture, "Identificador duplicado") { $0.devices[1].id = $0.devices[0].id }
        try rejectMutation(fixture, "Configuración excesiva") { $0.devices[0].configuration = String(repeating: "x", count: 65537) }
        try rejectMutation(fixture, "Autoenlace") { $0.links[0].toDeviceID = $0.links[0].fromDeviceID }
        try rejectMutation(fixture, "IPv4 inválida") { $0.devices[0].ipv4 = "999.168.1.1" }
        try rejectMutation(fixture, "Puerto desconocido") { $0.devices[0].ports.append("InventedPort0") }
        try rejectMutation(fixture, "ID largo") { $0.devices[0].id = String(repeating: "a", count: 65) }
        var crowded = fixture
        crowded.links = []
        crowded.devices = (0..<25).map { index in
            var device = fixture.devices[0]; device.id = "pc-\(index)"; return device
        }
        reject("Más de 24 PCs necesita más puestos") { _ = try LabImport.project(from: JSONEncoder().encode(crowded)) }
        var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        var devices = object["devices"] as! [[String: Any]]
        devices[0]["offset"] = ["NaN", 0, 0] as [Any]; object["devices"] = devices
        reject("NaN JSON") { _ = try LabImport.project(from: JSONSerialization.data(withJSONObject: object)) }
        for path in CommandLine.arguments.dropFirst() {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            let source = try JSONDecoder().decode(LabTopology.self, from: data)
            let exported = try LabImport.project(from: data)
            try exported.topology.validate(layout: exported.layout)
            precondition(exported.layout.importedRoom)
            if let plan = source.logicalPlan {
                precondition(exported.topology.logicalPlan?.areas == plan.areas && exported.topology.logicalPlan?.labels == plan.labels)
                precondition(plan.devicePositions.allSatisfy { exported.topology.logicalPlan?.devicePositions[$0.key] == $0.value })
            }
            precondition(exported.topology.vlans == source.vlans)
            checkPatchedLinks(exported, original: source)
            for (before, after) in zip(source.devices, exported.topology.devices) {
                var expected = before
                expected.placementID = after.placementID
                expected.offset = after.offset
                precondition(expected == after, "Mantener identidad, modelos, puertos y configuración del PKT.")
                if before.modelID == "pt-server" {
                    precondition(after.visualModelID == "server-c220m5")
                    precondition(exported.layout.placements.contains { $0.id == after.placementID && $0.kind == .rack })
                }
            }
            let cables = try LabCablePlan.make(exported.topology, room: exported.room, layout: exported.layout)
            precondition(cables.segments.map(\.link) == exported.topology.links, "\(path) perdió enlaces.")
            for cable in cables.segments {
                precondition(cable.points.first == cable.endpoints.first?.point)
                precondition(cable.points.last == cable.endpoints.last?.point)
                precondition(cable.points.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite })
                for (start, end) in zip(cable.points, cable.points.dropFirst()) {
                    let step = end - start
                    precondition(simd_length(step) <= 0.035 || abs(step.y) <= 0.006 ||
                                 simd_length(SIMD2(step.x, step.z)) <= 0.008,
                                 "\(cable.link.id) atraviesa dos alturas en diagonal.")
                }
            }
            let restored = try LabImport.project(from: data)
            precondition(restored.layout.placements == exported.layout.placements)
            precondition(restored.topology == exported.topology)
            if let plan = source.logicalPlan {
                let broken = LabLogicalPlan(devicePositions: [:], areas: plan.areas, labels: plan.labels)
                try rejectMutation(exported.topology, "Plano sin posiciones de equipos") { $0.logicalPlan = broken }
            }
            let desks = exported.layout.placements.filter { $0.kind == .workstation }
            if exported.topology.name == "Project #1" {
                precondition(Set(desks.map(\.title)) == ["Admin / IT", "Finance / HR", "Customer services / Reception"])
                let finance = desks.first { $0.title == "Finance / HR" }!
                let laptops = exported.topology.devices.filter { $0.placementID == finance.id && $0.modelID == "pt-laptop" }
                precondition(laptops.count == 2 && laptops[0].offset != laptops[1].offset)
            }
            if exported.topology.name == "Project #2", source.devices.contains(where: { $0.packetTracer != nil }) {
                var plan = exported.topology
                let dhcp = plan.devices.filter(\.providesDHCP)
                precondition(Set(dhcp.map(\.name)) == ["DHCP 1", "DHCP 2", "DHCP3", "DHCP 4"])
                precondition(Set(dhcp.map(\.placementID)).count == 4)
                for server in dhcp {
                    let rack = plan.devices.filter { $0.placementID == server.placementID }
                    precondition(rack.filter { $0.modelID == "switch-2960" }.count == 1)
                    precondition(rack.filter { $0.modelID == "router-2911" }.count == 1)
                }
                let source = plan.devices.first { $0.name == "Laptop 1A1" }!
                let local = dhcp.first { $0.name == "DHCP 1" }!
                let remote = dhcp.first { $0.name == "DHCP3" }!
                precondition(source.ipv4 == "192.168.0.4")
                let localPath = plan.importedIPv4Path(from: source, to: local, poweredOff: [])
                precondition(localPath?.filter { !$0.modelID.hasPrefix("patch-") }.map(\.name) == ["Laptop 1A1", "Switch0", "DHCP 1"])
                let routed = plan.importedIPv4Path(from: source, to: remote, poweredOff: [])
                precondition(routed?.filter { !$0.modelID.hasPrefix("patch-") }.map(\.name) ==
                             ["Laptop 1A1", "Switch0", "Router3", "Router3(1)", "Switch0(1)", "DHCP3"])
                let healthy = plan.diagnosePing(from: source, to: remote, poweredOff: [])
                precondition(healthy.issue == nil && healthy.path?.devices == routed)
                let routeLinks = healthy.path?.links ?? []
                let wanIndex = routeLinks.firstIndex { $0.medium == .serial }!
                let wan = routeLinks[wanIndex]
                var interrupted = plan
                let routerIndex = interrupted.devices.firstIndex { $0.id == wan.fromDeviceID }!
                interrupted.devices[routerIndex].shutdownPorts = [wan.fromPort]
                let broken = interrupted.diagnosePing(from: source, to: remote, poweredOff: [])
                precondition(broken.blockedLink == wan && broken.issue?.contains(wan.fromPort) == true)
                precondition(broken.path?.links == Array(routeLinks.prefix(wanIndex)))
                let reversed = interrupted.diagnosePing(from: remote, to: source, poweredOff: [])
                precondition(reversed.blockedLink == wan && reversed.path?.devices.first == remote)
                let off = plan.diagnosePing(from: source, to: local, poweredOff: [local.id])
                precondition(off.blockedDevice == local && off.issue?.contains("apagado") == true)
                var console = LabOperationsSession(stationID: source.id, targetID: source.id)
                let success = console.execute("ping DHCP3", on: &plan)
                precondition(success.contains("icmp_seq=0 ttl=62") && success.contains("0.0% packet loss"))
                let timeout = console.execute("ping DHCP 1", on: &plan, poweredOff: [local.id])
                precondition(timeout.contains("Request timeout") && timeout.contains("100.0% packet loss"))
                let original = plan
                _ = console.execute("hostname Laptop-CLI", on: &plan)
                precondition(plan == original)
                _ = console.execute("hostname Laptop-CLI", on: &plan, editingAllowed: true)
                var candidate = exported
                candidate.topology = plan
                var (copy, entry) = try LabImport.createEditableCopy(of: candidate, site: UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: entry.url.deletingLastPathComponent()) }
                _ = console.execute("ip address 192.168.0.125 255.255.255.0", on: &copy.topology)
                try LabImport.saveEditable(copy, to: entry)
                var saved = try LabImport.load(entry).topology
                precondition(saved.devices.first { $0.id == source.id }?.name == "Laptop-CLI")
                precondition(console.execute("ipconfig /all", on: &saved).contains("192.168.0.125"))
                precondition(console.execute("ping DHCP 1", on: &saved).contains("0.0% packet loss"))
            }
            let rackCount = exported.layout.placements.count - desks.count
            print("\(exported.topology.name): \(exported.topology.devices.count) equipos, \(cables.segments.count) enlaces, \(rackCount) racks, \(desks.count) puestos")
        }
        print("PASS: sala física, conservación de topología y plano de origen, puertos, límites y rutas para todos los enlaces.")
    }

    @MainActor private static func checkLibrary(_ original: Data) throws {
        let suite = "NexusAR.ImportCheck." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let file = directory.appendingPathComponent("project.nexus.json")
        try original.write(to: file)
        let entry = LabImport.Entry(url: file, name: "Original", date: .now)
        let library = SavedLaboratories(defaults: defaults)
        try library.saveFolder("Prácticas")
        let folder = library.folders[0]
        try library.rename(entry, to: "  Práctica 1 ")
        try library.change(entry) {
            $0.folderID = folder.id
            $0.enabled = false
            $0.archived = true
            $0.deleted = true
        }
        let restored = SavedLaboratories(defaults: defaults)
        precondition(restored.name(entry) == "Práctica 1" && restored.hiddenKeys == [entry.libraryKey])
        precondition(restored.details(entry).folderID == folder.id && !restored.details(entry).enabled)
        try restored.change(entry) { $0.deleted = false }
        precondition(restored.details(entry).archived)
        try restored.change(entry) { $0.archived = false }
        precondition(restored.details(entry).inLibrary)
        try restored.removeFolder(folder)
        precondition(restored.details(entry).folderID == nil && restored.folders.isEmpty)
        let contents = try Data(contentsOf: file)
        precondition(contents == original)
    }

    private static func checkPatchedLinks(_ project: LabProject, original: LabTopology) {
        let topology = project.topology
        let racks = Set(project.layout.placements.filter { $0.kind == .rack }.map(\.id))
        let devices = Dictionary(uniqueKeysWithValues: topology.devices.map { ($0.id, $0) })
        for link in original.links {
            let trunk = topology.links.first { $0.id == link.id }!
            let segments = topology.circuit(for: trunk)
            precondition(segments.first?.fromDeviceID == link.fromDeviceID && segments.first?.fromPort == link.fromPort)
            precondition(segments.last?.toDeviceID == link.toDeviceID && segments.last?.toPort == link.toPort)
            precondition(trunk.sourceCableType == link.sourceCableType)
            precondition(segments.allSatisfy { $0.medium == link.medium && $0.vlanIDs == link.vlanIDs })
            let rackEndpoint = [link.fromDeviceID, link.toDeviceID].contains { devices[$0].map { racks.contains($0.placementID) } ?? false }
            if rackEndpoint && link.medium != .serial {
                precondition(segments.count > 1, "Falta patch panel en \(topology.name) · \(link.id).")
            }
        }
    }

    private static func checkLegacyEditable(_ project: LabProject, original: LabTopology) throws {
        let (copy, entry) = try LabImport.createEditableCopy(of: project, site: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: entry.url.deletingLastPathComponent()) }
        var legacy = copy
        legacy.topology.devices.removeAll { $0.modelID.hasPrefix("patch-") }
        legacy.topology.links = original.links
        try LabImport.saveEditable(legacy, to: entry)
        let before = try Data(contentsOf: entry.url)
        let upgraded = try LabImport.load(entry)
        let reopened = try LabImport.load(entry)
        precondition(upgraded.topology == reopened.topology && upgraded.editableID == legacy.editableID)
        precondition(upgraded.layout.placements == legacy.layout.placements)
        let after = try Data(contentsOf: entry.url)
        precondition(before == after)
        checkPatchedLinks(upgraded, original: original)

        let link = original.links[0]
        var assembly = LabARAssembly(id: UUID(), name: "Antiguo montaje por piezas")
        assembly.set(.init(id: .device(link.fromDeviceID), position: .zero, yaw: 0))
        assembly.set(.init(id: .device(link.toDeviceID), position: [3, 0, 0], yaw: 0))
        let plan = assembly.cablePlan(in: upgraded.topology, layout: upgraded.layout)
        precondition(plan.connections.contains { $0.link.id == link.id && $0.routed && $0.link.toDeviceID == link.toDeviceID })
    }

    private static func makeFixture() -> LabTopology {
        func device(_ id: String, _ model: String, _ ip: String) -> LabTopology.Device {
            .init(id: id, name: id, modelID: model, placementID: "unplaced", offset: SIMD3(10000, -20000, 30000),
                  ipv4: ip, vlan: 10, services: id == "pc-1" ? ["HTTP"] : [], ports: LabDemo.ports(model),
                  sourceModel: model == "pc-optiplex7010" ? "PC-PT" : "Cisco de prueba",
                  configuration: "hostname \(id)\n! configuración conservada\n",
                  sourcePortNames: model == "pc-optiplex7010" ? ["Ethernet": "FastEthernet0"] : nil)
        }
        return LabTopology(name: "Fixture de importación", devices: [
            device("pc-1", "pc-optiplex7010", "192.168.10.10"), device("pc-2", "pc-optiplex7010", "192.168.10.11"),
            device("sw-1", "switch-2960", "192.168.10.2"), device("rt-1", "router-1941", "192.168.10.1")],
            links: [
                .init(id: "pc1-sw", fromDeviceID: "pc-1", fromPort: "Ethernet", toDeviceID: "sw-1", toPort: "FastEthernet0/1", medium: .copper, vlanIDs: [10]),
                .init(id: "pc2-sw", fromDeviceID: "pc-2", fromPort: "Ethernet", toDeviceID: "sw-1", toPort: "FastEthernet0/2", medium: .copper, vlanIDs: [10]),
                .init(id: "sw-rt", fromDeviceID: "sw-1", fromPort: "GigabitEthernet0/1", toDeviceID: "rt-1", toPort: "GigabitEthernet0/0", medium: .copper, vlanIDs: [10])],
            vlans: [.init(id: 10, name: "Pruebas", subnet: "192.168.10.0/24")], notes: ["Datos sintéticos propios."])
    }

    private static func rejectMutation(_ fixture: LabTopology, _ message: String, _ mutation: (inout LabTopology) -> Void) throws {
        var value = fixture; mutation(&value)
        reject(message) { _ = try LabImport.project(from: JSONEncoder().encode(value)) }
    }

    private static func reject(_ message: String, _ operation: () throws -> Void) {
        do { try operation(); preconditionFailure("Se aceptó entrada inválida: \(message)") }
        catch { }
    }
}
