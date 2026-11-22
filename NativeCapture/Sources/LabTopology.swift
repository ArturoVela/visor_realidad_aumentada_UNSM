import Foundation
import simd

nonisolated enum LabCableLevel: String, Codable, Sendable { case floor, overhead }

nonisolated enum LabClientConnection: String, Codable, Sendable, CaseIterable, Identifiable {
    case ethernet, wifi, both
    var id: Self { self }
    var title: String {
        switch self { case .ethernet: "Cable"; case .wifi: "Wi-Fi"; case .both: "Wi-Fi y cable" }
    }
}

nonisolated enum LabDeskEquipment: String, CaseIterable, Identifiable, Sendable {
    case pc = "pc-optiplex7010", laptop = "laptop-latitude5420", phone = "pt-smartphone", accessPoint = "access-point"
    case genericPC = "pt-desktop", genericLaptop = "pt-laptop", genericAccessPoint = "pt-access-point"
    case ipPhone = "phone-7960", printer = "pt-printer", raspberryPi = "raspberry-pi5"

    var id: Self { self }
    var title: String { HardwareCatalog.reference(rawValue)?.name ?? rawValue }
    var supportsWiFi: Bool { self == .phone || self == .laptop || self == .genericLaptop }
    var size: SIMD3<Float> { HardwareCatalog.renderSize(LabTopology.Device.visualModel(for: rawValue)) }
    var minimumDesk: SIMD2<Float> { simd_max(SIMD2(0.26, 0.26), SIMD2(size.x + 0.12, size.z + 0.12)) }
}

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
        var packetTracer: PacketTracerDevice? = nil
        var serverServices: LabServerServices? = nil
        var leasedBy: String? = nil
        var connectionMode: LabClientConnection? = nil
        var wifiAccessPointID: String? = nil
        var parkedOnDesk: Bool? = nil
        var icmpEchoDeny: ICMPEchoDeny? = nil

        var supportsWiFi: Bool { LabDeskEquipment(rawValue: modelID)?.supportsWiFi == true }
        var allowsEthernet: Bool { connectionMode != .wifi }
        var isAccessPoint: Bool { modelID == "access-point" || modelID == "pt-access-point" }
        var isFanTray: Bool { modelID == RackMount.Equipment.fans.rawValue }

        var visualModelID: String { Self.visualModel(for: modelID) }

        static func visualModel(for modelID: String) -> String {
            switch modelID {
            case "pt-server": "server-c220m5"
            case "pt-desktop": "pc-optiplex7010"
            case "pt-laptop": "laptop-latitude5420"
            default: modelID
            }
        }

        var visualSize: SIMD3<Float> { HardwareCatalog.renderSize(visualModelID) }

        func portNames(_ port: String) -> [String] {
            let families = [("fastethernet", "fa"), ("gigabitethernet", "gi"), ("ethernet", "eth"), ("serial", "se")]
            let names = [port, sourcePortNames?[port]].compactMap { $0?.lowercased() }
            return names + names.compactMap { name in
                guard let (full, short) = families.first(where: { name.hasPrefix($0.0) }) else { return nil }
                return short + name.dropFirst(full.count)
            }
        }
        var providesDHCP: Bool {
            if serverServices?.dhcp != nil { return true }
            return packetTracer.map { $0.dhcpPools.contains(where: \.enabled) }
                ?? services.contains { $0.hasPrefix("DHCP:") || $0 == "DHCP" }
        }
    }

    struct ICMPEchoDeny: Codable, Sendable, Equatable {
        let port: String
        let source: String
        let destination: String

        static let name = "NEXUS-ICMP-IN"
    }

    struct PacketTracerDevice: Codable, Sendable, Equatable {
        struct Interface: Codable, Sendable, Equatable {
            let port: String
            var ipv4: String?
            var mask: String?
            var gateway: String?
            let ospfArea: String?
            var dhcp: Bool?
            var fromLease: Bool?
            var dhcpServer: String?
            var description: String?
        }

        struct Pool: Codable, Sendable, Equatable {
            let name: String
            let network: String
            let mask: String
            let start: String
            let end: String
            let gateway: String
            let dns: String
            let enabled: Bool
        }

        let description: String
        var interfaces: [Interface]
        let dhcpPools: [Pool]
        var localConfiguration: Bool? = nil
    }

    enum Medium: String, Codable, Sendable {
        case copper, fiber, serial, console, powerA, powerB

        var title: String {
            switch self {
            case .copper: "Ethernet de cobre"
            case .fiber: "Fibra óptica"
            case .serial: "Serial WAN"
            case .console: "Consola"
            case .powerA: "Alimentación A"
            case .powerB: "Alimentación B"
            }
        }

        // Nominal outside diameter of the Belden 2412 Cat 6 U/UTP reference cable.
        var cableRadius: Float {
            switch self {
            case .copper: 0.00569 / 2
            case .fiber: 0.0025
            default: 0.0035
            }
        }
        // The copper design radius exceeds the 25 mm stationary minimum of the reference cable.
        var referenceBendRadius: Float { self == .fiber ? 0.040 : 0.032 }
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
        var sourceCableType: String? = nil
        var arRouteLevel: LabCableLevel? = nil
        var autoPatchTrunk: Bool? = nil

        var cableTitle: String {
            switch (medium, sourceCableType) {
            case (.copper, "eStraightThrough"): "Ethernet de cobre · directo"
            case (.copper, "eCrossOver"): "Ethernet de cobre · cruzado"
            default: medium.title
            }
        }
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
    var logicalPlan: LabLogicalPlan? = nil
    var editableProfileID: UUID? = nil

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
            let available = Set(LabDemo.ports(device.modelID, includingSerial: true))
            guard !device.id.isEmpty, device.id.count <= 160, !device.name.isEmpty, device.name.count <= 160,
                  !device.placementID.isEmpty, device.placementID.count <= 160,
                  (HardwareCatalog.item(device.modelID) != nil || RackMount.Equipment(rawValue: device.modelID) != nil),
                  device.modelID != "rack-r42612",
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
                  device.icmpEchoDeny.map({ rule in
                      device.modelID.hasPrefix("router-") && device.ports.contains(rule.port)
                          && Self.mediumForPort(modelID: device.modelID, port: rule.port) == .copper
                          && Self.ipv4(rule.source) != nil && Self.ipv4(rule.destination) != nil
                  }) ?? true,
                  device.connectionMode == nil || device.supportsWiFi,
                  device.wifiAccessPointID.map({ access in
                      device.supportsWiFi && device.connectionMode != nil && device.connectionMode != .ethernet
                          && devices.contains { $0.id == access && $0.isAccessPoint }
                  }) ?? true,
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
            case .copper, .fiber, .serial:
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
        guard layout.placements.count <= 132,
              layout.placements.filter({ $0.kind == .rack }).count <= 12,
              layout.placements.filter({ $0.kind == .workstation }).count <= 24,
              layout.placements.filter({ $0.kind == .floor }).count <= 96,
              Set(layout.placements.map(\.id)).count == layout.placements.count,
              layout.floorHeight.isFinite, layout.area.isFinite, layout.area > 0 else {
            throw LabLayoutError.invalid("Distribución fuera de los límites de importación.")
        }
        _ = try LabGeometry.triangulate(layout.floorPolygon)
        let byID = Dictionary(uniqueKeysWithValues: layout.placements.map { ($0.id, $0) })
        let monitorGroups = layout.rackMonitors ?? [:]
        let monitors = monitorGroups.values.flatMap { $0 }
        let servers = Set(devices.filter { $0.visualModelID.hasPrefix("server-") }.map(\.id))
        guard Set(monitors.map(\.id)).count == monitors.count,
              monitorGroups.allSatisfy({ rackID, monitors in
                  guard let rack = byID[rackID], rack.kind == .rack, (0.2...4).contains(rack.size.y) else { return false }
                  let rows = LabARAssembly.monitorRowCount(on: rack)
                  return monitors.count <= rows * 2
                      && Set(monitors.map { $0.side.rawValue + String($0.row) }).count == monitors.count
                      && monitors.allSatisfy { (0..<rows).contains($0.row) && servers.contains($0.device) }
              }) else { throw LabLayoutError.invalid("Hay monitores con un servidor o soporte inválido.") }
        let accessories = layout.accessories ?? []
        let partIDs = accessories.map { $0.id.name } + monitors.map { $0.id.uuidString }
        guard accessories.count <= 64, Set(partIDs).count == partIDs.count,
              accessories.allSatisfy({ piece in
                  guard piece.monitorMount == nil, piece.yaw.isFinite,
                        (0..<3).allSatisfy({ piece.position[$0].isFinite }),
                        LabGeometry.contains(SIMD2(piece.position.x, piece.position.z), polygon: layout.floorPolygon) else { return false }
                  switch piece.id {
                  case .extra(let model, _): return LabARAssembly.accessorySize(model) != nil
                  case .monitor(let id, _, _): return servers.contains(id)
                  default: return false
                  }
              }) else { throw LabLayoutError.invalid("Hay accesorios con un modelo o una posición inválida.") }
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
                guard !Self.overlaps(layout.placements[i], layout.placements[j]) else {
                    throw LabLayoutError.invalid("Hay colocaciones solapadas.")
                }
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
        for placement in layout.placements where placement.kind == .floor {
            let equipment = devices.filter { $0.placementID == placement.id }
            guard let device = equipment.first, equipment.count == 1, placement.size == device.visualSize,
                  device.offset == SIMD3(0, device.visualSize.y / 2, 0) else {
                throw LabLayoutError.invalid("Un equipo en el piso necesita una posición propia: \(placement.title).")
            }
        }
    }

    func parkedDeviceIDs(in layout: LabLayout) -> Set<String> {
        let floor = Set(layout.placements.lazy.filter { $0.kind == .floor }.map(\.id))
        return Set(devices.lazy.filter { $0.parkedOnDesk == true || floor.contains($0.placementID) }.map(\.id))
    }

    func pendingCableCircuits(in layout: LabLayout) -> Set<String> {
        let loose = parkedDeviceIDs(in: layout)
        guard !loose.isEmpty else { return [] }
        return Set(links.lazy.filter { loose.contains($0.fromDeviceID) || loose.contains($0.toDeviceID) }
            .map { $0.circuitID ?? $0.id })
    }

    static func mediumForPort(modelID: String, port: String) -> Medium? {
        guard LabDemo.ports(modelID, includingSerial: true).contains(port) else { return nil }
        if modelID == "patch-fiber" { return .fiber }
        if port == "Console" { return .console }
        if port.hasPrefix("Serial") { return .serial }
        if modelID == "switch-3560" && port.hasPrefix("GigabitEthernet") { return .fiber }
        if modelID == "switch-3650" && port.hasPrefix("GigabitEthernet1/1/") { return .fiber }
        return .copper
    }

    func circuit(for link: Link) -> [Link] {
        guard let id = link.circuitID else { return [link] }
        return links.filter { $0.circuitID == id }
    }

    enum PortSignal: String, Sendable {
        case active = "Enlace activo"
        case negotiating = "Negociando enlace"
        case blocked = "Puerto del circuito desactivado"
        case noPower = "Equipo del circuito sin alimentación"
        case pending = "Conexión pendiente de montaje"
        case unplugged = "Sin cable"
    }

    func link(at port: Port) -> Link? {
        links.first { $0.fromDeviceID == port.deviceID && $0.fromPort == port.name
            || $0.toDeviceID == port.deviceID && $0.toPort == port.name }
    }

    static func signal(for circuit: [Link], devices: [String: Device], poweredOff: Set<String>, pending: Set<String>,
                       negotiating: String? = nil) -> PortSignal {
        guard !circuit.isEmpty else { return .unplugged }
        let ports = circuit.flatMap { [Port(deviceID: $0.fromDeviceID, name: $0.fromPort), Port(deviceID: $0.toDeviceID, name: $0.toPort)] }
        if ports.contains(where: { pending.contains($0.deviceID) }) { return .pending }
        if ports.contains(where: { port in
            guard let device = devices[port.deviceID], !device.modelID.hasPrefix("patch-") else { return false }
            return poweredOff.contains(device.id) || poweredOff.contains(device.placementID)
        }) { return .noPower }
        if ports.contains(where: { devices[$0.deviceID]?.shutdownPorts?.contains($0.name) == true }) { return .blocked }
        if let negotiating, circuit.contains(where: { $0.id == negotiating }) { return .negotiating }
        return .active
    }

    func signal(at port: Port, poweredOff: Set<String>, pending: Set<String>, negotiating: String? = nil) -> PortSignal {
        let devices = Dictionary(uniqueKeysWithValues: devices.map { ($0.id, $0) })
        if let link = link(at: port) {
            return Self.signal(for: circuit(for: link), devices: devices, poweredOff: poweredOff, pending: pending, negotiating: negotiating)
        }
        if let device = devices[port.deviceID] {
            if pending.contains(device.id) { return .pending }
            if poweredOff.contains(device.id) || poweredOff.contains(device.placementID) { return .noPower }
            if device.shutdownPorts?.contains(port.name) == true { return .blocked }
        }
        return .unplugged
    }

    func pendingSignalDevices(in layout: LabLayout, assembly: LabARAssembly?) -> Set<String> {
        let parked = parkedDeviceIDs(in: layout)
        guard let assembly else { return parked }
        let placed = Set(assembly.resolvedPieces(in: layout).map(\.id))
        return parked.union(devices.filter { !placed.contains(.device($0.id)) && !placed.contains(.support($0.placementID)) }.map(\.id))
    }

    func speedLimit(for circuit: [Link]) -> Int? {
        guard let first = circuit.first, let last = circuit.last, [.copper, .fiber].contains(first.medium) else { return nil }
        func speed(_ id: String, _ port: String) -> Int? {
            guard let model = devices.first(where: { $0.id == id })?.visualModelID else { return nil }
            if port.hasPrefix("FastEthernet") || model == "firewall-asa5505" || model == "phone-7960" { return 100 }
            if port.hasPrefix("GigabitEthernet") { return 1_000 }
            if ["server-c220m5", "server-firewall"].contains(model) { return 10_000 }
            return nil
        }
        guard let a = speed(first.fromDeviceID, first.fromPort), let b = speed(last.toDeviceID, last.toPort) else { return nil }
        return min(a, b)
    }

    func rackPowerFailures(in layout: LabLayout, poweredOff: Set<String>, assembly: LabARAssembly? = nil) -> Set<String> {
        guard !poweredOff.isEmpty else { return [] }
        let groups = Dictionary(grouping: devices.filter { assembly?.piece(.device($0.id)) == nil }, by: \.placementID)
        var failed = Set<String>()
        for rack in layout.placements where rack.kind == .rack {
            guard let devices = groups[rack.id] else { continue }
            let sources = LabRackPower.upsSources(in: devices)
            guard let primary = sources.first, poweredOff.contains(primary.id) else { continue }
            let backupWorks = layout.pduConfiguration(for: rack.id) == .dual
                && sources.dropFirst().first.map { !poweredOff.contains($0.id) } == true
            for device in devices where LabRackPower.isConsumer(device.visualModelID)
                && !(backupWorks && LabRackPower.hasDualSupply(device.visualModelID)) { failed.insert(device.id) }
        }
        return failed
    }

    func visibleCableIDs(for filter: LabCableFilter) -> Set<String> {
        switch filter {
        case .medium(let medium): return Set(links.filter { $0.medium == medium }.map(\.id))
        case .vlan(let vlan): return Set(links.filter { $0.vlanIDs.contains(vlan) }.map(\.id))
        case .rack(let rack):
            let installed = Set(devices.filter { $0.placementID == rack }.map(\.id))
            let circuits = Set(links.filter { installed.contains($0.fromDeviceID) || installed.contains($0.toDeviceID) }
                .map { $0.circuitID ?? $0.id })
            return Set(links.filter { circuits.contains($0.circuitID ?? $0.id) }.map(\.id))
        }
    }

    struct PingPath {
        var devices: [Device]
        var links: [Link] = []

        func followed(by next: Self) -> Self {
            .init(devices: devices + next.devices.dropFirst(), links: links + next.links)
        }

        var reversed: Self { .init(devices: Array(devices.reversed()), links: Array(links.reversed())) }
    }

    struct PingDiagnosis {
        var path: PingPath? = nil
        var issue: String? = nil
        var blockedLink: Link? = nil
        var blockedDevice: Device? = nil

        var sample: PingSample { .init(hops: issue == nil ? path?.devices.count : nil) }
    }

    struct PingSample {
        let hops: Int?
        let sent = 4
        var received: Int { hops == nil ? 0 : sent }
        var loss: Int { (sent - received) * 100 / sent }
        var times: [Double] {
            guard let hops else { return [] }
            let base = 0.45 + Double(hops) * 0.28
            return [base, base + 0.06, base + 0.02, base + 0.04]
        }
        var mean: Double? {
            let samples = times
            return samples.isEmpty ? nil : samples.reduce(0, +) / Double(samples.count)
        }
    }

    func switchedPath(from source: String, to destination: String, vlan: Int,
                      toGateway: Bool = false, poweredOff: Set<String> = []) -> [Device]? {
        if let wired = switchedPingPath(from: source, to: destination, vlan: vlan, toGateway: toGateway, poweredOff: poweredOff) {
            return wired.devices
        }
        guard let a = devices.first(where: { $0.id == source }), let b = devices.first(where: { $0.id == destination }),
              a.vlan == vlan, b.vlan == vlan || toGateway else { return nil }
        return wirelessPath(from: a, to: b, vlan: vlan, toGateway: toGateway, poweredOff: poweredOff)?.devices
    }

    private func switchedPingPath(from source: String, to destination: String, vlan: Int?,
                                  toGateway: Bool = false, bridgeEndpoints: Bool = false, poweredOff: Set<String> = []) -> PingPath? {
        struct Hop: Hashable {
            let device: String
            var entry: String? = nil
        }
        let inventory = Dictionary(uniqueKeysWithValues: devices.filter {
            !poweredOff.contains($0.id) && !poweredOff.contains($0.placementID)
        }.map { ($0.id, $0) })
        guard let origin = inventory[source], origin.vlan == vlan || (bridgeEndpoints && origin.isAccessPoint),
              let endpoint = inventory[destination],
              toGateway || endpoint.vlan == vlan || (bridgeEndpoints && endpoint.isAccessPoint) else { return nil }
        let start = Hop(device: source)
        var queue: [(hop: Hop, path: PingPath)] = [(start, .init(devices: [origin]))]
        var visited = Set([start])
        var index = 0
        while index < queue.count {
            let (hop, path) = queue[index]
            index += 1
            guard let device = inventory[hop.device] else { continue }
            if hop.device == destination { return path }
            let pairedPort = hop.entry.map { ($0.hasPrefix("F") ? "R" : "F") + $0.dropFirst() }
            guard hop.device == source || device.modelID.hasPrefix("switch-") || device.isAccessPoint || pairedPort != nil else { continue }
            for link in links where (vlan.map(link.vlanIDs.contains) ?? link.vlanIDs.isEmpty)
                && (link.medium == .copper || link.medium == .fiber)
                && inventory[link.fromDeviceID]?.allowsEthernet == true && inventory[link.toDeviceID]?.allowsEthernet == true
                && inventory[link.fromDeviceID]?.shutdownPorts?.contains(link.fromPort) != true
                && inventory[link.toDeviceID]?.shutdownPorts?.contains(link.toPort) != true {
                let next: String, ingress: String, egress: String
                if link.fromDeviceID == hop.device {
                    (next, ingress, egress) = (link.toDeviceID, link.toPort, link.fromPort)
                } else if link.toDeviceID == hop.device {
                    (next, ingress, egress) = (link.fromDeviceID, link.fromPort, link.toPort)
                } else { continue }
                guard pairedPort == nil || pairedPort == egress, let neighbor = inventory[next] else { continue }
                let candidate = Hop(device: next, entry: neighbor.modelID.hasPrefix("patch-") ? ingress : nil)
                if visited.insert(candidate).inserted {
                    queue.append((candidate, .init(devices: path.devices + [neighbor], links: path.links + [link])))
                }
            }
        }
        return nil
    }

    private func wirelessPath(from source: Device, to destination: Device, vlan: Int?, toGateway: Bool = false,
                              poweredOff: Set<String>) -> PingPath? {
        func online(_ device: Device) -> Bool { !poweredOff.contains(device.id) && !poweredOff.contains(device.placementID) }
        func access(_ client: Device) -> Device? {
            guard let mode = client.connectionMode, mode != .ethernet, let id = client.wifiAccessPointID else { return nil }
            return devices.first { $0.id == id && $0.isAccessPoint && online($0) }
        }
        guard online(source), online(destination) else { return nil }
        let left = [source.allowsEthernet ? source : nil, access(source)].compactMap { $0 }
        let right = [destination.allowsEthernet ? destination : nil, access(destination)].compactMap { $0 }
        for a in left {
            for b in right where a.id != source.id || b.id != destination.id {
                guard let wired = switchedPingPath(from: a.id, to: b.id, vlan: vlan, toGateway: toGateway,
                                                   bridgeEndpoints: true, poweredOff: poweredOff) else { continue }
                return .init(devices: (a.id == source.id ? [] : [source]) + wired.devices
                    + (b.id == destination.id ? [] : [destination]), links: wired.links)
            }
        }
        return nil
    }

    /// IPv4 reachability in imported LANs and between routers over explicitly configured OSPF serial links.
    func importedIPv4Path(from source: Device, to endpoint: Device, poweredOff: Set<String>) -> [Device]? {
        let diagnostic = routedIPv4Diagnosis(from: source, to: endpoint, poweredOff: poweredOff, applyEchoACL: false)
        return diagnostic.issue == nil ? diagnostic.path?.devices : nil
    }

    private func routedIPv4Diagnosis(from source: Device, to endpoint: Device, poweredOff: Set<String>,
                                     applyEchoACL: Bool = true) -> PingDiagnosis {
        typealias Interface = PacketTracerDevice.Interface
        let active = Dictionary(uniqueKeysWithValues: devices.filter {
            !poweredOff.contains($0.id) && !poweredOff.contains($0.placementID)
        }.map { ($0.id, $0) })
        guard active[source.id] != nil, active[endpoint.id] != nil,
              let sourceIP = source.ipv4, let destinationIP = endpoint.ipv4 else {
            return .init(issue: "Un extremo está apagado o carece de IPv4.")
        }
        if source.id == endpoint.id { return .init(path: .init(devices: [source])) }
        let connected = links.filter {
            active[$0.fromDeviceID]?.allowsEthernet == true && active[$0.toDeviceID]?.allowsEthernet == true
                && active[$0.fromDeviceID]?.shutdownPorts?.contains($0.fromPort) != true
                && active[$0.toDeviceID]?.shutdownPorts?.contains($0.toPort) != true
        }
        func interface(_ device: Device, ip: String) -> Interface? {
            let interfaces = device.packetTracer?.interfaces ?? []
            if operationsProfile == LabDemo.vlanProfile, let server = device.leasedBy,
               let pool = devices.first(where: { $0.id == server })?.serverServices?.dhcp,
               var ethernet = interfaces.first(where: { $0.port == "Ethernet" }),
               device.shutdownPorts?.contains(ethernet.port) != true {
                ethernet.ipv4 = ip
                ethernet.gateway = pool.gateway
                return ethernet
            }
            return interfaces.first { $0.ipv4 == ip && device.shutdownPorts?.contains($0.port) != true }
        }
        func sameNetwork(_ a: Interface, _ b: Interface) -> Bool {
            guard let aIP = a.ipv4.flatMap(Self.ipv4), let bIP = b.ipv4.flatMap(Self.ipv4),
                  let mask = a.mask.flatMap(Self.ipv4), mask == b.mask.flatMap(Self.ipv4), mask != 0 else { return false }
            let hosts = ~mask
            return hosts & (hosts &+ 1) == 0 && aIP & mask == bIP & mask
        }
        func path(from origin: Device, to target: Device, next: (String) -> [Link]) -> PingPath? {
            struct Hop: Hashable {
                let device: String
                let outlet: String?
            }
            let start = Hop(device: origin.id, outlet: nil)
            var queue = [(start, PingPath(devices: [origin]))], visited = Set([start]), cursor = 0
            while cursor < queue.count {
                let (hop, path) = queue[cursor]
                cursor += 1
                if hop.device == target.id { return path }
                for link in next(hop.device) {
                    let forward = link.fromDeviceID == hop.device
                    let local = forward ? link.fromPort : link.toPort
                    let remote = forward ? link.toPort : link.fromPort
                    let neighbor = forward ? link.toDeviceID : link.fromDeviceID
                    guard hop.outlet == nil || hop.outlet == local, let device = active[neighbor] else { continue }
                    let paired = device.modelID.hasPrefix("patch-") ? (remote.hasPrefix("F") ? "R" : "F") + remote.dropFirst() : nil
                    let step = Hop(device: neighbor, outlet: paired)
                    guard visited.insert(step).inserted else { continue }
                    queue.append((step, .init(devices: path.devices + [device], links: path.links + [link])))
                }
            }
            return nil
        }
        func lan(_ from: Device, _ a: Interface, _ to: Device, _ b: Interface, vlan: Int?) -> PingPath? {
            guard sameNetwork(a, b) else { return nil }
            return path(from: from, to: to) { current in
                let model = active[current]?.modelID ?? ""
                guard current == from.id || model.hasPrefix("switch-") || model.hasPrefix("patch-") else { return [] }
                return connected.compactMap { link in
                    guard link.medium == .copper || link.medium == .fiber,
                          vlan.map(link.vlanIDs.contains) ?? link.vlanIDs.isEmpty else { return nil }
                    let forward = link.fromDeviceID == current
                    guard forward || link.toDeviceID == current else { return nil }
                    let local = forward ? link.fromPort : link.toPort
                    let other = forward ? link.toDeviceID : link.fromDeviceID
                    let remote = forward ? link.toPort : link.fromPort
                    guard (current != from.id || local == a.port), (other != to.id || remote == b.port) else { return nil }
                    return link
                }
            }
        }
        guard let start = interface(source, ip: sourceIP), let end = interface(endpoint, ip: destinationIP) else {
            return .init(issue: "Falta una interfaz activa con la IPv4 de uno de los extremos.")
        }
        if sameNetwork(start, end), source.vlan == endpoint.vlan || source.vlan == nil || endpoint.vlan == nil {
            if let route = lan(source, start, endpoint, end, vlan: source.vlan ?? endpoint.vlan) { return .init(path: route) }
            if let route = wirelessPath(from: source, to: endpoint, vlan: source.vlan ?? endpoint.vlan, poweredOff: poweredOff) {
                return .init(path: route)
            }
            return .init(issue: "La subred local no tiene un camino continuo por la VLAN de los extremos.")
        }

        func gateway(for host: Device, interface port: Interface) -> (Device, Interface, PingPath)? {
            if host.modelID.hasPrefix("router-") { return (host, port, .init(devices: [host])) }
            guard let address = port.gateway, !address.isEmpty else { return nil }
            let routers = active.values.filter { $0.modelID.hasPrefix("router-") }
            let candidates = routers.compactMap { router -> (Device, Interface, PingPath)? in
                guard let gateway = interface(router, ip: address),
                      let route = lan(host, port, router, gateway, vlan: host.vlan) else { return nil }
                return (router, gateway, route)
            }
            return candidates.count == 1 ? candidates.first : nil
        }
        guard let (ingress, ingressLAN, before) = gateway(for: source, interface: start) else {
            return .init(issue: "No se encontró un gateway alcanzable y único para \(source.name).")
        }
        if applyEchoACL, source.id != ingress.id, let rule = ingress.icmpEchoDeny, rule.port == ingressLAN.port,
           rule.source == sourceIP, rule.destination == destinationIP {
            return .init(path: before, issue: "La ACL \(ICMPEchoDeny.name) de \(ingress.name) bloquea ICMP de \(sourceIP) a \(destinationIP).",
                         blockedDevice: ingress)
        }
        guard let (egress, egressLAN, after) = gateway(for: endpoint, interface: end) else {
            return .init(path: before, issue: "No se encontró un gateway alcanzable y único para \(endpoint.name).")
        }
        if ingress.id == egress.id { return .init(path: before.followed(by: after.reversed)) }
        guard let area = ingressLAN.ospfArea, area == egressLAN.ospfArea else {
            return .init(path: before, issue: "Los gateways carecen de un área OSPF común en el plano importado.")
        }
        let wan = path(from: ingress, to: egress) { current in
            connected.compactMap { link in
                guard link.medium == .serial,
                      let a = active[link.fromDeviceID], let b = active[link.toDeviceID],
                      a.modelID.hasPrefix("router-"), b.modelID.hasPrefix("router-"),
                      let front = a.packetTracer?.interfaces.first(where: { $0.port == link.fromPort }),
                      let back = b.packetTracer?.interfaces.first(where: { $0.port == link.toPort }),
                      front.ospfArea == area, back.ospfArea == area, sameNetwork(front, back) else { return nil }
                return a.id == current || b.id == current ? link : nil
            }
        }
        guard let wan else {
            return .init(path: before, issue: "No se encontró una ruta WAN serie compatible con OSPF entre \(ingress.name) y \(egress.name).")
        }
        return .init(path: before.followed(by: wan).followed(by: after.reversed))
    }

    func diagnosePing(from source: Device, to destination: Device, poweredOff: Set<String>) -> PingDiagnosis {
        func isOff(_ device: Device) -> Bool {
            poweredOff.contains(device.id) || poweredOff.contains(device.placementID)
        }
        for device in [source, destination] {
            if isOff(device) { return .init(issue: "\(device.name) está apagado.", blockedDevice: device) }
            if device.ipv4 == nil { return .init(issue: "\(device.name) no tiene una IPv4 disponible.", blockedDevice: device) }
        }
        let diagnosis = ping(from: source, to: destination, poweredOff: poweredOff)
        guard diagnosis.issue != nil, !poweredOff.isEmpty || devices.contains(where: { $0.shutdownPorts?.isEmpty == false }) else {
            return diagnosis
        }

        // Identify the first blocking endpoint only if the same design admits a route with faults cleared.
        var reference = self
        for index in reference.devices.indices { reference.devices[index].shutdownPorts = nil }
        guard let referenceSource = reference.devices.first(where: { $0.id == source.id }),
              let referenceDestination = reference.devices.first(where: { $0.id == destination.id }) else { return diagnosis }
        let expected = reference.ping(from: referenceSource, to: referenceDestination, poweredOff: [])
        guard expected.issue == nil, let path = expected.path, path.links.count + 1 == path.devices.count else { return diagnosis }
        let inventory = Dictionary(uniqueKeysWithValues: devices.map { ($0.id, $0) })
        for (index, link) in path.links.enumerated() {
            let forward = link.fromDeviceID == path.devices[index].id
            let ports = forward ? [link.fromPort, link.toPort] : [link.toPort, link.fromPort]
            for (hop, port) in zip(path.devices[index...index + 1], ports) {
                guard let device = inventory[hop.id] else { continue }
                let issue: String
                if isOff(device) { issue = "\(device.name) está apagado." }
                else if device.shutdownPorts?.contains(port) == true {
                    issue = "El puerto \(device.sourcePortNames?[port] ?? port) de \(device.name) está desactivado."
                } else { continue }
                let reached = PingPath(devices: Array(path.devices.prefix(index + 1)), links: Array(path.links.prefix(index)))
                return .init(path: reached, issue: issue, blockedLink: link, blockedDevice: device)
            }
        }
        return diagnosis
    }

    private func ping(from source: Device, to destination: Device, poweredOff: Set<String>) -> PingDiagnosis {
        if operationsProfile == LabDemo.vlanProfile, source.vlan != destination.vlan {
            return routedIPv4Diagnosis(from: source, to: destination, poweredOff: poweredOff)
        }
        if operationsProfile == nil, source.leasedBy == nil, destination.leasedBy == nil,
           source.serverServices == nil, destination.serverServices == nil,
           [source, destination].contains(where: { device in
               guard let details = device.packetTracer else { return false }
               return details.localConfiguration != true || device.vlan == nil
           }) {
            return routedIPv4Diagnosis(from: source, to: destination, poweredOff: poweredOff)
        }
        guard let vlan = source.vlan, destination.vlan == vlan else {
            return .init(issue: "Los extremos necesitan una VLAN común para esta prueba simulada.")
        }
        if let path = switchedPingPath(from: source.id, to: destination.id, vlan: vlan, poweredOff: poweredOff) {
            return .init(path: path)
        }
        if let path = wirelessPath(from: source, to: destination, vlan: vlan, poweredOff: poweredOff) {
            return .init(path: path)
        }
        return .init(issue: "No se encontró un camino activo en la VLAN \(vlan). Revisa sus conexiones y puertos.")
    }

    fileprivate static func ipv4(_ text: String) -> UInt32? {
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

    static func overlaps(_ a: LabPlacement, _ b: LabPlacement) -> Bool {
        overlapDepth(a, b) > 0.00001
    }

    static func overlapDepth(_ a: LabPlacement, _ b: LabPlacement) -> Float {
        let axes = [SIMD2(cos(a.yaw), -sin(a.yaw)), SIMD2(sin(a.yaw), cos(a.yaw)),
                    SIMD2(cos(b.yaw), -sin(b.yaw)), SIMD2(sin(b.yaw), cos(b.yaw))]
        let ac = corners(a), bc = corners(b)
        return axes.map { axis in
            let ap = ac.map { simd_dot($0, axis) }, bp = bc.map { simd_dot($0, axis) }
            return min(ap.max()! - bp.min()!, bp.max()! - ap.min()!)
        }.min() ?? 0
    }

    private static func crosses(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ c: SIMD2<Float>, _ d: SIMD2<Float>) -> Bool {
        func cross(_ x: SIMD2<Float>, _ y: SIMD2<Float>) -> Float { x.x * y.y - x.y * y.x }
        return cross(b - a, c - a) * cross(b - a, d - a) < -0.000001
            && cross(d - c, a - c) * cross(d - c, b - c) < -0.000001
    }

}

nonisolated struct LabProject: Codable, Sendable {
    var room: RoomStructure
    var layout: LabLayout
    var topology: LabTopology
    var isHomeLab = false
    var editableID: UUID? = nil

    @concurrent func connectingARPorts(_ from: LabTopology.Port, to: LabTopology.Port, vlans: [Int],
                                      level: LabCableLevel, in assembly: LabARAssembly) async throws
        -> (project: Self, linkID: String) {
        var project = self
        let link = try project.topology.connect(from, to: to, vlans: vlans)
        project.topology.links.removeLast()
        let result = try project.patchLink(link, level: level, assembly: assembly)
        let segments = result.links
        guard project.topology.links.count + segments.count <= 192 else {
            throw LabLayoutError.invalid("El montaje alcanzó el límite de tramos de cable.")
        }
        project.topology.links += segments
        try project.topology.validate(layout: project.layout)
        try Task.checkCancellation()
        try assembly.validateCableRoutes(segments.map(\.id), in: project)
        return (project, segments[result.trunk].id)
    }

    @concurrent func connectingRoomPorts(_ from: LabTopology.Port, to: LabTopology.Port, vlans: [Int], level: LabCableLevel) async throws
        -> (project: Self, linkID: String) {
        var installation = LabARAssembly(id: UUID(), name: "Cuarto 3D")
        for placement in layout.placements {
            installation.set(.init(id: .support(placement.id), position: placement.position, yaw: placement.yaw))
        }
        var editable = self
        editable.layout.placements = layout.placements.map { placement in
            placement.at(SIMD3(placement.position.x, layout.floorHeight, placement.position.z), yaw: placement.yaw)
        }
        let result = try await editable.connectingARPorts(from, to: to, vlans: vlans, level: level, in: installation)
        try result.project.validateRoomCable(result.linkID, layout: layout)
        return result
    }

    mutating func setCableLevel(_ id: String, to level: LabCableLevel, assembly: LabARAssembly?) throws {
        guard let link = topology.links.first(where: { $0.id == id }) else { throw LabLayoutError.invalid("El cable ya no existe.") }
        let ids = Set(topology.circuit(for: link).map(\.id))
        var next = self
        for index in next.topology.links.indices where ids.contains(next.topology.links[index].id) {
            next.topology.links[index].arRouteLevel = level
        }
        if let assembly { try assembly.validateCableRoutes(ids.sorted(), in: next) }
        else { try next.validateRoomCable(id, layout: layout) }
        self = next
    }

    private func validateRoomCable(_ id: String, layout: LabLayout) throws {
        let plan = try LabCablePlan.make(topology, room: room, layout: layout)
        let visible = Set(plan.segments.map(\.link.id))
        guard let link = topology.links.first(where: { $0.id == id }),
              topology.circuit(for: link).allSatisfy({ visible.contains($0.id) }) else {
            throw LabLayoutError.invalid("El trazado no cabe en el cuarto. Prueba por piso o ajusta la posición de los equipos.")
        }
    }

    func completingRackCabling() throws -> Self {
        var project = self
        var migrated: [String: (original: LabTopology.Link, segments: [LabTopology.Link])] = [:]
        var missingPanels = false
        let pending = topology.pendingCableCircuits(in: layout)
        for link in topology.links where link.circuitID == nil && !pending.contains(link.id) {
            var candidate = project
            do {
                let result = try candidate.patchLink(link, level: link.arRouteLevel)
                guard result.links.count > 1 else { continue }
                guard candidate.topology.links.count + result.links.count - 1 <= 192,
                      let index = candidate.topology.links.firstIndex(where: { $0.id == link.id }) else {
                    missingPanels = true
                    continue
                }
                candidate.topology.links.replaceSubrange(index...index, with: result.links)
                migrated[result.links[0].id] = (link, result.links)
                project = candidate
            } catch {
                missingPanels = true
            }
        }
        for rack in layout.placements where rack.kind == .rack {
            let members = project.topology.devices.filter { $0.placementID == rack.id }
            let copper = members.contains { device in
                device.ports.contains { LabTopology.mediumForPort(modelID: device.modelID, port: $0) == .copper }
            }
            let fiber = members.contains { $0.modelID == RackMount.Equipment.fiberPanel.rawValue }
            if fiber { _ = try project.patchPanels(in: rack, equipment: .fiberPanel) }
            if copper || !fiber { _ = try project.patchPanels(in: rack, equipment: .copperPanel) }
        }
        try project.topology.validate(layout: layout)
        if !migrated.isEmpty {
            let plan = try LabCablePlan.make(project.topology, room: room, layout: layout)
            let rendered = Set(plan.segments.map { $0.link.id })
            project.topology.links = project.topology.links.compactMap { link in
                guard let circuit = link.circuitID, let change = migrated[circuit],
                      !change.segments.allSatisfy({ rendered.contains($0.id) }) else { return link }
                missingPanels = true
                return link.id == circuit ? change.original : nil
            }
        }
        let warning = "Algunos enlaces conservan su trazado directo por espacio, puertos o capacidad de canaleta."
        if missingPanels && !project.layout.warnings.contains(warning) { project.layout.warnings.insert(warning, at: 0) }
        return project
    }

    private mutating func patchLink(_ link: LabTopology.Link, level: LabCableLevel?, assembly: LabARAssembly? = nil) throws
        -> (links: [LabTopology.Link], trunk: Int) {
        let from = LabTopology.Port(deviceID: link.fromDeviceID, name: link.fromPort)
        let to = LabTopology.Port(deviceID: link.toDeviceID, name: link.toPort)
        func rack(of port: LabTopology.Port) -> LabPlacement? {
            guard let device = topology.devices.first(where: { $0.id == port.deviceID }) else { return nil }
            if let assembly, assembly.piece(.device(device.id)) != nil || assembly.piece(.support(device.placementID)) == nil {
                return nil
            }
            return layout.placements.first { $0.id == device.placementID && $0.kind == .rack }
        }
        let originRack = rack(of: from), destinationRack = rack(of: to)
        var pairs: [(LabTopology.Port, LabTopology.Port)] = []
        var start = from, end = to
        if link.medium == .copper || link.medium == .fiber {
            let equipment: RackMount.Equipment = link.medium == .fiber ? .fiberPanel : .copperPanel
            let source = topology.devices.first { $0.id == from.deviceID }
            let target = topology.devices.first { $0.id == to.deviceID }
            let sourceIsPanel = source?.modelID.hasPrefix("patch-") == true
            let targetIsPanel = target?.modelID.hasPrefix("patch-") == true
            let sameRack = originRack != nil && originRack?.id == destinationRack?.id
            if let originRack, let source, !sourceIsPanel, !(sameRack && targetIsPanel) {
                let serverOnSameRack = sameRack && !source.visualModelID.hasPrefix("server-")
                    && target?.visualModelID.hasPrefix("server-") == true
                let height = serverOnSameRack ? target?.offset.y ?? source.offset.y : source.offset.y
                let panel = try patchPorts(in: originRack, near: height, equipment: equipment, assembly: assembly)
                pairs.append((from, panel.front))
                start = panel.rear
            }
            if let destinationRack, let target, !targetIsPanel, !sameRack {
                let panel = try patchPorts(in: destinationRack, near: target.offset.y, equipment: equipment, assembly: assembly)
                end = panel.rear
                pairs.append((start, end))
                pairs.append((panel.front, to))
            } else {
                pairs.append((start, end))
            }
        } else {
            pairs.append((start, end))
        }
        let trunk = pairs.firstIndex { $0.0 == start && $0.1 == end } ?? 0
        let occupiedIDs = Set(topology.links.map(\.id))
        let ids = pairs.indices.map { index -> String in
            if index == trunk { return link.id }
            return Self.availableID("\(link.id.prefix(47)).patch\(index + 1)", among: occupiedIDs)
        }
        let segments = pairs.enumerated().map { index, pair in
            LabTopology.Link(id: ids[index],
                  fromDeviceID: pair.0.deviceID, fromPort: pair.0.name, toDeviceID: pair.1.deviceID, toPort: pair.1.name,
                  medium: link.medium, vlanIDs: link.vlanIDs, circuitID: pairs.count > 1 ? ids[0] : nil,
                  sourceCableType: index == trunk ? link.sourceCableType : nil, arRouteLevel: index == trunk ? level : nil,
                  autoPatchTrunk: index == trunk && pairs.count > 1 ? true : nil)
        }
        return (segments, trunk)
    }

    private mutating func patchPorts(in rack: LabPlacement, near height: Float, equipment: RackMount.Equipment,
                                     assembly: LabARAssembly?) throws -> (front: LabTopology.Port, rear: LabTopology.Port) {
        let panels = try patchPanels(in: rack, equipment: equipment, assembly: assembly)
        for panel in panels.sorted(by: { (abs($0.offset.y - height), $0.id) < (abs($1.offset.y - height), $1.id) }) {
            let free = Set(topology.freePorts(on: panel).map(\.name))
            if let front = panel.ports.first(where: { $0.hasPrefix("F") && free.contains($0) && free.contains("R" + $0.dropFirst()) }) {
                return (.init(deviceID: panel.id, name: front),
                        .init(deviceID: panel.id, name: "R" + front.dropFirst()))
            }
        }
        throw LabLayoutError.invalid("Hace falta una unidad libre o un par de puertos en el patch panel de \(rack.title).")
    }

    @discardableResult private mutating func patchPanels(in rack: LabPlacement, equipment: RackMount.Equipment,
                                                         assembly: LabARAssembly? = nil) throws -> [LabTopology.Device] {
        let model = equipment.rawValue
        var panels = topology.devices.filter {
            $0.placementID == rack.id && $0.modelID == model && assembly?.piece(.device($0.id)) == nil
        }
        let capacity = RackMount.capacity(height: rack.size.y)
        let count = capacity >= 42 ? 3 : capacity > 16 ? 2 : 1
        for band in 0..<count {
            let slots = (band * capacity / count)..<((band + 1) * capacity / count)
            guard !panels.contains(where: { slots.contains(RackMount.slot(model, near: $0.offset.y)) }),
                  topology.devices.count < 96 else { continue }
            let middle = Float(slots.lowerBound + slots.upperBound - 1) / 2
            let available = Set(availableSlots(in: rack, model: model))
            let free = slots.filter(available.contains)
            let clearance = free.filter { (available.contains($0 - 1) || $0 == 0) &&
                                         (available.contains($0 + 1) || $0 == capacity - 1) }
            guard let slot = (clearance.isEmpty ? free : clearance).min(by: {
                abs(Float($0) - middle) < abs(Float($1) - middle)
            }) else { continue }
            let name = equipment == .fiberPanel ? "PP-LC" : "PP-CAT6"
            let id = Self.availableID("\(rack.id.prefix(36)):\(model):\(slot + 1)", among: Set(topology.devices.map(\.id)))
            panels.append(try mount(equipment, name: "\(name) · \(rack.title.prefix(56)) · U\(slot + 1)",
                                    rackID: rack.id, slot: slot, deviceID: id))
        }
        return panels
    }

    private static func availableID(_ base: String, among occupied: Set<String>) -> String {
        guard occupied.contains(base) else { return base }
        var suffix = 2
        while occupied.contains("\(base).\(suffix)") { suffix += 1 }
        return "\(base).\(suffix)"
    }

    mutating func addRack(_ height: RackMount.Height, name: String) throws -> LabPlacement {
        try addSupport(.rack, size: height.size, name: name)
    }

    mutating func addDesk(width: Float, depth: Float, name: String) throws -> LabPlacement {
        guard (0.26...3).contains(width), (0.26...2).contains(depth) else {
            throw LabLayoutError.invalid("Usa entre 26 y 300 cm de ancho y entre 26 y 200 cm de fondo.")
        }
        return try addSupport(.workstation, size: SIMD3(width, 1.25, depth), name: name)
    }

    private mutating func addSupport(_ kind: LabPlacement.Kind, size: SIMD3<Float>, name: String,
                                     near reference: LabPlacement? = nil) throws -> LabPlacement {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let limit = switch kind { case .rack: 12; case .workstation: 24; case .floor: 96 }
        guard !title.isEmpty, title.count <= 80,
              layout.placements.count(where: { $0.kind == kind }) < limit else {
            throw LabLayoutError.invalid("Escribe un nombre de hasta 80 caracteres. El plano admite hasta 12 racks y 24 mesas.")
        }
        let coordinates = layout.floorPolygon
        guard let minX = coordinates.map(\.x).min(), let maxX = coordinates.map(\.x).max(),
              let minZ = coordinates.map(\.y).min(), let maxZ = coordinates.map(\.y).max() else {
            throw LabLayoutError.invalid("El plano necesita una superficie para añadir equipos.")
        }
        let id = UUID().uuidString
        let left = minX + size.x / 2 + 0.12, right = maxX - size.x / 2 - 0.12
        let front = minZ + size.z / 2 + 0.12, back = maxZ - size.z / 2 - 0.12
        guard left <= right, front <= back else { throw LabLayoutError.invalid("Esta pieza no cabe en el cuarto.") }
        let step = max(kind == .rack ? 0.4 : 0.16, max(right - left, back - front) / 64)
        if let reference {
            let rotation = simd_quatf(angle: reference.yaw, axis: SIMD3(0, 1, 0))
            for lateral: Float in [1, -1] {
                let offset = rotation.act(SIMD3(lateral * ((reference.size.x + size.x) / 2 + 0.22), 0, 0))
                let position = SIMD3(reference.position.x, layout.floorHeight, reference.position.z) + offset
                let placement = LabPlacement(id: id, kind: kind, title: title, position: position, yaw: reference.yaw, size: size)
                if LabARAssembly.roomPlacementFits(placement, in: layout, topology: topology) {
                    layout.placements.append(placement)
                    return placement
                }
            }
        }
        var fallback: LabPlacement?
        for z in stride(from: front, through: back, by: step) {
            for x in stride(from: left, through: right, by: step) {
                let item = LabPlacement(id: id, kind: kind, title: title, position: SIMD3(x, layout.floorHeight, z),
                                        yaw: 0, size: size, bareDesk: kind == .workstation ? true : nil)
                guard LabARAssembly.roomPlacementFits(item, in: layout, topology: topology) else { continue }
                if kind == .workstation, size.x < 1.20 || size.z < 0.65 {
                    let expanded = LabPlacement(id: id, kind: kind, title: title, position: item.position, yaw: item.yaw,
                                                size: SIMD3(max(1.20, size.x), size.y, max(0.65, size.z)))
                    if !LabARAssembly.roomPlacementFits(expanded, in: layout, topology: topology) {
                        if fallback == nil { fallback = item }
                        continue
                    }
                }
                layout.placements.append(item)
                return item
            }
        }
        if let fallback { layout.placements.append(fallback); return fallback }
        throw LabLayoutError.invalid("El plano de la copia no tiene espacio libre para esta pieza.")
    }

    func deskOffset(for equipment: LabDeskEquipment, on desk: LabPlacement) -> SIMD3<Float>? {
        deskOffset(for: equipment.size, on: desk)
    }

    func deskOffset(for size: SIMD3<Float>, on desk: LabPlacement, at point: SIMD2<Float>? = nil,
                    excluding deviceID: String? = nil) -> SIMD3<Float>? {
        guard desk.kind == .workstation, 0.75 + size.y / 2 <= desk.size.y else { return nil }
        let limit = (SIMD2(desk.size.x, desk.size.z) - SIMD2(size.x, size.z)) / 2 - 0.035
        guard limit.x >= 0, limit.y >= 0 else { return nil }
        let members = topology.devices.filter { $0.placementID == desk.id && $0.id != deviceID }
        var occupied = members.map { (SIMD2($0.offset.x, $0.offset.z), SIMD2($0.visualSize.x, $0.visualSize.z)) }
        if desk.bareDesk != true, !layout.importedRoom || members.contains(where: { $0.visualModelID == "pc-optiplex7010" }) {
            occupied += [(SIMD2(-0.1, 0.12), SIMD2(0.54, 0.18)), (SIMD2(-0.1, -0.19), SIMD2(0.42, 0.16))]
        }
        func fits(_ center: SIMD2<Float>) -> Bool {
            guard abs(center.x) <= limit.x, abs(center.y) <= limit.y else { return false }
            return occupied.allSatisfy { position, footprint in
                let gap = simd_abs(center - position) - (footprint + SIMD2(size.x, size.z)) / 2
                return gap.x >= 0.025 || gap.y >= 0.025
            }
        }
        if let point { return fits(point) ? SIMD3(point.x, 0.75 + size.y / 2, point.y) : nil }
        func positions(_ bound: Float) -> [Float] { [0, bound, -bound] + Array(stride(from: -bound, to: bound, by: 0.05)) }
        for z in positions(limit.y) {
            for x in positions(limit.x) where fits(SIMD2(x, z)) { return SIMD3(x, 0.75 + size.y / 2, z) }
        }
        return nil
    }

    mutating func addDeskEquipment(_ equipment: LabDeskEquipment, name: String, deskID: String?) throws -> LabTopology.Device {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 80, topology.devices.count < 96 else {
            throw LabLayoutError.invalid("Escribe un nombre de hasta 80 caracteres. Límite de 96 equipos.")
        }
        var next = self
        let desk: LabPlacement
        if let deskID, let existing = layout.placements.first(where: { $0.id == deskID }) { desk = existing }
        else if deskID == nil {
            desk = try next.addDesk(width: equipment.minimumDesk.x, depth: equipment.minimumDesk.y,
                                    name: "Mesa \(layout.placements.count { $0.kind == .workstation } + 1)")
        } else { throw LabLayoutError.invalid("La mesa ya no está disponible.") }
        guard let offset = next.deskOffset(for: equipment, on: desk) else {
            throw LabLayoutError.invalid("No hay suficiente espacio libre en la mesa para este equipo.")
        }
        let model = equipment.rawValue
        let device = LabTopology.Device(id: UUID().uuidString, name: title, modelID: model, placementID: desk.id,
            offset: offset, services: [], ports: LabDemo.ports(model), connectionMode: equipment == .phone ? .wifi : nil)
        next.appendDevice(device, drawingOffset: SIMD2(offset.x, offset.z) * 30)
        self = next
        return device
    }

    mutating func resizeDesk(_ id: String, width: Float, depth: Float) throws {
        guard (0.26...3).contains(width), (0.26...2).contains(depth),
              let index = layout.placements.firstIndex(where: { $0.id == id && $0.kind == .workstation }) else {
            throw LabLayoutError.invalid("Selecciona una mesa y dimensiones válidas.")
        }
        let old = layout.placements[index]
        let candidate = LabPlacement(id: old.id, kind: old.kind, title: old.title, position: old.position,
            yaw: old.yaw, size: SIMD3(width, old.size.y, depth), bareDesk: old.bareDesk)
        guard topology.devices.filter({ $0.placementID == id }).allSatisfy({ device in
            abs(device.offset.x) + device.visualSize.x / 2 + 0.025 <= width / 2
                && abs(device.offset.z) + device.visualSize.z / 2 + 0.025 <= depth / 2
        }), LabARAssembly.roomPlacementFits(candidate, in: layout, topology: topology) else {
            throw LabLayoutError.invalid("Con esas medidas los equipos no caben o la mesa toca otro objeto.")
        }
        layout.placements[index] = candidate
    }

    func availableSlots(in rack: LabPlacement, model: String = "server-c220m5", excluding deviceID: String? = nil) -> [Int] {
        guard rack.kind == .rack else { return [] }
        let occupied = Set(topology.devices.filter { $0.placementID == rack.id && $0.id != deviceID }.flatMap { device in
            let slot = RackMount.slot(device.visualModelID, near: device.offset.y)
            return Array(slot..<(slot + RackMount.units(device.visualModelID)))
        })
        let units = RackMount.units(model), capacity = RackMount.capacity(height: rack.size.y)
        guard capacity >= units, HardwareCatalog.renderSize(model).z <= rack.size.z - RackMount.frontInset else { return [] }
        return (0...(capacity - units)).filter { slot in
            (slot..<(slot + units)).allSatisfy { !occupied.contains($0) }
        }
    }

    mutating func setRoomRackMonitors(_ monitors: [LabARAssembly.RackMonitor], rackID: String) throws {
        var next = self
        next.layout.rackMonitors = (layout.rackMonitors ?? [:]).merging([rackID: monitors]) { _, updated in updated }
        try next.topology.validate(layout: floorLevelLayout(next.layout))
        let before = LabARAssembly(roomLayout: layout)
        let after = LabARAssembly(roomLayout: next.layout)
        guard !after.conflicts(with: before, in: next.layout, topology: topology) else {
            throw LabLayoutError.invalid(LabARAssembly.collisionHint)
        }
        self = next
    }

    mutating func registerAccessory(_ item: LabARAssembly.Item) throws {
        if layout.accessories?.contains(where: { $0.id == item }) == true { return }
        guard (layout.accessories?.count ?? 0) < 64,
              let size = LabARAssembly.size(of: item, in: layout, topology: topology),
              let minX = layout.floorPolygon.map(\.x).min(), let maxX = layout.floorPolygon.map(\.x).max(),
              let minZ = layout.floorPolygon.map(\.y).min(), let maxZ = layout.floorPolygon.map(\.y).max() else {
            throw LabLayoutError.invalid("El plano no admite otro accesorio.")
        }
        var occupied = layout
        let parts = LabARAssembly(roomLayout: layout).resolvedPieces(in: layout).filter {
            switch $0.id { case .extra, .monitor: true; default: false }
        }
        for part in parts {
            guard let size = LabARAssembly.size(of: part.id, in: layout, topology: topology) else { continue }
            occupied.placements.append(.init(id: part.id.name, kind: .workstation, title: "",
                                            position: part.position, yaw: part.yaw, size: size))
        }
        let left = minX + size.x / 2 + 0.08, right = maxX - size.x / 2 - 0.08
        let front = minZ + size.z / 2 + 0.08, back = maxZ - size.z / 2 - 0.08
        let step = max(0.14, max(right - left, back - front) / 48)
        if left <= right && front <= back {
            for z in stride(from: front, through: back, by: step) {
                for x in stride(from: left, through: right, by: step) {
                    let position = SIMD3(x, layout.floorHeight, z)
                    let box = LabPlacement(id: item.name, kind: .workstation, title: "", position: position, yaw: 0, size: size)
                    guard LabTopology.fitsPlacement(box, in: occupied) else { continue }
                    layout.accessories = (layout.accessories ?? []) + [.init(id: item, position: position, yaw: 0)]
                    return
                }
            }
        }
        throw LabLayoutError.invalid("No hay espacio libre para colocar el accesorio en 3D.")
    }

    mutating func mirrorRackMonitors(_ monitors: [LabARAssembly.RackMonitor], rackID: String) throws {
        guard let rack = layout.placements.first(where: { $0.id == rackID && $0.kind == .rack }) else { return }
        let previous = layout.rackMonitors?[rackID] ?? []
        layout.rackMonitors = (layout.rackMonitors ?? [:]).merging([rackID: []]) { _, updated in updated }
        var roomAssembly = LabARAssembly(roomLayout: layout)
        for monitor in monitors {
            let preferred = previous.first { $0.id == monitor.id } ?? monitor
            for side in [preferred.side, preferred.side == .left ? .right : .left] {
                let slots = roomAssembly.freeMonitorRows(on: rack, side: side, in: layout, topology: topology)
                guard let first = slots.first else { continue }
                roomAssembly.set(LabARAssembly.RackMonitor(id: monitor.id, device: monitor.device, panel: monitor.panel,
                    side: side, row: slots.contains(preferred.row) ? preferred.row : first).piece(on: rack))
                break
            }
            if roomAssembly.piece(monitor.item) == nil {
                try registerAccessory(monitor.item)
                if let accessory = layout.accessories?.first(where: { $0.id == monitor.item }) { roomAssembly.set(accessory) }
            }
            layout.rackMonitors?[rackID] = roomAssembly.rackMonitors(on: rackID)
        }
    }

    mutating func putRackDeviceOnFloor(_ id: String, at position: SIMD3<Float>? = nil, yaw: Float? = nil) throws -> LabPlacement {
        guard let index = topology.devices.firstIndex(where: { $0.id == id }),
              let rack = layout.placements.first(where: { $0.id == topology.devices[index].placementID }),
              rack.kind == .rack || topology.devices[index].parkedOnDesk == true else {
            throw LabLayoutError.invalid("Selecciona un equipo montado en rack.")
        }
        let device = topology.devices[index]
        var next = self
        let floor: LabPlacement
        if let position {
            floor = .init(id: UUID().uuidString, kind: .floor, title: device.name,
                          position: SIMD3(position.x, layout.floorHeight, position.z), yaw: yaw ?? rack.yaw, size: device.visualSize)
            guard LabARAssembly.roomPlacementFits(floor, in: layout, topology: topology) else {
                throw LabLayoutError.invalid("El equipo no cabe en ese punto del piso.")
            }
            next.layout.placements.append(floor)
        } else {
            floor = try next.addSupport(.floor, size: device.visualSize, name: String(device.name.prefix(80)), near: rack)
        }
        next.topology.devices[index].placementID = floor.id
        next.topology.devices[index].offset = SIMD3(0, floor.size.y / 2, 0)
        next.topology.devices[index].parkedOnDesk = nil
        try next.topology.validate(layout: floorLevelLayout(next.layout))
        self = next
        return floor
    }

    mutating func putRackDeviceOnDesk(_ id: String, deskID: String, at point: SIMD2<Float>) throws {
        guard let index = topology.devices.firstIndex(where: { $0.id == id }),
              let origin = layout.placements.first(where: { $0.id == topology.devices[index].placementID }),
              origin.kind == .rack || origin.kind == .floor || topology.devices[index].parkedOnDesk == true,
              let desk = layout.placements.first(where: { $0.id == deskID }),
              let offset = deskOffset(for: topology.devices[index].visualSize, on: desk, at: point, excluding: id) else {
            throw LabLayoutError.invalid("Elige un punto libre en una mesa donde quepa el equipo.")
        }
        var next = self
        if origin.kind == .floor { next.layout.placements.removeAll { $0.id == origin.id } }
        next.topology.devices[index].placementID = desk.id
        next.topology.devices[index].offset = offset
        next.topology.devices[index].parkedOnDesk = true
        try next.topology.validate(layout: floorLevelLayout(next.layout))
        self = next
    }

    mutating func deleteRackDevice(_ id: String) throws {
        guard let device = topology.devices.first(where: { $0.id == id }),
              let support = layout.placements.first(where: { $0.id == device.placementID }),
              support.kind == .rack || support.kind == .floor || device.parkedOnDesk == true else {
            throw LabLayoutError.invalid("El equipo ya no está disponible para eliminarlo.")
        }
        var next = self
        for link in topology.links where link.fromDeviceID == id || link.toDeviceID == id {
            next.topology.disconnect(link.id)
        }
        next.topology.devices.removeAll { $0.id == id }
        for index in next.topology.devices.indices {
            if next.topology.devices[index].wifiAccessPointID == id { next.topology.devices[index].wifiAccessPointID = nil }
            if next.topology.devices[index].leasedBy == id { next.topology.devices[index].leasedBy = nil }
        }
        if let plan = topology.logicalPlan {
            next.topology.logicalPlan = .init(devicePositions: plan.devicePositions.filter { $0.key != id },
                                             areas: plan.areas, labels: plan.labels)
        }
        next.layout.rackMonitors = layout.rackMonitors?.mapValues { $0.filter { $0.device != id } }
        next.layout.accessories?.removeAll {
            if case .monitor(let device, _, _) = $0.id { return device == id }
            return false
        }
        if support.kind == .floor { next.layout.placements.removeAll { $0.id == support.id } }
        try next.topology.validate(layout: floorLevelLayout(next.layout))
        self = next
    }

    @concurrent func relocatingRackDevice(_ id: String, to rackID: String, slot: Int, assembly: LabARAssembly?) async throws -> Self {
        guard let index = topology.devices.firstIndex(where: { $0.id == id }),
              let rack = layout.placements.first(where: { $0.id == rackID && $0.kind == .rack }),
              let origin = layout.placements.first(where: { $0.id == topology.devices[index].placementID }),
              origin.kind == .rack || origin.kind == .floor || topology.devices[index].parkedOnDesk == true,
              assembly.map({ $0.piece(.support(rackID)) != nil }) ?? true else {
            throw LabLayoutError.invalid("Elige un equipo instalado y un rack disponible.")
        }
        let model = topology.devices[index].visualModelID
        guard availableSlots(in: rack, model: model, excluding: id).contains(slot) else {
            throw LabLayoutError.invalid("El equipo no cabe en esas unidades. Elige otro espacio.")
        }
        var next = self
        next.topology.devices[index].placementID = rackID
        next.topology.devices[index].offset = RackMount.center(model, rackDepth: rack.size.z, slot: slot)
        next.topology.devices[index].parkedOnDesk = nil
        if origin.kind == .floor { next.layout.placements.removeAll { $0.id == origin.id } }
        var mounted = assembly
        mounted?.remove(.device(id))
        if origin.kind == .floor { mounted?.remove(.support(origin.id)) }
        let original = topology.devices[index]
        guard next.topology.devices[index] != original || assembly?.piece(.device(id)) != nil else { return self }

        let affected = topology.links.filter { $0.fromDeviceID == id || $0.toDeviceID == id }
        var reviewed = Set(affected.map(\.id))
        var handled = Set<String>()
        for link in affected {
            guard let circuitID = link.circuitID, handled.insert(circuitID).inserted else { continue }
            let circuit = topology.circuit(for: link)
            guard let start = circuit.first, let end = circuit.last,
                  let trunk = circuit.first(where: { $0.autoPatchTrunk == true }),
                  start.fromDeviceID == id || end.toDeviceID == id else { continue }
            var direct = trunk
            direct.fromDeviceID = start.fromDeviceID
            direct.fromPort = start.fromPort
            direct.toDeviceID = end.toDeviceID
            direct.toPort = end.toPort
            let oldIDs = Set(circuit.map(\.id))
            next.topology.links.removeAll { oldIDs.contains($0.id) }
            let route = try next.patchLink(direct, level: trunk.arRouteLevel)
            let replacement = route.links.map { segment in
                var segment = segment
                if circuit.allSatisfy({ $0.arRouteLevel == trunk.arRouteLevel }) { segment.arRouteLevel = trunk.arRouteLevel }
                return segment
            }
            next.topology.links += replacement
            reviewed.subtract(oldIDs)
            reviewed.formUnion(replacement.map(\.id))
        }
        try next.topology.validate(layout: floorLevelLayout(next.layout))
        let pending = next.topology.pendingCableCircuits(in: next.layout)
        reviewed.subtract(next.topology.links.filter { pending.contains($0.circuitID ?? $0.id) }.map(\.id))
        if let assembly, let mounted {
            guard !mounted.conflicts(with: assembly, in: next.layout, topology: next.topology,
                                     previousTopology: topology, previousLayout: layout) else {
                throw LabLayoutError.invalid(LabARAssembly.collisionHint)
            }
            let plan = mounted.cablePlan(in: next.topology, layout: next.layout)
            let present = Set(plan.connections.filter(\.routed).map { $0.link.id })
            let relevant = next.topology.links.filter { link in
                let endpoints = next.topology.devices.filter { $0.id == link.fromDeviceID || $0.id == link.toDeviceID }
                return reviewed.contains(link.id) && endpoints.allSatisfy {
                    mounted.piece(.device($0.id)) != nil || mounted.piece(.support($0.placementID)) != nil
                }
            }
            guard relevant.allSatisfy({ present.contains($0.id) && !plan.overCapacityLinks.contains($0.id) }) else {
                throw LabLayoutError.invalid("Los cables no se pueden acomodar en ese montaje. Prueba otra unidad.")
            }
        } else if !reviewed.isEmpty {
            let plan = try LabCablePlan.make(next.topology, room: room, layout: next.layout)
            guard reviewed.isSubset(of: Set(plan.segments.map(\.link.id))) else {
                throw LabLayoutError.invalid("Los cables no se pueden acomodar en esa posición. Prueba otra unidad.")
            }
        }
        try Task.checkCancellation()
        return next
    }

    private func floorLevelLayout(_ layout: LabLayout) -> LabLayout {
        var normalized = layout
        normalized.placements = layout.placements.map {
            $0.at(SIMD3($0.position.x, layout.floorHeight, $0.position.z), yaw: $0.yaw)
        }
        return normalized
    }

    mutating func addServer(name: String, rackID: String, slot: Int) throws -> LabTopology.Device {
        try mount(.server, name: name, rackID: rackID, slot: slot)
    }

    mutating func mount(_ equipment: RackMount.Equipment, name: String, rackID: String, slot: Int,
                        deviceID: String = UUID().uuidString) throws -> LabTopology.Device {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = equipment.rawValue
        guard !title.isEmpty, title.count <= 80, topology.devices.count < 96,
              let rack = layout.placements.first(where: { $0.id == rackID }),
              availableSlots(in: rack, model: model).contains(slot) else {
            throw LabLayoutError.invalid("Elige un nombre y unidades libres contiguas para este equipo. Límite de 96 equipos.")
        }
        let device = LabTopology.Device(id: deviceID, name: title, modelID: model, placementID: rack.id,
            offset: RackMount.center(model, rackDepth: rack.size.z, slot: slot), services: [], ports: LabDemo.ports(model))
        appendDevice(device, drawingOffset: SIMD2(0, Float(slot + 1) * 12))
        return device
    }

    private mutating func appendDevice(_ device: LabTopology.Device, drawingOffset: SIMD2<Float>) {
        if let drawing = topology.logicalPlan {
            var positions = drawing.devicePositions
            let anchor = topology.devices.lazy.filter { $0.placementID == device.placementID }.compactMap { positions[$0.id] }.first
                ?? SIMD2((positions.values.map(\.x).max() ?? 0) + 50, 0)
            positions[device.id] = anchor + drawingOffset
            topology.logicalPlan = LabLogicalPlan(devicePositions: positions, areas: drawing.areas, labels: drawing.labels)
        }
        topology.devices.append(device)
    }
}

nonisolated struct LabServerServices: Codable, Equatable, Sendable {
    struct DNSRecord: Codable, Equatable, Sendable {
        var hostname: String
        var address: String
    }

    struct DHCPPool: Codable, Equatable, Sendable {
        var start: String
        var end: String
        var gateway: String?
        var dns: String?
    }

    var dns: DNSRecord?
    var dhcp: DHCPPool?
    var httpTitle: String?

    var summary: [String] {
        var rows: [String] = []
        if let dns { rows.append("DNS · \(dns.hostname) → \(dns.address)") }
        if let dhcp { rows.append("DHCP · \(dhcp.start) a \(dhcp.end)") }
        if let httpTitle { rows.append("HTTP · \(httpTitle)") }
        return rows
    }
}

nonisolated extension LabTopology {
    struct Port: Codable, Hashable, Identifiable, Sendable {
        let deviceID: String
        let name: String
        var id: Self { self }
    }

    static func fitsPlacement(_ placement: LabPlacement, in layout: LabLayout) -> Bool {
        guard placement.position.x.isFinite, placement.position.y.isFinite, placement.position.z.isFinite,
              placement.yaw.isFinite else { return false }
        let corners = corners(placement)
        return corners.allSatisfy { LabGeometry.contains($0, polygon: layout.floorPolygon) }
            && !corners.indices.contains { i in
                layout.floorPolygon.indices.contains { j in
                    Self.crosses(corners[i], corners[(i + 1) % corners.count],
                                 layout.floorPolygon[j], layout.floorPolygon[(j + 1) % layout.floorPolygon.count])
                }
            }
            && !layout.placements.contains { $0.id != placement.id && Self.overlaps($0, placement) }
            && !(layout.facility.map { facility in
                facility.fixtures.contains { fixture in
                    Self.overlaps(placement, .init(id: fixture.id, kind: .rack, title: fixture.name,
                        position: facility.world(fixture.position), yaw: facility.yaw + fixture.yaw, size: fixture.kind.size))
                }
            } ?? false)
    }

    func medium(at port: Port) -> Medium? {
        guard let device = devices.first(where: { $0.id == port.deviceID }), device.ports.contains(port.name) else { return nil }
        return Self.mediumForPort(modelID: device.modelID, port: port.name)
    }

    func suggestedVLAN(at port: Port) -> Int? {
        guard let device = devices.first(where: { $0.id == port.deviceID }) else { return nil }
        let names = Set([port.name, device.sourcePortNames?[port.name] ?? port.name].map { $0.lowercased() })
        var matchesPort = false
        for rawLine in device.configuration?.split(whereSeparator: \.isNewline) ?? [] {
            let parts = rawLine.lowercased().split(whereSeparator: \.isWhitespace)
            if parts.first == "interface" {
                matchesPort = parts.count == 2 && names.contains(String(parts[1]))
            } else if let command = parts.first, ["!", "exit", "end", "vlan"].contains(command) {
                matchesPort = false
            } else if matchesPort, parts.count == 4, parts.prefix(3).elementsEqual(["switchport", "access", "vlan"]),
                      let id = Int(parts[3]), vlans.contains(where: { $0.id == id }) {
                return id
            }
        }
        return device.vlan
    }

    func serviceRows(for device: Device) -> [String] {
        var rows = device.serverServices?.summary ?? []
        if device.serverServices?.dhcp != nil {
            let leases = devices.count { $0.leasedBy == device.id }
            rows.append("\(leases) \(leases == 1 ? "concesión DHCP" : "concesiones DHCP")")
        }
        return rows + device.services + (device.siteHosts ?? [])
    }

    func freePorts(on device: Device, matching medium: Medium? = nil) -> [Port] {
        guard device.allowsEthernet else { return [] }
        let occupied = Set(links.flatMap { [
            Port(deviceID: $0.fromDeviceID, name: $0.fromPort), Port(deviceID: $0.toDeviceID, name: $0.toPort)
        ] })
        return device.ports.compactMap { name in
            let port = Port(deviceID: device.id, name: name)
            guard let type = self.medium(at: port), [.copper, .fiber, .serial].contains(type),
                  medium == nil || type == medium, !occupied.contains(port), device.shutdownPorts?.contains(name) != true else { return nil }
            return port
        }
    }

    mutating func connect(_ from: Port, to: Port, vlans: [Int]) throws -> Link {
        guard links.count < 192, let source = devices.first(where: { $0.id == from.deviceID }),
              let target = devices.first(where: { $0.id == to.deviceID }), from.deviceID != to.deviceID,
              let medium = medium(at: from), freePorts(on: source).contains(from),
              freePorts(on: target, matching: medium).contains(to) else {
            throw LabLayoutError.invalid("Elige dos puertos libres, habilitados y compatibles.")
        }
        let link = Link(id: UUID().uuidString, fromDeviceID: from.deviceID, fromPort: from.name,
                        toDeviceID: to.deviceID, toPort: to.name, medium: medium, vlanIDs: vlans)
        var next = self
        next.links.append(link)
        if vlans.count == 1, let vlan = vlans.first {
            for index in next.devices.indices where [from.deviceID, to.deviceID].contains(next.devices[index].id) {
                let device = next.devices[index]
                if device.vlan == nil, device.ipv4 == nil, LabDeskEquipment(rawValue: device.visualModelID) != nil {
                    next.devices[index].vlan = vlan
                }
            }
        }
        try next.validate()
        self = next
        return link
    }

    mutating func configureClient(_ id: String, mode: LabClientConnection, accessPoint: String?) throws {
        guard let index = devices.firstIndex(where: { $0.id == id && $0.supportsWiFi }),
              devices[index].modelID != "pt-smartphone" || mode == .wifi else {
            throw LabLayoutError.invalid("Elige un equipo compatible con este modo de conexión.")
        }
        let selected = mode == .ethernet ? nil : accessPoint
        let access = devices.first { $0.id == selected && $0.isAccessPoint }
        guard selected == nil || access != nil else { throw LabLayoutError.invalid("El punto de acceso ya no está disponible.") }
        devices[index].connectionMode = mode
        devices[index].wifiAccessPointID = selected
        if let access, devices[index].vlan == nil, devices[index].ipv4 == nil {
            devices[index].vlan = access.vlan ?? links.first(where: {
                ($0.fromDeviceID == access.id || $0.toDeviceID == access.id) && !$0.vlanIDs.isEmpty
            })?.vlanIDs.first
        }
    }

    mutating func disconnect(_ id: String) {
        guard let link = links.first(where: { $0.id == id }) else { return }
        links.removeAll { ($0.circuitID ?? $0.id) == (link.circuitID ?? link.id) }
    }

    mutating func configureServer(_ id: String, name: String, address: String?, vlan: Int?,
                                  services: LabServerServices) throws {
        guard let index = devices.firstIndex(where: { $0.id == id && $0.visualModelID.hasPrefix("server-") }),
              !name.isEmpty, name.count <= 80 else { throw LabLayoutError.invalid("Escribe un nombre válido para el servidor.") }
        var device = devices[index]
        device.name = name
        device.vlan = vlan
        device.ipv4 = address
        device.leasedBy = nil
        if let address, !permitsAddress(address, for: device) {
            throw LabLayoutError.invalid("La IPv4 debe estar libre y pertenecer a la VLAN del servidor.")
        }
        if let dns = services.dns {
            let labels = dns.hostname.split(separator: ".", omittingEmptySubsequences: false)
            guard address != nil, dns.hostname.count <= 253, !labels.isEmpty,
                  labels.allSatisfy({ label in
                    (1...63).contains(label.count) && label.first != "-" && label.last != "-" &&
                    label.utf8.allSatisfy { (48...57).contains($0) || (97...122).contains($0) || $0 == 45 }
                  }), Self.ipv4(dns.address) != nil else {
                throw LabLayoutError.invalid("DNS necesita una IPv4 en el servidor y un registro A válido, como app.lab.")
            }
        }
        if let pool = services.dhcp {
            guard let address, let lo = Self.ipv4(pool.start), let hi = Self.ipv4(pool.end),
                  lo <= hi, permitsAddress(pool.start, for: device, requireUnused: false),
                  permitsAddress(pool.end, for: device, requireUnused: false),
                  !(lo...hi).contains(Self.ipv4(address) ?? 0),
                  pool.gateway.map({ permitsAddress($0, for: device, requireUnused: false) }) ?? true,
                  pool.dns.map({ Self.ipv4($0) != nil }) ?? true else {
                throw LabLayoutError.invalid("El rango DHCP debe quedar en la VLAN y excluir la IPv4 del servidor.")
            }
            let overlaps = devices.contains { other in
                guard other.id != id, other.vlan == vlan, let other = other.serverServices?.dhcp,
                      let lower = Self.ipv4(other.start), let upper = Self.ipv4(other.end), lower <= upper else { return false }
                return lower <= hi && upper >= lo
            }
            guard !overlaps else { throw LabLayoutError.invalid("Este rango DHCP se solapa con otro servidor de la VLAN.") }
        }
        if let title = services.httpTitle {
            guard address != nil, !title.isEmpty, title.count <= 80 else {
                throw LabLayoutError.invalid("HTTP necesita una IPv4 en el servidor y un título de hasta 80 caracteres.")
            }
        }
        device.serverServices = services.summary.isEmpty ? nil : services
        devices[index] = device
    }

    @discardableResult
    mutating func requestDHCP(for id: String, vlan: Int, poweredOff: Set<String> = []) throws -> String {
        guard let index = devices.firstIndex(where: { $0.id == id && $0.serverServices == nil }),
              vlans.contains(where: { $0.id == vlan }) else { throw LabLayoutError.invalid("Selecciona cliente y VLAN.") }
        let client = devices[index]
        var plan = self
        plan.devices[index].vlan = vlan
        let servers = devices.filter { server in
            server.id != id && server.vlan == vlan && server.serverServices?.dhcp != nil &&
                plan.switchedPath(from: id, to: server.id, vlan: vlan, poweredOff: poweredOff) != nil
        }
        let used = Set(devices.filter { $0.id != id }.compactMap { $0.ipv4.flatMap(Self.ipv4) })
        for server in servers {
            guard let pool = server.serverServices?.dhcp, let lower = Self.ipv4(pool.start),
                  let upper = Self.ipv4(pool.end), lower <= upper else { continue }
            let reserved = pool.gateway.flatMap(Self.ipv4)
            let previous = client.leasedBy == server.id ? client.ipv4.flatMap(Self.ipv4) : nil
            let leased = previous.flatMap { (lower...upper).contains($0) && !used.contains($0) && $0 != reserved ? $0 : nil }
            let free = leased ?? (UInt64(lower)...UInt64(upper)).lazy.map(UInt32.init).first { !used.contains($0) && $0 != reserved }
            guard let free else { continue }
            let address = [24, 16, 8, 0].map { String((free >> $0) & 255) }.joined(separator: ".")
            plan.devices[index].ipv4 = address
            plan.devices[index].leasedBy = server.id
            self = plan
            let options = [pool.gateway.map { "Puerta de enlace \($0)" }, pool.dns.map { "DNS \($0)" }].compactMap { $0 }
            return (["DHCP · \(address) · \(server.name)"] + options).joined(separator: "\n")
        }
        throw LabLayoutError.invalid(servers.isEmpty ? "Sin camino DHCP en la VLAN seleccionada." : "El rango DHCP está agotado.")
    }
}

nonisolated enum LabDemo {
    private static let allVLANs = [10, 20, 30, 40, 50]
    static let labServerID = "rack-app:server-1"
    static let vlanProfile = "vlan-demo"
    static let vlanName = "Demo de VLAN y ping"

    static func vlanLab() throws -> LabProject {
        let room = try virtualRoom(width: 6, depth: 4.8, height: 2.7)
        let rack = LabPlacement(id: "rack-demo", kind: .rack, title: "Rack de prácticas",
                                position: SIMD3(0, 0, -1.15), yaw: -.pi / 4, size: RackMount.Height.medium.size)
        let clients = [("PC-A", "192.168.10.11", 10), ("PC-B", "192.168.10.12", 10), ("PC-C", "192.168.20.13", 20)]
        let desks = clients.enumerated().map { index, client in
            LabPlacement(id: "puesto-\(client.0)", kind: .workstation, title: "Puesto \(client.0)",
                         position: SIMD3(Float(index - 1) * 1.65, 0, 1.15), yaw: 0, size: SIMD3(1.12, 1.25, 0.7))
        }
        let layout = LabLayout(area: 28.8, floorHeight: 0,
                               floorPolygon: [SIMD2(-3, -2.4), SIMD2(3, -2.4), SIMD2(3, 2.4), SIMD2(-3, 2.4)],
                               placements: [rack] + desks, warnings: [], importedRoom: true,
                               rackPDUs: [rack.id: .right])
        var topology = LabTopology(name: vlanName, devices: [], links: [], vlans: [
            .init(id: 10, name: "Puestos A y B", subnet: "192.168.10.0/24"),
            .init(id: 20, name: "Puesto C", subnet: "192.168.20.0/24")
        ], notes: [
            "PC-A → PC-B cruza el troncal 802.1Q en la VLAN 10. PC-B → PC-C cruza el router.",
            "La ACL de R-VLAN bloquea las solicitudes ICMP de 192.168.10.11 a 192.168.20.13 en Gi0/0.",
            "UPS-01 alimenta la PDU derecha. Apágalo en la ficha del UPS para comprobar el corte de red; vuelve a encenderlo para repetir.",
            "SRV-DEMO ofrece DNS, DHCP y HTTP simulados en VLAN 10. Las dos pantallas del rack muestran red y servicios."
        ], operationsProfile: vlanProfile)
        let mask = "255.255.255.0"
        for ((name, address, vlan), desk) in zip(clients, desks) {
            let model = "pc-optiplex7010"
            add(&topology, id: name, name: name, model: model, placement: desk,
                offset: SIMD3(0.37, HardwareCatalog.renderSize(model).y / 2 + 0.015, 0), ip: address, vlan: vlan)
            topology.devices[topology.devices.count - 1].packetTracer = .init(description: "", interfaces: [
                .init(port: "Ethernet", ipv4: address, mask: mask, gateway: "192.168.\(vlan).1", ospfArea: nil)
            ], dhcpPools: [], localConfiguration: true)
        }
        func mount(_ id: String, _ model: String, _ slot: Int, ip: String? = nil, vlan: Int? = nil, services: [String] = []) {
            add(&topology, id: id, name: id, model: model, placement: rack,
                offset: RackMount.center(model, rackDepth: rack.size.z, slot: slot), ip: ip, vlan: vlan, services: services)
        }
        mount("SW-A", "switch-2960", 19, services: ["Acceso y troncal 802.1Q"])
        mount("SW-B", "switch-2960", 16, services: ["Acceso y troncal 802.1Q"])
        mount("R-VLAN", "router-1941", 12, ip: "192.168.10.1", vlan: 10, services: ["Enrutamiento entre VLAN", "ACL ICMP"])
        let router = topology.devices.count - 1
        topology.devices[router].packetTracer = .init(description: "", interfaces: [
            .init(port: "GigabitEthernet0/0", ipv4: "192.168.10.1", mask: mask, gateway: nil, ospfArea: nil),
            .init(port: "GigabitEthernet0/1", ipv4: "192.168.20.1", mask: mask, gateway: nil, ospfArea: nil)
        ], dhcpPools: [], localConfiguration: true)
        topology.devices[router].icmpEchoDeny = .init(port: "GigabitEthernet0/0", source: clients[0].1, destination: clients[2].1)
        let server = "SRV-DEMO", serverIP = "192.168.10.20"
        mount(server, "server-c220m5", 6)
        try topology.configureServer(server, name: server, address: serverIP, vlan: 10, services: .init(
            dns: .init(hostname: "demo.lab", address: serverIP),
            dhcp: .init(start: "192.168.10.100", end: "192.168.10.109", gateway: "192.168.10.1", dns: serverIP),
            httpTitle: "Nexus AR · Laboratorio"))
        mount("UPS-01", LabRackPower.upsModel, 0, services: ["Respaldo de la PDU"])
        mount("VENT-RACK", RackMount.Equipment.fans.rawValue, 22)
        connect(&topology, "acceso-a", "PC-A", "Ethernet", "SW-A", "FastEthernet0/1", .copper, [10])
        connect(&topology, "acceso-b", "PC-B", "Ethernet", "SW-B", "FastEthernet0/1", .copper, [10])
        connect(&topology, "acceso-c", "PC-C", "Ethernet", "SW-A", "FastEthernet0/2", .copper, [20])
        connect(&topology, "troncal", "SW-A", "GigabitEthernet0/1", "SW-B", "GigabitEthernet0/1", .copper, [10, 20])
        connect(&topology, "gateway-vlan10", "SW-B", "GigabitEthernet0/2", "R-VLAN", "GigabitEthernet0/0", .copper, [10])
        connect(&topology, "gateway-vlan20", "SW-A", "GigabitEthernet0/2", "R-VLAN", "GigabitEthernet0/1", .copper, [20])
        connect(&topology, "servicios", server, "LOM1", "SW-B", "FastEthernet0/2", .copper, [10])
        var project = try LabProject(room: room, layout: layout, topology: topology).completingRackCabling()
        try project.setRoomRackMonitors([
            .init(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                  device: server, panel: .network, side: .left, row: 0),
            .init(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
                  device: server, panel: .services, side: .right, row: 0)
        ], rackID: rack.id)
        return project
    }

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
        return try LabProject(room: room, layout: layout, topology: topology).completingRackCabling()
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
        return try LabProject(room: room, layout: layout, topology: topology).completingRackCabling().topology
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
        return try LabProject(room: room, layout: layout, topology: topology, isHomeLab: true).completingRackCabling()
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

    static func ports(_ model: String, includingSerial: Bool = false) -> [String] {
        switch model {
        case "patch-copper", "patch-fiber":
            return (1...(model == "patch-copper" ? 24 : 12)).flatMap {
                let suffix = String(format: "%02d", $0)
                return ["F" + suffix, "R" + suffix]
            }
        case "switch-2960", "switch-3560": return (1...24).map { "FastEthernet0/\($0)" } + ["GigabitEthernet0/1", "GigabitEthernet0/2"]
        case "switch-3650": return (1...24).map { "GigabitEthernet1/0/\($0)" } + (1...4).map { "GigabitEthernet1/1/\($0)" }
        case "router-1941": return ["GigabitEthernet0/0", "GigabitEthernet0/1", "Console"]
        case "router-2811", "router-2911":
            let ethernet = model == "router-2811" ? ["FastEthernet0/0", "FastEthernet0/1"]
                : ["GigabitEthernet0/0", "GigabitEthernet0/1", "GigabitEthernet0/2"]
            let serial = includingSerial ? (0..<4).flatMap { ["Serial0/\($0)/0", "Serial0/\($0)/1"] } : []
            return ethernet + ["Console"] + serial
        case "firewall-asa5505": return (0...7).map { "Ethernet0/\($0)" }
        case "server-c220m5": return ["LOM1", "LOM2"]
        case "pt-server": return ["Ethernet", "Ethernet 2"]
        case "server-firewall": return ["P0", "P1", "P2"]
        case "phone-7960": return ["SW", "PC"]
        case "pc-optiplex7010", "laptop-latitude5420", "raspberry-pi5", "access-point", "camera-ip",
             "pt-desktop", "pt-laptop", "pt-access-point", "pt-printer": return ["Ethernet"]
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
                         yaw: placement.yaw, size: device.visualSize)
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
        guard device.ports.contains(name), let index = LabDemo.ports(device.modelID, includingSerial: true).firstIndex(of: name) else {
            throw LabLayoutError.invalid("Puerto \(name) ausente en \(device.name).")
        }
        let size = device.visualSize, w = size.x, h = size.y, d = size.z
        if let panel = networkPanel(device.visualModelID, port: name) {
            return .init(deviceID: device.id, name: name, point: panel.point, normal: panel.normal)
        }
        var point = SIMD3<Float>(0, 0, d / 2 + 0.004), normal = SIMD3<Float>(0, 0, 1)
        if name.hasPrefix("Serial"), let slotText = name.split(separator: "/").dropFirst().first,
           let slot = Int(slotText), let number = Int(name.suffix(1)) {
            point.x = w * (0.18 + Float(slot % 2) * 0.17) + (Float(number) - 0.5) * 0.027
            point.y = slot < 2 ? -h * 0.23 : h * 0.23
        } else if name == "Console" {
            point.x = w / 2 - 0.025
        } else {
            switch device.visualModelID {
            case "patch-copper", "patch-fiber":
                let count = LabDemo.ports(device.modelID).count / 2
                point.x = (Float(index / 2) - Float(count - 1) / 2) * (w - 0.045) / Float(count)
                normal.z = index.isMultiple(of: 2) ? -1 : 1
                point.z = normal.z * (d / 2 + 0.006)
                point.y = -0.004
            case "firewall-asa5505":
                point.x = -w / 2 + 0.027 + Float(index) * 0.021
            case "server-c220m5", "server-firewall": point.x = -0.04 + Float(index) * 0.024
            case "raspberry-pi5": point.x = w * 0.26; point.y = 0.002
            case "access-point", "pt-access-point", "camera-ip": point.y = -h * 0.12
            case "pt-printer": point.y = -h * 0.25
            case "pc-optiplex7010": point.y = h * 0.2
            case "laptop-latitude5420":
                point = SIMD3(w / 2 + 0.004, 0, d * 0.2); normal = SIMD3(1, 0, 0)
            case "phone-7960": point.x = -0.017 + Float(index) * 0.034; point.y = -h * 0.15
            default: throw LabLayoutError.invalid("Modelo sin anclaje de puerto visual: \(device.modelID).")
            }
        }
        return LabScenePort(deviceID: device.id, name: name, point: point, normal: normal)
    }

    static func networkPanel(_ model: String, port: String) -> (point: SIMD3<Float>, normal: SIMD3<Float>)? {
        guard ["switch-2960", "switch-3560", "switch-3650", "router-1941", "router-2811", "router-2911"].contains(model),
              let index = LabDemo.ports(model, includingSerial: true).firstIndex(of: port) else { return nil }
        let size = HardwareCatalog.renderSize(model)
        let w = size.x, h = size.y, d = size.z
        if model.hasPrefix("switch-") {
            let x: Float
            let y: Float
            if index < 24 {
                x = w / 2 - 0.061 - Float(index / 2) * 0.021 - Float(index / 12) * 0.012
                y = index.isMultiple(of: 2) ? 0.009 : -0.009
            } else if model == "switch-3650" {
                x = -w / 2 + 0.057 - Float((index - 24) / 2) * 0.022
                y = index.isMultiple(of: 2) ? 0.009 : -0.009
            } else {
                x = -w / 2 + 0.061 - Float(index - 24) * 0.024
                y = 0
            }
            return (.init(x, y, -d / 2 - 0.004), .init(0, 0, -1))
        }
        let rear = d / 2 + 0.004
        if port.hasPrefix("Serial"), let slot = port.split(separator: "/").dropFirst().first.flatMap({ Int($0) }),
           let jack = Int(port.suffix(1)) {
            let center = moduleCenter(model, slot: slot)
            return (.init(center.x + (Float(jack) - 0.5) * 0.026, center.y, rear), .init(0, 0, 1))
        }
        if port == "Console" {
            return model == "router-2811" ? (.init(-0.039, 0, -rear), .init(0, 0, -1))
                : (.init(-w * 0.29, -h * 0.26, rear), .init(0, 0, 1))
        }
        let x = model == "router-1941" ? 0.015 + Float(index) * 0.025 : -w * 0.37 + Float(index) * 0.022
        return (.init(x, model == "router-2811" ? -0.002 : -h * 0.26, rear), .init(0, 0, 1))
    }

    static func moduleCenter(_ model: String, slot: Int) -> SIMD2<Float> {
        if model == "router-2811" { return .init(-0.055 + Float(slot) * 0.064, -0.006) }
        return .init(0.059 + Float(slot % 2) * 0.085, slot < 2 ? -0.020 : 0.020)
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

nonisolated struct TierFixture: Identifiable, Sendable {
    enum Kind: Equatable, Sendable {
        case batteryBank, switchboard, cooling

        var size: SIMD3<Float> {
            switch self {
            case .batteryBank: HardwareCatalog.renderSize("rack-r42612")
            case .switchboard: SIMD3(0.51, 1.30, 0.24)
            case .cooling: HardwareCatalog.renderSize("cooling-inrow")
            }
        }
    }

    let id: String
    let kind: Kind
    let name: String
    let circuit: String
    let position: SIMD3<Float> // Relative to the Tier IV room origin.
    let yaw: Float
}

extension TierFacility {
    nonisolated var fixtures: [TierFixture] {
        [-1 as Float, 1].flatMap { side in
            let circuit = side < 0 ? "A" : "B"
            return [
                TierFixture(id: "bank-" + circuit, kind: .batteryBank, name: "UPS y baterías " + circuit,
                            circuit: circuit, position: SIMD3(side * 6.15, 0, -3.55), yaw: .pi),
                TierFixture(id: "board-" + circuit, kind: .switchboard, name: "Tablero eléctrico " + circuit,
                            circuit: circuit, position: SIMD3(side * 6.62, 0.33, -1.86), yaw: 0),
                TierFixture(id: "cooling-" + circuit + "1", kind: .cooling, name: "Refrigeración " + circuit + "1",
                            circuit: circuit, position: SIMD3(side * 1.84, 0, -2.1), yaw: .pi),
                TierFixture(id: "cooling-" + circuit + "2", kind: .cooling, name: "Refrigeración " + circuit + "2",
                            circuit: circuit, position: SIMD3(side * 1.84, 0, 0.95), yaw: 0)
            ]
        }
    }
}

nonisolated enum LabARFocus: Hashable, Sendable {
    case all, placement(String), device(String), fixture(String)

    func placementID(in topology: LabTopology?) -> String? {
        switch self {
        case .all, .fixture: nil
        case .placement(let id): id
        case .device(let id): topology?.devices.first(where: { $0.id == id })?.placementID
        }
    }

    func pivot(in layout: LabLayout, topology: LabTopology?) -> SIMD3<Float>? {
        if case .fixture(let id) = self, let facility = layout.facility,
           let fixture = facility.fixtures.first(where: { $0.id == id }) {
            return facility.world(fixture.position)
        }
        guard let id = placementID(in: topology), let placement = layout.placements.first(where: { $0.id == id })
        else { return nil }
        if case .device(let deviceID) = self,
           let device = topology?.devices.first(where: { $0.id == deviceID }) {
            let rotation = simd_quatf(angle: placement.yaw, axis: SIMD3(0, 1, 0))
            return placement.position + rotation.act(device.offset)
                - SIMD3(0, device.visualSize.y / 2, 0)
        }
        return placement.position
    }

    func size(in layout: LabLayout, topology: LabTopology?) -> SIMD3<Float>? {
        switch self {
        case .all: nil
        case .placement(let id): layout.placements.first { $0.id == id }?.size
        case .device(let id): topology?.devices.first { $0.id == id }?.visualSize
        case .fixture(let id): layout.facility?.fixtures.first { $0.id == id }?.kind.size
        }
    }

    func includes(_ device: LabTopology.Device) -> Bool {
        switch self {
        case .all: true
        case .placement(let id): device.placementID == id
        case .device(let id): device.id == id
        case .fixture: false
        }
    }
}

nonisolated enum LabCableFilter: Hashable {
    case medium(LabTopology.Medium), vlan(Int), rack(String)
}

nonisolated struct LabViewerSearchResult: Identifiable {
    var id: LabInspectionDestination { destination }
    let destination: LabInspectionDestination
    let name: String
    let detail: String

    static func find(_ query: String, devices: [LabTopology.Device], in layout: LabLayout) -> [Self] {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        let placements = Dictionary(uniqueKeysWithValues: layout.placements.map { ($0.id, $0.title) })

        func matches(_ term: String, in fields: [String]) -> Bool {
            fields.contains { $0.localizedStandardContains(term) }
        }

        return devices.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }.flatMap { device in
            let location = placements[device.placementID] ?? ""
            let identity = [device.name, location]
            var results: [Self] = []
            if terms.allSatisfy({ matches($0, in: identity + [device.ipv4 ?? ""]) }) {
                results.append(.init(destination: .init(deviceID: device.id), name: device.name,
                                     detail: [location, device.ipv4 ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")))
            }
            if !terms.isEmpty {
                let interfaces = device.packetTracer?.interfaces ?? []
                for port in device.ports {
                    let names = device.portNames(port)
                    let address = interfaces.first(where: { names.contains($0.port.lowercased()) })?.ipv4
                    let fields = names + [address ?? ""]
                    guard terms.contains(where: { matches($0, in: fields) }),
                          terms.allSatisfy({ matches($0, in: identity + fields) }) else { continue }
                    let label = device.sourcePortNames?[port] ?? port
                    results.append(.init(destination: .init(deviceID: device.id, port: port), name: device.name,
                                         detail: [label, address ?? "", location].filter { !$0.isEmpty }.joined(separator: " · ")))
                }
            }
            return results
        }
    }
}

nonisolated struct LabInspectionDestination: Hashable {
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
        let size = device.visualSize
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
    var interfaces: [String: LabTopology.PacketTracerDevice]? = nil
    var circuitVLANs: [String: [Int]]? = nil

    init() {}

    init(_ plan: LabTopology, against base: LabTopology) {
        let originals = Dictionary(uniqueKeysWithValues: base.devices.map { ($0.id, $0) })
        let originalRoutes = base.siteRoutes
        for device in plan.devices {
            guard let original = originals[device.id] else { continue }
            if device.name != original.name { names[device.id] = device.name }
            if device.ipv4 != original.ipv4 { addresses[device.id] = device.ipv4 }
            if device.shutdownPorts != original.shutdownPorts { ports[device.id] = device.shutdownPorts ?? [] }
            if let details = device.packetTracer, details != original.packetTracer {
                if interfaces == nil { interfaces = [:] }
                interfaces?[device.id] = details
            }
        }
        routes = plan.siteRoutes.filter { originalRoutes[$0.key] != $0.value }
        let originalsByLink = Dictionary(uniqueKeysWithValues: base.links.map { ($0.id, $0.vlanIDs) })
        for link in plan.links where link.vlanIDs != originalsByLink[link.id] {
            if circuitVLANs == nil { circuitVLANs = [:] }
            circuitVLANs?[link.id] = link.vlanIDs
        }
    }

    func apply(to base: LabTopology) -> LabTopology {
        guard self != Self() else { return base }
        var plan = base
        for i in plan.devices.indices {
            let id = plan.devices[i].id
            if let name = names[id] { plan.devices[i].name = name }
            if let address = addresses[id] { plan.devices[i].ipv4 = address }
            if let disabled = ports[id] { plan.devices[i].shutdownPorts = disabled.intersection(plan.devices[i].ports) }
            if let details = interfaces?[id] { plan.devices[i].packetTracer = details }
        }
        for i in plan.links.indices {
            if let vlans = circuitVLANs?[plan.links[i].id] { plan.links[i].vlanIDs = vlans }
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

    func permitsAddress(_ address: String, for device: Device, requireUnused: Bool = true) -> Bool {
        guard let number = Self.ipv4(address), let vlan = device.vlan,
              !requireUnused || !devices.contains(where: { $0.id != device.id && $0.ipv4.flatMap(Self.ipv4) == number }),
              let subnet = vlans.first(where: { $0.id == vlan })?.subnet else { return false }
        let fields = subnet.split(separator: "/")
        guard fields.count == 2, let network = Self.ipv4(String(fields[0])),
              let prefix = Int(fields[1]), (0...32).contains(prefix) else { return false }
        let mask = prefix == 0 ? 0 : UInt32.max << (32 - prefix)
        return number & mask == network && (prefix >= 31 || (number != network && number != (network | ~mask)))
    }
}

nonisolated struct LabOperationsSession: Sendable {
    enum Mode: String, Sendable {
        case user = ">", privileged = "#", configuration = "(config)#", interface = "(config-if)#"
    }

    let stationID: String
    var targetID: String
    var port: String?
    private(set) var mode: Mode = .user

    mutating func selectTarget(_ id: String) {
        targetID = id
        port = nil
        mode = .user
    }

    private static let syntax = [
        "enable", "disable", "exit", "end", "help", "?", "configure terminal", "write memory",
        "copy running-config startup-config", "show version", "show devices", "show ip route", "show ip interface brief",
        "show interfaces", "show interfaces status", "show interfaces trunk", "show vlan brief", "show vlans",
        "show services", "show running-config", "show startup-config", "show imported-config",
        "interface", "shutdown", "no shutdown", "description", "no description", "hostname",
        "switchport access vlan", "switchport mode trunk", "ip address", "ip default-gateway", "ip addr show", "ip show",
        "ipconfig /all", "connect", "site move", "resolve", "test", "ping", "traceroute", "tracert"
    ].map { $0.split(separator: " ").map(String.init) }

    private static let aliases = ["en": "enable", "enbl": "enable", "conf": "configure", "sh": "show",
                                  "int": "interface", "wr": "write"]

    func prediction(for input: String, device: LabTopology.Device, history: [String]) -> String? {
        let prefixes = input.split(whereSeparator: \.isWhitespace).map { $0.lowercased() }
        guard !prefixes.isEmpty else { return nil }
        let commands = Self.syntax.filter { words in
            if words.first == "switchport" || words.starts(with: ["show", "interfaces", "trunk"]) {
                return device.modelID.hasPrefix("switch-")
            }
            if words.first == "ipconfig" { return !device.modelID.hasPrefix("router-") && !device.modelID.hasPrefix("switch-") }
            if ["shutdown", "description", "no"].contains(words[0]) { return port != nil }
            return true
        }.map { $0.joined(separator: " ") }
        let ports = device.ports.map { "interface " + (device.sourcePortNames?[$0] ?? $0) }
        return (Array(history.reversed()) + ports + commands).first { candidate in
            let words = candidate.split(whereSeparator: \.isWhitespace).map { $0.lowercased() }
            guard words.count >= prefixes.count, words != prefixes else { return false }
            return zip(words, prefixes).enumerated().allSatisfy { index, pair in
                let (word, prefix) = pair
                return word.hasPrefix(prefix) || (index == 0 && Self.aliases[prefix] == word)
            }
        }
    }

    static let help = """
    enable / disable · cambiar modo EXEC
    configure terminal / end / exit · cambiar modo de configuración
    ipconfig /all · IPv4, máscara y puerta de enlace
    hostname · nombre del equipo seleccionado
    show devices · inventario y direcciones
    connect <equipo> · elegir por ID, nombre o IP
    show interfaces [puerto] / show ip interface brief · estado y cableado
    show services · servicios y dominios
    show running-config / show startup-config · configuración guardada
    show version / show vlan brief / show interfaces trunk / show ip route
    show imported-config · configuración original del archivo PKT
    resolve <dominio> · DNS del plano
    test <equipo> <puerto TCP> · política y camino entre VLAN
    interface <puerto> · elegir interfaz
    description <texto> / no description · editar descripción
    shutdown / no shutdown · cambiar estado
    hostname <nombre> · renombrar equipo
    ip address <IPv4> [máscara] · asignar dirección
    ip default-gateway <IPv4> · configurar puerta de enlace en la interfaz
    switchport access vlan <ID> / switchport mode trunk · cambiar VLAN del circuito
    write memory / copy running-config startup-config · confirmar guardado automático
    site move <dominio> <servidor> · cambiar destino
    ping / traceroute / tracert <equipo o IPv4> · consultar recorrido simulado
    """

    mutating func execute(_ line: String, on plan: inout LabTopology,
                          poweredOff: Set<String> = [], editingAllowed: Bool? = nil) -> String {
        guard line.utf8.count <= 2048 else { return "El comando supera el límite de 2048 bytes." }
        var words = line.split(whereSeparator: \.isWhitespace).map(String.init)
        if words.first?.lowercased() == "do" { words.removeFirst() }
        if let first = words.first, let full = Self.aliases[first.lowercased()] { words[0] = full }
        if words.count == 2 && words[0].lowercased() == "ip" && words[1].lowercased() == "addr" {
            words.append("show")
        }
        if words.count > 1 && words[0].lowercased() == "show" && ["run", "start"].contains(words[1].lowercased()) {
            words[1] = words[1].lowercased() == "run" ? "running-config" : "startup-config"
        }
        for index in words.indices {
            let prefix = words[index].lowercased()
            let previous = words.prefix(index).map { $0.lowercased() }
            let matches = Set(Self.syntax.filter { $0.count > index && $0.starts(with: previous) && $0[index].hasPrefix(prefix) }
                .map { $0[index] })
            if matches.contains(prefix) { continue }
            if matches.count > 1 { return "Comando ambiguo: \(words.prefix(index + 1).joined(separator: " "))." }
            guard let unique = matches.first else { break }
            words[index] = unique
        }
        let command = words.map { $0.lowercased() }
        guard let verb = command.first else { return "" }
        guard let index = plan.devices.firstIndex(where: { $0.id == targetID }) else { return "Equipo no disponible." }
        let device = plan.devices[index]
        let readOnly = "Este equipo está disponible para consulta."
        let canEdit = !device.modelID.hasPrefix("patch-") && (editingAllowed ?? (plan.operationsProfile != nil || plan.editableProfileID != nil))
        func resolvePort(_ argument: String) -> String? {
            device.ports.first { device.portNames($0).contains(argument.lowercased()) }
        }
        func cable(for port: String) -> LabTopology.Link? {
            plan.links.first {
                ($0.fromDeviceID == device.id && $0.fromPort == port) || ($0.toDeviceID == device.id && $0.toPort == port)
            }
        }
        let primaryPort = device.packetTracer?.interfaces.first(where: { device.ipv4 != nil && $0.ipv4 == device.ipv4 })?.port
            ?? device.ports.first { [.copper, .fiber].contains(plan.medium(at: .init(deviceID: device.id, name: $0))) }
        let subnet = plan.vlans.first { $0.id == device.vlan }?.subnet
        let subnetMask = subnet?.split(separator: "/").last.flatMap { prefix in
            Int(prefix).flatMap { (0...32).contains($0) ? Self.maskText(prefix: $0) : nil }
        }
        func settings(_ port: String) -> LabTopology.PacketTracerDevice.Interface {
            device.packetTracer?.interfaces.first { $0.port == port } ?? .init(port: port,
                ipv4: port == primaryPort ? device.ipv4 : nil, mask: port == primaryPort ? subnetMask : nil,
                gateway: nil, ospfArea: nil, dhcp: nil, fromLease: nil, dhcpServer: nil, description: nil)
        }
        func update(_ configuration: LabTopology.PacketTracerDevice.Interface) -> LabTopology.PacketTracerDevice {
            var details = device.packetTracer ?? .init(description: "", interfaces: [], dhcpPools: [], localConfiguration: true)
            if let i = details.interfaces.firstIndex(where: { $0.port == configuration.port }) {
                details.interfaces[i] = configuration
            } else { details.interfaces.append(configuration) }
            return details
        }
        func find(_ text: String) -> LabTopology.Device? {
            let matches = plan.devices.filter { [$0.id, $0.name, $0.ipv4 ?? ""].contains { $0.caseInsensitiveCompare(text) == .orderedSame } }
            return matches.count == 1 ? matches.first : nil
        }
        func isDown(_ device: LabTopology.Device) -> Bool {
            poweredOff.contains(device.id) || poweredOff.contains(device.placementID)
        }
        switch command {
        case ["help"], ["?"]:
            return Self.help
        case ["enable"]:
            mode = .privileged
            port = nil
            return "Modo EXEC privilegiado."
        case ["disable"], ["exit"], ["end"]:
            if verb == "exit" && mode == .interface { mode = .configuration }
            else if verb == "end" || (verb == "exit" && mode == .configuration) { mode = .privileged }
            else { mode = .user }
            port = nil
            return "Modo \(mode.rawValue)"
        case ["configure", "terminal"], ["configure", "t"]:
            guard canEdit else { return readOnly }
            guard mode != .user else { return "Usa enable antes de configure terminal." }
            mode = .configuration
            port = nil
            return "Introduce los comandos de configuración. Usa end para salir."
        case ["write"], ["write", "memory"], ["copy", "running-config", "startup-config"], ["copy", "run", "start"]:
            return canEdit ? "La consola guarda cada cambio válido al ejecutarlo." : readOnly
        case ["show", "version"]:
            return "Nexus AR · simulador de laboratorio\nModelo: \(device.sourceModel ?? device.visualModelID)\nEquipo: \(device.name)\nInterfaces: \(device.ports.count)"
        case ["show", "ip", "route"]:
            let rows = device.ports.compactMap { port -> String? in
                let config = settings(port)
                guard !isDown(device), device.shutdownPorts?.contains(port) != true,
                      let ip = config.ipv4.flatMap(LabTopology.ipv4), let mask = config.mask.flatMap(LabTopology.ipv4) else { return nil }
                return "C  \(Self.ipText(ip & mask))/\(mask.nonzeroBitCount) · \(device.sourcePortNames?[port] ?? port)"
            }
            return (["Redes directamente conectadas"] + (rows.isEmpty ? ["Sin redes conectadas."] : rows)).joined(separator: "\n")
        case ["ipconfig"], ["ipconfig", "/all"], ["ip", "addr"], ["ip", "show"], ["ip", "addr", "show"]:
            let network = plan.vlans.first { $0.id == device.vlan }
            let detailed = command == ["ipconfig", "/all"]
            let interfaces = device.ports.map(settings).filter { $0.ipv4 != nil || $0.dhcp == true }
            if !interfaces.isEmpty && (detailed || (device.packetTracer != nil && device.leasedBy == nil && device.serverServices == nil)) {
                return ([device.name] + interfaces.map {
                    let address = $0.ipv4.flatMap { $0.isEmpty ? nil : $0 } ?? "Sin dirección"
                    let origin = $0.fromLease == true ? " (concesión DHCP del archivo)" : ""
                    return "\(device.sourcePortNames?[$0.port] ?? $0.port)\n  IPv4: \(address)\(origin)\n  Máscara: \($0.mask ?? "—")\n  Puerta de enlace: \($0.gateway ?? "—")"
                }).joined(separator: "\n")
            }
            let origin = device.leasedBy.flatMap { id in plan.devices.first { $0.id == id }?.name }
            let status = [device.name, "IPv4: \(device.ipv4 ?? "Sin dirección")",
                          "VLAN: \(device.vlan.map(String.init) ?? "—")", "Subred: \(network?.subnet ?? "—")"]
            return (status + [origin.map { "Concesión DHCP: " + $0 }].compactMap { $0 }).joined(separator: "\n")
        case ["hostname"]: return device.name
        case ["show", "devices"]:
            return plan.devices.filter { !$0.modelID.hasPrefix("patch-") }.map {
                "\($0.id) · \($0.name) · \($0.ipv4 ?? "Sin IPv4")"
            }.joined(separator: "\n")
        case ["show", "vlans"], ["show", "vlan"], ["show", "vlan", "brief"]:
            return plan.vlans.isEmpty ? "Sin VLAN definidas." : plan.vlans.map { vlan in
                let ports = device.ports.filter { cable(for: $0)?.vlanIDs == [vlan.id] }
                return "\(vlan.id) · \(vlan.name) · \(vlan.subnet)" + (ports.isEmpty ? "" : " · " + ports.joined(separator: ", "))
            }.joined(separator: "\n")
        case ["show", "services"]:
            let services = plan.serviceRows(for: device)
            return services.isEmpty ? "Sin servicios asignados." : services.joined(separator: "\n")
        case ["show", "interfaces", "trunk"]:
            let trunks = device.ports.compactMap { port -> String? in
                guard let ids = cable(for: port)?.vlanIDs, ids.count > 1 else { return nil }
                return port + " · VLAN " + ids.map(String.init).joined(separator: ", ")
            }
            return trunks.isEmpty ? "Sin enlaces con varias VLAN." : trunks.joined(separator: "\n")
        case _ where command.starts(with: ["show", "interfaces"]) || command.starts(with: ["show", "interface"])
                || command == ["show", "ip", "interface", "brief"]:
            guard !device.ports.isEmpty else { return "Equipo sin interfaces de red." }
            let brief = command.count == 2 || command == ["show", "interfaces", "status"] || command == ["show", "ip", "interface", "brief"]
            let ports: [String]
            if brief { ports = device.ports }
            else if let match = resolvePort(words.dropFirst(2).joined()) { ports = [match] }
            else { return "Puerto desconocido. Usa show interfaces." }
            return ports.map { port in
                let link = cable(for: port)
                let available = link.map { plan.circuit(for: $0).allSatisfy { cable in
                    [(cable.fromDeviceID, cable.fromPort), (cable.toDeviceID, cable.toPort)].allSatisfy { endpoint in
                        guard let item = plan.devices.first(where: { $0.id == endpoint.0 }) else { return false }
                        return !isDown(item) && item.allowsEthernet && item.shutdownPorts?.contains(endpoint.1) != true
                    }
                } } ?? false
                let state = if !device.allowsEthernet || device.shutdownPorts?.contains(port) == true { "Deshabilitado" }
                    else if link == nil { "Sin cable" } else if available { "Enlace activo" } else { "Enlace caído" }
                let config = settings(port)
                let details = [device.sourcePortNames?[port] ?? port, state, link.map { $0.circuitID ?? $0.id }]
                if command == ["show", "ip", "interface", "brief"] {
                    return "\(details[0] ?? port) · \(config.ipv4 ?? "Sin IPv4") · \(state)"
                }
                return (details + (brief ? [] : [config.ipv4, config.mask, config.description])).compactMap { $0 }.joined(separator: " · ")
            }.joined(separator: "\n")
        case ["show", "running-config"], ["show", "run"], ["show", "startup-config"], ["show", "start"]:
            var rows = ["hostname \(device.name)"]
            if let rule = device.icmpEchoDeny {
                rows += ["ip access-list extended \(LabTopology.ICMPEchoDeny.name)",
                         " deny icmp host \(rule.source) host \(rule.destination) echo", " permit ip any any"]
            }
            for port in device.ports {
                let config = settings(port)
                let disabled = device.shutdownPorts?.contains(port) == true
                let vlans = cable(for: port)?.vlanIDs ?? []
                guard disabled || config.ipv4 != nil || config.description != nil || config.gateway != nil || !vlans.isEmpty else { continue }
                rows.append("interface \(device.sourcePortNames?[port] ?? port)")
                if let description = config.description { rows.append(" description \(description)") }
                if let address = config.ipv4 { rows.append(" ip address \(address) \(config.mask ?? "")") }
                if let gateway = config.gateway { rows.append(" ip default-gateway \(gateway)") }
                if device.icmpEchoDeny?.port == port { rows.append(" ip access-group \(LabTopology.ICMPEchoDeny.name) in") }
                if !vlans.isEmpty { rows.append(" ! VLAN del enlace: " + vlans.map(String.init).joined(separator: ", ")) }
                if disabled { rows.append(" shutdown") }
            }
            return rows.joined(separator: "\n")
        case ["show", "imported-config"]:
            return device.configuration ?? "Sin configuración original importada."
        case ["shutdown"], ["no", "shutdown"]:
            guard canEdit else { return readOnly }
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
            selectTarget(next.id)
            return "Consola del plano · \(next.name)"
        case "interface":
            guard let match = resolvePort(words.dropFirst().joined()) else {
                return "Puerto desconocido. Usa show interfaces."
            }
            port = match
            if mode == .configuration || mode == .interface { mode = .interface }
            return "Interfaz seleccionada · \(match)"
        case "hostname":
            guard canEdit else { return readOnly }
            guard !argument.isEmpty, argument.count <= 63,
                  argument.allSatisfy({ $0.isLetter || $0.isNumber || "-_".contains($0) }),
                  !plan.devices.contains(where: { $0.id != device.id && $0.name.caseInsensitiveCompare(argument) == .orderedSame })
            else { return "Usa un nombre único, de hasta 63 caracteres, con letras, números, guion o guion bajo." }
            plan.devices[index].name = argument
            return "Nombre guardado · \(argument)"
        case _ where verb == "description" || command == ["no", "description"]:
            guard canEdit else { return readOnly }
            guard let port else { return "Elige un puerto con interface <puerto>." }
            guard verb == "no" || (!argument.isEmpty && !argument.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)) else {
                return "Usa description <texto>."
            }
            var details = settings(port)
            let description = verb == "no" ? nil : argument
            if details.description != description {
                details.description = description
                plan.devices[index].packetTracer = update(details)
            }
            return description.map { "Descripción guardada · " + $0 } ?? "Descripción eliminada."
        case "ip" where (3...4).contains(command.count) && command[1] == "address":
            guard canEdit else { return readOnly }
            guard let selected = port ?? primaryPort,
                  [.copper, .fiber, .serial].contains(plan.medium(at: .init(deviceID: device.id, name: selected))) else {
                return "Elige una interfaz de red con interface <puerto>."
            }
            let address = words[2]
            var details = settings(selected)
            let mask = words.count == 4 ? words[3] : details.mask ?? subnetMask
            let isPrimary = selected == primaryPort || device.ipv4 == nil
            let duplicate = plan.devices.contains { peer in
                (peer.id != device.id && peer.ipv4 == address) || (peer.packetTracer?.interfaces.contains {
                    (peer.id != device.id || $0.port != selected) && $0.ipv4 == address
                } ?? false)
            }
            guard let number = LabTopology.ipv4(address), !duplicate else { return "Usa una IPv4 válida y libre." }
            guard let mask, let bits = LabTopology.ipv4(mask), bits != 0,
                  (~bits & (~bits &+ 1)) == 0 else { return "Indica una máscara de subred válida." }
            let network = number & bits
            guard bits.nonzeroBitCount >= 31 || (number != network && number != network | ~bits) else {
                return "Usa una dirección de host de la subred."
            }
            if isPrimary, device.vlan != nil, device.packetTracer == nil || device.packetTracer?.localConfiguration == true,
               (!plan.permitsAddress(address, for: device) || subnetMask != mask) {
                return "Usa una IPv4 libre con la máscara de la VLAN de este equipo."
            }
            if isPrimary {
                plan.devices[index].ipv4 = address
                if plan.editableProfileID != nil { plan.devices[index].leasedBy = nil }
            }
            // Generated profiles derive their primary mask from the VLAN. Keep legacy simple IP edits that way.
            if device.packetTracer != nil || words.count == 4 || !isPrimary || device.vlan == nil {
                details.ipv4 = address
                details.mask = mask
                details.dhcp = nil
                details.fromLease = nil
                details.dhcpServer = nil
                plan.devices[index].packetTracer = update(details)
            }
            return "IPv4 guardada · \(address)"
        case "ip" where command.count == 3 && command[1] == "default-gateway":
            guard canEdit else { return readOnly }
            guard let selected = port ?? primaryPort else { return "Elige una interfaz de red." }
            var details = settings(selected)
            guard let address = details.ipv4.flatMap(LabTopology.ipv4), let mask = details.mask.flatMap(LabTopology.ipv4),
                  let gateway = LabTopology.ipv4(words[2]), gateway != address, gateway & mask == address & mask else {
                return "Configura primero una IPv4 y usa una puerta de enlace en su subred."
            }
            details.gateway = words[2]
            plan.devices[index].packetTracer = update(details)
            return "Puerta de enlace guardada · \(words[2])"
        case "switchport" where command.starts(with: ["switchport", "access", "vlan"]) || command == ["switchport", "mode", "trunk"]:
            guard canEdit else { return readOnly }
            guard device.modelID.hasPrefix("switch-"), let port, let link = cable(for: port),
                  link.medium == .copper || link.medium == .fiber else {
                return "Elige un puerto Ethernet cableado de un switch."
            }
            let vlans: [Int]
            if command.count == 4, let vlan = Int(command[3]), plan.vlans.contains(where: { $0.id == vlan }) {
                vlans = [vlan]
            } else if command == ["switchport", "mode", "trunk"], !plan.vlans.isEmpty {
                vlans = plan.vlans.map(\.id).sorted()
            } else { return "Indica una VLAN existente con switchport access vlan <ID>." }
            let ids = Set(plan.circuit(for: link).map(\.id))
            for segment in plan.links.indices where ids.contains(plan.links[segment].id) { plan.links[segment].vlanIDs = vlans }
            return "VLAN del circuito · " + vlans.map(String.init).joined(separator: ", ")
        case "site" where command.count >= 4 && command[1] == "move":
            guard plan.operationsProfile != nil else { return "La topología importada es de consulta." }
            let host = command[2]
            guard plan.siteRoutes[host] != nil else { return "Dominio desconocido en este plano." }
            guard let server = find(words.dropFirst(3).joined(separator: " ")), server.modelID == "server-c220m5" else {
                return "Indica el ID o nombre de un servidor del inventario."
            }
            plan.assign(host: host, to: server.id)
            return "\(host) → \(server.name) · Asignación del plano"
        case "resolve":
            guard plan.operationsProfile != nil || plan.editableProfileID != nil else {
                return "Configura un servidor DNS en una copia editable o abre una plantilla."
            }
            let dnsName = argument.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return plan.resolveSimulatedDNS(dnsName, from: device, poweredOff: poweredOff)
        case "test" where command.count >= 3:
            guard plan.operationsProfile != nil || plan.editableProfileID != nil else { return "Para esta importación, usa ping." }
            guard let last = command.last, let tcp = Int(last), (1...65535).contains(tcp),
                  let endpoint = find(words.dropFirst().dropLast().joined(separator: " ")) else {
                return "Usa test <equipo> <puerto TCP del plano>."
            }
            return plan.testNetwork(from: device, to: endpoint, tcp: tcp, poweredOff: poweredOff)
        case "ping", "traceroute", "tracert":
            guard !argument.isEmpty else { return "Usa \(verb) <equipo o IPv4>." }
            guard let endpoint = find(argument), let address = endpoint.ipv4 else {
                return "\(verb): cannot resolve \(argument): Unknown host"
            }
            let diagnostic = plan.diagnosePing(from: device, to: endpoint, poweredOff: poweredOff)
            if verb != "ping" {
                let hops = (diagnostic.path?.devices.dropFirst() ?? []).enumerated().map { i, device in
                    "\(i + 1)  \(device.name)  \(device.ipv4 ?? "")"
                }
                return (["Recorrido simulado a \(address)"] + hops + [diagnostic.issue].compactMap { $0 }).joined(separator: "\n")
            }
            let route = diagnostic.issue == nil ? diagnostic.path?.devices : nil
            let output = Self.pingOutput(address: address, route: route)
            if plan.operationsProfile == LabDemo.vlanProfile, let issue = diagnostic.issue {
                return output + "\n" + issue
            }
            return output
        default:
            return "Comando desconocido. Usa help."
        }
    }

    private static func maskText(prefix: Int) -> String {
        ipText(prefix == 0 ? 0 : UInt32.max << (32 - prefix))
    }

    private static func ipText(_ value: UInt32) -> String {
        [24, 16, 8, 0].map { String((value >> $0) & 255) }.joined(separator: ".")
    }

    private static func pingOutput(address: String, route: [LabTopology.Device]?) -> String {
        let locale = Locale(identifier: "en_US_POSIX")
        let ttl = 64 - min(63, route?.dropFirst().dropLast().filter { $0.modelID.hasPrefix("router-") }.count ?? 0)
        let sample = LabTopology.PingSample(hops: route?.count)
        let times = sample.times
        func ms(_ value: Double) -> String { String(format: "%.3f", locale: locale, value) }
        var output = ["PING \(address) (\(address)): 56 data bytes"]
        for index in 0..<sample.sent {
            output.append(times.isEmpty ? "Request timeout for icmp_seq \(index)"
                : "64 bytes from \(address): icmp_seq=\(index) ttl=\(ttl) time=\(ms(times[index])) ms")
        }
        output += ["", "--- \(address) ping statistics ---",
                   "\(sample.sent) packets transmitted, \(sample.received) packets received, \(sample.loss).0% packet loss"]
        if let route, let mean = sample.mean, let minimum = times.min(), let maximum = times.max() {
            output += ["round-trip min/avg/max/stddev = \(ms(minimum))/\(ms(mean))/\(ms(maximum))/0.022 ms",
                       "", "Ruta simulada · " + route.map(\.name).joined(separator: " → ")]
        }
        return output.joined(separator: "\n")
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
        var points: [SIMD3<Float>]
        var pickingPath: [SIMD3<Float>]
        let bendRadius: Float
        var length: Float { zip(points, points.dropFirst()).reduce(0) { $0 + simd_distance($1.0, $1.1) } }
    }

    var segments: [Segment] = []
    var guides: [LabCablePacking.Guide] = []
    var anchors: [LabCablePacking.Anchor] = []
    var terminations: [LabCablePacking.Termination] = []
    var organizers: [LabCablePacking.Organizer] = []
    var channelHeight: Float = 0
    var ceiling: Float = 0
    var reviewCount = 0

    static func make(_ topology: LabTopology, room: RoomStructure, layout: LabLayout) throws -> Self {
        let ceiling = room.surfaces.filter { $0.kind == .wall }.map {
            $0.transformColumnMajor[13] + $0.dimensions[1] / 2
        }.min()
        let top = layout.placements.map { $0.position.y + $0.size.y }.max() ?? layout.floorHeight
        let level: LabCableLevel = ceiling.map { $0 - top > 0.28 } == true ? .overhead : .floor
        var installation = LabARAssembly(id: UUID(), name: "")
        for placement in layout.placements {
            let item = LabARAssembly.Item.support(placement.id)
            installation.set(.init(id: item, position: placement.position, yaw: placement.yaw))
            installation.setLevel(level, for: item)
            for monitor in layout.rackMonitors?[placement.id] ?? [] { installation.set(monitor.piece(on: placement)) }
        }
        for accessory in layout.accessories ?? [] { installation.set(accessory) }
        let route = installation.cablePlan(in: topology, layout: layout, virtualCeiling: ceiling)
        let devices = Dictionary(uniqueKeysWithValues: topology.devices.map { ($0.id, $0) })
        let segments = try route.connections.filter(\.routed).map { connection -> Segment in
            let link = connection.link
            guard let from = devices[link.fromDeviceID], let to = devices[link.toDeviceID] else {
                throw LabLayoutError.invalid("Conexión con equipo inexistente.")
            }
            let a = try LabScenePort.world(from, link.fromPort, in: layout)
            let b = try LabScenePort.world(to, link.toPort, in: layout)
            let path = connection.points
            let picking = path.dropLast().enumerated().compactMap { $0.offset.isMultiple(of: 3) ? $0.element : nil }
            return .init(link: link, endpoints: [a, b], points: path, pickingPath: picking + path.suffix(1),
                         bendRadius: link.medium.referenceBendRadius)
        }
        return .init(segments: segments, guides: route.channels, anchors: route.anchors,
                     terminations: route.terminations, organizers: route.organizers, channelHeight: route.overhead,
                     ceiling: ceiling ?? 0, reviewCount: route.reviewCount + route.overCapacityLinks.count)
    }

    func csv(for topology: LabTopology) -> String {
        let names = Dictionary(uniqueKeysWithValues: topology.devices.map { ($0.id, $0.name) })
        let paths = Dictionary(uniqueKeysWithValues: segments.map { ($0.link.id, $0) })
        let locale = Locale(identifier: "en_US_POSIX")
        let header = "Etiqueta,Circuito,Equipo A,Puerto A,Equipo B,Puerto B,Medio,VLAN,Longitud simulada (m),Radio modelo (mm),Trazado"
        let rows = topology.links.map { link in
            let path = paths[link.id]
            let length = path.map { String(format: "%.3f", locale: locale, $0.length) } ?? ""
            var radius = "", route = "Sin recorrido válido"
            if let path {
                route = path.bendRadius > 0 ? "Simulado" : "Aproximado"
                if path.bendRadius > 0 { radius = String(format: "%.0f", locale: locale, path.bendRadius * 1000) }
            }
            let fields = [link.id, link.circuitID ?? link.id, names[link.fromDeviceID] ?? link.fromDeviceID, link.fromPort,
                    names[link.toDeviceID] ?? link.toDeviceID, link.toPort, link.medium.title,
                    link.vlanIDs.map(String.init).joined(separator: " "), length, radius, route]
            return fields.map { value in
                let safe = value.first.map { "=+-@".contains($0) } == true ? "'" + value : value
                return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            }.joined(separator: ",")
        }
        return ([header] + rows).joined(separator: "\r\n") + "\r\n"
    }
}

nonisolated struct LabCablePacking {
    static let rackBundleScale: Float = 0.18

    static func supportAnchor(for contact: Float, onCeiling: Bool, floor: Float, ceiling: Float?) -> Float {
        guard onCeiling else { return floor }
        if let ceiling, ceiling > contact + 0.006 { return ceiling }
        return contact + 0.20
    }

    struct Path: Sendable {
        let link: LabTopology.Link
        let points: [SIMD3<Float>]
    }

    struct Run: Sendable {
        let start: SIMD3<Float>
        let end: SIMD3<Float>
        let links: [LabTopology.Link]

        var occupiedArea: Float {
            links.reduce(0) { area, link in
                let radius = link.medium.cableRadius
                return area + .pi * radius * radius
            }
        }

        func guide(offsets: [String: SIMD3<Float>], offsetScale: Float = 1) -> Guide {
            let largest = SIMD2<Float>(0.20, 0.10)
            let sizes: [SIMD2<Float>] = [.init(0.05, 0.025), .init(0.10, 0.04),
                                        .init(0.15, 0.06), .init(0.12, 0.08), largest]
            let axis = simd_normalize(end - start)
            let (side, up) = LabCablePacking.frame(along: axis)
            let clearance = links.reduce(SIMD2<Float>.zero) { envelope, link in
                let offset = (offsets[link.id] ?? .zero) * offsetScale
                return simd_max(envelope, simd_abs(SIMD2(simd_dot(offset, side), simd_dot(offset, up)))
                    + SIMD2(repeating: link.medium.cableRadius + 0.002))
            }
            // Reserve space for pulling and adding cables. The 40% value describes this planning model.
            let area = occupiedArea
            let size = sizes.first { area <= 0.40 * $0.x * $0.y && 2 * clearance.x <= $0.x && 2 * clearance.y <= $0.y }
            return .init(start: start, end: end, size: size ?? largest, cableCount: links.count,
                         overCapacity: size == nil || links.contains { offsets[$0.id] == nil })
        }
    }

    struct Guide: Sendable {
        let start: SIMD3<Float>
        let end: SIMD3<Float>
        let size: SIMD2<Float>
        let cableCount: Int
        let overCapacity: Bool
    }

    struct Termination: Sendable, Hashable {
        let point: SIMD3<Float>
        let yaw: Float
        let side: RackMount.Side?

        var rack: Bool { side != nil }
    }

    struct Organizer: Sendable {
        enum Mount: Sendable {
            case horizontal(rows: ClosedRange<Float>)
            case vertical(x: Float, heights: ClosedRange<Float>)
            case depthRun(ports: ClosedRange<Float>, rows: ClosedRange<Float>, span: ClosedRange<Float>)
        }

        let rack: Anchor
        let face: RackMount.CableFace
        let mount: Mount
        var routeDepth: Float? = nil
        var portDepth: Float? = nil

        var depth: Float { routeDepth ?? face.channelDepth(in: rack.size) }
        var railX: Float { face == .front ? RackMount.frontRailX : rack.size.x / 2 - 0.019 }
    }

    static func groupedOrganizers(_ organizers: [Organizer]) -> [Organizer] {
        func joined(_ a: ClosedRange<Float>, _ b: ClosedRange<Float>) -> ClosedRange<Float> {
            min(a.lowerBound, b.lowerBound)...max(a.upperBound, b.upperBound)
        }
        func near(_ a: ClosedRange<Float>, _ b: ClosedRange<Float>, gap: Float) -> Bool {
            a.lowerBound <= b.upperBound + gap && b.lowerBound <= a.upperBound + gap
        }
        var grouped: [Organizer] = []
        for organizer in organizers {
            var candidate = organizer
            for index in grouped.indices.reversed() {
                let current = grouped[index]
                guard current.rack == candidate.rack, current.face == candidate.face,
                      abs(current.depth - candidate.depth) <= 0.006 else { continue }
                let mount: Organizer.Mount
                switch (current.mount, candidate.mount) {
                case (.horizontal(let a), .horizontal(let b)) where near(a, b, gap: 0.018):
                    mount = .horizontal(rows: joined(a, b))
                case (.vertical(let x, let a), .vertical(let otherX, let b))
                    where abs(x - otherX) <= 0.008 && near(a, b, gap: 0.05):
                    mount = .vertical(x: x, heights: joined(a, b))
                case (.depthRun(let a, let rows, let span), .depthRun(let b, let otherRows, let otherSpan))
                    where span == otherSpan && current.portDepth == candidate.portDepth
                        && near(rows, otherRows, gap: 0.012) && near(a, b, gap: 0.04):
                    mount = .depthRun(ports: joined(a, b), rows: joined(rows, otherRows), span: span)
                default: continue
                }
                candidate = .init(rack: current.rack, face: current.face, mount: mount,
                                  routeDepth: current.routeDepth, portDepth: current.portDepth)
                grouped.remove(at: index)
            }
            grouped.append(candidate)
        }
        return grouped
    }

    struct Elbow: Sendable {
        let points: [SIMD3<Float>]
        let incoming: SIMD3<Float>
        let outgoing: SIMD3<Float>
        let startSize: SIMD2<Float>
        let endSize: SIMD2<Float>
        let overCapacity: Bool
    }

    struct Junction: Sendable {
        let point: SIMD3<Float>
        let size: SIMD3<Float>
        let overCapacity: Bool
    }

    struct FittedGuides: Sendable {
        let straights: [Guide]
        let elbows: [Elbow]
        let junctions: [Junction]
    }

    static func connectGuides(_ guides: [Guide]) -> FittedGuides {
        struct End {
            let index: Int
            let atStart: Bool
            let point: SIMD3<Float>
            let direction: SIMD3<Float>
            let length: Float
        }
        var nodes: [SIMD3<Int32>: [End]] = [:]
        var starts = guides.map(\.start), ends = guides.map(\.end)
        var elbows: [Elbow] = [], junctions: [Junction] = []
        for (index, guide) in guides.enumerated() {
            let span = guide.end - guide.start
            let length = simd_length(span)
            guard length > 0.001 else { continue }
            for (position, atStart) in [(guide.start, true), (guide.end, false)] {
                let key = SIMD3<Int32>((position * 1_000).rounded(.toNearestOrAwayFromZero))
                nodes[key, default: []].append(.init(index: index, atStart: atStart, point: position,
                    direction: span * (atStart ? 1 / length : -1 / length), length: length))
            }
        }
        for neighbours in nodes.values where neighbours.count > 1 {
            let point = neighbours.reduce(SIMD3<Float>.zero) { $0 + $1.point } / Float(neighbours.count)
            let section = neighbours.reduce(SIMD2<Float>.zero) { simd_max($0, guides[$1.index].size) }
            let warning = neighbours.contains { guides[$0.index].overCapacity }
            let first = neighbours[0], second = neighbours[1]
            let dot = simd_dot(first.direction, second.direction)
            if neighbours.count == 2 && dot < -0.999 && guides[first.index].size == guides[second.index].size { continue }
            if neighbours.count == 2, dot > -0.999, dot < 0.99 {
                let tangent = tan(acos(max(-1, -dot)) / 2)
                let trim = min((0.040 + section.x / 2) * tangent, min(first.length, second.length) * 0.44)
                let radius = trim / tangent
                // The inside of the U profile folds back on itself below this radius.
                let halfProfile = section / 2 + SIMD2(repeating: 0.004)
                let horizontal = abs(first.direction.y) < 0.001 && abs(second.direction.y) < 0.001
                let profileRadius = horizontal ? halfProfile.x : simd_length(halfProfile)
                if trim > 0.0005, radius > profileRadius,
                   let route = LabGeometry.cableBends([
                    point + first.direction * (trim + 0.002), point,
                    point + second.direction * (trim + 0.002)
                   ], radius: radius, segmentsPerBend: 10), route.count > 3 {
                    let curve = Array(route.dropFirst().dropLast())
                    if first.atStart { starts[first.index] = curve[0] } else { ends[first.index] = curve[0] }
                    if second.atStart { starts[second.index] = curve[curve.count - 1] }
                    else { ends[second.index] = curve[curve.count - 1] }
                    elbows.append(.init(points: curve, incoming: -first.direction, outgoing: second.direction,
                        startSize: guides[first.index].size, endSize: guides[second.index].size, overCapacity: warning))
                    continue
                }
            }
            let hasVertical = neighbours.contains { abs($0.direction.y) > 0.4 }
            let width = section.x + 0.012
            let depth = hasVertical ? max(section.y, width * 0.65) : width
            junctions.append(.init(point: point, size: SIMD3(width, hasVertical ? depth : section.y + 0.009, width),
                                   overCapacity: warning))
        }
        let straights = guides.indices.map { index in
            let guide = guides[index]
            return Guide(start: starts[index], end: ends[index], size: guide.size,
                         cableCount: guide.cableCount, overCapacity: guide.overCapacity)
        }
        return .init(straights: straights, elbows: elbows, junctions: junctions)
    }

    struct Anchor: Equatable, Sendable {
        let position: SIMD3<Float>
        let yaw: Float
        let size: SIMD3<Float>

        func face(near point: SIMD3<Float>) -> SIMD3<Float>? {
            let rotation = simd_quatf(angle: yaw, axis: SIMD3(0, 1, 0))
            var local = rotation.inverse.act(point - position)
            guard local.y >= 0.015, local.y <= size.y - 0.006 else { return nil }
            let half = SIMD2(size.x, size.z) / 2
            let xy = SIMD2(local.x, local.z)
            let outside = simd_abs(xy) - half
            var face = simd_clamp(xy, -half, half)
            if outside.x < 0 && outside.y < 0 {
                let axis = outside.x > outside.y ? 0 : 1
                face[axis] = xy[axis] >= 0 ? half[axis] : -half[axis]
            }
            guard simd_distance_squared(xy, face) <= 0.27 * 0.27 else { return nil }
            local.x = face.x; local.z = face.y
            return position + rotation.act(local)
        }
    }

    static func frame(along direction: SIMD3<Float>) -> (side: SIMD3<Float>, up: SIMD3<Float>) {
        let side = simd_normalize(simd_cross(abs(direction.y) > 0.99 ? SIMD3(0, 0, -1) : SIMD3(0, 1, 0), direction))
        return (side, simd_cross(direction, side))
    }

    private static let lanes: [SIMD3<Float>] = {
        var grid: [SIMD3<Float>] = []
        for x in -10...10 {
            for y in -3...3 {
                for z in -10...10 { grid.append(SIMD3(Float(x), Float(y), Float(z)) * 0.008) }
            }
        }
        return grid.sorted {
            let a = simd_length_squared($0), b = simd_length_squared($1)
            return (a, $0.y, $0.x, $0.z) < (b, $1.y, $1.x, $1.z)
        }
    }()

    static func offsets(for paths: [Path], sharing runs: [Run]) -> [String: SIMD3<Float>] {
        var neighbours: [String: [String: Set<SIMD3<Int32>>]] = [:]
        for run in runs where run.links.count > 1 {
            let direction = simd_normalize(run.end - run.start)
            let key = SIMD3<Int32>((direction * 1_000).rounded(.toNearestOrAwayFromZero))
            for (index, link) in run.links.enumerated() {
                for other in run.links.dropFirst(index + 1) {
                    neighbours[link.id, default: [:]][other.id, default: []].insert(key)
                    neighbours[other.id, default: [:]][link.id, default: []].insert(key)
                }
            }
        }
        let ordered = paths.map(\.link).sorted {
            (-(neighbours[$0.id]?.count ?? 0), $0.id) < (-(neighbours[$1.id]?.count ?? 0), $1.id)
        }
        let radii = Dictionary(ordered.map { ($0.id, $0.medium.cableRadius) }, uniquingKeysWith: { first, _ in first })
        var offsets: [String: SIMD3<Float>] = [:]
        for link in ordered {
            let occupied = (neighbours[link.id] ?? [:]).sorted { $0.key < $1.key }.flatMap { id, directions in
                guard let offset = offsets[id], let radius = radii[id] else { return [(SIMD3<Float>, SIMD3<Float>, Float)]() }
                let clearance = link.medium.cableRadius + radius + 0.0008
                return directions.map { (offset, simd_normalize(SIMD3<Float>($0)), clearance * clearance) }
            }
            offsets[link.id] = lanes.first { candidate in
                occupied.allSatisfy { origin, direction, distance in
                    simd_length_squared(simd_cross(candidate - origin, direction)) >= distance
                }
            }
        }
        return offsets
    }

    static func strand(_ points: [SIMD3<Float>], offset: SIMD3<Float>,
                       mountedStart: Float = 0, mountedEnd: Float = 0) -> [SIMD3<Float>] {
        guard offset != .zero, let first = points.first, points.count > 2 else { return points }
        var distances: [Float] = [0]
        for (a, b) in zip(points, points.dropFirst()) { distances.append(distances.last! + simd_distance(a, b)) }
        guard let length = distances.last, length > 0.0001 else { return points }
        let transition = min(0.22, length / 2)
        let straightEnd = min(0.024, transition * 0.25)
        let mounted = mountedStart > 0 || mountedEnd > 0
        let ramp: Float = 0.16
        let stops = ([straightEnd, transition, length - transition, length - straightEnd] + (mounted
            ? [mountedStart, mountedStart + ramp, length - mountedEnd - ramp, length - mountedEnd] : [])).sorted()
        func projected(_ point: SIMD3<Float>, at distance: Float) -> SIMD3<Float> {
            let t = max(0, min(1, (min(distance, length - distance) - straightEnd) / (transition - straightEnd)))
            let reach = max(0, min(1, min(distance - mountedStart, length - distance - mountedEnd) / ramp))
            let withinRack = mounted ? rackBundleScale + (1 - rackBundleScale) * reach * reach * (3 - 2 * reach) : 1
            return point + offset * (withinRack * t * t * (3 - 2 * t))
        }
        var result = [first]
        for index in 1..<points.count {
            let a = distances[index - 1], b = distances[index]
            guard b > a + 0.00001 else { continue }
            let sections = [a] + stops.filter { $0 > a && $0 < b } + [b]
            for (start, end) in zip(sections, sections.dropFirst()) where end > start {
                let inRamp = mounted && ((start < mountedStart + ramp && end > mountedStart)
                    || (end > length - mountedEnd - ramp && start < length - mountedEnd))
                let samples = start < transition || end > length - transition || inRamp
                let steps = samples ? max(1, Int(ceil((end - start) / 0.012))) : 1
                for step in 1...steps {
                    let distance = start + (end - start) * (Float(step) / Float(steps))
                    let part = (distance - a) / (b - a)
                    result.append(projected(points[index - 1] + (points[index] - points[index - 1]) * part, at: distance))
                }
            }
        }
        result[result.count - 1] = points[points.count - 1]
        return result
    }

    static func guidePath(_ path: Path) -> Path {
        var points = path.points
        if points.count >= 2 {
            for (index, neighbour) in [(0, 1), (points.count - 1, points.count - 2)] {
                let delta = points[neighbour] - points[index]
                let length = simd_length(delta)
                if length > 0.001 { points[index] += delta * min(0.065 / length, 0.45) }
            }
        }
        return .init(link: path.link, points: points)
    }

    private struct Line: Hashable {
        let direction: SIMD3<Int32>
        let origin: SIMD3<Int32>

        init(direction: SIMD3<Float>, origin: SIMD3<Float>) {
            self.direction = SIMD3((direction * 10_000).rounded(.toNearestOrAwayFromZero))
            self.origin = SIMD3((origin * 2_000).rounded(.toNearestOrAwayFromZero))
        }
    }

    private struct Track {
        let direction: SIMD3<Float>
        let origin: SIMD3<Float>
        var events: [Int: [String: Int]] = [:]
    }

    // Split collinear runs at branch points to measure the occupancy of each shared span.
    static func runs(_ paths: [Path]) -> [Run] {
        let links = Dictionary(paths.map { ($0.link.id, $0.link) }, uniquingKeysWith: { first, _ in first })
        var tracks: [Line: Track] = [:]
        for path in paths {
            for (a, b) in zip(path.points, path.points.dropFirst()) {
                let d = b - a
                let length = simd_length(d)
                guard length.isFinite, length > 0.00015, simd_length_squared(a) < 1e10, simd_length_squared(b) < 1e10 else { continue }
                let magnitude = simd_abs(d)
                let axis = magnitude.x >= magnitude.y && magnitude.x >= magnitude.z ? 0 : magnitude.y >= magnitude.z ? 1 : 2
                let direction = d / (d[axis] < 0 ? -length : length)
                let origin = a - direction * simd_dot(a, direction)
                let key = Line(direction: direction, origin: origin)
                let basis = tracks[key]?.direction ?? direction
                let first = Int((simd_dot(a, basis) * 10_000).rounded())
                let last = Int((simd_dot(b, basis) * 10_000).rounded())
                guard first != last else { continue }
                tracks[key, default: .init(direction: direction, origin: origin)]
                    .events[min(first, last), default: [:]][path.link.id, default: 0] += 1
                tracks[key]?.events[max(first, last), default: [:]][path.link.id, default: 0] -= 1
            }
        }
        var result: [Run] = []
        for track in tracks.values {
            var active: [String: Int] = [:]
            var previous: Int?
            for (step, events) in track.events.sorted(by: { $0.key < $1.key }) {
                if let previous, !active.isEmpty {
                    result.append(.init(start: track.origin + track.direction * (Float(previous) / 10_000),
                                        end: track.origin + track.direction * (Float(step) / 10_000),
                                        links: active.keys.sorted().compactMap { links[$0] }))
                }
                for (id, delta) in events {
                    let count = active[id, default: 0] + delta
                    active[id] = count == 0 ? nil : count
                }
                previous = step
            }
        }
        return result
    }
}

nonisolated struct Lab3DPositions: Codable, Sendable {
    private struct Pose: Codable, Sendable {
        let xz: SIMD2<Float>
        let yaw: Float
        let y: Float?
    }

    private var poses: [String: Pose] = [:]

    mutating func set(_ placement: LabPlacement) {
        poses[placement.id] = .init(xz: SIMD2(placement.position.x, placement.position.z), yaw: placement.yaw, y: placement.position.y)
    }

    func applying(to base: LabLayout) -> LabLayout {
        var layout = base
        var valid = poses
        while !valid.isEmpty {
            layout.placements = base.placements.map { original in
                guard let pose = valid[original.id] else { return original }
                let y = LabARAssembly.Adjustment.forARPlacement(original).contains(.lift)
                    ? max(original.position.y, pose.y ?? original.position.y) : original.position.y
                return original.at(SIMD3(pose.xz.x, y, pose.xz.y), yaw: pose.yaw)
            }
            let invalid = layout.placements.filter { valid[$0.id] != nil && !LabTopology.fitsPlacement($0, in: layout) }
            if invalid.isEmpty { return layout }
            for placement in invalid { valid.removeValue(forKey: placement.id) }
        }
        return base
    }
}

nonisolated extension LabPlacement {
    func at(_ position: SIMD3<Float>, yaw: Float) -> Self {
        .init(id: id, kind: kind, title: title, position: position, yaw: yaw, size: size, bareDesk: bareDesk)
    }
}

nonisolated extension LabTopology {
    func testNetwork(from source: Device, to endpoint: Device, tcp: Int, poweredOff: Set<String>) -> String {
        guard let a = source.vlan, let b = endpoint.vlan else { return "Simulación · Extremo sin VLAN." }
        if a == b {
            let route = switchedPath(from: source.id, to: endpoint.id, vlan: a, poweredOff: poweredOff)
            return route.map { path in
                let result = tcp == 80 ? endpoint.serverServices?.httpTitle.map { "HTTP 200 · " + $0 } : nil
                return (result ?? "Simulación · Enlace local") + "\n" + path.map(\.name).joined(separator: " → ")
            }
                ?? "Simulación · VLAN \(a) sin camino."
        }
        if operationsProfile == LabDemo.vlanProfile {
            guard let route = importedIPv4Path(from: source, to: endpoint, poweredOff: poweredOff) else {
                return "Simulación · Camino interrumpido · TCP \(tcp)."
            }
            return "Simulación · Permitido · TCP \(tcp)\n" + route.map(\.name).joined(separator: " → ")
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
        if source.ipv4 != nil, let vlan = source.vlan, let resolver = devices.first(where: { server in
            server.serverServices?.dns?.hostname == name &&
                switchedPath(from: source.id, to: server.id, vlan: vlan, poweredOff: poweredOff) != nil
        }), let record = resolver.serverServices?.dns {
            return "DNS simulado · \(name) → \(record.address) · \(resolver.name)"
        }
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

nonisolated struct LabMonitorConfiguration: Codable, Equatable, Sendable {
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
