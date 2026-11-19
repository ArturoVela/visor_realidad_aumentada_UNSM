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
        var siteHosts: [String]? = nil
        var shutdownPorts: Set<String>? = nil
    }

    enum Medium: String, Codable, Sendable {
        case copper, fiber, console, powerA, powerB

        var title: String {
            switch self {
            case .copper: "Ethernet de cobre"
            case .fiber: "Fibra óptica"
            case .console: "Consola"
            case .powerA: "Alimentación A"
            case .powerB: "Alimentación B"
            }
        }

        var cableRadius: Float { self == .fiber ? 0.0025 : 0.0035 }
    }

    struct Link: Identifiable, Codable, Sendable, Equatable {
        var id: String
        var fromDeviceID: String
        var fromPort: String
        var toDeviceID: String
        var toPort: String
        var medium: Medium
        var vlanIDs: [Int]
        var circuitID: String? = nil
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
    var operationsProfile: String? = nil

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
                  (HardwareCatalog.item(device.modelID) != nil || device.modelID == "ups-9px"), device.modelID != "rack-r42612",
                  device.offset.x.isFinite, device.offset.y.isFinite, device.offset.z.isFinite,
                  (0..<3).allSatisfy({ abs(device.offset[$0]) <= 100 }),
                  device.services.count <= 32, device.services.allSatisfy({ !$0.isEmpty && $0.count <= 120 }),
                  Set(device.ports).count == device.ports.count, device.ports.count <= 128,
                  device.ports.allSatisfy({ available.contains($0) }),
                  device.shutdownPorts?.isSubset(of: Set(device.ports)) ?? true,
                  (device.siteHosts?.count ?? 0) <= LabSite.all.count,
                  device.siteHosts?.allSatisfy({ LabSite.byHost[$0] != nil }) ?? true,
                  device.ipv4 == nil || Self.ipv4(device.ipv4!) != nil,
                  device.vlan == nil || vlans.contains(where: { $0.id == device.vlan }),
                  device.sourceModel == nil || device.sourceModel!.count <= 256,
                  device.sourcePortNames == nil || (device.sourcePortNames!.count <= 128 && device.sourcePortNames!.allSatisfy({ available.contains($0.key) && !$0.value.isEmpty && $0.value.count <= 128 })),
                  device.configuration == nil || device.configuration!.utf8.count <= 65536 else {
                throw LabLayoutError.invalid("Equipo, dirección o puertos inválidos: \(device.name).")
            }
        }
        let assignedHosts = devices.flatMap { $0.siteHosts ?? [] }
        guard Set(assignedHosts).count == assignedHosts.count else {
            throw LabLayoutError.invalid("Un dominio está asignado a más de un equipo.")
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
                throw LabLayoutError.invalid("La alimentación A/B pertenece al plano de infraestructura, fuera de la topología Ethernet.")
            }
        }
        let circuits = Dictionary(grouping: links.compactMap { link in link.circuitID.map { (id: $0, link: link) } }, by: \.id)
        for (id, entries) in circuits {
            let segments = entries.map(\.link)
            guard (2...3).contains(segments.count), let first = segments.first, first.id == id,
                  segments.allSatisfy({ $0.medium == first.medium && $0.vlanIDs == first.vlanIDs }),
                  zip(segments, segments.dropFirst()).allSatisfy({ a, b in
                      a.toDeviceID == b.fromDeviceID && byID[a.toDeviceID]?.modelID.hasPrefix("patch-") == true
                          && a.toPort.first != b.fromPort.first && a.toPort.dropFirst() == b.fromPort.dropFirst()
                  }) else { throw LabLayoutError.invalid("Circuito de patch panel inválido: \(id).") }
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
        if modelID == "patch-fiber" { return .fiber }
        if port == "Console" { return .console }
        if modelID == "switch-3560" && port.hasPrefix("GigabitEthernet") { return .fiber }
        return .copper
    }

    func circuit(for link: Link) -> [Link] {
        guard let id = link.circuitID else { return [link] }
        return links.filter { $0.circuitID == id }
    }

    func switchedPath(from source: String, to destination: String, vlan: Int,
                      toGateway: Bool = false, poweredOff: Set<String> = []) -> [Device]? {
        struct Hop: Hashable {
            let device: String
            var entry: String? = nil
        }
        let inventory = Dictionary(uniqueKeysWithValues: devices.filter {
            !poweredOff.contains($0.id) && !poweredOff.contains($0.placementID)
        }.map { ($0.id, $0) })
        guard inventory[source]?.vlan == vlan, let endpoint = inventory[destination],
              toGateway || endpoint.vlan == vlan else { return nil }
        var queue = [[Hop(device: source)]]
        var visited = Set(queue[0])
        var index = 0
        while index < queue.count {
            let path = queue[index]
            index += 1
            guard let hop = path.last, let device = inventory[hop.device] else { continue }
            if hop.device == destination { return path.compactMap { inventory[$0.device] } }
            let pairedPort = hop.entry.map { ($0.hasPrefix("F") ? "R" : "F") + $0.dropFirst() }
            guard hop.device == source || device.modelID.hasPrefix("switch-") || pairedPort != nil else { continue }
            for link in links where link.vlanIDs.contains(vlan)
                && inventory[link.fromDeviceID] != nil && inventory[link.toDeviceID] != nil
                && inventory[link.fromDeviceID]?.shutdownPorts?.contains(link.fromPort) != true
                && inventory[link.toDeviceID]?.shutdownPorts?.contains(link.toPort) != true {
                let next: String, ingress: String, egress: String
                if link.fromDeviceID == hop.device {
                    (next, ingress, egress) = (link.toDeviceID, link.toPort, link.fromPort)
                } else if link.toDeviceID == hop.device {
                    (next, ingress, egress) = (link.fromDeviceID, link.fromPort, link.toPort)
                } else { continue }
                guard pairedPort == nil || pairedPort == egress else { continue }
                let candidate = Hop(device: next, entry: inventory[next]?.modelID.hasPrefix("patch-") == true ? ingress : nil)
                if visited.insert(candidate).inserted { queue.append(path + [candidate]) }
            }
        }
        return nil
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
    var isHomeLab = false
}

nonisolated enum LabDemo {
    private static let allVLANs = [10, 20, 30, 40, 50]
    static let labServerID = "rack-app:server-1"

    static func dataCenter(in captured: (room: RoomStructure, layout: LabLayout)? = nil) throws -> LabProject {
        let room = try captured?.room ?? virtualRoom(width: 16, depth: 12)
        let template = try captured.map { try TierFacility.fit(room: $0.room, layout: $0.layout) }
            ?? TierFacility(origin: .zero, yaw: 0, height: 3.5)
        let rackSize = HardwareCatalog.item("rack-r42612")!.size!
        let names = ["Red y DNS A", "Red y DNS B", "Almacenamiento", "SaaS y laboratorio", "Publicación web", "Respaldo y vídeo"]
        let rackIDs = ["rack-a", "rack-b", "rack-mail", "rack-app", "rack-web", "rack-backup"]
        var placements = (0..<6).map { index in
            LabPlacement(id: rackIDs[index], kind: .rack, title: names[index],
                         position: SIMD3(Float(index % 3 - 1) * 3.7, 0, index < 3 ? -2.1 : 0.95),
                         yaw: index < 3 ? .pi : 0, size: rackSize)
        }
        placements += (1...3).map { index in
            LabPlacement(id: "desk-\(index)", kind: .workstation, title: ["Operaciones", "Seguridad y vídeo", "Laboratorio aislado"][index - 1],
                         position: SIMD3(Float(index - 2) * 2.15, 0, 4.05), yaw: .pi, size: SIMD3(1.2, 1.25, 0.75))
        }
        placements = placements.map(template.place)
        let layout = LabLayout(area: captured?.layout.area ?? 192, floorHeight: template.origin.y,
                               floorPolygon: captured?.layout.floorPolygon ?? [SIMD2(-8, -6), SIMD2(8, -6), SIMD2(8, 6), SIMD2(-8, 6)],
                               placements: placements, warnings: ["Plantilla de referencia Tier IV · carga y sitio por validar."],
                               facility: template)
        var topology = empty("Sala de servidores · referencia Tier IV")
        topology.operationsProfile = "tier"
        topology.vlans[2] = .init(id: 30, name: "Almacenamiento", subnet: "192.168.30.0/24")
        topology.vlans[4] = .init(id: 50, name: "Copias", subnet: "192.168.50.0/24")
        topology.vlans += [
            .init(id: 60, name: "Videovigilancia", subnet: "192.168.66.0/24"),
            .init(id: 70, name: "Laboratorio aislado", subnet: "192.168.67.0/24")
        ]
        topology.notes.removeLast()
        topology.notes += ["La planta de ejemplo mide 16 × 12 × 3,5 m; su superficie no es un requisito Tier IV.",
                           "El visor muestra distribución A/B. Autonomía, aislamiento constructivo y refrigeración continua requieren pruebas físicas.",
                           "Los dominios de velaarturo.com están asignados en el plano. El laboratorio aislado y la publicación tienen VLAN independientes.",
                           "Redundancia NAS, respaldos y acceso privado tienen fichas de operación. Herramientas ejecutables en Tools/Operations."]
        for index in 0..<2 {
            let placement = placements[index]
            addNetworkRack(&topology, placement: placement, index: index, serverCount: 1)
            let suffix = index == 0 ? "A" : "B"
            let border = id(placement, "firewall")
            let segmentation = id(placement, "firewall-seg")
            if let slot = topology.devices.firstIndex(where: { $0.id == border }) {
                topology.devices[slot].modelID = "server-firewall"
                topology.devices[slot].ports = ports("server-firewall")
                topology.devices[slot].offset = RackMount.center("server-firewall", rackDepth: placement.size.z, slot: 20)
            }
            set(&topology, deviceID: border, name: "FW-BORDE-" + suffix, ip: "192.168.10.\(40 + index)", vlan: 10,
                services: ["Firewall perimetral", "Tránsito exterior", "Estado HA"])
            configure(&topology, deviceID: border, detail: "Par de borde A/B. P0 tránsito externo, P1 tránsito a router de borde, P2 estado HA. Entrada por defecto bloqueada.")
            add(&topology, id: segmentation, name: "FW-SEGMENTACIÓN-" + suffix, model: "server-firewall",
                placement: placement, offset: RackMount.center("server-firewall", rackDepth: placement.size.z, slot: 27),
                ip: "192.168.10.\(44 + index)", vlan: 10, services: ["Política entre VLAN", "DMZ", "Estado HA"])
            configure(&topology, deviceID: segmentation, detail: "Par interno A/B. P0 tránsito al router de borde, P1 enlace etiquetado al núcleo, P2 estado HA. Controla accesos de publicación, vídeo, copias y laboratorio aislado.")
            for link in topology.links.indices {
                switch topology.links[link].id {
                case "\(placement.id)-core-edge":
                    topology.links[link].toDeviceID = segmentation
                    topology.links[link].toPort = "P1"
                case "\(placement.id)-edge-fw":
                    topology.links[link].toPort = "P1"
                    topology.links[link].vlanIDs = allVLANs
                case "\(placement.id)-fw-wan":
                    topology.links[link].fromPort = "P0"
                    topology.links[link].vlanIDs = []
                default: break
                }
            }
            connect(&topology, "fw-seg-edge-\(suffix)", segmentation, "P0", id(placement, "edge"), "GigabitEthernet0/1", .copper, allVLANs)
            let dnsID = id(placement, "server-1")
            set(&topology, deviceID: dnsID, name: "DNS \(index == 0 ? "A" : "B")", ip: "192.168.10.\(53 + index)", vlan: 10, services: ["DNS"])
        }
        for role in ["firewall", "firewall-seg"] {
            connect(&topology, role + "-ha", id(placements[0], role), "P2", id(placements[1], role), "P2", .copper, [])
        }
        connect(&topology, "core-fiber", id(placements[0], "core"), "GigabitEthernet0/1",
                id(placements[1], "core"), "GigabitEthernet0/1", .fiber, allVLANs)
        connect(&topology, "wan-simulada", id(placements[0], "wan"), "GigabitEthernet0/1",
                id(placements[1], "wan"), "GigabitEthernet0/1", .copper, [])
        for index in 0..<2 {
            connect(&topology, "dns-path-b-\(index)", id(placements[index], "server-1"), "LOM2",
                    id(placements[1 - index], "access"), "GigabitEthernet0/2", .copper, [10])
        }
        let serviceRoles: [[(String, Int, [String])]] = [
            [("NAS-PRINCIPAL", 30, LabSite.nasServices), ("NAS-RÉPLICA", 30, ["ZFS RAIDZ2", "Replicación ZFS", "Instantáneas"])],
            [("SAAS-VELAARTURO", 20, ["Aplicaciones SaaS", "HTTPS", "Base de datos"]) ,
             ("IA-LOCAL", 20, ["Ollama", "Inferencia local", "VLAN de aplicaciones"])],
            [("WEB-VELAARTURO", 40, ["HTTPS", "Portafolio y herramientas web"]),
             ("APPS-PERSONALES", 40, ["Aplicaciones personales", "HTTPS"])],
            [("PBS-PRINCIPAL", 50, ["Proxmox Backup Server", "Verificación", "Retención"]),
             ("OBSERVABILIDAD", 10, ["Métricas", "Alertas", "Estado de servicios"])]
        ]
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
                let service = role[server]
                let vlan = service.1
                add(&topology, id: serverID, name: service.0, model: "server-c220m5",
                    placement: placement, height: 0.77 - Float(server) * 0.18,
                    ip: "192.168.\(vlan).\(vlan == 10 ? 60 : 10 + server)", vlan: vlan, services: service.2)
                for path in 0..<2 {
                    connect(&topology, "server-\(index)-\(server)-\(path)", serverID, "LOM\(path + 1)",
                            id(placement, "access-\(path)"), "GigabitEthernet0/\(server + 1)", .copper, [vlan])
                }
            }
        }
        assignSites(&topology, to: labServerID, groups: [.saas])
        assignSites(&topology, to: "rack-web:server-1", groups: [.main, .publicApps])
        assignSites(&topology, to: "rack-web:server-2", groups: [.personal])
        configure(&topology, deviceID: "rack-mail:server-1",
                  detail: "ZFS RAIDZ2. Comparticiones SMB/NFS: \(LabSite.shares.joined(separator: ", ")). Privado con ACL individual. Programa la réplica y verifica una copia externa.")
        let additions: [[(String, String, Int, [String], String)]] = [
            [("proxy-a", "PROXY-INVERSO-A", 40, ["Reverse proxy", "TLS", "Rutas por dominio"], "Conserva cabecera Host y registro de auditoría. Orígenes limitados a las VLAN autorizadas."),
             ("filter-a", "DNS-FILTRO-A", 10, ["DNS recursivo", "Bloqueos DNS", "Registros locales"], "Resolución local y listas de bloqueo. TTL y excepciones por grupo de clientes.")],
            [("proxy-b", "PROXY-INVERSO-B", 40, ["Reverse proxy", "TLS", "Rutas por dominio"], "Segundo proxy con configuración versionada."),
             ("filter-b", "DNS-FILTRO-B", 10, ["DNS recursivo", "Bloqueos DNS"], "DNS alterno. Replica zonas locales y políticas de bloqueo.")],
            [("media", "BIBLIOTECA-MULTIMEDIA", 30, ["Jellyfin", "Películas", "Biblioteca multimedia"], "Monta Películas en lectura. Conserva metadatos y copias fuera de la biblioteca."),
             ("archive", "ARCHIVO-INSTITUCIONAL", 30, ["Datos", "Trabajos", "Universidad"], "Grupos de acceso, directorios separados e instantáneas por conjunto de datos.")],
            [("sandbox", "LAB-AISLADO", 70, ["Instancias desechables", "CI", "Validación de cambios"], "VLAN 70. Sin rutas directas al NAS privado o a la bóveda. Limita salida y automatiza limpieza de entornos."),
             ("database", "DATOS-SAAS", 20, ["PostgreSQL", "Copias y recuperación"], "Acceso de aplicación por VLAN 20. Mantén roles separados y prueba restauración periódicamente.")],
            [("vault", "BÓVEDA-DE-CONTRASEÑAS", 10, ["Vaultwarden", "Bóveda privada", "MFA"], "HTTPS en red de gestión. Custodia de secretos fuera del visor. Respaldo cifrado y recuperación ensayada."),
             ("build", "PUBLICACIÓN-CONTINUA", 40, ["Artefactos estáticos", "Registro de publicaciones"], "Publica a los servidores web mediante cuentas de servicio con permisos acotados.")],
            [("nvr", "NVR-SEGURIDAD", 60, ["RTSP", "Grabación continua", "Retención por cámara"], "VLAN 60. Captura con credenciales locales a cada cámara y escribe segmentos en almacenamiento dedicado."),
             ("pbs-replica", "PBS-RÉPLICA", 50, ["Copias externas", "Verificación de integridad"], "Replica al destino de recuperación y comprueba archivos. Define retención con el administrador.")]
        ]
        for (index, roles) in additions.enumerated() {
            for (extra, role) in roles.enumerated() {
                let rack = placements[index], device = id(rack, role.0)
                let subnet = [60: 66, 70: 67][role.2] ?? role.2
                let slot = extra == 0 ? 18 : 23
                add(&topology, id: device, name: role.1, model: "server-c220m5", placement: rack,
                    offset: RackMount.center("server-c220m5", rackDepth: rack.size.z, slot: slot),
                    ip: "192.168.\(subnet).\(70 + 2 * index + extra)", vlan: role.2, services: role.3)
                configure(&topology, deviceID: device, detail: role.4)
                for path in 0..<2 {
                    let access = index < 2 ? id(placements[path], "access") : id(rack, "access-\(path)")
                    let port = index < 2 ? 8 + 2 * index + extra : 8 + extra
                    connect(&topology, "\(device)-\(path)", device, "LOM\(path + 1)", access,
                            "FastEthernet0/\(port)", .copper, [role.2])
                }
            }
        }
        for index in topology.links.indices where topology.links[index].vlanIDs == allVLANs {
            topology.links[index].vlanIDs += [60, 70]
        }
        for (index, desk) in placements.filter({ $0.kind == .workstation }).enumerated() {
            let pc = id(desk, "pc")
            let tower = HardwareCatalog.renderSize("pc-optiplex7010")
            add(&topology, id: pc, name: ["PC-OPERACIONES", "PC-SEGURIDAD", "PC-LAB"][index], model: "pc-optiplex7010", placement: desk,
                offset: SIMD3(0.44, tower.y / 2 + 0.015, 0.06), ip: "192.168.20.\(101 + index)", vlan: 20,
                services: index == 0 ? ["Consola de operación"] : index == 1 ? ["Operación de vídeo"] : ["Validación de servicios"])
            let access = id(placements[index % 2], "access")
            connect(&topology, "test-pc-\(index + 1)", pc, "Ethernet", access, "FastEthernet0/\(index + 1)", .copper, [20])
        }
        add(&topology, id: "tier-admin-laptop", name: "LAPTOP-ADMIN-TIER", model: "laptop-latitude5420", placement: placements[6],
            offset: SIMD3(0.34, 0.77, -0.13), ip: "192.168.10.121", vlan: 10, services: ["Consola de administración"])
        connect(&topology, "tier-admin", "tier-admin-laptop", "Ethernet", id(placements[0], "access"), "FastEthernet0/14", .copper, [10])
        try patch(&topology, layout: layout)
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
        try patch(&topology, layout: layout)
        try topology.validate(layout: layout)
        return topology
    }

    static let homeName = "HomeLab Proxmox"

    static func homeLab(in captured: (room: RoomStructure, layout: LabLayout)? = nil) throws -> LabProject {
        let room = try captured?.room ?? virtualRoom(width: 5.6, depth: 4.8, height: 2.6)
        let polygon = captured?.layout.floorPolygon ?? [SIMD2(-2.8, -2.4), SIMD2(2.8, -2.4), SIMD2(2.8, 2.4), SIMD2(-2.8, 2.4)]
        let floor = captured?.layout.floorHeight ?? 0
        let rack = LabPlacement(id: "home-rack", kind: .rack, title: "HOME-R01", position: .zero,
                                yaw: 0, size: SIMD3(0.60, 0.95, 1.02))
        let desks = [Float(-1.48), 1.48].enumerated().map { index, x in
            LabPlacement(id: "home-desk-\(index + 1)", kind: .workstation,
                         title: index == 0 ? "Puesto de administración" : "Estación de servicios",
                         position: SIMD3(x, 0, 1.25), yaw: 0, size: SIMD3(1.12, 1.25, 0.7))
        }
        let arrangement = [rack] + desks
        let placements = if captured != nil {
            try fitHome(arrangement, room: room, polygon: polygon, floor: floor)
        } else { arrangement }
        let layout = LabLayout(area: captured?.layout.area ?? 26.88, floorHeight: floor,
                               floorPolygon: polygon, placements: placements, warnings: [])
        var topology = LabTopology(name: homeName, devices: [], links: [], vlans: [
            .init(id: 10, name: "Gestión", subnet: "192.168.60.0/24"),
            .init(id: 20, name: "Servicios", subnet: "192.168.61.0/24"),
            .init(id: 30, name: "Clientes", subnet: "192.168.62.0/24"),
            .init(id: 40, name: "Almacenamiento", subnet: "192.168.63.0/24"),
            .init(id: 50, name: "Domótica", subnet: "192.168.64.0/24"),
            .init(id: 60, name: "Vídeo", subnet: "192.168.65.0/24")
        ], notes: [
            "Rack HOME-R01 · 18 U · 600 × 950 × 1.020 mm. Mantén un pasillo libre delante y detrás.",
            "Dominios de velaarturo.com, automatizaciones locales, DNS con bloqueos y grabación RTSP. Operación en Tools/Operations.",
            "Cat 6 en azul. Selecciona un tramo para seguir el canal desde el switch, por el panel, hasta el equipo."
        ], operationsProfile: "home")
        func mount(_ id: String, _ name: String, _ model: String, _ slot: Int,
                   _ ip: String?, _ vlan: Int?, _ services: [String], _ configuration: String) {
            add(&topology, id: id, name: name, model: model, placement: placements[0],
                offset: RackMount.center(model, rackDepth: rack.size.z, slot: slot), ip: ip, vlan: vlan, services: services)
            topology.devices[topology.devices.count - 1].configuration = "U\(slot + 1)\n" + configuration
        }
        mount("home-switch", "SW-HOME", "switch-2960", 15, "192.168.60.2", 10, ["802.1Q", "Gestión"],
              "Gi0/1 → PVE-01 · VLAN 10 sin etiqueta, 20 y 40 etiquetadas.\nGi0/2 → GW-HOME · VLAN 10, 20, 30, 40, 50 y 60 etiquetadas.\nFa0/1 → PC-ADMIN · VLAN 10.\nFa0/2 → PC-SERVICIOS · VLAN 30.\nFa0/3 → NAS-01 · VLAN 40.\nFa0/4–9 → laptop, copias, NVR, servidor web y las dos Pi.\nFa0/10 → AP-HOME · VLAN 10, 30 y 50.\nFa0/11 → CAM-ACCESO · VLAN 60.")
        mount("home-gw", "GW-HOME", "router-2911", 11, "192.168.60.1", 10, ["Gateway 802.1Q", "Políticas entre VLAN"],
              "Gi0/1 ↔ SW-HOME. Subinterfaces con gateway .1 por VLAN. Reglas de salida por VLAN. Autoriza DNS al PI-DNS y HTTPS al proxy. Limita IoT y vídeo a sus servicios locales. Impide acceso directo a Gestión y Almacenamiento.")
        mount("home-pve", "PVE-01", "server-c220m5", 7, "192.168.60.10", 10,
              ["Proxmox VE · TCP 8006", "Sitios web y herramientas", "Copias de VM"],
              "LOM1 ↔ SW-HOME Gi0/1. Bridge vmbr0 VLAN-aware.\nVM de publicación Debian · VLAN 20 · 192.168.61.20. El proxy publica los sitios asignados por HTTPS. El hipervisor se administra por la VLAN 10.")
        mount("home-nas", "NAS-01", "server-c220m5", 5, "192.168.63.10", 40,
              ["ZFS espejo"] + LabSite.nasServices.filter { $0 != "ZFS RAIDZ2" },
              "Espejo ZFS de dos discos. Carpetas separadas; Privado con ACL individual. Copias fuera del rack.")
        mount("home-backup", "BACKUP-HOME", "server-c220m5", 3, "192.168.63.20", 40, ["Copias", "Verificación", "Restauración"],
              "Segundo destino físico. Comprueba cada copia con SHA-256 y prueba restauración en una carpeta nueva.")
        mount("home-nvr", "NVR-HOME", "server-c220m5", 9, "192.168.65.20", 60, ["Grabación RTSP", "Videovigilancia"],
              "VLAN 60. Las cámaras se registran en el grabador desde la red local.")
        mount("home-web", "VELAARTURO-SERVICIOS", "server-c220m5", 13, "192.168.61.21", 20,
              ["Proxy inverso", "Vaultwarden", "IA local · Ollama", "Sitios HTTPS"],
              "VMs separadas para proxy, bóveda e inferencia. Limita acceso a bóveda y API de IA a redes autorizadas.")
        mount("home-pi-dns", "PI-DNS", "raspberry-pi5", 8, "192.168.60.53", 10, ["Pi-hole", "DNS local", "Bloqueos"],
              "Raspberry Pi 5 en bandeja 1 U. DNS, resolución local y listas de bloqueo con excepciones administradas.")
        mount("home-pi-automation", "PI-DOMÓTICA", "raspberry-pi5", 10, "192.168.64.10", 50,
              ["Home Assistant", "MQTT", "Automatizaciones"],
              "Raspberry Pi 5 en bandeja ventilada con SSD y adaptador Zigbee por USB. Home Assistant OS y Mosquitto. Movimiento → luz al anochecer; humedad → ventilador con histéresis; fuga → aviso local. Prueba sensores y añade sus IDs en las automatizaciones.")
        assignSites(&topology, to: "home-pve", groups: [.main, .publicApps])
        assignSites(&topology, to: "home-web", groups: [.personal, .saas])
        mount("home-ups", "UPS-01", "ups-9px", 0, nil, nil, ["Batería", "Apagado ordenado"],
              "Montar en la parte baja. Dimensionar según carga real y configurar apagado del host mediante el sistema de gestión del UPS.")
        connect(&topology, "home-pve-trunk", "home-switch", "GigabitEthernet0/1", "home-pve", "LOM1", .copper, [10, 20, 40])
        connect(&topology, "home-gw-trunk", "home-switch", "GigabitEthernet0/2", "home-gw", "GigabitEthernet0/1", .copper, [10, 20, 30, 40, 50, 60])
        connect(&topology, "home-nas-link", "home-switch", "FastEthernet0/3", "home-nas", "LOM1", .copper, [40])
        for (index, desk) in placements.dropFirst().enumerated() {
            let pc = desk.id + ":pc", vlan = index == 0 ? 10 : 30
            add(&topology, id: pc, name: index == 0 ? "PC-ADMIN" : "PC-SERVICIOS", model: "pc-optiplex7010", placement: desk,
                offset: SIMD3(0.37, 0.195, 0), ip: index == 0 ? "192.168.60.101" : "192.168.62.101", vlan: vlan,
                services: index == 0 ? ["Consola de administración", "Proxmox VE"] : ["Panel de servicios", "Acceso a NAS y sitios"])
            connect(&topology, "home-pc-\(index + 1)", "home-switch", "FastEthernet0/\(index + 1)", pc, "Ethernet", .copper, [vlan])
        }
        add(&topology, id: "home-admin-laptop", name: "LAPTOP-ADMIN-HOME", model: "laptop-latitude5420", placement: placements[1],
            offset: SIMD3(0.34, 0.77, -0.13), ip: "192.168.60.121", vlan: 10, services: ["Consola de administración"])
        connect(&topology, "home-admin-laptop", "home-switch", "FastEthernet0/4", "home-admin-laptop", "Ethernet", .copper, [10])
        for (index, device) in [("home-backup", 40), ("home-nvr", 60), ("home-web", 20), ("home-pi-dns", 10), ("home-pi-automation", 50)].enumerated() {
            let port = device.0.hasPrefix("home-pi") ? "Ethernet" : "LOM1"
            connect(&topology, device.0 + "-link", "home-switch", "FastEthernet0/\(index + 5)",
                    device.0, port, .copper, [device.1])
        }
        add(&topology, id: "home-ap", name: "AP-HOME", model: "access-point", placement: placements[2],
            offset: SIMD3(0.36, 0.746, -0.17), ip: "192.168.60.5", vlan: 10,
            services: ["Wi-Fi clientes", "Wi-Fi IoT", "SSID por VLAN"])
        configure(&topology, deviceID: "home-ap",
                  detail: "SSID Casa → VLAN 30. SSID Casa-IoT → VLAN 50. Gestión en VLAN 10. Aislamiento entre clientes IoT; permite sólo los servicios locales necesarios.")
        connect(&topology, "home-ap-trunk", "home-switch", "FastEthernet0/10", "home-ap", "Ethernet", .copper, [10, 30, 50])
        add(&topology, id: "home-camera", name: "CAM-ACCESO", model: "camera-ip", placement: placements[2],
            offset: SIMD3(-0.43, 0.803, -0.17), ip: "192.168.65.31", vlan: 60,
            services: ["Cámara IP", "RTSP", "Grabación en NVR-HOME"])
        configure(&topology, deviceID: "home-camera",
                  detail: "Fa0/11 → VLAN 60. Alimentación externa compatible. NVR-HOME usa RTSP con cuenta dedicada. Montaje de sobremesa de referencia; valida distancia, campo de visión y ubicación final.")
        connect(&topology, "home-camera-link", "home-switch", "FastEthernet0/11", "home-camera", "Ethernet", .copper, [60])
        try patch(&topology, layout: layout)
        try topology.validate(layout: layout)
        return LabProject(room: room, layout: layout, topology: topology, isHomeLab: true)
    }

    private static func fitHome(_ placements: [LabPlacement], room: RoomStructure,
                                polygon: [SIMD2<Float>], floor: Float) throws -> [LabPlacement] {
        let height = try room.surfaces.filter { $0.kind == .wall }.map {
            try LabGeometry.matrix($0).columns.3.y + $0.dimensions[1] / 2 - floor
        }.min() ?? 0
        guard height >= 2.1 else {
            throw LabLayoutError.invalid("La distribución necesita 2,1 m de altura medida para paso y bandeja de red.")
        }
        let edges = zip(polygon, polygon.dropFirst() + polygon.prefix(1)).map { $1 - $0 }
        if let edge = edges.max(by: { simd_length_squared($0) < simd_length_squared($1) }) {
            let center = polygon.reduce(.zero, +) / Float(polygon.count)
            let base = atan2(-edge.y, edge.x)
            let opening = [SIMD3<Float>(-2.16, 0, -1.40), SIMD3(2.16, 0, -1.40),
                           SIMD3(2.16, 0, 2), SIMD3(-2.16, 0, 2)]
            for turn in 0..<4 {
                let yaw = base + Float(turn) * .pi / 2
                let rotation = simd_quatf(angle: yaw, axis: SIMD3<Float>(0, 1, 0))
                for z: Float in [0, -0.30, 0.30, -0.60, 0.60] {
                    let offset = rotation.act(SIMD3(0, 0, z))
                    let origin = SIMD3(center.x + offset.x, floor, center.y + offset.z)
                    let corners = opening.map { origin + rotation.act($0) }.map { SIMD2($0.x, $0.z) }
                    guard corners.indices.allSatisfy({
                        LabGeometry.traySpanFits(from: corners[$0], to: corners[($0 + 1) % 4], within: polygon)
                    }) else { continue }
                    return placements.map {
                        LabPlacement(id: $0.id, kind: $0.kind, title: $0.title,
                                     position: origin + rotation.act($0.position), yaw: yaw + $0.yaw, size: $0.size)
                    }
                }
            }
        }
        throw LabLayoutError.invalid("Reserva una zona libre de 4,32 × 3,4 m para el rack y los dos puestos. También puedes elegir su posición en AR.")
    }

    private static func patch(_ topology: inout LabTopology, layout: LabLayout) throws {
        let racks = Dictionary(uniqueKeysWithValues: layout.placements.filter { $0.kind == .rack }.map { ($0.id, $0) })
        let devices = Dictionary(uniqueKeysWithValues: topology.devices.map { ($0.id, $0) })
        let original = topology.links
        var counts: [String: Int] = [:]
        topology.links = []
        func pair(at rack: LabPlacement, medium: LabTopology.Medium) throws -> (String, String, String) {
            let model = medium == .fiber ? "patch-fiber" : "patch-copper"
            let id = rack.id + ":" + model
            let index = counts[id, default: 0] + 1
            if index == 1 {
                let busy = Set(topology.devices.filter { $0.placementID == rack.id }.flatMap {
                    let slot = RackMount.slot($0.modelID, near: $0.offset.y)
                    return slot..<(slot + RackMount.units($0.modelID))
                })
                guard let slot = (0..<RackMount.capacity(height: rack.size.y)).reversed().first(where: { !busy.contains($0) }) else {
                    throw LabLayoutError.invalid("Falta 1 U libre para un patch panel en \(rack.title).")
                }
                let name = medium == .fiber ? "PP-LC" : "PP-CAT6"
                add(&topology, id: id, name: "\(name) · \(rack.title)", model: model, placement: rack,
                    offset: RackMount.center(model, rackDepth: rack.size.z, slot: slot), ip: nil, vlan: nil)
            }
            guard index <= ports(model).count / 2 else { throw LabLayoutError.invalid("Patch panel sin puertos libres.") }
            counts[id] = index
            let suffix = String(format: "%02d", index)
            return (id, "F" + suffix, "R" + suffix)
        }
        for link in original {
            let a = devices[link.fromDeviceID].flatMap { racks[$0.placementID] }
            let b = devices[link.toDeviceID].flatMap { racks[$0.placementID] }
            guard let rack = a ?? b, link.medium == .copper || link.medium == .fiber else {
                topology.links.append(link)
                continue
            }
            let (panel, front, rear) = try pair(at: rack, medium: link.medium)
            var segments: [(String, String, String, String)] = []
            if let a, let b, a.id != b.id {
                let (other, otherFront, otherRear) = try pair(at: b, medium: link.medium)
                segments = [(link.fromDeviceID, link.fromPort, panel, front), (panel, rear, other, otherRear),
                            (other, otherFront, link.toDeviceID, link.toPort)]
            } else {
                let frontFirst = a != nil && (b == nil || devices[link.fromDeviceID]?.modelID.hasPrefix("switch-") == true)
                segments = [(link.fromDeviceID, link.fromPort, panel, frontFirst ? front : rear),
                            (panel, frontFirst ? rear : front, link.toDeviceID, link.toPort)]
            }
            for (index, (from, fromPort, to, toPort)) in segments.enumerated() {
                topology.links.append(.init(id: index == 0 ? link.id : "\(link.id).p\(index + 1)",
                                            fromDeviceID: from, fromPort: fromPort, toDeviceID: to, toPort: toPort,
                                            medium: link.medium, vlanIDs: link.vlanIDs, circuitID: link.id))
            }
        }
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
            add(&topology, id: id(placement, role), name: "\(["access": "SW-ACCESO", "core": "SW-CORE", "edge": "RTR-EDGE", "wan": "RTR-WAN", "firewall": "FW"][role]!)–\(suffix)",
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
        let center = offset ?? RackMount.center(model, rackDepth: placement.size.z, slot: RackMount.slot(model, near: height))
        topology.devices.append(.init(id: id, name: name, modelID: model, placementID: placement.id,
                                      offset: center, ipv4: ip, vlan: vlan, services: services,
                                      ports: ports(model)))
    }

    private static func configure(_ topology: inout LabTopology, deviceID: String, detail: String) {
        if let index = topology.devices.firstIndex(where: { $0.id == deviceID }) {
            topology.devices[index].configuration = detail
        }
    }

    private static func assignSites(_ topology: inout LabTopology, to id: String, groups: Set<LabSite.Group>) {
        if let index = topology.devices.firstIndex(where: { $0.id == id }) {
            topology.devices[index].siteHosts = LabSite.all.filter { groups.contains($0.group) }.map(\.host)
        }
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
        case "patch-copper", "patch-fiber":
            return (1...(model == "patch-copper" ? 24 : 12)).flatMap {
                let suffix = String(format: "%02d", $0)
                return ["F" + suffix, "R" + suffix]
            }
        case "switch-2960", "switch-3560": return (1...24).map { "FastEthernet0/\($0)" } + ["GigabitEthernet0/1", "GigabitEthernet0/2"]
        case "router-1941": return ["GigabitEthernet0/0", "GigabitEthernet0/1", "Console"]
        case "router-2911": return ["GigabitEthernet0/0", "GigabitEthernet0/1", "GigabitEthernet0/2", "Console"]
        case "firewall-asa5505": return (0...7).map { "Ethernet0/\($0)" }
        case "server-c220m5": return ["LOM1", "LOM2"]
        case "server-firewall": return ["P0", "P1", "P2"]
        case "phone-7960": return ["SW", "PC"]
        case "pc-optiplex7010", "laptop-latitude5420", "raspberry-pi5", "access-point", "camera-ip": return ["Ethernet"]
        default: return []
        }
    }
}

nonisolated enum LabFocusMode: String, CaseIterable, Identifiable {
    case aim = "Por mira"
    case nearby = "Por proximidad"
    var id: Self { self }
}

nonisolated struct LabFocusTarget: Identifiable, Equatable {
    let id: String
    let name: String
    let placementID: String
    let center: SIMD3<Float>
    let yaw: Float
    let size: SIMD3<Float>

    static func inventory(_ topology: LabTopology?, in layout: LabLayout) -> [Self] {
        guard let topology else { return [] }
        return layout.placements.flatMap { placement in
            let rotation = simd_quatf(angle: placement.yaw, axis: SIMD3(0, 1, 0))
            return topology.devices.filter { $0.placementID == placement.id }
                .sorted { $0.offset.y == $1.offset.y ? $0.id < $1.id : $0.offset.y > $1.offset.y }
                .map { device in
                    Self(id: device.id, name: device.name, placementID: placement.id,
                         center: placement.position + rotation.act(device.offset),
                         yaw: placement.yaw, size: HardwareCatalog.renderSize(device.modelID))
                }
        }
    }

    static func pick(_ mode: LabFocusMode, from origin: SIMD3<Float>, direction: SIMD3<Float>,
                     in targets: [Self], maximumDistance: Float? = nil) -> Self? {
        guard mode != .aim || simd_length_squared(direction) > 0.00001 else { return nil }
        let ray = mode == .aim ? simd_normalize(direction) : .zero
        var best: Self?
        var depth = maximumDistance ?? (mode == .aim ? Float(8) : 3)
        for target in targets {
            let local = simd_quatf(angle: -target.yaw, axis: SIMD3(0, 1, 0))
            let relative = local.act(origin - target.center)
            let distance: Float?
            if mode == .aim {
                distance = target.hitDistance(from: relative, direction: local.act(ray), upTo: depth)
            } else {
                distance = simd_length(simd_max(simd_abs(relative) - target.size / 2, .zero))
            }
            if let distance, distance < depth {
                best = target
                depth = distance
            }
        }
        return best
    }

    var frontNormal: SIMD3<Float> { SIMD3(-sin(yaw), 0, -cos(yaw)) }

    func framingPoint(in layout: LabLayout) -> SIMD3<Float> {
        var point = center + frontNormal * (size.z / 2)
        if let rack = layout.placements.first(where: { $0.id == placementID && $0.kind == .rack }) {
            point.y = (center.y + rack.position.y + rack.size.y * 0.5) / 2
        }
        return point
    }

    func face(toward observer: SIMD3<Float>) -> SIMD3<Float> {
        let depthAxis = SIMD3(sin(yaw), 0, cos(yaw))
        let sign: Float = simd_dot(observer - center, depthAxis) < 0 ? -1 : 1
        return center + depthAxis * (sign * size.z / 2)
    }

    private func hitDistance(from start: SIMD3<Float>, direction: SIMD3<Float>, upTo limit: Float) -> Float? {
        // Small tolerance around the face makes narrow rack units easier to acquire.
        let half = size / 2 + SIMD3<Float>(0.014, 0.006, 0.009)
        var near: Float = 0, far = limit
        for axis in 0..<3 {
            let component = direction[axis]
            if abs(component) < 0.00001 {
                guard abs(start[axis]) <= half[axis] else { return nil }
                continue
            }
            let a = (-half[axis] - start[axis]) / component
            let b = (half[axis] - start[axis]) / component
            near = max(near, min(a, b))
            far = min(far, max(a, b))
            guard near <= far else { return nil }
        }
        return near
    }

    static func step(_ delta: Int, after id: String, in targets: [Self]) -> Self? {
        guard let index = targets.firstIndex(where: { $0.id == id }), !targets.isEmpty else { return nil }
        let count = targets.count
        return targets[(index + delta % count + count) % count]
    }
}


nonisolated struct LabScenePort: Equatable, Sendable {
    let deviceID: String
    let name: String
    let point: SIMD3<Float>
    let normal: SIMD3<Float>

    static func local(_ device: LabTopology.Device, _ name: String) throws -> LabScenePort {
        guard device.ports.contains(name), let index = LabDemo.ports(device.modelID).firstIndex(of: name) else {
            throw LabLayoutError.invalid("Puerto \(name) ausente en \(device.name).")
        }
        let size = HardwareCatalog.renderSize(device.modelID), w = size.x, h = size.y, d = size.z
        var point = SIMD3<Float>(0, 0, d / 2 + 0.004), normal = SIMD3<Float>(0, 0, 1)
        if name.lowercased().contains("console") {
            point.x = w / 2 - 0.025
        } else {
            switch device.modelID {
            case "patch-copper", "patch-fiber":
                let count = LabDemo.ports(device.modelID).count / 2
                point.x = (Float(index / 2) - Float(count - 1) / 2) * (w - 0.045) / Float(count)
                normal.z = index.isMultiple(of: 2) ? -1 : 1
                point.z = normal.z * (d / 2 + 0.006)
                point.y = -0.004
            case "switch-2960", "switch-3560":
                normal = SIMD3(0, 0, -1)
                point.z = -d / 2 - 0.004
                if index < 24 { point.x = -w / 2 + 0.045 + Float(index % 12) * 0.023; point.y = -0.009 + Float(index / 12) * 0.018 }
                else { point.x = w / 2 - 0.055 + Float(index - 24) * 0.024 }
            case "router-1941", "router-2911", "firewall-asa5505": point.x = -w / 2 + 0.027 + Float(index) * 0.021
            case "server-c220m5", "server-firewall": point.x = -0.04 + Float(index) * 0.024
            case "raspberry-pi5": point.x = w * 0.26; point.y = 0.002
            case "access-point", "camera-ip": point.y = -h * 0.12
            case "pc-optiplex7010": point.y = h * 0.2
            case "laptop-latitude5420": point = SIMD3(w / 2 + 0.004, 0, d * 0.2); normal = SIMD3(1, 0, 0)
            case "phone-7960": point.x = -0.017 + Float(index) * 0.034; point.y = -h * 0.15
            default: throw LabLayoutError.invalid("Modelo sin anclaje de puerto visual: \(device.modelID).")
            }
        }
        return LabScenePort(deviceID: device.id, name: name, point: point, normal: normal)
    }

    static func world(_ device: LabTopology.Device, _ name: String, in layout: LabLayout) throws -> Self {
        guard let placement = layout.placements.first(where: { $0.id == device.placementID }) else {
            throw LabLayoutError.invalid("Equipo sin rack o puesto: \(device.name).")
        }
        let port = try local(device, name)
        let rotation = simd_quatf(angle: placement.yaw, axis: SIMD3(0, 1, 0))
        return Self(deviceID: device.id, name: name,
                    point: placement.position + rotation.act(device.offset + port.point),
                    normal: rotation.act(port.normal))
    }
}

nonisolated struct LabInspectionDestination: Equatable {
    let deviceID: String
    var port: String? = nil
    var linkID: String? = nil

    func spot(in topology: LabTopology, layout: LabLayout, observer: SIMD3<Float>) -> (point: SIMD3<Float>, normal: SIMD3<Float>)? {
        guard let device = topology.devices.first(where: { $0.id == deviceID }),
              let placement = layout.placements.first(where: { $0.id == device.placementID }) else { return nil }
        if let port, let location = try? LabScenePort.world(device, port, in: layout) {
            return (location.point, location.normal)
        }
        let front = SIMD3<Float>(-sin(placement.yaw), 0, -cos(placement.yaw))
        let center = placement.position + simd_quatf(angle: placement.yaw, axis: SIMD3(0, 1, 0)).act(device.offset)
        let size = HardwareCatalog.renderSize(device.modelID)
        let outward = simd_dot(observer - center, front) < 0 ? -front : front
        return (center + outward * (size.z / 2), outward)
    }
}

nonisolated struct LabSite: Identifiable, Sendable {
    enum Group: String, CaseIterable, Sendable {
        case main = "Principal", publicApps = "Herramientas públicas", personal = "Personal", saas = "SaaS"
    }

    let host: String
    let group: Group
    var id: String { host }
    var url: URL? { URL(string: "https://" + host + (host == "sphere.velaarturo.com" ? "/#/library" : "")) }

    static let shares = ["Backups", "Películas", "Datos", "Trabajos", "Universidad", "Privado"]
    static let nasServices = ["ZFS RAIDZ2", "SMB/NFS"] + shares

    static let all: [Self] = {
        func sites(_ hosts: String, group: Group) -> [Self] {
            hosts.split(separator: " ").map { LabSite(host: $0 + ".velaarturo.com", group: group) }
        }
        return [LabSite(host: "velaarturo.com", group: .main)]
            + sites("torneo divide textos color cotiza cuando foto pdf qr horas llevamos ruleta explora cafetero formularios un-ramito hub cv", group: .publicApps)
            + sites("brain status store crm dash docs updates blog support pizarra prompt sphere", group: .personal)
            + [LabSite(host: "taller.vealarturo.com", group: .personal)]
            + sites("finanzas ventas agua agro bc tarjetas", group: .saas)
    }()
    static let byHost = Dictionary(uniqueKeysWithValues: all.map { ($0.host, $0) })
}

/// Changes belong to the plan. Keep them keyed by stable device ID when the layout is regenerated.
nonisolated struct LabOperationsOverrides: Codable, Equatable, Sendable {
    var names: [String: String] = [:]
    var addresses: [String: String] = [:]
    var ports: [String: Set<String>] = [:]
    var routes: [String: String] = [:]

    init() {}

    init(_ plan: LabTopology, against base: LabTopology) {
        let originals = Dictionary(uniqueKeysWithValues: base.devices.map { ($0.id, $0) })
        let originalRoutes = base.siteRoutes
        for device in plan.devices {
            guard let original = originals[device.id] else { continue }
            if device.name != original.name { names[device.id] = device.name }
            if device.ipv4 != original.ipv4 { addresses[device.id] = device.ipv4 }
            if device.shutdownPorts != original.shutdownPorts { ports[device.id] = device.shutdownPorts ?? [] }
        }
        routes = plan.siteRoutes.filter { originalRoutes[$0.key] != $0.value }
    }

    func apply(to base: LabTopology) -> LabTopology {
        guard self != Self() else { return base }
        var plan = base
        for i in plan.devices.indices {
            let id = plan.devices[i].id
            if let name = names[id] { plan.devices[i].name = name }
            if let address = addresses[id] { plan.devices[i].ipv4 = address }
            if let disabled = ports[id] { plan.devices[i].shutdownPorts = disabled.intersection(plan.devices[i].ports) }
        }
        for (host, id) in routes { plan.assign(host: host, to: id) }
        return (try? plan.validate()) == nil ? base : plan
    }
}

nonisolated extension LabTopology {
    var siteRoutes: [String: String] {
        devices.reduce(into: [:]) { routes, item in
            for host in item.siteHosts ?? [] { routes[host] = item.id }
        }
    }

    mutating func assign(host: String, to id: String) {
        guard LabSite.byHost[host] != nil,
              let target = devices.firstIndex(where: { $0.id == id && $0.modelID == "server-c220m5" }),
              siteRoutes[host] != id else { return }
        for i in devices.indices { devices[i].siteHosts?.removeAll { $0 == host } }
        devices[target].siteHosts = ((devices[target].siteHosts ?? []) + [host]).sorted()
    }

    func permitsAddress(_ address: String, for device: Device) -> Bool {
        guard let number = Self.ipv4(address), let vlan = device.vlan,
              !devices.contains(where: { $0.id != device.id && $0.ipv4 == address }),
              let subnet = vlans.first(where: { $0.id == vlan })?.subnet else { return false }
        let fields = subnet.split(separator: "/")
        guard fields.count == 2, let network = Self.ipv4(String(fields[0])),
              let prefix = Int(fields[1]), (0...32).contains(prefix) else { return false }
        let mask = prefix == 0 ? 0 : UInt32.max << (32 - prefix)
        return number & mask == network && (prefix >= 31 || (number != network && number != (network | ~mask)))
    }
}

nonisolated struct LabOperationsSession: Sendable {
    let stationID: String
    var targetID: String
    var port: String?

    static let help = """
    show devices · inventario y direcciones
    connect <equipo> · elegir por ID, nombre o IP
    show interfaces · estado y cableado
    show services · servicios y dominios
    show running-config · ficha del equipo
    show vlans · redes del plano
    resolve <dominio> · DNS del plano
    test <equipo> <puerto TCP> · política y camino entre VLAN
    interface <puerto> · elegir interfaz
    shutdown / no shutdown · cambiar estado
    hostname <nombre> · renombrar equipo
    ip address <IPv4> · asignar IP en su VLAN
    site move <dominio> <servidor> · cambiar destino
    ping <equipo> · trazar camino desde el equipo actual en su VLAN
    """

    mutating func execute(_ line: String, on plan: inout LabTopology,
                          poweredOff: Set<String> = []) -> String {
        let words = line.split(whereSeparator: \.isWhitespace).map(String.init)
        let command = words.map { $0.lowercased() }
        guard let verb = command.first else { return "" }
        guard let index = plan.devices.firstIndex(where: { $0.id == targetID }) else { return "Equipo no disponible." }
        let device = plan.devices[index]
        func find(_ text: String) -> LabTopology.Device? {
            let matches = plan.devices.filter { [$0.id, $0.name, $0.ipv4 ?? ""].contains { $0.caseInsensitiveCompare(text) == .orderedSame } }
            return matches.count == 1 ? matches.first : nil
        }
        func isDown(_ device: LabTopology.Device) -> Bool {
            poweredOff.contains(device.id) || poweredOff.contains(device.placementID)
        }
        switch command {
        case ["help"], ["?"]: return Self.help
        case ["show", "devices"]:
            return plan.devices.filter { !$0.modelID.hasPrefix("patch-") }.map {
                "\($0.id) · \($0.name) · \($0.ipv4 ?? "Sin IPv4")"
            }.joined(separator: "\n")
        case ["show", "vlans"]:
            return plan.vlans.map { "\($0.id) · \($0.name) · \($0.subnet)" }.joined(separator: "\n")
        case ["show", "services"]:
            let services = device.services + (device.siteHosts ?? [])
            return services.isEmpty ? "Sin servicios asignados." : services.joined(separator: "\n")
        case ["show", "interfaces"]:
            guard !device.ports.isEmpty else { return "Equipo sin interfaces de red." }
            return device.ports.map { port in
                let link = plan.links.first {
                    ($0.fromDeviceID == device.id && $0.fromPort == port) || ($0.toDeviceID == device.id && $0.toPort == port)
                }
                if device.shutdownPorts?.contains(port) == true { return "\(port) · Deshabilitado" }
                guard let link else { return "\(port) · Sin cable" }
                let circuit = plan.circuit(for: link)
                let available = circuit.allSatisfy { cable in
                    [(cable.fromDeviceID, cable.fromPort), (cable.toDeviceID, cable.toPort)].allSatisfy { endpoint in
                        guard let item = plan.devices.first(where: { $0.id == endpoint.0 }) else { return false }
                        return !isDown(item) && item.shutdownPorts?.contains(endpoint.1) != true
                    }
                }
                return "\(port) · \(available ? "Enlace activo" : "Enlace caído") · \(link.circuitID ?? link.id)"
            }.joined(separator: "\n")
        case ["show", "running-config"]:
            return (["hostname \(device.name)", "IPv4 \(device.ipv4 ?? "Sin dirección")", "VLAN \(device.vlan.map(String.init) ?? "—")"]
                    + (device.shutdownPorts ?? []).sorted().map { "\($0): shutdown" }
                    + [device.configuration].compactMap { $0 }).joined(separator: "\n")
        case ["shutdown"], ["no", "shutdown"]:
            guard let port else { return "Elige un puerto con interface <puerto>." }
            var disabled = device.shutdownPorts ?? []
            if verb == "no" { disabled.remove(port) } else { disabled.insert(port) }
            plan.devices[index].shutdownPorts = disabled.isEmpty ? nil : disabled
            return "\(port) · \(disabled.contains(port) ? "Deshabilitado" : "Habilitado")"
        default: break
        }

        let argument = words.dropFirst().joined(separator: " ")
        switch verb {
        case "connect":
            guard let next = find(argument) else { return "Equipo desconocido o ambiguo. Usa show devices." }
            targetID = next.id
            port = nil
            return "Consola del plano · \(next.name)"
        case "interface":
            guard let match = device.ports.first(where: { $0.caseInsensitiveCompare(argument) == .orderedSame }) else {
                return "Puerto desconocido. Usa show interfaces."
            }
            port = match
            return "Interfaz seleccionada · \(match)"
        case "hostname":
            guard !argument.isEmpty, argument.count <= 63,
                  argument.allSatisfy({ $0.isLetter || $0.isNumber || "-_".contains($0) }),
                  !plan.devices.contains(where: { $0.id != device.id && $0.name.caseInsensitiveCompare(argument) == .orderedSame })
            else { return "Usa un nombre único, de hasta 63 caracteres, con letras, números, guion o guion bajo." }
            plan.devices[index].name = argument
            return "Nombre guardado · \(argument)"
        case "ip" where command.count == 3 && command[1] == "address":
            guard plan.permitsAddress(words[2], for: device) else { return "Usa una IPv4 libre de la subred de este equipo." }
            plan.devices[index].ipv4 = words[2]
            return "IPv4 guardada · \(words[2])"
        case "site" where command.count >= 4 && command[1] == "move":
            let host = command[2]
            guard plan.siteRoutes[host] != nil else { return "Dominio desconocido en este plano." }
            guard let server = find(words.dropFirst(3).joined(separator: " ")), server.modelID == "server-c220m5" else {
                return "Indica el ID o nombre de un servidor del inventario."
            }
            plan.assign(host: host, to: server.id)
            return "\(host) → \(server.name) · Asignación del plano"
        case "resolve":
            let dnsName = argument.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return plan.resolveSimulatedDNS(dnsName, from: device, poweredOff: poweredOff)
        case "test" where command.count >= 3:
            guard let last = command.last, let tcp = Int(last), (1...65535).contains(tcp),
                  let endpoint = find(words.dropFirst().dropLast().joined(separator: " ")) else {
                return "Usa test <equipo> <puerto TCP del plano>."
            }
            return plan.testNetwork(from: device, to: endpoint, tcp: tcp, poweredOff: poweredOff)
        case "ping":
            guard let endpoint = find(argument), let vlan = device.vlan, endpoint.vlan == vlan else {
                return "El diagnóstico requiere dos equipos de la misma VLAN."
            }
            let allowed = plan.links.filter { link in
                ![link.fromDeviceID, link.toDeviceID].contains { id in
                    plan.devices.first(where: { $0.id == id }).map(isDown) ?? true
                }
            }
            var activePlan = plan
            activePlan.links = allowed
            guard !isDown(device), !isDown(endpoint),
                  let route = activePlan.switchedPath(from: device.id, to: endpoint.id, vlan: vlan) else {
                return "VLAN \(vlan) · Sin camino habilitado."
            }
            return "VLAN \(vlan) · Camino del plano\n" + route.map(\.name).joined(separator: " → ")
        default:
            return "Comando desconocido. Usa help."
        }
    }
}

nonisolated extension LabWalkPose {
    func framing(_ target: LabFocusTarget, in layout: LabLayout) -> Self {
        let front = target.frontNormal
        let aim = target.framingPoint(in: layout)
        guard let rack = layout.placements.first(where: { $0.id == target.placementID }), rack.kind == .rack else {
            return inspecting(aim, fromSide: front, in: layout)
        }
        let rotation = simd_quatf(angle: rack.yaw, axis: SIMD3<Float>(0, 1, 0))
        let rackFront = rack.position + front * (rack.size.z / 2)
        for distance: Float in [1.59, 1.47, 1.32, 1.14, 0.91] {
            for side: Float in [0, -0.25, 0.25, -0.48, 0.48] {
                let eye = rackFront + front * distance + rotation.act(SIMD3(side, 1.48, 0))
                let origin = SIMD2(eye.x, eye.z), destination = SIMD2(aim.x, aim.z)
                guard Self.permits(origin, in: layout),
                      LabGeometry.traySpanFits(from: origin, to: destination, within: layout.floorPolygon),
                      (1..<10).allSatisfy({ step in
                          Self.permits(origin + (SIMD2(rackFront.x, rackFront.z) - origin) * (Float(step) / 12),
                                       in: layout)
                      }) else { continue }
                return Self(position: eye, yaw: yaw).aimed(at: aim)
            }
        }
        return inspecting(aim, fromSide: front, in: layout)
    }

}

nonisolated struct LabCablePlan: Sendable {
    struct Segment: Sendable {
        let link: LabTopology.Link
        let endpoints: [LabScenePort]
        let points: [SIMD3<Float>]
        let pickingPath: [SIMD3<Float>]
        let bendRadius: Float
        var length: Float { zip(points, points.dropFirst()).reduce(0) { $0 + simd_distance($1.0, $1.1) } }
    }

    struct Upright: Sendable {
        let size: SIMD3<Float>
        let center: SIMD3<Float>
        let yaw: Float
    }

    var segments: [Segment] = []
    var trays: [(start: SIMD3<Float>, end: SIMD3<Float>)] = []
    var uprights: [Upright] = []

    static func make(_ topology: LabTopology, room: RoomStructure, layout: LabLayout) throws -> Self {
        var result = Self()
        func addTray(from start: SIMD3<Float>, to end: SIMD3<Float>) {
            result.trays.append((start, end))
        }
        var trayPairs = Set<[String]>()
        var risers = Set<String>()
        var trayDrops = Set<String>()
        var trunkSpans: [ClosedRange<Float>] = []
        let floor = layout.floorPolygon
        let edges = zip(floor, floor.dropFirst() + floor.prefix(1)).map { $1 - $0 }
        let longEdge = edges.max { simd_length_squared($0) < simd_length_squared($1) } ?? SIMD2<Float>(1, 0)
        let along = longEdge / max(simd_length(longEdge), 0.0001)
        let across = SIMD2(-along.y, along.x)
        let widths = floor.map { simd_dot($0, across) }
        let centerLine = ((widths.min() ?? 0) + (widths.max() ?? 0)) / 2
        func trunkPoint(_ longitudinal: Float) -> SIMD2<Float> { along * longitudinal + across * centerLine }
        let ceiling = room.surfaces.filter { $0.kind == .wall }.map {
            $0.transformColumnMajor[13] + $0.dimensions[1] / 2
        }.min() ?? layout.floorHeight
        let tallest = layout.placements.map { $0.position.y + $0.size.y }.max() ?? ceiling
        let trayHeight = min(ceiling - 0.035, max(ceiling - 0.14, tallest + 0.055))
        func putOnTray(_ p: SIMD2<Float>) -> SIMD3<Float> { SIMD3(p.x, trayHeight, p.y) }
        for (index, link) in topology.links.enumerated() {
            // Electrical A/B remains metadata until actual PDUs and PSU inputs are catalogued.
            if link.medium == .powerA || link.medium == .powerB { continue }
            guard let from = topology.devices.first(where: { $0.id == link.fromDeviceID }),
                  let to = topology.devices.first(where: { $0.id == link.toDeviceID }) else {
                throw LabLayoutError.invalid("Conexión \(link.id) con equipo inexistente.")
            }
            let a = try LabScenePort.world(from, link.fromPort, in: layout), b = try LabScenePort.world(to, link.toPort, in: layout)
            guard let pa = layout.placements.first(where: { $0.id == from.placementID }),
                  let pb = layout.placements.first(where: { $0.id == to.placementID }) else {
                throw LabLayoutError.invalid("No se encontró soporte físico para cablear.")
            }
            // For two front ports in the same rack, patch through the front guide.
            let front = simd_quatf(angle: pa.yaw, axis: SIMD3(0, 1, 0)).act(SIMD3<Float>(0, 0, -1))
            let frontPatch = pa.id == pb.id && pa.kind == .rack &&
                simd_dot(a.normal, front) > 0.99 && simd_dot(b.normal, front) > 0.99
            let branchA = cableBranch(a, through: pa, lane: index % 4, medium: link.medium, frontPatch: frontPatch)
            let branchB = cableBranch(b, through: pb, lane: index % 4, medium: link.medium, frontPatch: frontPatch)
            var points = branchA
            if pa.id != pb.id {
                let exitA = trayExit(pa, height: trayHeight), exitB = trayExit(pb, height: trayHeight)
                guard trayHeight > tallest + 0.018 else { continue }
                let start = SIMD2(exitA.x, exitA.z), end = SIMD2(exitB.x, exitB.z)
                let laneA = simd_dot(start, along), laneB = simd_dot(end, along)
                let junctionA = trunkPoint(laneA), junctionB = trunkPoint(laneB)
                let trunkRoute = [start, junctionA, junctionB, end]
                let followsTrunk = zip(trunkRoute, trunkRoute.dropFirst()).allSatisfy { a, b in
                    simd_distance(a, b) < 0.0001 || LabGeometry.traySpanFits(from: a, to: b, within: floor)
                }
                let tray: [SIMD3<Float>]
                if followsTrunk {
                    tray = trunkRoute.map(putOnTray)
                    trunkSpans.append(min(laneA, laneB)...max(laneA, laneB))
                    if trayDrops.insert(pa.id).inserted { addTray(from: tray[0], to: tray[1]) }
                    if trayDrops.insert(pb.id).inserted { addTray(from: tray[2], to: tray[3]) }
                } else {
                    guard let path = LabGeometry.trayPath(from: start, to: end, within: floor) else { continue }
                    tray = path.map(putOnTray)
                    if trayPairs.insert([pa.id, pb.id].sorted()).inserted {
                        for (a, b) in zip(tray, tray.dropFirst()) { addTray(from: a, to: b) }
                    }
                }
                let branchEndA = branchA[branchA.count - 1], branchEndB = branchB[branchB.count - 1]
                let riserA = SIMD3(branchEndA.x, trayHeight, branchEndA.z)
                let riserB = SIMD3(branchEndB.x, trayHeight, branchEndB.z)
                let separation = SIMD3<Float>(0, Float(index % 4) * 0.004 - 0.006, 0)
                points += ([riserA] + tray + [riserB]).map { $0 + separation }
                for (placement, exit) in [(pa, exitA), (pb, exitB)] {
                    if risers.insert(placement.id).inserted {
                        let rotation = simd_quatf(angle: placement.yaw, axis: SIMD3(0, 1, 0))
                        let rack = placement.kind == .rack
                        let sides: [Float] = rack ? [-0.274, 0.274] : [0]
                        let top = placement.position.y + (rack ? placement.size.y : 0.04)
                        let span = rotation.act(SIMD3<Float>(0.29, 0, 0))
                        if rack { addTray(from: exit - span, to: exit + span) }
                        for side in sides where trayHeight > top {
                            let shift = rotation.act(SIMD3(side, 0, 0.023))
                            result.uprights.append(.init(size: SIMD3(0.05, trayHeight - top, 0.024),
                                                         center: exit + shift + SIMD3(0, (top - trayHeight) / 2, 0),
                                                         yaw: placement.yaw))
                        }
                    }
                }
            }
            points += branchB.reversed()
            let bendRadius: Float = link.medium == .fiber ? 0.040 : 0.032
            guard let rounded = LabGeometry.cableBends(points, radius: bendRadius),
                  let pickingPath = LabGeometry.cableBends(points, radius: bendRadius, segmentsPerBend: 2) else { continue }
            result.segments.append(.init(link: link, endpoints: [a, b], points: rounded,
                                          pickingPath: pickingPath, bendRadius: bendRadius))
        }
        var mergedSpans: [ClosedRange<Float>] = []
        for span in trunkSpans.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = mergedSpans.last, span.lowerBound <= last.upperBound + 0.001 {
                mergedSpans[mergedSpans.count - 1] = last.lowerBound...max(last.upperBound, span.upperBound)
            } else { mergedSpans.append(span) }
        }
        for span in mergedSpans {
            addTray(from: putOnTray(trunkPoint(span.lowerBound)), to: putOnTray(trunkPoint(span.upperBound)))
        }
        return result
    }

    private static func cableBranch(_ port: LabScenePort, through placement: LabPlacement, lane: Int,
                             medium: LabTopology.Medium, frontPatch: Bool) -> [SIMD3<Float>] {
        let rotation = simd_quatf(angle: placement.yaw, axis: SIMD3(0, 1, 0))
        let stub = port.point + port.normal * 0.080
        let p = rotation.inverse.act(stub - placement.position)
        func world(_ x: Float, _ y: Float, _ z: Float) -> SIMD3<Float> {
            placement.position + rotation.act(SIMD3(x, y, z))
        }
        if placement.kind == .rack {
            let x: Float = (medium == .fiber ? -1 : 1) * (0.267 + Float(lane) * 0.003)
            let z = placement.size.z / 2 - 0.016
            if frontPatch { return [port.point, stub, world(x, p.y, p.z)] }
            return [port.point, stub, world(x, p.y, p.z), world(x, p.y, z)]
        }
        let rear = placement.size.z / 2 + 0.026
        return [port.point, stub, world(p.x, p.y, rear), world(0, p.y, rear)]
    }

    private static func trayExit(_ placement: LabPlacement, height: Float) -> SIMD3<Float> {
        let z = placement.size.z / 2 + (placement.kind == .rack ? -0.016 : 0.026)
        let position = placement.position + simd_quatf(angle: placement.yaw, axis: SIMD3(0, 1, 0)).act(SIMD3(0, 0, z))
        return SIMD3(position.x, height, position.z)
    }


    func csv(for topology: LabTopology) -> String {
        let names = Dictionary(uniqueKeysWithValues: topology.devices.map { ($0.id, $0.name) })
        let paths = Dictionary(uniqueKeysWithValues: segments.map { ($0.link.id, $0) })
        let locale = Locale(identifier: "en_US_POSIX")
        let header = "Etiqueta,Circuito,Equipo A,Puerto A,Equipo B,Puerto B,Medio,VLAN,Longitud simulada (m),Radio modelo (mm),Trazado"
        let rows = topology.links.map { link in
            let path = paths[link.id]
            return [link.id, link.circuitID ?? link.id, names[link.fromDeviceID] ?? link.fromDeviceID, link.fromPort,
                    names[link.toDeviceID] ?? link.toDeviceID, link.toPort, link.medium.title,
                    link.vlanIDs.map(String.init).joined(separator: " "),
                    path.map { String(format: "%.3f", locale: locale, $0.length) } ?? "",
                    path.map { String(format: "%.0f", locale: locale, $0.bendRadius * 1000) } ?? "",
                    path == nil ? "Sin recorrido válido" : "Simulado"].map { value in
                let safe = value.first.map { "=+-@".contains($0) } == true ? "'" + value : value
                return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            }.joined(separator: ",")
        }
        return ([header] + rows).joined(separator: "\r\n") + "\r\n"
    }
}

nonisolated extension LabTopology {
    func testNetwork(from source: Device, to endpoint: Device, tcp: Int, poweredOff: Set<String>) -> String {
        guard let a = source.vlan, let b = endpoint.vlan else { return "Simulación · Extremo sin VLAN." }
        if a == b {
            let route = switchedPath(from: source.id, to: endpoint.id, vlan: a, poweredOff: poweredOff)
            return route.map { "Simulación · Enlace local\n" + $0.map(\.name).joined(separator: " → ") }
                ?? "Simulación · VLAN \(a) sin camino."
        }
        let dns = tcp == 53 && endpoint.services.contains(where: { $0.localizedCaseInsensitiveContains("dns") })
        let tier = operationsProfile == "tier"
        let allowed = tier
            ? (a == 10 && [22, 443, 8006].contains(tcp)) || (a == 20 && b == 40 && tcp == 443) || (a != 70 && dns)
            : (a == 10 && [22, 443, 8006].contains(tcp)) || (a == 30 && b == 20 && tcp == 443) || (a != 60 && dns)
        guard allowed else { return "Simulación · Bloqueado por política VLAN \(a) → \(b) · TCP \(tcp)." }
        guard let route = gatewayRoute(from: source, to: endpoint, poweredOff: poweredOff) else {
            return "Simulación · Política permite TCP \(tcp). Camino interrumpido."
        }
        return "Simulación · Permitido · TCP \(tcp)\n" + route.map(\.name).joined(separator: " → ")
    }

    func resolveSimulatedDNS(_ name: String, from source: Device, poweredOff: Set<String>) -> String {
        let tier = operationsProfile == "tier"
        let ids = tier ? ["rack-a:filter-a", "rack-b:filter-b"] : ["home-pi-dns"]
        guard let vlan = source.vlan, (tier ? vlan != 70 : vlan != 60) else {
            return "DNS simulado · Política impide consultar desde esta VLAN."
        }
        let resolver = ids.compactMap { id in devices.first { $0.id == id } }.first { server in
            if server.vlan == vlan {
                return switchedPath(from: source.id, to: server.id, vlan: vlan, poweredOff: poweredOff) != nil
            }
            return gatewayRoute(from: source, to: server, poweredOff: poweredOff) != nil
        }
        guard let resolver else { return "DNS simulado · Sin respuesta." }
        guard let id = siteRoutes[name], let address = devices.first(where: { $0.id == id })?.ipv4 else {
            return "DNS simulado · NXDOMAIN · \(resolver.name)"
        }
        return "DNS simulado · \(name) → \(address) · \(resolver.name)"
    }

    private func gatewayRoute(from source: Device, to endpoint: Device, poweredOff: Set<String>) -> [Device]? {
        guard let a = source.vlan, let b = endpoint.vlan else { return nil }
        let gateways = operationsProfile == "tier" ? ["rack-a:firewall-seg", "rack-b:firewall-seg"] : ["home-gw"]
        for id in gateways {
            guard let incoming = switchedPath(from: source.id, to: id, vlan: a, toGateway: true, poweredOff: poweredOff),
                  let outgoing = switchedPath(from: endpoint.id, to: id, vlan: b, toGateway: true, poweredOff: poweredOff) else { continue }
            return incoming + Array(outgoing.dropLast().reversed())
        }
        return nil
    }
}

nonisolated struct LabMonitorConfiguration: Codable, Equatable {
    enum Panel: String, Codable, CaseIterable {
        case status = "Estado", network = "Red", services = "Servicios"

        var metrics: [Metric] {
            switch self {
            case .status: [.cpu, .memory]
            case .network: [.receive, .transmit]
            case .services: []
            }
        }
    }

    enum Chart: String, Codable, CaseIterable {
        case automatic = "Automático", rings = "Anillos", columns = "Columnas"
    }

    enum Metric: String {
        case cpu = "CPU", memory = "Memoria", receive = "Recepción", transmit = "Envío"

        var maximum: Double { self == .receive || self == .transmit ? 65 : 100 }
        var unit: String { self == .receive || self == .transmit ? "Mb/s" : "%" }

        func value(in sample: LabServerSample) -> Double {
            switch self {
            case .cpu: sample.cpu
            case .memory: sample.memory
            case .receive: sample.receiveMbps
            case .transmit: sample.transmitMbps
            }
        }

        func formatted(_ value: Double) -> String {
            value.formatted(.number.precision(.fractionLength(1))) + " " + unit
        }
    }

    var panel: Panel = .status
    var chart: Chart = .automatic
    var usesRings: Bool { chart == .rings || (chart == .automatic && panel == .status) }
}

nonisolated struct LabServerSample {
    static let interval: TimeInterval = 2

    enum State: String {
        case available = "En servicio", offline = "Equipo apagado", isolated = "Sin enlace"
    }

    let state: State
    let timestamp: Date
    let cpu: Double
    let memory: Double
    let receiveMbps: Double
    let transmitMbps: Double

    /// Deterministic by host and interval so every dashboard agrees on a reading.
    init(device: LabTopology.Device, topology: LabTopology, poweredOff: Set<String>, timestamp: Date = .now) {
        let power = !poweredOff.contains(device.id) && !poweredOff.contains(device.placementID)
        let linked = power && topology.links.contains { link in
            let port: String
            if link.fromDeviceID == device.id { port = link.fromPort }
            else if link.toDeviceID == device.id { port = link.toPort }
            else { return false }
            if device.modelID == "server-firewall", port == "P2" { return false }
            return topology.circuit(for: link).allSatisfy { segment in
                [(segment.fromDeviceID, segment.fromPort), (segment.toDeviceID, segment.toPort)].allSatisfy { id, port in
                    guard let endpoint = topology.devices.first(where: { $0.id == id }) else { return false }
                    return !poweredOff.contains(id) && !poweredOff.contains(endpoint.placementID)
                        && endpoint.shutdownPorts?.contains(port) != true
                }
            }
        }
        state = !power ? .offline : linked ? .available : .isolated
        self.timestamp = timestamp
        let seed = Double(device.id.utf8.enumerated().reduce(0) { $0 + ($1.offset % 31 + 1) * Int($1.element) })
        let tick = floor(timestamp.timeIntervalSince1970 / Self.interval)
        let rhythm = (sin(tick * 0.23 + seed) + 1) / 2
        let wave = (cos(tick * 0.16 + seed * 0.12) + 1) / 2
        cpu = power ? 9 + seed.truncatingRemainder(dividingBy: 19) + rhythm * 29 : 0
        memory = power ? 25 + seed.truncatingRemainder(dividingBy: 35) + wave * 8 : 0
        receiveMbps = state == .available ? 3 + wave * 54 + rhythm * 8 : 0
        transmitMbps = state == .available ? 1 + rhythm * 45 + wave * 7 : 0
    }
}

nonisolated extension LabTopology.Device {
    var hasDashboard: Bool { modelID == "server-c220m5" || modelID == "server-firewall" }
}
