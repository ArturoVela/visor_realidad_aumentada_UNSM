import Foundation
import simd

@main
struct LabARAssemblyCheck {
    @MainActor static func main() async throws {
        checkEquipmentCatalog()
        try await checkEditableNetwork()
        try await checkRearPatchRouting()
        try await checkSharedEquipmentEditor()
        try await checkRackChanges()
        try checkSharedInventory()
        try checkDirectRackEditing()
        try checkCablePackingAnd3DPositions()
        try checkFixedPathways()
        try checkRackElevation()
        try checkSavedLocationEdits()
        try checkRackClearanceAndCableTurns()
        try checkRackPower()
        try checkRackFansAndSignals()
        var projects = [try LabDemo.dataCenter(), try LabDemo.homeLab()]
        for input in CommandLine.arguments.dropFirst() {
            let bytes = try Data(contentsOf: URL(fileURLWithPath: input))
            projects.append(try LabImport.project(from: bytes))
        }
        for project in projects {
            let topology = project.topology, layout = project.layout
            guard let link = topology.links.first(where: { $0.medium == .copper }),
                  let source = topology.devices.first(where: { $0.id == link.fromDeviceID }),
                  let target = topology.devices.first(where: { $0.id == link.toDeviceID }) else {
                preconditionFailure("Se necesita un enlace de cobre.")
            }
            var assembly = LabARAssembly(id: UUID(), name: "Sala A")
            let a = LabARAssembly.Piece(id: .device(source.id), position: SIMD3(0, 0, 0), yaw: 0)
            let b = LabARAssembly.Piece(id: .device(target.id), position: SIMD3(3, 0, 0), yaw: 0)
            assembly.set(a)
            precondition(assembly.cablePlan(in: topology, layout: layout).connections.isEmpty)
            assembly.set(b)
            let floor = assembly.cablePlan(in: topology, layout: layout)
            precondition(floor.channels.contains { $0.start.y == 0.055 && $0.end.y == 0.055 })
            assembly.setLevel(.overhead, for: b.id)
            let mixed = assembly.cablePlan(in: topology, layout: layout)
            let horizontalLevels = Set(mixed.channels.filter { $0.start.y == $0.end.y }.map { $0.start.y })
            precondition(horizontalLevels.contains(0.055) && horizontalLevels.contains(mixed.overhead))
            precondition(mixed.channels.contains { $0.start.y <= 0.055 && $0.end.y >= 2.15 })
            precondition(mixed.connections.first?.routed == true)
            let initial = assembly.cablePlan(in: topology, layout: layout).connections.first { $0.link.id == link.id }!
            var adjusted = b
            adjusted.adjust(.move, axes: SIMD2(1, 1), forward: SIMD3(0, 0, -1), seconds: 0.1)
            precondition(adjusted.position.x > b.position.x && adjusted.position.z < b.position.z && adjusted.position.y == b.position.y)
            adjusted.adjust(.turn, axes: SIMD2(0, 1), forward: .zero, seconds: 0.1)
            precondition(adjusted.yaw == b.yaw)
            adjusted.adjust(.turn, axes: SIMD2(1, 0), forward: .zero, seconds: 0.1)
            precondition(adjusted.yaw < b.yaw)
            precondition(LabWalkPose.joystickAxes(SIMD2(0.1, 0.1)) == .zero)
            var moved = b
            moved.position = SIMD3(0, 1, 4)
            moved.yaw = .pi / 2
            assembly.set(moved)
            let updated = assembly.cablePlan(in: topology, layout: layout).connections.first { $0.link.id == link.id }!
            let local = try LabScenePort.local(target, link.toPort)
            let expected = moved.world(SIMD3(0, target.visualSize.y / 2, 0) + local.point)
            precondition(initial.points.first == updated.points.first && simd_distance(updated.points.last!, expected) < 0.0001)
            precondition(updated.points.last != initial.points.last && moved.rotation.act(SIMD3(0, 1, 0)) == SIMD3(0, 1, 0))
            // Consecutive draft poses use the same coordinates for the device and its rendered patch cord.
            var draft = assembly
            for step in [LabARAssembly.Adjustment.move, .turn, .move, .turn] {
                let previous = draft
                var piece = draft.piece(b.id)!
                piece.adjust(step, axes: SIMD2(1, 0), forward: SIMD3(0, 0, -1), seconds: 0.1)
                draft.set(piece)
                precondition(!draft.hasSameCableLayout(as: previous))
                let plan = draft.cablePlan(in: topology, layout: layout)
                let connection = plan.connections.first { $0.link.id == link.id }!
                let port = piece.world(SIMD3(0, target.visualSize.y / 2, 0) + local.point)
                precondition(simd_distance(connection.leads[1].first!, port) < 0.0001)
                precondition(plan.channels.contains { $0.start.y == $0.end.y && abs($0.start.y - plan.overhead) < 0.001 })
            }
            let wired = draft
            draft.showsCables = false
            precondition(draft.hasSameCableLayout(as: wired))
            draft.setLevel(.floor, for: b.id)
            precondition(!draft.hasSameCableLayout(as: wired))
            assembly.placeAll(in: layout, at: SIMD3(0, 0, 2), yaw: 0)
            precondition(assembly.cablePlan(in: topology, layout: layout).connections.map(\.link.id) == topology.links.map(\.id))
            precondition(assembly.piece(moved.id) == moved)
            let plan = assembly.cablePlan(in: topology, layout: layout)
            precondition(plan.channels.allSatisfy { channel in channel.size.x > 0 && channel.cableCount > 0 })
            precondition(assembly.level(for: moved.id) == .overhead)
            var untouched = LabARAssembly(id: UUID(), name: "Montaje completo")
            let empty = untouched
            untouched.placeAll(in: layout, at: .zero, yaw: 0)
            precondition(!untouched.conflicts(with: empty, in: layout, topology: topology))
            let grouped = untouched.cablePlan(in: topology, layout: layout)
            precondition(grouped.connections.map(\.link.id) == topology.links.map(\.id))
            precondition(grouped.reviewCount == 0 && grouped.connections.allSatisfy { $0.routed && $0.bendRadius != nil })
            precondition(grouped.channels.contains { $0.cableCount > 1 })
            try checkRackRouting(project)
            for connection in grouped.connections {
                let directions = zip(connection.points, connection.points.dropFirst()).compactMap { a, b in
                    simd_distance(a, b) > 0.0001 ? simd_normalize(b - a) : nil
                }
                precondition(zip(directions, directions.dropFirst()).allSatisfy { simd_dot($0, $1) > 0.1 },
                             "Todo cable visible debe pasar por curvas suaves.")
            }
            let count = assembly.pieces.count
            assembly.placeAll(in: layout, at: SIMD3(2, 0, 2), yaw: .pi)
            precondition(assembly.pieces.count == count && assembly.piece(moved.id) == moved)
            assembly.showsCables = false
            let suite = "NexusAR.AssemblyCheck." + UUID().uuidString
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let store = LabARAssemblyStore(scope: "laboratorio", defaults: defaults)
            try store.save(assembly)
            let other = LabARAssembly(id: UUID(), name: "Sala B")
            try store.save(other)
            let saved = try store.all()
            let differentProject = try LabARAssemblyStore(scope: "otro", defaults: defaults).all()
            precondition(saved == [other, assembly] && differentProject.isEmpty)
            precondition(saved.last?.level(for: moved.id) == .overhead)
            precondition(other.anchorName != assembly.anchorName)
            let legacy = try JSONDecoder().decode(LabARAssembly.self, from: JSONEncoder().encode(other))
            precondition(legacy.level(for: moved.id) == .floor)
            print("\(topology.name): \(topology.links.count) cables tras colocar todo. Piezas y ubicaciones conservadas.")
        }
    }

    private static func checkEquipmentCatalog() {
        let items = HardwareCatalog.byGroup.values.flatMap { $0 }
        precondition(Set(items.map(\.id)).count == items.count)
        precondition(Set(items.map(\.id)) == Set(HardwareCatalog.byFamily.values.flatMap { $0.map(\.id) }))
        precondition(items.allSatisfy { LabARAssembly.accessorySize($0.id) != nil })
        precondition(RackMount.Equipment.allCases.allSatisfy { HardwareCatalog.reference($0.rawValue) != nil })
        precondition(LabDeskEquipment.allCases.allSatisfy { HardwareCatalog.reference($0.rawValue) != nil })
        precondition(RackMount.Equipment(rawValue: "router-1941")?.units == 2)
        precondition(LabDeskEquipment(rawValue: "pt-laptop")?.supportsWiFi == true)
        precondition(RackMount.Equipment(rawValue: "cooling-inrow") == nil && LabDeskEquipment(rawValue: "cooling-inrow") == nil)
        let expected: [(String, HardwareItem.Group, String)] = [
            ("server-c220m5", .servers, "Servidor"),
            ("router-2911", .routers, "2911"),
            ("switch-3650", .switches, "Switches"),
            ("access-point", .wireless, "WiFi"),
            ("pt-access-point", .wireless, "Access Point"),
            ("pc-optiplex7010", .computers, "PC"),
            ("laptop-latitude5420", .computers, "Latitude"),
            ("pt-smartphone", .mobile, "Celular")
        ]
        for (id, group, query) in expected {
            let item = HardwareCatalog.byGroup[group]?.first { $0.id == id }
            precondition(item?.matchesCatalogSearch(query) == true)
            precondition(item?.matchesCatalogSearch("zz sin coincidencias") == false)
        }
    }

    private static func checkRackPower() throws {
        let size = RackMount.Height.compact.size
        let rack = LabPlacement(id: "rack-home", kind: .rack, title: "Rack", position: .zero, yaw: 0, size: size)
        var layout = LabLayout(area: 16, floorHeight: 0, floorPolygon: [], placements: [rack], warnings: [])
        let id = LabARAssembly.Item.support(rack.id)
        let models = ["server-c220m5", "switch-2960", "router-1941", "patch-copper", "ups-9px", "battery-9px"]
        let devices = zip(models, [0, 1, 2, 4, 5, 7]).map { model, slot in
            LabTopology.Device(id: model, name: model, modelID: model, placementID: rack.id,
                               offset: RackMount.center(model, rackDepth: size.z, slot: slot),
                               ipv4: nil, vlan: nil, services: [], ports: [])
        }
        precondition(layout.pduConfiguration(for: rack.id) == .right)
        for height in RackMount.Height.allCases {
            let slots = RackMount.capacity(height: height.size.y)
            let load = (0..<slots).map { slot in
                var device = devices[0]
                device.id = "server-\(slot)"
                device.offset = RackMount.center(device.visualModelID, rackDepth: height.size.z, slot: slot)
                return device
            }
            let strips = LabRackPower.strips(for: height.size, configuration: .dual, devices: load)
            precondition(strips.allSatisfy { $0.sockets.count == slots && $0.leads.count == slots })
            precondition(strips[0].input.x < 0 && strips[1].input.x > 0)
            for (circuit, strip) in strips.enumerated() {
                let intake = LabRackPower.equipmentSocket("server-c220m5", circuit: circuit)
                for (slot, lead) in strip.leads.enumerated() {
                    precondition(lead.points.first == strip.sockets[slot] && lead.points.last == load[slot].offset + intake)
                }
            }
        }
        let strip = LabRackPower.strips(for: size, configuration: .right, devices: devices)[0]
        precondition(strip.leads.map(\.deviceID) == Array(models.prefix(3)) + ["ups-9px"])
        precondition(strip.upsID == "ups-9px" && strip.upstream.point == LabRackPower.upsSocket(at: devices[4].offset))
        let dual = LabRackPower.strips(for: size, configuration: .dual, devices: devices)
        precondition(dual[1].leads.map(\.deviceID) == ["server-c220m5", "ups-9px"])
        precondition(Set(strip.leads.compactMap { $0.points.first }).count == strip.leads.count)
        for strip in [strip] + dual + LabRackPower.strips(for: size, configuration: .left, devices: devices.reversed()) {
            for lead in strip.leads {
                let points = lead.points
                let start = points.first!, end = points.last!
                let rearSocket = min(start.z, end.z)
                precondition(points.allSatisfy { abs($0.x) < size.x / 2 && $0.z >= rearSocket - 0.001 && $0.z < size.z / 2 })
                for (socket, next) in [(start, points[1]), (end, points[points.count - 2])] {
                    let exit = next - socket
                    precondition(abs(exit.x) < 0.0001 && abs(exit.y) < 0.0001 && exit.z >= LabRackPower.cordExit - 0.0001)
                }
                for (a, b) in zip(points, points.dropFirst()) {
                    let delta = abs(b - a)
                    let changingAxes = [delta.x, delta.y, delta.z].filter { $0 > 0.0001 }.count
                    // Only short chords sampling the bends can move in two axes.
                    precondition(changingAxes == 1 || simd_length(delta) < 0.020)
                }
            }
        }

        var topology = try LabDemo.homeLab().topology
        topology.devices = devices
        var assembly = LabARAssembly(roomLayout: layout)
        let outlet = LabRackPower.Outlet(position: SIMD3(0.7, 0.32, 2.0), normal: SIMD3(0, 0, -1))
        assembly.setPowerOutlet(outlet, for: id)
        let withUPS = assembly.powerFeedPlan(in: layout, topology: topology)
        precondition(withUPS.reviewRacks.isEmpty && withUPS.leads.count == 1)
        precondition(withUPS.leads[0].points.first == strip.upstream.point)
        precondition(simd_distance(withUPS.leads[0].points.last!, outlet.position + outlet.normal * 0.012) < 0.0001)
        topology.devices.removeLast(2)
        let withoutUPS = assembly.powerFeedPlan(in: layout, topology: topology)
        precondition(withoutUPS.reviewRacks.isEmpty && withoutUPS.leads[0].points.first == strip.input)

        var rotated = assembly
        rotated.set(.init(id: id, position: .zero, yaw: .pi / 4))
        let turned = rotated.powerFeedPlan(in: layout, topology: topology)
        precondition(turned.reviewRacks.isEmpty && turned.leads.count == 1)
        precondition(turned.leads[0].points.first == rotated.piece(id)?.world(strip.input))

        let ups = LabARAssembly.Item.extra(model: "ups-9px", id: UUID())
        assembly.set(.init(id: ups, position: SIMD3(1.4, 0, 0.4), yaw: 0))
        let external = assembly.powerFeedPlan(in: layout, topology: topology)
        precondition(external.reviewRacks.isEmpty && external.leads.count == 2)
        precondition(external.externalUPSSources[id]?.point == external.leads.last?.points.first)

        let encoded = try JSONEncoder().encode(assembly)
        var saved = try JSONDecoder().decode(LabARAssembly.self, from: encoded)
        precondition(saved.powerOutlets?[id] == outlet)
        saved.unplace(id)
        precondition(saved.powerOutlets?[id] == nil)
        assembly.setPowerOutlet(.init(position: .zero, normal: outlet.normal), for: id)
        precondition(assembly.powerFeedPlan(in: layout, topology: topology).reviewRacks.contains(id))

        layout.rackPDUs = [rack.id: .left]
        let savedLayout = try JSONDecoder().decode(LabLayout.self, from: JSONEncoder().encode(layout))
        precondition(savedLayout.pduConfiguration(for: rack.id) == .left)
    }

    private static func checkRackFansAndSignals() throws {
        let room = try LabDemo.virtualRoom(width: 5, depth: 5)
        let size = RackMount.Height.compact.size
        let rack = LabPlacement(id: "rack-ventilado", kind: .rack, title: "Rack", position: .zero, yaw: 0, size: size)
        let corners: [SIMD2<Float>] = [[-2.5, -2.5], [2.5, -2.5], [2.5, 2.5], [-2.5, 2.5]]
        let layout = LabLayout(area: 25, floorHeight: 0, floorPolygon: corners, placements: [rack], warnings: [])
        var project = LabProject(room: room, layout: layout,
                                 topology: .init(name: "Ventilación", devices: [], links: [], vlans: [], notes: []))
        let access = try project.mount(.switch24, name: "Switch", rackID: rack.id, slot: 1)
        let server = try project.mount(.server, name: "Servidor", rackID: rack.id, slot: 0)
        let panel = try project.mount(.copperPanel, name: "Patch panel", rackID: rack.id, slot: 2)
        let primary = try project.mount(.ups, name: "UPS A", rackID: rack.id, slot: 3)
        let backup = try project.mount(.ups, name: "UPS B", rackID: rack.id, slot: 5)
        let fan = try project.mount(.fans, name: "Ventiladores", rackID: rack.id, slot: 11)
        let first = LabTopology.Link(id: "edge", fromDeviceID: access.id, fromPort: "FastEthernet0/1",
                                     toDeviceID: panel.id, toPort: "F01", medium: .copper, vlanIDs: [], circuitID: "edge")
        let last = LabTopology.Link(id: "last", fromDeviceID: panel.id, fromPort: "R01",
                                    toDeviceID: server.id, toPort: "LOM1", medium: .copper, vlanIDs: [], circuitID: "edge")
        project.topology.links = [first, last]
        try project.topology.validate(layout: project.layout)
        let topology = project.topology
        let port = LabTopology.Port(deviceID: access.id, name: first.fromPort)
        precondition(fan.ports.isEmpty && fan.isFanTray)
        let strip = LabRackPower.strips(for: size, configuration: .right, devices: topology.devices)[0]
        precondition(strip.upsID == primary.id && strip.leads.contains { $0.deviceID == fan.id })
        let lost = topology.rackPowerFailures(in: layout, poweredOff: [primary.id])
        precondition(lost == [access.id, fan.id, server.id])
        project.layout.rackPDUs = [rack.id: .dual]
        precondition(topology.rackPowerFailures(in: project.layout, poweredOff: [primary.id]) == [access.id, fan.id])
        precondition(topology.rackPowerFailures(in: project.layout, poweredOff: [backup.id]).isEmpty)
        precondition(topology.signal(at: port, poweredOff: [], pending: []) == .active)
        precondition(topology.signal(at: port, poweredOff: [], pending: [], negotiating: first.id) == .negotiating)
        precondition(topology.signal(at: port, poweredOff: lost, pending: []) == .noPower)
        precondition(topology.signal(at: port, poweredOff: [], pending: [server.id]) == .pending)
        precondition(topology.signal(at: .init(deviceID: access.id, name: "FastEthernet0/2"), poweredOff: [], pending: []) == .unplugged)
        precondition(topology.speedLimit(for: topology.circuit(for: last)) == 100)
        let placed = LabARAssembly(roomLayout: layout)
        let unplaced = LabARAssembly(id: UUID(), name: "Sin colocar")
        precondition(topology.pendingSignalDevices(in: layout, assembly: placed).isEmpty)
        precondition(topology.pendingSignalDevices(in: layout, assembly: unplaced).contains(server.id))
        var shut = topology
        shut.devices[1].shutdownPorts = [last.toPort]
        precondition(shut.signal(at: port, poweredOff: [], pending: []) == .blocked)
        let ok = LabTopology.PingDiagnosis(path: .init(devices: [access, server])).sample
        let blocked = LabTopology.PingDiagnosis(issue: "Corte").sample
        precondition(ok.received == 4 && ok.loss == 0 && ok.mean != nil)
        precondition(blocked.received == 0 && blocked.loss == 100 && blocked.mean == nil)
        print("Ventiladores, fuentes A/B, estado de puertos a través del panel y métricas de ping comprobados.")
    }

    private static func checkSharedInventory() throws {
        let room = try LabDemo.virtualRoom(width: 9, depth: 7)
        let rack = LabPlacement(id: "rack", kind: .rack, title: "Rack", position: [1, 0, 0],
                                yaw: 0, size: RackMount.Height.full.size)
        let floor: [SIMD2<Float>] = [[-4.5, -3.5], [4.5, -3.5], [4.5, 3.5], [-4.5, 3.5]]
        let layout = LabLayout(area: 63, floorHeight: 0, floorPolygon: floor, placements: [rack], warnings: [])
        var project = LabProject(room: room, layout: layout, topology: .init(name: "Inventario compartido", devices: [],
                                                                             links: [], vlans: [], notes: []))
        let server = try project.mount(.server, name: "Servidor", rackID: rack.id, slot: 4)
        var assembly = LabARAssembly(id: UUID(), name: "Sala")
        let physicalRack = LabARAssembly.Piece(id: .support(rack.id), position: [6, 0, 3], yaw: .pi / 2)
        assembly.set(physicalRack)

        let laptop = try project.addDeskEquipment(.laptop, name: "Laptop", deskID: nil)
        let monitor = LabARAssembly.RackMonitor(id: UUID(), device: server.id, panel: .services, side: .left, row: 1)
        try project.setRoomRackMonitors([monitor], rackID: rack.id)
        let extra = LabARAssembly.Item.extra(model: "test-desk", id: UUID())
        try project.registerAccessory(extra)
        let phone = LabARAssembly.Item.extra(model: "pt-smartphone", id: UUID())
        try project.registerAccessory(phone)
        let decoder = JSONDecoder(), encoder = JSONEncoder()
        var reopened = try decoder.decode(LabProject.self, from: encoder.encode(project))
        assembly.syncInventory(in: reopened.layout, topology: reopened.topology)
        precondition(assembly.piece(.support(rack.id)) == physicalRack)
        let physicalDesk = assembly.piece(.support(laptop.placementID))!
        precondition(physicalDesk.position != reopened.layout.placements.first { $0.id == laptop.placementID }?.position)
        precondition(assembly.adjustmentPiece(.device(laptop.id), topology: reopened.topology) != nil)
        precondition(assembly.piece(monitor.item)?.monitorMount?.side == .left)
        precondition(assembly.piece(phone) != nil)
        let accessory = assembly.piece(extra)!
        precondition(accessory.position != reopened.layout.accessories?.first?.position)
        let snapshot = assembly
        assembly.syncInventory(in: reopened.layout, topology: reopened.topology)
        precondition(assembly == snapshot)

        let physicalMonitor = LabARAssembly.RackMonitor(id: monitor.id, device: server.id, panel: .services, side: .right, row: 0)
        assembly.set(physicalMonitor.piece(on: rack))
        try reopened.mirrorRackMonitors([physicalMonitor], rackID: rack.id)
        precondition(reopened.layout.rackMonitors?[rack.id]?.first?.side == .left)
        assembly.syncInventory(in: reopened.layout, topology: reopened.topology)
        precondition(assembly.piece(monitor.item)?.monitorMount?.side == .right)

        let accessoryFromAR = LabARAssembly.Item.extra(model: "battery-bank", id: UUID())
        let physicalAccessory = LabARAssembly.Piece(id: accessoryFromAR, position: [10, 0, 3], yaw: 0)
        assembly.set(physicalAccessory)
        try reopened.registerAccessory(accessoryFromAR)
        precondition(LabARAssembly(roomLayout: reopened.layout).piece(accessoryFromAR) != nil)
        assembly.syncInventory(in: reopened.layout, topology: reopened.topology)
        precondition(assembly.piece(accessoryFromAR) == physicalAccessory)
        reopened.layout.accessories?.removeAll { $0.id == accessoryFromAR }
        try reopened.setRoomRackMonitors([], rackID: rack.id)
        assembly.unplace(.support(laptop.placementID))
        assembly.syncInventory(in: reopened.layout, topology: reopened.topology)
        precondition(assembly.piece(.support(laptop.placementID)) == nil)
        precondition(assembly.piece(accessoryFromAR) == nil && assembly.piece(monitor.item) == nil)
        print("Inventario 3D/RA sincronizado, posiciones propias, accesorios y monitores persistidos sin duplicados.")
    }

    private static func checkRackChanges() async throws {
        let room = try LabDemo.virtualRoom(width: 9, depth: 7)
        let rackA = LabPlacement(id: "rack-a", kind: .rack, title: "Rack A", position: [-2, 0, 0],
                                 yaw: 0, size: RackMount.Height.full.size)
        let rackB = LabPlacement(id: "rack-b", kind: .rack, title: "Rack B", position: [0, 0, 0],
                                 yaw: 0, size: RackMount.Height.medium.size)
        let layout = LabLayout(area: 63, floorHeight: 0, floorPolygon: [[-4.5, -3.5], [4.5, -3.5], [4.5, 3.5], [-4.5, 3.5]],
                               placements: [rackA, rackB], warnings: [])
        var project = LabProject(room: room, layout: layout, topology: .init(name: "Edición de racks", devices: [], links: [],
                                                                             vlans: [], notes: []))
        let router = try project.mount(.router, name: "Router", rackID: rackA.id, slot: 3)
        let server = try project.mount(.server, name: "Servidor", rackID: rackA.id, slot: 8)
        let station = try project.addDeskEquipment(.pc, name: "PC", deskID: nil)
        let start = LabTopology.Port(deviceID: router.id, name: "GigabitEthernet0/0")
        let end = LabTopology.Port(deviceID: station.id, name: "Ethernet")
        let first = try await project.connectingRoomPorts(start, to: end, vlans: [], level: .overhead)
        project = first.project
        let trunk = project.topology.links.first { $0.id == first.linkID }!
        let oldPanel = project.topology.circuit(for: trunk).first!.toDeviceID
        do {
            _ = try await project.relocatingRackDevice(router.id, to: rackA.id, slot: 7, assembly: nil)
            preconditionFailure("El router de 2 U se solaparía con el servidor.")
        } catch is LabLayoutError {}
        let higher = try await project.relocatingRackDevice(router.id, to: rackA.id, slot: 37, assembly: nil)
        let higherTrunk = higher.topology.links.first { $0.id == trunk.id }!
        precondition(higher.topology.circuit(for: higherTrunk).first?.toDeviceID != oldPanel)
        precondition(higherTrunk.arRouteLevel == .overhead)
        let higherPort = try LabScenePort.world(higher.topology.devices.first { $0.id == router.id }!,
                                                start.name, in: higher.layout)
        let originalPort = try LabScenePort.world(router, start.name, in: project.layout)
        precondition(higherPort.point.y > originalPort.point.y + 1)

        let assembly = LabARAssembly(roomLayout: project.layout)
        let moved = try await higher.relocatingRackDevice(router.id, to: rackB.id, slot: 0, assembly: assembly)
        let movedRouter = moved.topology.devices.first { $0.id == router.id }!
        let movedTrunk = moved.topology.links.first { $0.id == trunk.id }!
        let final = moved.topology.circuit(for: movedTrunk)
        precondition(movedRouter.placementID == rackB.id && movedRouter.ports == router.ports)
        precondition(final.first?.fromDeviceID == router.id && final.first?.fromPort == start.name)
        precondition(final.last?.toDeviceID == station.id && final.last?.toPort == end.name)
        precondition(moved.topology.devices.first { $0.id == final.first?.toDeviceID }?.placementID == rackB.id)
        let routed = assembly.cablePlan(in: moved.topology, layout: moved.layout).connections.filter(\.routed)
        precondition(final.allSatisfy { link in routed.contains { $0.link.id == link.id } })

        var detached = moved
        let floorPoint = SIMD3<Float>(2, 0, 2)
        let floor = try detached.putRackDeviceOnFloor(router.id, at: floorPoint)
        precondition(floor.position == floorPoint)
        let parked = detached.topology.devices.first { $0.id == router.id }!
        var expected = movedRouter
        expected.placementID = floor.id
        expected.offset = [0, floor.size.y / 2, 0]
        precondition(floor.kind == .floor && parked == expected)
        precondition(detached.availableSlots(in: rackB, model: router.visualModelID).contains(0))
        precondition(detached.topology.links == moved.topology.links)
        let circuit = movedTrunk.circuitID ?? movedTrunk.id
        precondition(detached.topology.pendingCableCircuits(in: detached.layout) == [circuit])
        let detachedAR = LabARAssembly(roomLayout: detached.layout)
        let paused = detachedAR.cablePlan(in: detached.topology, layout: detached.layout)
        precondition(paused.connections.allSatisfy { ($0.link.circuitID ?? $0.link.id) != circuit })
        let paused3D = try LabCablePlan.make(detached.topology, room: room, layout: detached.layout)
        precondition(paused3D.segments.allSatisfy { ($0.link.circuitID ?? $0.link.id) != circuit })
        let savedFloor = try JSONDecoder().decode(LabProject.self, from: JSONEncoder().encode(detached))
        precondition(savedFloor.layout == detached.layout && savedFloor.topology == detached.topology)

        let remounted = try await savedFloor.relocatingRackDevice(router.id, to: rackA.id, slot: 3, assembly: detachedAR)
        precondition(remounted.topology.devices.first { $0.id == router.id } == router)
        precondition(!remounted.layout.placements.contains { $0.id == floor.id })
        precondition(remounted.topology.pendingCableCircuits(in: remounted.layout).isEmpty)
        var synced = detachedAR
        synced.syncInventory(in: remounted.layout, topology: remounted.topology, placeMissing: false)
        precondition(synced.piece(.support(floor.id)) == nil)
        precondition(synced.cablePlan(in: remounted.topology, layout: remounted.layout).connections.contains {
            $0.routed && $0.link.fromDeviceID == router.id
        })
        var onDesk = detached
        let desk = try onDesk.addDesk(width: 1.4, depth: 0.9, name: "Mesa de equipos")
        let deskPoint = SIMD2<Float>(0.12, 0.04)
        do {
            try onDesk.putRackDeviceOnDesk(router.id, deskID: desk.id, at: [desk.size.x, 0])
            preconditionFailure("El equipo quedaría fuera de la mesa.")
        } catch is LabLayoutError {}
        precondition(onDesk.layout.placements.contains { $0.id == floor.id })
        try onDesk.putRackDeviceOnDesk(router.id, deskID: desk.id, at: deskPoint)
        let stagedRouter = onDesk.topology.devices.first { $0.id == router.id }!
        precondition(stagedRouter.placementID == desk.id && stagedRouter.parkedOnDesk == true)
        precondition(stagedRouter.offset.x == deskPoint.x && stagedRouter.offset.z == deskPoint.y)
        precondition(!onDesk.layout.placements.contains { $0.id == floor.id })
        precondition(onDesk.topology.pendingCableCircuits(in: onDesk.layout) == [circuit])
        let fromDesk = try await onDesk.relocatingRackDevice(router.id, to: rackB.id, slot: 0,
                                                             assembly: LabARAssembly(roomLayout: onDesk.layout))
        precondition(fromDesk.topology.devices.first { $0.id == router.id } == movedRouter)
        precondition(fromDesk.topology.pendingCableCircuits(in: fromDesk.layout).isEmpty)
        try detached.deleteRackDevice(router.id)
        precondition(detached.topology.devices.allSatisfy { $0.id != router.id })
        precondition(!detached.layout.placements.contains { $0.id == floor.id })
        precondition(!detached.topology.links.contains { ($0.circuitID ?? $0.id) == circuit })

        let monitor = LabARAssembly.RackMonitor(id: UUID(), device: server.id, panel: .services, side: .left, row: 1)
        try project.setRoomRackMonitors([monitor], rackID: rackA.id)
        let updated = LabARAssembly.RackMonitor(id: monitor.id, device: server.id, panel: .services, side: .right, row: 1)
        try project.setRoomRackMonitors([updated], rackID: rackA.id)
        let decoded = try JSONDecoder().decode(LabProject.self, from: JSONEncoder().encode(project))
        precondition(decoded.layout.rackMonitors?[rackA.id] == [updated])
        var obstructed = project
        obstructed.layout.placements = obstructed.layout.placements.map {
            $0.id == rackB.id ? $0.at(rackA.position + SIMD3(-0.82, 0, 0), yaw: 0) : $0
        }
        do {
            try obstructed.setRoomRackMonitors([monitor], rackID: rackA.id)
            preconditionFailure("El monitor chocaría con el rack de al lado.")
        } catch is LabLayoutError {}
        print("Cambio de rack, desmontaje al piso, suspensión de cables, remontaje, eliminación y monitores comprobados.")
    }

    private static func checkSharedEquipmentEditor() async throws {
        let room = try LabDemo.virtualRoom(width: 8, depth: 8)
        let layout = LabLayout(area: 64, floorHeight: 0, floorPolygon: [[-4, -4], [4, -4], [4, 4], [-4, 4]],
                               placements: [], warnings: [])
        var project = LabProject(room: room, layout: layout, topology: .init(name: "Editor compartido", devices: [], links: [],
                                                                             vlans: [], notes: []))
        let rack = try project.addRack(.compact, name: "Rack 12 U")
        let network = try project.mount(.switch24, name: "Switch", rackID: rack.id, slot: 2)
        let server = try project.mount(.server, name: "Servidor", rackID: rack.id, slot: 5)
        precondition(server.placementID == rack.id)
        let pc = try project.addDeskEquipment(.pc, name: "PC", deskID: nil)
        let desk = project.layout.placements.first { $0.id == pc.placementID }!
        precondition(desk.bareDesk == true && desk.size.x == LabDeskEquipment.pc.minimumDesk.x)
        precondition(project.deskOffset(for: .pc, on: desk) == nil)
        try project.resizeDesk(desk.id, width: 1.20, depth: 0.65)
        let laptop = try project.addDeskEquipment(.laptop, name: "Laptop", deskID: desk.id)
        let phone = try project.addDeskEquipment(.phone, name: "Celular", deskID: desk.id)
        precondition(laptop.placementID == desk.id && phone.placementID == desk.id && phone.connectionMode == .wifi)
        precondition(laptop.offset.x != pc.offset.x || laptop.offset.z != pc.offset.z)
        let result = try await project.connectingRoomPorts(.init(deviceID: network.id, name: "FastEthernet0/1"),
            to: .init(deviceID: pc.id, name: "Ethernet"), vlans: [], level: .floor)
        project = result.project
        try project.setCableLevel(result.linkID, to: .overhead, assembly: nil)
        let link = project.topology.links.first { $0.id == result.linkID }!
        precondition(project.topology.circuit(for: link).count > 1)
        precondition(project.topology.circuit(for: link).allSatisfy { $0.arRouteLevel == .overhead })
        var assembly = LabARAssembly(id: UUID(), name: "Editor compartido en RA")
        assembly.placeAll(in: project.layout, at: .zero, yaw: 0)
        let route = assembly.cablePlan(in: project.topology, layout: project.layout)
        precondition(route.channels.contains { abs($0.start.y - route.overhead) < 0.004 && abs($0.end.y - route.overhead) < 0.004 })
        precondition(LabCablePacking.supportAnchor(for: 2.2, onCeiling: true, floor: 0, ceiling: nil) > 2.2)
        precondition(LabCablePacking.supportAnchor(for: 2.2, onCeiling: true, floor: 0, ceiling: 2.7) == 2.7)
        precondition(LabCablePacking.supportAnchor(for: 0.08, onCeiling: false, floor: 0, ceiling: 2.7) == 0)

        let raised = rack.at(rack.position + SIMD3(0, 0.25, 0), yaw: rack.yaw)
        var poses = Lab3DPositions()
        poses.set(raised)
        let decoded = try JSONDecoder().decode(Lab3DPositions.self, from: JSONEncoder().encode(poses))
        precondition(decoded.applying(to: project.layout).placements.first { $0.id == rack.id }?.position.y == 0.25)
        let originalY = assembly.piece(.support(rack.id))?.position.y ?? 0
        try assembly.apply3DChange(from: rack, to: raised, in: project.layout, topology: project.topology)
        precondition(assembly.piece(.support(rack.id))?.position.y == originalY + 0.25)
        try assembly.apply3DChange(from: raised, to: rack, in: project.layout, topology: project.topology)
        precondition(assembly.piece(.support(rack.id))?.position.y == originalY)

        var home = try LabDemo.homeLab().topology
        let client = "home-admin-laptop"
        try home.configureClient(client, mode: .wifi, accessPoint: "home-ap")
        let configured = home.devices.first { $0.id == client }!
        let host = home.devices.first { $0.id == "home-pve" }!
        precondition(home.diagnosePing(from: configured, to: host, poweredOff: []).path?.devices.map(\.id).contains("home-ap") == true)
        precondition(home.diagnosePing(from: configured, to: host, poweredOff: ["home-ap"]).issue != nil)
        precondition(home.freePorts(on: configured).isEmpty)
        try home.configureClient(client, mode: .both, accessPoint: "home-ap")
        let both = home.devices.first { $0.id == client }!
        precondition(home.diagnosePing(from: both, to: host, poweredOff: ["home-ap"]).issue == nil)
        try home.configureClient(client, mode: .ethernet, accessPoint: "home-ap")
        precondition(home.devices.first { $0.id == client }?.wifiAccessPointID == nil)

        let slot = project.availableSlots(in: rack, model: RackMount.Equipment.router1941.rawValue).first!
        let catalogRouter = try project.mount(.router1941, name: "ISR 1941", rackID: rack.id, slot: slot)
        let catalogAP = try project.addDeskEquipment(.genericAccessPoint, name: "AccessPoint-PT", deskID: nil)
        let catalogLaptop = try project.addDeskEquipment(.genericLaptop, name: "Laptop-PT", deskID: nil)
        try project.topology.configureClient(catalogLaptop.id, mode: .wifi, accessPoint: catalogAP.id)
        try project.topology.validate(layout: project.layout)
        precondition(catalogRouter.modelID == "router-1941" && catalogRouter.ports.contains("GigabitEthernet0/0"))
        precondition(catalogAP.isAccessPoint && catalogLaptop.modelID == "pt-laptop")
        precondition(catalogLaptop.visualSize == LabDeskEquipment.genericLaptop.size)
        precondition(project.topology.devices.first { $0.id == catalogLaptop.id }?.wifiAccessPointID == catalogAP.id)
        print("Mesas, ampliación, montaje 3D/RA, patch panel, techo, altura guardada y Wi-Fi comprobados.")
    }

    private static func checkRackRouting(_ project: LabProject) throws {
        let plan = try LabCablePlan.make(project.topology, room: project.room, layout: project.layout)
        precondition(plan.reviewCount == 0 && plan.segments.count == project.topology.links.count)
        let racks = Dictionary(uniqueKeysWithValues: project.layout.placements.filter { $0.kind == .rack }.map { ($0.id, $0) })
        let supports = Dictionary(uniqueKeysWithValues: project.topology.devices.map { ($0.id, $0.placementID) })
        for organizer in plan.organizers {
            precondition(racks.values.contains { $0.position == organizer.rack.position &&
                $0.yaw == organizer.rack.yaw && $0.size == organizer.rack.size })
            let size = organizer.rack.size
            let rail = organizer.face.railDepth(in: size)
            precondition(abs(organizer.depth) < size.z / 2 && abs(organizer.depth - rail) < 0.09)
            switch organizer.mount {
            case .horizontal(let rows):
                precondition(organizer.railX < size.x / 2 && rows.lowerBound > 0 && rows.upperBound < size.y)
            case .vertical(let x, let heights):
                precondition(abs(x) + 0.018 < size.x / 2 && heights.upperBound <= size.y)
            case .depthRun(let ports, let rows, let span):
                precondition(ports.lowerBound > -size.x / 2 && ports.upperBound < size.x / 2)
                precondition(rows.lowerBound > 0 && rows.upperBound < size.y)
                precondition(span.lowerBound > -size.z / 2 && span.upperBound < size.z / 2 && span.upperBound - span.lowerBound > 0.054)
            }
        }
        for segment in plan.segments {
            guard let support = supports[segment.link.fromDeviceID], support == supports[segment.link.toDeviceID],
                  let rack = racks[support] else { continue }
            let inverse = simd_quatf(angle: -rack.yaw, axis: SIMD3(0, 1, 0))
            for point in segment.points {
                let local = inverse.act(point - rack.position)
                precondition(abs(local.x) < rack.size.x / 2 + 0.004 && abs(local.z) < rack.size.z / 2 + 0.004,
                             "Un latiguillo interno sale del rack: \(segment.link.id)")
            }
        }
    }

    private static func checkRackElevation() throws {
        for units in [12, 16, 17, 24, 42] {
            let size = RackMount.Height.full.size - SIMD3<Float>(0, Float(42 - units) * RackMount.unit, 0)
            let rack = LabPlacement(id: "rack", kind: .rack, title: "Rack", position: .zero, yaw: 0, size: size)
            precondition(RackMount.capacity(height: size.y) == units)
            let modes = LabARAssembly.Adjustment.forARPlacement(rack)
            precondition(modes == (units <= 16 ? [.move, .turn, .lift] : [.move, .turn]))
        }
        let original = LabARAssembly.Piece(id: .support("rack"), position: [1, 0.70, 2], yaw: .pi / 3)
        var rack = original
        rack.adjust(.lift, axes: [1, 1], forward: [1, 0, 0], seconds: 1)
        precondition(rack.position.x == 1 && rack.position.z == 2 && rack.position.y > original.position.y && rack.yaw == original.yaw)
        let saved = try JSONEncoder().encode(rack)
        rack = try JSONDecoder().decode(LabARAssembly.Piece.self, from: saved)
        rack.adjust(.lift, axes: [0, -1], forward: .zero, seconds: 10)
        precondition(rack.position.y == original.position.y)
    }

    private static func checkSavedLocationEdits() throws {
        let suite = "NexusAR.LocationCheck." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = LabARAssemblyStore(scope: "lab", defaults: defaults)
        let copy = LabARAssemblyStore(scope: "copy", defaults: defaults)
        let other = try store.save(.init(id: UUID(), name: "Sala B"))
        var original = LabARAssembly(id: UUID(), name: "Sala A")
        original.set(.init(id: .support("rack"), position: [1, 0, 2], yaw: .pi))
        try store.save(original)
        try copy.save(original)
        store.preferredID = original.id
        copy.preferredID = original.id
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data([1]).write(to: url)
        let renamed = try store.rename(original.id, to: "  Sala principal  ")
        precondition(renamed.name == "Sala principal" && renamed.pieces == original.pieces)
        precondition(renamed.anchorName == original.anchorName && store.preferredID == original.id)
        precondition((try? store.rename(original.id, to: "sAlA b")) == nil)
        precondition((try? store.rename(original.id, to: "Sala\nA")) == nil)
        try store.delete(original.id) { _ in url }
        let remaining = try store.all()
        precondition(remaining == [other] && store.preferredID == nil && copy.preferredID == original.id)
        precondition(FileManager.default.fileExists(atPath: url.path))
        try copy.delete(original.id) { _ in url }
        precondition(!FileManager.default.fileExists(atPath: url.path) && copy.preferredID == nil)
        try store.delete(other.id) { _ in url }
        let empty = try store.all()
        precondition(empty.isEmpty)
    }

    private static func checkRackClearanceAndCableTurns() throws {
        let size = RackMount.Height.compact.size
        let a = LabPlacement(id: "left", kind: .rack, title: "Rack pequeño", position: .zero, yaw: 0, size: size)
        let b = LabPlacement(id: "right", kind: .rack, title: "Rack contiguo", position: [2, 0, 0], yaw: 0, size: size)
        let layout = LabLayout(area: 36, floorHeight: 0, floorPolygon: [[-3, -3], [3, -3], [3, 3], [-3, 3]],
                               placements: [a, b], warnings: [])
        let room = try LabDemo.virtualRoom(width: 6, depth: 6)
        var project = LabProject(room: room, layout: layout, topology: .init(name: "Organización física", devices: [],
                                                                            links: [], vlans: [], notes: []))
        let network = try project.mount(.switch24, name: "Switch", rackID: a.id, slot: 4)
        let panel = try project.mount(.copperPanel, name: "Panel", rackID: a.id, slot: 5)
        let from = LabTopology.Port(deviceID: network.id, name: "FastEthernet0/2")
        let to = LabTopology.Port(deviceID: panel.id, name: "F22")
        let link = try project.topology.connect(from, to: to, vlans: [])
        let server = try project.mount(.server, name: "Servidor", rackID: a.id, slot: 8)
        let back = try project.topology.connect(.init(deviceID: server.id, name: "LOM1"),
                                              to: .init(deviceID: panel.id, name: "R22"), vlans: [])
        var assembly = LabARAssembly(id: UUID(), name: "Dos racks")
        assembly.placeAll(in: layout, at: .zero, yaw: 0)
        let plan = assembly.cablePlan(in: project.topology, layout: layout)
        let cable = plan.connections.first { $0.link.id == link.id }!
        precondition(cable.routed && cable.bendRadius == LabTopology.Medium.copper.referenceBendRadius)
        precondition(cable.endpoints.count == 2 && cable.points.first == cable.endpoints.first?.point &&
                     cable.points.last == cable.endpoints.last?.point)
        precondition(cable.points.contains { $0.y < min(cable.endpoints[0].point.y, cable.endpoints[1].point.y) - 0.03 })
        let rack = assembly.piece(.support(a.id))!
        let lowPoint = cable.points.map(\.y).min()! - rack.position.y
        precondition(plan.organizers.contains { organizer in
            guard organizer.rack.position == rack.position, organizer.face == .front,
                  case .horizontal(let rows) = organizer.mount else { return false }
            return rows.contains(lowPoint) || abs(rows.lowerBound - lowPoint) < 0.005
        }, "El latiguillo bajo dos unidades contiguas necesita un organizador a su altura real.")
        precondition(plan.organizers.contains { organizer in
            guard organizer.rack.position == rack.position, organizer.face == .front,
                  case .depthRun(_, _, let span) = organizer.mount else { return false }
            return span.upperBound - span.lowerBound < 0.13
        }, "El giro lateral debe unir los dos carriles del organizador.")
        for (start, end) in zip(cable.points, cable.points.dropFirst()) {
            let delta = simd_abs(end - start)
            if simd_length(delta) > 0.016 {
                precondition((0..<3).count { delta[$0] > 0.003 } <= 1, "El tramo entre dos U contiguas debe seguir el organizador.")
            }
        }
        let rear = plan.connections.first { $0.link.id == back.id }!
        precondition(rear.routed)
        let rearChannel = RackMount.CableFace.rear.channelDepth(in: size)
        let leads = plan.organizers.compactMap { organizer -> ClosedRange<Float>? in
            guard organizer.rack.position == rack.position, organizer.face == .rear,
                  case .depthRun(_, _, let span) = organizer.mount else { return nil }
            return span
        }
        precondition(leads.count == 2)
        for endpoint in rear.endpoints {
            let z = endpoint.point.z - rack.position.z
            precondition(leads.contains { abs($0.lowerBound - z) < 0.002 && abs($0.upperBound - rearChannel) < 0.002 })
        }

        var occupied = assembly
        let incoming = LabARAssembly.Piece(id: .support(a.id), position: [1.8, 0, 0], yaw: .pi / 8)
        occupied.set(incoming)
        precondition(occupied.conflicts(with: assembly, in: layout, topology: project.topology))
        var separating = occupied
        var moving = incoming
        moving.position.x = 1.6
        separating.set(moving)
        precondition(!separating.conflicts(with: occupied, in: layout, topology: project.topology, allowingSeparation: true))
        precondition(separating.conflicts(with: occupied, in: layout, topology: project.topology))
        moving.position.y = size.y + 0.05
        separating.set(moving)
        precondition(!separating.conflicts(with: occupied, in: layout, topology: project.topology))
    }

    private static func checkFixedPathways() throws {
        func guide(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> LabCablePacking.Guide {
            .init(start: a, end: b, size: SIMD2(0.05, 0.025), cableCount: 4, overCapacity: false)
        }
        let corner = SIMD3<Float>(1, 0, 0)
        let straights = [guide(.zero, corner), guide(corner, SIMD3(1, 0, 1))]
        let fitted = LabCablePacking.connectGuides(straights)
        precondition(fitted.elbows.count == 1 && fitted.junctions.isEmpty)
        let elbow = fitted.elbows[0]
        precondition(elbow.points.count == 11 && fitted.straights[0].end == elbow.points.first
                     && fitted.straights[1].start == elbow.points.last)
        precondition(fitted.straights[0].end != corner && fitted.straights[1].start != corner)
        let tight = LabCablePacking.connectGuides([guide([0.96, 0, 0], corner), guide(corner, [1, 0, 0.04])])
        precondition(tight.elbows.isEmpty && tight.junctions.count == 1,
                     "Un codo estrecho necesita una unión para que la sección en U no se cruce.")
        let tee = LabCablePacking.connectGuides(straights + [guide(corner, SIMD3(2, 0, 0))])
        precondition(tee.elbows.isEmpty && tee.junctions.count == 1 && tee.junctions[0].point == corner)
        for degrees: Float in [20, 35, 45] {
            let angle = degrees * .pi / 180
            let span = SIMD3(cos(angle), 0, sin(angle)) * 0.06
            let turn = LabCablePacking.connectGuides([guide(.zero, corner), guide(corner, corner + span)])
            precondition(turn.elbows.count == 1 && turn.junctions.isEmpty)
            precondition(turn.straights[0].end == turn.elbows[0].points.first &&
                         turn.straights[1].start == turn.elbows[0].points.last)
        }

        let project = try LabDemo.homeLab()
        let rack = project.layout.placements.first { $0.kind == .rack }!
        var assembly = LabARAssembly(id: UUID(), name: "Rack de pruebas")
        assembly.set(.init(id: .support(rack.id), position: rack.position, yaw: rack.yaw))
        let local = assembly.cablePlan(in: project.topology, layout: project.layout)
        precondition(!local.connections.isEmpty && !local.organizers.isEmpty)
        precondition(local.channels.isEmpty && local.terminations.isEmpty)
        assembly.placeAll(in: project.layout, at: .zero, yaw: 0)
        let complete = assembly.cablePlan(in: project.topology, layout: project.layout)
        precondition(complete.terminations.count == project.layout.placements.count)
        precondition(complete.terminations.filter(\.rack).count == 1 && !complete.channels.isEmpty)

        let touch = SIMD2<Float>(40, 20)
        let orbit = LabOrbitGesture.rotation(for: touch, fingers: 1)
        precondition(orbit.x < 0 && orbit.y > 0)
        precondition(LabOrbitGesture.rotation(for: touch, fingers: 2) == .zero)
        precondition(LabOrbitGesture.rotation(for: touch, fingers: 3) == orbit * 0.5)
        precondition(LabOrbitGesture.rotation(for: touch, fingers: 4) == .zero)
        let pan = LabOrbitGesture.screenOffset(touch, radius: 3, field: 55, viewportHeight: 600)
        precondition(pan.x > 0 && pan.y < 0)
        print("Tomas por puesto, organizadores, codos, uniones y gestos de cámara comprobados.")
    }

    private static func checkCablePackingAnd3DPositions() throws {
        let anchor = LabCablePacking.Anchor(position: .zero, yaw: 0, size: RackMount.Height.full.size)
        let organizers = LabCablePacking.groupedOrganizers([
            .init(rack: anchor, face: .front, mount: .horizontal(rows: 0.20...0.21)),
            .init(rack: anchor, face: .front, mount: .horizontal(rows: 0.22...0.23)),
            .init(rack: anchor, face: .rear, mount: .horizontal(rows: 0.20...0.21)),
            .init(rack: anchor, face: .front, mount: .horizontal(rows: 0.60...0.61))
        ])
        precondition(organizers.count == 3 && organizers.contains {
            if case .horizontal(let rows) = $0.mount { return $0.face == .front && rows == 0.20...0.23 }
            return false
        })
        let link: (Int) -> LabTopology.Link = { index in
            .init(id: "cable-\(index)", fromDeviceID: "A", fromPort: "P\(index)",
                  toDeviceID: "B", toPort: "P\(index)", medium: .copper, vlanIDs: [])
        }
        let paths: [LabCablePacking.Path] = [
            .init(link: link(1), points: [.zero, SIMD3(3, 0, 0)]),
            .init(link: link(2), points: [SIMD3(4, 0, 0), SIMD3(1, 0, 0)]),
            .init(link: link(3), points: [SIMD3(2, 0.020, 0), SIMD3(3, 0.020, 0)])
        ]
        let pieces = LabCablePacking.runs(paths)
        let shared = pieces.filter { $0.links.count > 1 }
        precondition(shared.count == 1 && shared[0].start.x == 1 && shared[0].end.x == 3)
        precondition(abs(LabTopology.Medium.copper.cableRadius * 2 - 0.00569) < 0.000001)
        let offsets = LabCablePacking.offsets(for: paths, sharing: pieces)
        let distance = simd_length(simd_cross(offsets[link(1).id]! - offsets[link(2).id]!, SIMD3(1, 0, 0)))
        precondition(distance > 2 * LabTopology.Medium.copper.cableRadius)
        let laid = LabCablePacking.strand([.zero, SIMD3(1, 0, 0), SIMD3(2, 0, 0)], offset: SIMD3(0, 0.008, 0))
        precondition(laid.first == .zero && laid.last == SIMD3(2, 0, 0) && laid.contains(SIMD3(1, 0.008, 0)))
        let one = LabCablePacking.Run(start: .zero, end: SIMD3(1, 0, 0), links: [link(1)])
        let full = LabCablePacking.Run(start: .zero, end: SIMD3(1, 0, 0), links: (1...192).map(link))
        let capacity = full.guide(offsets: offsets)
        precondition(capacity.size.x > one.guide(offsets: offsets).size.x && capacity.overCapacity)

        let project = try LabDemo.homeLab()
        let layout = project.layout
        let original = layout.placements[0]
        var ar = LabARAssembly(id: UUID(), name: "Guardado AR")
        ar.placeAll(in: layout, at: SIMD3(1, 0, 1), yaw: 0)
        let arBytes = try JSONEncoder().encode(ar)
        let candidates = [-0.25, -0.1, 0.1, 0.25].map {
            original.at(original.position + SIMD3(Float($0), 0, 0), yaw: original.yaw + 0.1)
        }
        let moved = candidates.first { LabTopology.fitsPlacement($0, in: layout) }!
        var edits = Lab3DPositions()
        edits.set(moved)
        let restored = try JSONDecoder().decode(Lab3DPositions.self, from: JSONEncoder().encode(edits))
        let edited = restored.applying(to: layout)
        precondition(edited.placements[0] == moved)
        precondition(layout.placements[0] == original)
        let initialPlan = try LabCablePlan.make(project.topology, room: project.room, layout: layout)
        let editedPlan = try LabCablePlan.make(project.topology, room: project.room, layout: edited)
        precondition(initialPlan.segments.map(\.link.id) == editedPlan.segments.map(\.link.id))
        precondition(zip(initialPlan.segments, editedPlan.segments).contains { $0.points != $1.points })
        let savedAR = try JSONDecoder().decode(LabARAssembly.self, from: arBytes)
        precondition(savedAR == ar)
        let suite = "NexusAR.SyncCheck." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = LabARAssemblyStore(scope: "qa", defaults: defaults)
        let independent = LabARAssembly(id: UUID(), name: "Otro montaje")
        try store.save(independent)
        try store.save(ar)
        let support = LabARAssembly.Item.support(original.id)
        let previous = ar.piece(support)!
        try ar.apply3DChange(from: original, to: moved, in: edited, topology: project.topology)
        try store.save(ar)
        let stored = try store.all()
        precondition(stored.contains(independent) && stored.contains(ar) && ar.anchorName == savedAR.anchorName)
        let updated = ar.piece(support)!
        precondition(abs(simd_distance(updated.position, previous.position) - simd_distance(moved.position, original.position)) < 0.0001)
        precondition(abs(updated.yaw - previous.yaw - (moved.yaw - original.yaw)) < 0.0001)
        edits.set(original.at(SIMD3(10_000, original.position.y, 10_000), yaw: 0))
        precondition(edits.applying(to: layout).placements[0] == original)
        for id in ["switch-2960", "switch-3560", "switch-3650"] {
            let names = LabDemo.ports(id)
            let upper = LabScenePort.networkPanel(id, port: names[0])!
            let lower = LabScenePort.networkPanel(id, port: names[1])!
            precondition(upper.point.x == lower.point.x && upper.point.y > lower.point.y && upper.normal.z < 0)
        }
        precondition(LabScenePort.networkPanel("router-2811", port: "Console")?.normal.z == -1)
        precondition(LabScenePort.networkPanel("router-2911", port: "GigabitEthernet0/2")?.normal.z == 1)
        print("Cables individuales, capacidad, puertos físicos y sincronización selectiva comprobados.")
    }

    private static func checkDirectRackEditing() throws {
        var project = try LabDemo.dataCenter()
        let rack = try project.addRack(.compact, name: "Rack de montaje directo")
        let firstUnit = RackMount.base + RackMount.unit / 2
        precondition(RackMount.target(origin: SIMD3(0, firstUnit, -3), direction: SIMD3(0, 0, 1), size: rack.size) == .unit(0))
        precondition(RackMount.target(origin: SIMD3(-3, 0.25, 0), direction: SIMD3(1, 0, 0), size: rack.size) == .side(.left))
        precondition(RackMount.target(origin: SIMD3(3, 0.25, 0), direction: SIMD3(-1, 0, 0), size: rack.size) == .side(.right))
        precondition(RackMount.target(origin: SIMD3(0, 0, -3), direction: SIMD3(0, 0, 1), size: rack.size) == nil)

        let ups = try project.mount(.ups, name: "UPS de pruebas", rackID: rack.id, slot: 0)
        let battery = try project.mount(.battery, name: "Batería de pruebas", rackID: rack.id, slot: 2)
        let router = try project.mount(.router, name: "Router de pruebas", rackID: rack.id, slot: 4)
        let networkSwitch = try project.mount(.switch24, name: "Switch de pruebas", rackID: rack.id, slot: 11)
        precondition(ups.ports.isEmpty && battery.ports.isEmpty && !router.ports.isEmpty && !networkSwitch.ports.isEmpty)
        precondition(project.availableSlots(in: rack) == Array(6...10))
        precondition(!project.availableSlots(in: rack, model: RackMount.Equipment.ups.rawValue).contains(10))
        let switchPort = LabTopology.Port(deviceID: networkSwitch.id, name: networkSwitch.ports[0])
        let switchIndex = project.topology.devices.firstIndex { $0.id == networkSwitch.id }!
        project.topology.devices[switchIndex].sourcePortNames = [switchPort.name: "FastEthernet1/1"]
        project.topology.devices[switchIndex].configuration = "interface FastEthernet1/1\nswitchport access vlan 20\n!\ninterface FastEthernet1/2\nswitchport access vlan 10"
        precondition(project.topology.suggestedVLAN(at: switchPort) == 20)
        precondition(project.topology.suggestedVLAN(at: .init(deviceID: networkSwitch.id, name: networkSwitch.ports[1])) == nil)
        let circuit = try project.topology.connect(.init(deviceID: router.id, name: router.ports[0]),
            to: switchPort, vlans: [20])
        precondition(circuit.medium == .copper && circuit.vlanIDs == [20])
        try project.topology.validate(layout: project.layout)
        let site = UUID().uuidString
        let (copy, entry) = try LabImport.createEditableCopy(of: project, site: site)
        defer { try? FileManager.default.removeItem(at: entry.url.deletingLastPathComponent()) }
        let opened = try LabImport.load(entry)
        precondition(opened.topology == copy.topology)

        var assembly = LabARAssembly(id: UUID(), name: "Pantallas laterales")
        let support = LabARAssembly.Item.support(rack.id)
        assembly.set(.init(id: support, position: .zero, yaw: 0))
        let server = project.topology.devices.first { $0.visualModelID == "server-c220m5" }!
        let left = LabARAssembly.Item.monitor(device: server.id, panel: .services, id: UUID())
        let right = LabARAssembly.Item.monitor(device: server.id, panel: .network, id: UUID())
        let blocker = LabARAssembly.Item.extra(model: "battery-bank", id: UUID())
        assembly.set(.init(id: blocker, position: [rack.size.x / 2 + 0.45, 0, -rack.size.z / 2], yaw: 0))
        precondition(assembly.freeMonitorRows(on: rack, side: .right, in: project.layout, topology: project.topology).isEmpty)
        precondition(assembly.freeMonitorRows(on: rack, side: .left, in: project.layout, topology: project.topology) == [0])
        assembly.remove(blocker)
        for (item, side) in [(left, RackMount.Side.left), (right, .right)] {
            precondition(assembly.freeMonitorRows(on: rack, side: side, in: project.layout, topology: project.topology) == [0])
            assembly.set(.init(id: item, position: .zero, yaw: 0, monitorMount: .init(rackID: rack.id, side: side, row: 0)))
            precondition(assembly.freeMonitorRows(on: rack, side: side, in: project.layout, topology: project.topology).isEmpty)
        }
        let first = assembly.resolvedPieces(in: project.layout)
        let original = first.first { $0.id == left }!.position
        precondition(original.x < 0 && first.first { $0.id == right }!.position.x > 0)
        var nearMonitor = assembly
        nearMonitor.set(.init(id: blocker, position: [original.x - 0.15, 0, original.z], yaw: 0))
        precondition(nearMonitor.conflicts(with: assembly, in: project.layout, topology: project.topology))
        let moved = LabARAssembly.Piece(id: support, position: SIMD3(2, 0, 3), yaw: .pi / 2)
        assembly.set(moved)
        let adjusted = assembly.resolvedPieces(in: project.layout).first { $0.id == left }!
        precondition(simd_distance(adjusted.position, moved.world(original)) < 0.0001 && adjusted.yaw == moved.yaw)
        let restored = try JSONDecoder().decode(LabARAssembly.self, from: JSONEncoder().encode(assembly))
        precondition(restored == assembly)
        assembly.remove(support)
        precondition(assembly.resolvedPieces(in: project.layout).isEmpty)

        let origin = SIMD3<Float>(0, 1.4, 0)
        precondition(LabARAssembly.waypointPlaneHit(origin: origin, direction: SIMD3(1, -1, 0), height: 0.055)?.y == 0.055)
        precondition(LabARAssembly.waypointPlaneHit(origin: origin, direction: SIMD3(1, 1, 0), height: 2.2)?.y == 2.2)
        precondition(LabARAssembly.waypointPlaneHit(origin: origin, direction: SIMD3(1, 0, 0), height: 2.2) == nil)
        print("Unidades, laterales del rack, UPS, baterías, router, switch, pantallas ancladas y plano de arrastre comprobados.")
    }

    private static func checkRearPatchRouting() async throws {
        let room = try LabDemo.virtualRoom(width: 10, depth: 10)
        let rack = LabPlacement(id: "rear-rack", kind: .rack, title: "Rack", position: .zero, yaw: .pi / 2,
                                size: RackMount.Height.full.size)
        let desk = LabPlacement(id: "rear-desk", kind: .workstation, title: "Puesto", position: SIMD3(3, 0, 0.3), yaw: -.pi / 2,
                                 size: SIMD3(1.35, 1.25, 0.75))
        let layout = LabLayout(area: 100, floorHeight: 0, floorPolygon: [[-5, -5], [5, -5], [5, 5], [-5, 5]],
                               placements: [rack, desk], warnings: [])
        let pcs = (0..<3).map { index in
            LabTopology.Device(id: "pc-\(index)", name: "PC \(index)", modelID: "pc-optiplex7010", placementID: desk.id,
                               offset: SIMD3(Float(index - 1) * 0.3, 0.3, 0), services: [], ports: ["Ethernet"])
        }
        var project = LabProject(room: room, layout: layout, topology: .init(name: "Salida trasera", devices: pcs,
                                                                            links: [], vlans: [], notes: []))
        let servers = try [1, 20, 39].map { slot in try project.addServer(name: "Servidor U\(slot + 1)", rackID: rack.id, slot: slot) }
        var assembly = LabARAssembly(id: UUID(), name: "Salida trasera")
        for placement in layout.placements {
            assembly.set(.init(id: .support(placement.id), position: placement.position, yaw: placement.yaw))
        }
        var chosen = Set<String>()
        for (server, pc) in zip(servers, pcs) {
            let serverPort = LabTopology.Port(deviceID: server.id, name: "LOM1")
            let pcPort = LabTopology.Port(deviceID: pc.id, name: "Ethernet")
            let connected = try await project.connectingARPorts(serverPort, to: pcPort, vlans: [], level: .floor, in: assembly)
            project = connected.project
            let trunk = project.topology.links.first { $0.id == connected.linkID }!
            let panels = project.topology.devices.filter { $0.modelID == "patch-copper" }
            let nearest = panels.min { abs($0.offset.y - server.offset.y) < abs($1.offset.y - server.offset.y) }
            precondition(panels.count == 3 && nearest?.id == trunk.fromDeviceID && trunk.fromPort.hasPrefix("R"))
            precondition(chosen.insert(trunk.fromDeviceID).inserted)
        }
        let plan = assembly.cablePlan(in: project.topology, layout: project.layout)
        let rearPlane = rack.size.z / 2 - 0.04
        precondition(plan.reviewCount == 0 && plan.terminations.contains { $0.rack && $0.point.x >= rearPlane })
        precondition(plan.channels.allSatisfy { $0.start.x >= rearPlane && $0.end.x >= rearPlane })
        let design = try LabCablePlan.make(project.topology, room: room, layout: project.layout)
        for trunk in plan.connections where trunk.link.autoPatchTrunk == true {
            let port = trunk.endpoints[0].point
            let local = simd_quatf(angle: -rack.yaw, axis: SIMD3<Float>(0, 1, 0)).act(port - rack.position)
            for organizers in [plan.organizers, design.organizers] {
                precondition(organizers.contains { organizer in
                    guard organizer.face == .rear, let portDepth = organizer.portDepth,
                          case .depthRun(let ports, let rows, let span) = organizer.mount else { return false }
                    return abs(portDepth - local.z) < 0.001
                        && (ports.lowerBound - 0.001...ports.upperBound + 0.001).contains(local.x)
                        && (rows.lowerBound - 0.001...rows.upperBound + 0.001).contains(local.y)
                        && abs(span.upperBound - RackMount.CableFace.rear.channelDepth(in: rack.size)) < 0.001
                }, "La salida del panel al troncal debe conservar el sujetador en 3D y en el montaje RA.")
            }
        }
        let endpoints = [(servers[0].id, "LOM1", "192.168.1.10"), (pcs[0].id, "Ethernet", "192.168.1.20")]
        for (id, port, address) in endpoints {
            let index = project.topology.devices.firstIndex { $0.id == id }!
            project.topology.devices[index].ipv4 = address
            project.topology.devices[index].packetTracer = .init(description: "", interfaces: [
                .init(port: port, ipv4: address, mask: "255.255.255.0", gateway: nil, ospfArea: nil,
                      dhcp: nil, fromLease: nil, dhcpServer: nil, description: nil)
            ], dhcpPools: [])
        }
        let source = project.topology.devices.first { $0.id == servers[0].id }!
        let target = project.topology.devices.first { $0.id == pcs[0].id }!
        let importedPath = project.topology.importedIPv4Path(from: source, to: target, poweredOff: [])
        precondition(importedPath?.map(\.modelID) == [source.modelID, "patch-copper", target.modelID])
        print("Rack 42 U: panel más cercano por altura y canaletas detrás del rack girado.")
    }

    private static func checkEditableNetwork() async throws {
        let original = try LabDemo.dataCenter()
        let site = UUID().uuidString
        var (copy, entry) = try LabImport.createEditableCopy(of: original, site: site)
        defer { try? FileManager.default.removeItem(at: entry.url.deletingLastPathComponent()) }
        let compact = try copy.addRack(.compact, name: "Rack de servicios")
        let medium = try copy.addRack(.medium, name: "Rack de pruebas")
        precondition(RackMount.capacity(height: compact.size.y) == 12 && RackMount.capacity(height: medium.size.y) == 24)
        precondition(compact.size.x == medium.size.x && compact.size.z == medium.size.z)
        let server = try copy.addServer(name: "Servicios", rackID: compact.id, slot: 0)
        let client = try copy.addServer(name: "Cliente de pruebas", rackID: medium.id, slot: 0)
        precondition(!copy.availableSlots(in: compact).contains(0))
        do {
            _ = try copy.addServer(name: "Colisión", rackID: compact.id, slot: 0)
            preconditionFailure("Unidad ocupada aceptada.")
        } catch {}
        try copy.topology.configureServer(server.id, name: server.name, address: "192.168.20.160", vlan: 20,
            services: .init(dns: .init(hostname: "visor.lab", address: "192.168.20.160"),
                            dhcp: .init(start: "192.168.20.180", end: "192.168.20.184", gateway: nil, dns: "192.168.20.160"),
                            httpTitle: "Página de prueba"))
        let from = LabTopology.Port(deviceID: server.id, name: "LOM1"), to = LabTopology.Port(deviceID: client.id, name: "LOM1")
        var assembly = LabARAssembly(id: UUID(), name: "Montaje editable")
        let sourceRack = LabARAssembly.Piece(id: .support(compact.id), position: .zero, yaw: 0)
        let targetRack = LabARAssembly.Piece(id: .support(medium.id), position: SIMD3(3, 0, 0), yaw: 0)
        assembly.set(sourceRack)
        precondition(assembly.connectionPorts(on: server, in: copy.topology, from: nil).contains(from))
        precondition(assembly.connectionPorts(on: server, in: copy.topology, from: from).isEmpty)
        precondition(assembly.connectionPorts(on: client, in: copy.topology, from: from).isEmpty)
        let originalLinks = copy.topology.links
        do {
            _ = try await copy.connectingARPorts(from, to: to, vlans: [20], level: .overhead, in: assembly)
            preconditionFailure("Se aceptó un destino sin colocar.")
        } catch {}
        precondition(copy.topology.links == originalLinks)

        assembly.set(targetRack)
        precondition(assembly.connectionPorts(on: client, in: copy.topology, from: from).contains(to))
        let connected = try await copy.connectingARPorts(from, to: to, vlans: [20], level: .overhead, in: assembly)
        precondition(copy.topology.links == originalLinks)
        copy = connected.project
        let cable = copy.topology.links.first { $0.id == connected.linkID }!
        let circuit = copy.topology.circuit(for: cable)
        precondition(circuit.count == 3 && cable.arRouteLevel == .overhead && cable.vlanIDs == [20])
        precondition(cable.fromPort.hasPrefix("R") && cable.toPort.hasPrefix("R"))
        let panels = copy.topology.devices.filter { $0.modelID == "patch-copper" }
        precondition(panels.count { $0.placementID == compact.id } == 1 && panels.count { $0.placementID == medium.id } == 2)
        let nearest = panels.filter { $0.placementID == medium.id }.min {
            abs($0.offset.y - client.offset.y) < abs($1.offset.y - client.offset.y)
        }
        precondition(cable.toDeviceID == nearest?.id)
        precondition(!assembly.connectionPorts(on: client, in: copy.topology, from: nil).contains(to))
        do {
            _ = try await copy.connectingARPorts(from, to: to, vlans: [20], level: .overhead, in: assembly)
            preconditionFailure("Puerto ocupado aceptado.")
        } catch {}
        let lease = try copy.topology.requestDHCP(for: client.id, vlan: 20)
        precondition(lease.contains("192.168.20.180") && lease.contains("DNS 192.168.20.160"))
        let assigned = copy.topology.devices.first { $0.id == client.id }!
        let destination = copy.topology.devices.first { $0.id == server.id }!
        precondition(assigned.leasedBy == server.id)
        precondition(copy.topology.resolveSimulatedDNS("visor.lab", from: assigned, poweredOff: []).contains("192.168.20.160"))
        precondition(copy.topology.testNetwork(from: assigned, to: destination, tcp: 80, poweredOff: []).contains("HTTP 200"))
        try LabImport.saveEditable(copy, to: entry)
        let saved = try LabImport.load(entry)
        precondition(saved.editableID == copy.editableID && saved.topology == copy.topology && saved.layout.placements == copy.layout.placements)
        precondition(!original.topology.devices.contains(where: { $0.id == server.id }) && original.topology.name != saved.topology.name)

        let planned = assembly.cablePlan(in: saved.topology, layout: saved.layout)
        let firstRoute = planned.connections.first { $0.link.id == circuit.first!.id }!
        let lastRoute = planned.connections.first { $0.link.id == circuit.last!.id }!
        let sourceContact = try sourceRack.world(server.offset + LabScenePort.local(server, from.name).point)
        let targetContact = try targetRack.world(client.offset + LabScenePort.local(client, to.name).point)
        precondition(firstRoute.bendRadius != nil && lastRoute.bendRadius != nil &&
                     simd_distance(firstRoute.points.first!, sourceContact) < 0.0001 &&
                     simd_distance(lastRoute.points.last!, targetContact) < 0.0001)
        precondition(planned.terminations.filter(\.rack).count == 2 && planned.terminations.filter(\.rack).allSatisfy { $0.point.z > 0 })
        precondition(planned.channels.contains { $0.start.y == $0.end.y && $0.start.y > 2 })
        let candidate = assembly.snappedWaypoint(SIMD3(1.53, 0, 1.2))
        precondition(candidate == SIMD2(1.5, 1.2))
        assembly.setWaypoints([candidate], for: cable.id)
        let edited = assembly.cablePlan(in: saved.topology, layout: saved.layout)
        precondition(edited.connections.first { $0.link.id == cable.id }?.usesWaypoints == true)
        precondition(edited.connections.first { $0.link.id == cable.id }?.waypointHeight ?? 0 > 2)
        assembly.setWaypoints([.zero], for: cable.id)
        let obstructed = assembly.cablePlan(in: saved.topology, layout: saved.layout)
        precondition(obstructed.connections.first { $0.link.id == cable.id }?.usesWaypoints == false && obstructed.reviewCount > 0)
        assembly.set(.init(id: .monitor(device: server.id, panel: .services, id: UUID()),
                           position: SIMD3(5, 0, 2), yaw: 0))
        let reopened = try JSONDecoder().decode(LabARAssembly.self, from: JSONEncoder().encode(assembly))
        precondition(reopened == assembly)
        copy.topology.disconnect(cable.id)
        precondition(copy.topology.links == originalLinks)
        do {
            _ = try copy.topology.requestDHCP(for: client.id, vlan: 20)
            preconditionFailure("DHCP llegó con el cable desconectado.")
        } catch {}
        print("Copia editable, racks 12/24 U, puertos, canaleta aérea, puntos de paso, pantalla y DNS/DHCP/HTTP comprobados.")
    }
}
