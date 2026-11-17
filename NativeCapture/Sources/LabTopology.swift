import Foundation
import simd

nonisolated struct LabTopology: Codable, Sendable, Equatable {
    struct Device: Identifiable, Codable, Sendable, Equatable {
        var id: String
        var name: String
        var modelID: String
        var placementID: String
        var offset: SIMD3<Float>
        var ipv4: String?
        var vlan: Int?
        var services: [String]
        var ports: [String]
        var sourceModel: String? = nil
        var configuration: String? = nil
        var sourcePortNames: [String: String]? = nil
    }

    enum Medium: String, Codable, Sendable {
        case copper, fiber, console, powerA, powerB
    }

    struct Link: Identifiable, Codable, Sendable, Equatable {
        var id: String
        var fromDeviceID: String
        var fromPort: String
        var toDeviceID: String
        var toPort: String
        var medium: Medium
        var vlanIDs: [Int]
    }

    struct VLAN: Identifiable, Codable, Sendable, Equatable {
        var id: Int
        var name: String
        var subnet: String
    }

    var name: String
    var devices: [Device]
    var links: [Link]
    var vlans: [VLAN]
    var notes: [String]

    /// Validates structure and supported media, not reachability or a device's IOS configuration.
    func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 160,
              devices.count <= 256, links.count <= 512, vlans.count <= 64,
              notes.count <= 256, notes.allSatisfy({ $0.count <= 1024 }),
              Set(devices.map(\.id)).count == devices.count,
              Set(links.map(\.id)).count == links.count,
              Set(vlans.map(\.id)).count == vlans.count else {
            throw LabLayoutError.invalid("Topología vacía, excesiva o con identificadores duplicados.")
        }
        for vlan in vlans {
            guard (1...4094).contains(vlan.id), !vlan.name.isEmpty, vlan.name.count <= 120,
                  Self.validSubnet(vlan.subnet) else { throw LabLayoutError.invalid("VLAN o subred inválida: \(vlan.id).") }
        }
        for device in devices {
            let available = Set(LabDemo.ports(device.modelID))
            guard !device.id.isEmpty, device.id.count <= 160, !device.name.isEmpty, device.name.count <= 160,
                  !device.placementID.isEmpty, device.placementID.count <= 160,
                  HardwareCatalog.item(device.modelID) != nil, device.modelID != "rack-r42612",
                  device.offset.x.isFinite, device.offset.y.isFinite, device.offset.z.isFinite,
                  (0..<3).allSatisfy({ abs(device.offset[$0]) <= 100 }),
                  device.services.count <= 32, device.services.allSatisfy({ !$0.isEmpty && $0.count <= 120 }),
                  Set(device.ports).count == device.ports.count, device.ports.count <= 128,
                  device.ports.allSatisfy({ available.contains($0) }),
                  device.ipv4 == nil || Self.ipv4(device.ipv4!) != nil,
                  device.vlan == nil || vlans.contains(where: { $0.id == device.vlan }),
                  device.sourceModel == nil || device.sourceModel!.count <= 256,
                  device.sourcePortNames == nil || (device.sourcePortNames!.count <= 128 && device.sourcePortNames!.allSatisfy({ available.contains($0.key) && !$0.value.isEmpty && $0.value.count <= 128 })),
                  device.configuration == nil || device.configuration!.utf8.count <= 65536 else {
                throw LabLayoutError.invalid("Equipo, dirección o puertos inválidos: \(device.name).")
            }
        }
        let byID = Dictionary(uniqueKeysWithValues: devices.map { ($0.id, $0) })
        var occupied = Set<String>()
        for link in links {
            guard !link.id.isEmpty, link.id.count <= 160, link.fromDeviceID != link.toDeviceID,
                  let source = byID[link.fromDeviceID], let target = byID[link.toDeviceID],
                  source.ports.contains(link.fromPort), target.ports.contains(link.toPort),
                  occupied.insert(source.id + "\u{1f}" + link.fromPort).inserted,
                  occupied.insert(target.id + "\u{1f}" + link.toPort).inserted,
                  Set(link.vlanIDs).count == link.vlanIDs.count,
                  link.vlanIDs.allSatisfy({ id in vlans.contains { $0.id == id } }) else {
                throw LabLayoutError.invalid("Enlace con extremo, puerto, VLAN u ocupación inválida: \(link.id).")
            }
            let a = Self.mediumForPort(modelID: source.modelID, port: link.fromPort)
            let b = Self.mediumForPort(modelID: target.modelID, port: link.toPort)
            switch link.medium {
            case .copper, .fiber:
                guard a == link.medium, b == link.medium else { throw LabLayoutError.invalid("Medio incompatible en enlace \(link.id).") }
            case .console:
                // No serial host connector is asserted for the current ten-model catalog.
                throw LabLayoutError.invalid("La consola necesita un host serie documentado; ese enlace no está disponible todavía.")
            case .powerA, .powerB:
                throw LabLayoutError.invalid("Energía A/B es sólo metadato; no hay conectores PDU verificados en este catálogo.")
            }
        }
    }

    func validate(layout: LabLayout) throws {
        try validate()
        guard layout.placements.count <= 36,
              layout.placements.filter({ $0.kind == .rack }).count <= 12,
              layout.placements.filter({ $0.kind == .workstation }).count <= 24,
              Set(layout.placements.map(\.id)).count == layout.placements.count,
              layout.floorHeight.isFinite, layout.area.isFinite, layout.area > 0 else {
            throw LabLayoutError.invalid("Distribución fuera de los límites de importación.")
        }
        _ = try LabGeometry.triangulate(layout.floorPolygon)
        let byID = Dictionary(uniqueKeysWithValues: layout.placements.map { ($0.id, $0) })
        for placement in layout.placements {
            guard !placement.id.isEmpty, placement.yaw.isFinite,
                  (0..<3).allSatisfy({ placement.position[$0].isFinite && placement.size[$0].isFinite && placement.size[$0] > 0 }),
                  abs(placement.position.y - layout.floorHeight) <= 0.05 else {
                throw LabLayoutError.invalid("Posición o tamaño inválido: \(placement.title).")
            }
            let corners = Self.corners(placement)
            guard corners.allSatisfy({ LabGeometry.contains($0, polygon: layout.floorPolygon) }),
                  !corners.indices.contains(where: { i in
                      layout.floorPolygon.indices.contains { j in
                          Self.crosses(corners[i], corners[(i + 1) % 4], layout.floorPolygon[j], layout.floorPolygon[(j + 1) % layout.floorPolygon.count])
                      }
                  }) else { throw LabLayoutError.invalid("Equipo fuera del contorno de suelo: \(placement.title).") }
        }
        for i in layout.placements.indices {
            for j in layout.placements.indices where j > i {
                guard !Self.overlaps(layout.placements[i], layout.placements[j]) else { throw LabLayoutError.invalid("Hay colocaciones solapadas.") }
            }
        }
        for device in devices {
            guard let placement = byID[device.placementID], device.offset.y >= 0,
                  device.offset.y <= placement.size.y,
                  abs(device.offset.x) <= placement.size.x / 2,
                  abs(device.offset.z) <= placement.size.z / 2 else {
                throw LabLayoutError.invalid("Equipo sin colocación válida o centro fuera de su soporte: \(device.name).")
            }
        }
    }

    static func mediumForPort(modelID: String, port: String) -> Medium? {
        guard LabDemo.ports(modelID).contains(port) else { return nil }
        if port == "Console" { return .console }
        if modelID == "switch-3560" && port.hasPrefix("GigabitEthernet") { return .fiber }
        return .copper
    }

    private static func ipv4(_ text: String) -> UInt32? {
        let fields = text.split(separator: ".", omittingEmptySubsequences: false)
        guard fields.count == 4 else { return nil }
        var result: UInt32 = 0
        for field in fields {
            guard !field.isEmpty, field.count <= 3, field.allSatisfy({ $0 >= "0" && $0 <= "9" }),
                  field.count == 1 || field.first != "0", let byte = UInt8(field) else { return nil }
            result = (result << 8) | UInt32(byte)
        }
        return result
    }

    private static func validSubnet(_ text: String) -> Bool {
        if text.isEmpty { return true } // Unknown imported subnet is not guessed.
        let fields = text.split(separator: "/", omittingEmptySubsequences: false)
        guard fields.count == 2, let address = ipv4(String(fields[0])), let prefix = Int(fields[1]),
              (0...32).contains(prefix) else { return false }
        let mask: UInt32 = prefix == 0 ? 0 : UInt32.max << (32 - prefix)
        return address & mask == address
    }

    private static func corners(_ placement: LabPlacement) -> [SIMD2<Float>] {
        let u = SIMD2(cos(placement.yaw), -sin(placement.yaw)), v = SIMD2(sin(placement.yaw), cos(placement.yaw))
        return [SIMD2<Float>(-1, -1), SIMD2(1, -1), SIMD2(1, 1), SIMD2(-1, 1)].map {
            SIMD2(placement.position.x, placement.position.z) + u * ($0.x * placement.size.x / 2) + v * ($0.y * placement.size.z / 2)
        }
    }

    private static func overlaps(_ a: LabPlacement, _ b: LabPlacement) -> Bool {
        let axes = [SIMD2(cos(a.yaw), -sin(a.yaw)), SIMD2(sin(a.yaw), cos(a.yaw)),
                    SIMD2(cos(b.yaw), -sin(b.yaw)), SIMD2(sin(b.yaw), cos(b.yaw))]
        let ac = corners(a), bc = corners(b)
        return axes.allSatisfy { axis in
            let ap = ac.map { simd_dot($0, axis) }, bp = bc.map { simd_dot($0, axis) }
            return min(ap.max()!, bp.max()!) - max(ap.min()!, bp.min()!) > 0.00001
        }
    }

    private static func crosses(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ c: SIMD2<Float>, _ d: SIMD2<Float>) -> Bool {
        func cross(_ x: SIMD2<Float>, _ y: SIMD2<Float>) -> Float { x.x * y.y - x.y * y.x }
        return cross(b - a, c - a) * cross(b - a, d - a) < -0.000001
            && cross(d - c, a - c) * cross(d - c, b - c) < -0.000001
    }

}

nonisolated struct LabProject: Sendable {
    var room: RoomStructure
    var layout: LabLayout
    var topology: LabTopology
}

nonisolated enum LabDemo {
    private static let allVLANs = [10, 20, 30, 40, 50]

    static func dataCenter() throws -> LabProject {
        let room = try virtualRoom(width: 16, depth: 12)
        let rackSize = HardwareCatalog.item("rack-r42612")!.size!
        let names = ["Red A", "Red B", "Correo", "Aplicaciones", "Web", "Backup y monitorización"]
        let rackIDs = ["rack-a", "rack-b", "rack-mail", "rack-app", "rack-web", "rack-backup"]
        var placements = (0..<6).map { index in
            LabPlacement(id: rackIDs[index], kind: .rack, title: names[index],
                         position: SIMD3(Float(index % 3 - 1) * 4, 0, index < 3 ? -3 : 3),
                         yaw: index < 3 ? .pi : 0, size: rackSize)
        }
        placements += [LabPlacement(id: "desk-a", kind: .workstation, title: "Operación A",
                                    position: SIMD3(-6.3, 0, 0), yaw: -.pi / 2, size: SIMD3(1.2, 1.25, 0.75)),
                       LabPlacement(id: "desk-b", kind: .workstation, title: "Operación B",
                                    position: SIMD3(6.3, 0, 0), yaw: .pi / 2, size: SIMD3(1.2, 1.25, 0.75))]
        let layout = LabLayout(area: 192, floorHeight: 0,
                               floorPolygon: [SIMD2(-8, -6), SIMD2(8, -6), SIMD2(8, 6), SIMD2(-8, 6)],
                               placements: placements, warnings: ["Sala virtual de ejemplo; no certifica Tier IV ni sustituye ingeniería."])
        var topology = empty("Centro de datos virtual")
        topology.notes += ["Sala sintética de 16 × 12 × 3,5 m; no existe una superficie mínima universal Tier IV.",
                           "Red A/B y energía/refrigeración A/B son conceptos educativos; no se certifican aislamiento, tolerancia a fallos ni disponibilidad.",
                           "Internet es una WAN simulada entre routers; no abre una conexión real."]
        for index in 0..<2 {
            let placement = placements[index]
            addNetworkRack(&topology, placement: placement, index: index, serverCount: 1)
            let dnsID = id(placement, "server-1")
            set(&topology, deviceID: dnsID, name: "DNS \(index == 0 ? "A" : "B")", ip: "192.168.10.\(53 + index)", vlan: 10, services: ["DNS"])
        }
        connect(&topology, "core-fiber", id(placements[0], "core"), "GigabitEthernet0/1",
                id(placements[1], "core"), "GigabitEthernet0/1", .fiber, allVLANs)
        connect(&topology, "wan-simulada", id(placements[0], "wan"), "GigabitEthernet0/1",
                id(placements[1], "wan"), "GigabitEthernet0/1", .copper, [])
        for index in 0..<2 {
            connect(&topology, "dns-path-b-\(index)", id(placements[index], "server-1"), "LOM2",
                    id(placements[1 - index], "access"), "GigabitEthernet0/2", .copper, [10])
        }
        let serviceRoles: [(String, Int, [String])] = [
            ("Correo", 30, ["SMTP", "IMAP"]), ("Aplicaciones", 20, ["Aplicaciones", "API"]),
            ("Web", 40, ["HTTP", "HTTPS"]), ("Backup", 50, ["Backup"])]
        for index in 2..<6 {
            let placement = placements[index], role = serviceRoles[index - 2]
            for path in 0..<2 {
                let accessID = id(placement, "access-\(path)")
                add(&topology, id: accessID, name: "Acceso \(placement.title) \(path == 0 ? "A" : "B")",
                    model: "switch-2960", placement: placement, height: 1.79 - Float(path) * 0.12,
                    ip: "192.168.10.\(22 + (index - 2) * 2 + path)", vlan: 10)
                connect(&topology, "uplink-\(index)-\(path)", accessID, "FastEthernet0/24",
                        id(placements[path], "core"), "FastEthernet0/\(index + 1)", .copper, allVLANs)
            }
            for server in 0..<2 {
                let serverID = id(placement, "server-\(server + 1)")
                let monitor = index == 5 && server == 1
                let vlan = monitor ? 10 : role.1
                add(&topology, id: serverID, name: monitor ? "Monitorización" : "\(role.0) \(server + 1)",
                    model: "server-c220m5", placement: placement, height: 0.77 - Float(server) * 0.18,
                    ip: "192.168.\(vlan).\(monitor ? 60 : 10 + server)", vlan: vlan,
                    services: monitor ? ["Monitorización"] : role.2)
                for path in 0..<2 {
                    connect(&topology, "server-\(index)-\(server)-\(path)", serverID, "LOM\(path + 1)",
                            id(placement, "access-\(path)"), "GigabitEthernet0/\(server + 1)", .copper, [vlan])
                }
            }
        }
        for (index, desk) in placements.filter({ $0.kind == .workstation }).enumerated() {
            addWorkstation(&topology, placement: desk, index: index, accessID: id(placements[index], "access"))
        }
        try topology.validate(layout: layout)
        return LabProject(room: room, layout: layout, topology: topology)
    }

    static func roomLab(room: RoomStructure, layout: LabLayout) throws -> LabTopology {
        guard room.units == "meters", layout.placements.count <= 8,
              layout.placements.filter({ $0.kind == .rack }).count <= 6,
              layout.placements.filter({ $0.kind == .workstation }).count <= 2 else {
            throw LabLayoutError.invalid("Laboratorio de cuarto fuera de límites (6 racks y 2 puestos).")
        }
        var topology = empty("Laboratorio del cuarto")
        let racks = layout.placements.filter { $0.kind == .rack }
        for (index, rack) in racks.enumerated() { addNetworkRack(&topology, placement: rack, index: index, serverCount: 3) }
        if racks.count > 1 {
            for index in 0..<(racks.count - 1) {
                connect(&topology, "trunk-\(index)", id(racks[index], "core"), "GigabitEthernet0/2",
                        id(racks[index + 1], "core"), "GigabitEthernet0/1", .fiber, allVLANs)
            }
        }
        for (index, desk) in layout.placements.filter({ $0.kind == .workstation }).enumerated() {
            addWorkstation(&topology, placement: desk, index: index,
                           accessID: racks.isEmpty ? nil : id(racks[index % racks.count], "access"))
        }
        try topology.validate(layout: layout)
        return topology
    }

    static func virtualRoom(width: Float, depth: Float, height: Float = 3.5) throws -> RoomStructure {
        guard [width, depth, height].allSatisfy({ $0.isFinite && $0 >= 1 && $0 <= 100 }) else {
            throw LabLayoutError.invalid("Dimensiones de sala virtual fuera de rango (1–100 m).")
        }
        let identity: [Float] = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]
        func surface(_ index: Int, kind: RoomStructure.Surface.Kind, width: Float, height: Float,
                     matrix: [Float], corners: [[Float]] = [], parentID: UUID? = nil) -> RoomStructure.Surface {
            .init(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!, kind: kind,
                  confidence: "synthetic", dimensions: [width, height, 0], transformColumnMajor: matrix,
                  polygonCorners: corners, parentID: parentID, doorIsOpen: kind == .door ? true : nil, curve: nil)
        }
        var north = identity; north[13] = height / 2; north[14] = -depth / 2
        var south = identity; south[13] = height / 2; south[14] = depth / 2
        let east: [Float] = [0, 0, -1, 0, 0, 1, 0, 0, 1, 0, 0, 0, width / 2, height / 2, 0, 1]
        var west = east; west[12] = -width / 2
        let floor: [Float] = [1, 0, 0, 0, 0, 0, -1, 0, 0, 1, 0, 0, 0, 0, 0, 1]
        let walls = [surface(1, kind: .wall, width: width, height: height, matrix: north),
                     surface(2, kind: .wall, width: width, height: height, matrix: south),
                     surface(3, kind: .wall, width: depth, height: height, matrix: east),
                     surface(4, kind: .wall, width: depth, height: height, matrix: west)]
        var door = south
        let doorHeight = min(2.2, height - 0.2), doorWidth = min(1.2, width / 3)
        door[12] = width / 2 - doorWidth; door[13] = doorHeight / 2
        return RoomStructure(roomID: UUID(), surfaces: walls + [
            surface(5, kind: .floor, width: width, height: depth, matrix: floor,
                    corners: [[-width / 2, depth / 2, 0], [width / 2, depth / 2, 0],
                              [width / 2, -depth / 2, 0], [-width / 2, -depth / 2, 0]]),
            surface(6, kind: .door, width: doorWidth, height: doorHeight, matrix: door, parentID: walls[1].id)
        ], capturedAt: Date(timeIntervalSince1970: 0), source: "Demostración virtual sintética; no es un escaneo")
    }

    private static func empty(_ name: String) -> LabTopology {
        LabTopology(name: name, devices: [], links: [], vlans: [
            .init(id: 10, name: "Gestión", subnet: "192.168.10.0/24"),
            .init(id: 20, name: "Aplicaciones", subnet: "192.168.20.0/24"),
            .init(id: 30, name: "Correo", subnet: "192.168.30.0/24"),
            .init(id: 40, name: "Web", subnet: "192.168.40.0/24"),
            .init(id: 50, name: "Backup", subnet: "192.168.50.0/24")],
            notes: ["Topología educativa visual: no ejecuta servicios, routing, STP, VLAN ni Cisco IOS.",
                    "Direcciones y roles son configuraciones de ejemplo, no valores de fábrica.",
                    "LOM1/LOM2 identifican interfaces del esquema; velocidad negociada y módulos ópticos no se simulan.",
                    "Energía y refrigeración A/B son notas conceptuales; no se inventan puertos PDU ni fuentes del rack pasivo."])
    }

    private static func id(_ placement: LabPlacement, _ role: String) -> String { placement.id + ":" + role }

    private static func addNetworkRack(_ topology: inout LabTopology, placement: LabPlacement, index: Int, serverCount: Int) {
        let suffix = String(index + 1)
        for (role, model, height, ip) in [("access", "switch-2960", Float(1.79), 20 + index),
                                         ("core", "switch-3560", 1.67, 2 + index),
                                         ("edge", "router-2911", 1.23, 100 + index),
                                         ("wan", "router-1941", 1.46, 110 + index),
                                         ("firewall", "firewall-asa5505", 1.02, 40 + index)] {
            add(&topology, id: id(placement, role), name: "\(HardwareCatalog.item(model)!.name) · \(suffix)",
                model: model, placement: placement, height: height, ip: "192.168.10.\(ip)", vlan: 10)
        }
        connect(&topology, "\(placement.id)-access-core", id(placement, "access"), "FastEthernet0/24", id(placement, "core"), "FastEthernet0/23", .copper, allVLANs)
        connect(&topology, "\(placement.id)-core-edge", id(placement, "core"), "FastEthernet0/24", id(placement, "edge"), "GigabitEthernet0/1", .copper, allVLANs)
        connect(&topology, "\(placement.id)-edge-fw", id(placement, "edge"), "GigabitEthernet0/0", id(placement, "firewall"), "Ethernet0/1", .copper, allVLANs)
        connect(&topology, "\(placement.id)-fw-wan", id(placement, "firewall"), "Ethernet0/0", id(placement, "wan"), "GigabitEthernet0/0", .copper, [])
        let roles: [(Int, [String])] = [(20, ["Aplicaciones", "DNS"]), (40, ["HTTP", "HTTPS"]), (30, ["SMTP", "IMAP"])]
        for server in 0..<serverCount {
            let serverID = id(placement, "server-\(server + 1)"), role = roles[server]
            add(&topology, id: serverID, name: "Servidor \(suffix).\(server + 1)", model: "server-c220m5",
                placement: placement, height: 0.77 - Float(server) * 0.18,
                ip: "192.168.\(role.0).\(10 + index)", vlan: role.0, services: role.1)
            connect(&topology, "\(placement.id)-server-\(server)", serverID, "LOM1",
                    id(placement, server < 2 ? "access" : "edge"),
                    server < 2 ? "GigabitEthernet0/\(server + 1)" : "GigabitEthernet0/2", .copper, [role.0])
        }
    }

    private static func addWorkstation(_ topology: inout LabTopology, placement: LabPlacement, index: Int, accessID: String?) {
        let pc = id(placement, "pc"), laptop = id(placement, "laptop"), phone = id(placement, "phone")
        let pcHeight = HardwareCatalog.item("pc-optiplex7010")!.size!.y
        add(&topology, id: pc, name: "PC-\(index + 1)", model: "pc-optiplex7010", placement: placement,
            offset: SIMD3(placement.size.x / 2 - 0.16, pcHeight / 2 + 0.015, 0), ip: "192.168.20.\(100 + index)", vlan: 20)
        add(&topology, id: laptop, name: "Laptop-\(index + 1)", model: "laptop-latitude5420", placement: placement,
            offset: SIMD3(0.37, 0.77, -0.13), ip: "192.168.20.\(120 + index)", vlan: 20)
        add(&topology, id: phone, name: "Teléfono-\(index + 1)", model: "phone-7960", placement: placement,
            offset: SIMD3(-0.47, 0.79, 0.13), ip: "192.168.10.\(80 + index)", vlan: 10, services: ["Voz (visual)"])
        connect(&topology, "\(placement.id)-pc-phone", pc, "Ethernet", phone, "PC", .copper, [20])
        if let accessID {
            let base = 1 + index * 2
            connect(&topology, "\(placement.id)-phone-switch", phone, "SW", accessID, "FastEthernet0/\(base)", .copper, [10, 20])
            connect(&topology, "\(placement.id)-laptop-switch", laptop, "Ethernet", accessID, "FastEthernet0/\(base + 1)", .copper, [20])
        }
    }

    private static func add(_ topology: inout LabTopology, id: String, name: String, model: String,
                            placement: LabPlacement, height: Float = 0, offset: SIMD3<Float>? = nil,
                            ip: String?, vlan: Int?, services: [String] = []) {
        let depths: [String: Float] = ["switch-2960": 0.30, "switch-3560": 0.30, "server-c220m5": 0.787]
        let depth = HardwareCatalog.item(model)?.size?.z ?? depths[model] ?? 0
        let center = offset ?? SIMD3(0, height, -placement.size.z / 2 + 0.07 + depth / 2)
        topology.devices.append(.init(id: id, name: name, modelID: model, placementID: placement.id,
                                      offset: center, ipv4: ip, vlan: vlan, services: services,
                                      ports: ports(model)))
    }

    private static func set(_ topology: inout LabTopology, deviceID: String, name: String, ip: String, vlan: Int, services: [String]) {
        guard let index = topology.devices.firstIndex(where: { $0.id == deviceID }) else { return }
        topology.devices[index].name = name; topology.devices[index].ipv4 = ip
        topology.devices[index].vlan = vlan; topology.devices[index].services = services
        for link in topology.links.indices where topology.links[link].fromDeviceID == deviceID || topology.links[link].toDeviceID == deviceID {
            topology.links[link].vlanIDs = [vlan]
        }
    }

    private static func connect(_ topology: inout LabTopology, _ id: String, _ source: String, _ sourcePort: String,
                                _ target: String, _ targetPort: String, _ medium: LabTopology.Medium, _ vlans: [Int]) {
        topology.links.append(.init(id: id, fromDeviceID: source, fromPort: sourcePort,
                                    toDeviceID: target, toPort: targetPort, medium: medium, vlanIDs: vlans))
    }

    static func ports(_ model: String) -> [String] {
        switch model {
        case "switch-2960", "switch-3560": return (1...24).map { "FastEthernet0/\($0)" } + ["GigabitEthernet0/1", "GigabitEthernet0/2"]
        case "router-1941": return ["GigabitEthernet0/0", "GigabitEthernet0/1", "Console"]
        case "router-2911": return ["GigabitEthernet0/0", "GigabitEthernet0/1", "GigabitEthernet0/2", "Console"]
        case "firewall-asa5505": return (0...7).map { "Ethernet0/\($0)" }
        case "server-c220m5": return ["LOM1", "LOM2"]
        case "phone-7960": return ["SW", "PC"]
        case "pc-optiplex7010", "laptop-latitude5420": return ["Ethernet"]
        default: return []
        }
    }
}
