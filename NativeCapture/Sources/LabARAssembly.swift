import Foundation
import simd

nonisolated struct LabARAssembly: Codable, Equatable, Identifiable, Sendable {
    enum Item: Codable, Hashable, Sendable {
        case support(String)
        case device(String)
        case infrastructure(String)
        case monitor(device: String, panel: LabMonitorConfiguration.Panel, id: UUID)
        case extra(model: String, id: UUID)

        var name: String {
            switch self {
            case .support(let id), .device(let id), .infrastructure(let id): id
            case .extra(_, let id), .monitor(_, _, let id): id.uuidString
            }
        }
    }

    struct Piece: Codable, Equatable, Identifiable, Sendable {
        let id: Item
        var position: SIMD3<Float>
        var yaw: Float
        var monitorMount: MonitorMount? = nil
        var elevationBase: Float? = nil

        var rotation: simd_quatf { simd_quatf(angle: yaw, axis: SIMD3(0, 1, 0)) }
        func world(_ point: SIMD3<Float>) -> SIMD3<Float> { position + rotation.act(point) }

        mutating func adjust(_ mode: Adjustment, axes: SIMD2<Float>, forward: SIMD3<Float>, seconds: Float) {
            switch mode {
            case .move:
                let horizontal = SIMD2(forward.x, forward.z)
                let front = simd_length_squared(horizontal) > 0.01 ? simd_normalize(horizontal) : SIMD2(0, -1)
                let right = SIMD2(-front.y, front.x)
                let step = (right * axes.x + front * axes.y) * (0.55 * seconds)
                position += SIMD3(step.x, 0, step.y)
            case .turn:
                yaw = (yaw - axes.x * (.pi / 2) * seconds).truncatingRemainder(dividingBy: .pi * 2)
            case .lift:
                let base = elevationBase ?? position.y
                let height = max(base, position.y + axes.y * 0.35 * seconds)
                guard height != position.y else { return }
                elevationBase = base
                position.y = height
            }
        }
    }

    struct MonitorMount: Codable, Equatable, Sendable {
        let rackID: String
        let side: RackMount.Side
        let row: Int
    }

    struct RackMonitor: Codable, Equatable, Identifiable, Sendable {
        let id: UUID
        let device: String
        let panel: LabMonitorConfiguration.Panel
        let side: RackMount.Side
        let row: Int

        var item: Item { .monitor(device: device, panel: panel, id: id) }

        func piece(on rack: LabPlacement) -> Piece {
            .init(id: item, position: rack.position, yaw: rack.yaw,
                  monitorMount: .init(rackID: rack.id, side: side, row: row))
        }
    }

    enum WaypointGesture {
        case began(Int), moved(SIMD3<Float>), finished, cancelled
    }

    enum Adjustment: Equatable, Hashable {
        case move, turn, lift

        static func forARPlacement(_ placement: LabPlacement?) -> [Self] {
            guard let placement, placement.kind == .rack else { return [.move, .turn] }
            return RackMount.capacity(height: placement.size.y) <= 16 ? [.move, .turn, .lift] : [.move, .turn]
        }

        var title: String {
            switch self {
            case .move: "Mover"
            case .turn: "Girar"
            case .lift: "Altura"
            }
        }
    }
    typealias CableLevel = LabCableLevel

    let id: UUID
    var name: String
    var pieces: [Piece] = []
    var showsCables: Bool? = nil
    private(set) var cableLevels: [Item: CableLevel]? = nil
    private(set) var waypoints: [String: [SIMD2<Float>]]? = nil
    private(set) var powerOutlets: [Item: LabRackPower.Outlet]? = nil
    private var unplacedSupports: Set<String>?

    var anchorName: String { "NexusAR.Montaje." + id.uuidString }
    func piece(_ item: Item) -> Piece? { pieces.first { $0.id == item } }

    func hasSameCableLayout(as other: Self?) -> Bool {
        guard let other else { return false }
        return id == other.id && pieces == other.pieces && cableLevels == other.cableLevels && waypoints == other.waypoints
    }

    mutating func set(_ newPiece: Piece) {
        if case .support(let id) = newPiece.id { unplacedSupports?.remove(id) }
        if let index = pieces.firstIndex(where: { $0.id == newPiece.id }) { pieces[index] = newPiece }
        else { pieces.append(newPiece) }
    }

    mutating func remove(_ item: Item) {
        pieces.removeAll { $0.id == item }
        cableLevels?.removeValue(forKey: item)
        powerOutlets?.removeValue(forKey: item)
    }

    mutating func setPowerOutlet(_ outlet: LabRackPower.Outlet?, for rack: Item) {
        if let outlet {
            if powerOutlets == nil { powerOutlets = [:] }
            powerOutlets?[rack] = outlet
        } else {
            powerOutlets?.removeValue(forKey: rack)
        }
    }

    mutating func clearPowerOutlets() { powerOutlets = nil }

    static func isPowerRack(_ item: Item, in layout: LabLayout) -> Bool {
        switch item {
        case .support(let id): layout.placements.contains { $0.id == id && $0.kind == .rack }
        case .extra(let model, _): model == "rack-r42612"
        default: false
        }
    }

    func level(for item: Item, on support: Item? = nil) -> CableLevel {
        cableLevels?[item] ?? support.flatMap { cableLevels?[$0] } ?? .floor
    }

    mutating func setLevel(_ level: CableLevel, for item: Item) {
        if cableLevels == nil { cableLevels = [:] }
        cableLevels?[item] = level
    }

    static let monitorSize = SIMD3<Float>(0.57, 0.48, 0.23)

    static func monitorRowCount(on rack: LabPlacement) -> Int {
        max(0, Int((rack.size.y - 0.08) / (monitorSize.y + 0.06)))
    }

    static func monitorOffset(on rack: LabPlacement, side: RackMount.Side, row: Int) -> SIMD3<Float> {
        SIMD3(side.sign * (rack.size.x / 2 + monitorSize.x / 2 + 0.05),
              rack.size.y - monitorSize.y - 0.08 - Float(row) * (monitorSize.y + 0.06),
              -rack.size.z / 2 + 0.12)
    }

    init(id: UUID, name: String) {
        self.id = id
        self.name = name
    }

    init(roomLayout layout: LabLayout) {
        self.init(id: UUID(), name: "")
        pieces = layout.placements.flatMap { placement in
            [Piece(id: .support(placement.id), position: placement.position, yaw: placement.yaw)]
                + (layout.rackMonitors?[placement.id] ?? []).map { $0.piece(on: placement) }
        }
        pieces += layout.accessories ?? []
        if let facility = layout.facility {
            pieces += facility.fixtures.map {
                Piece(id: .infrastructure($0.id), position: facility.world($0.position), yaw: facility.yaw + $0.yaw)
            }
        }
    }

    static func roomPlacementFits(_ placement: LabPlacement, in layout: LabLayout, topology: LabTopology?,
                                  allowingSeparation: Bool = false) -> Bool {
        guard LabTopology.fitsPlacement(placement, in: layout) else { return false }
        guard layout.accessories?.isEmpty == false
                || layout.rackMonitors?.values.contains(where: { !$0.isEmpty }) == true else { return true }
        var updated = layout
        if let index = updated.placements.firstIndex(where: { $0.id == placement.id }) { updated.placements[index] = placement }
        else { updated.placements.append(placement) }
        return !Self(roomLayout: updated).conflicts(with: Self(roomLayout: layout), in: updated, topology: topology,
                                                    previousLayout: layout, allowingSeparation: allowingSeparation)
    }

    func rackMonitors(on rack: String) -> [RackMonitor] {
        pieces.compactMap { piece in
            guard let mount = piece.monitorMount, mount.rackID == rack,
                  case let .monitor(device, panel, id) = piece.id else { return nil }
            return RackMonitor(id: id, device: device, panel: panel, side: mount.side, row: mount.row)
        }
    }

    mutating func unplace(_ item: Item) {
        if case .support(let id) = item {
            if unplacedSupports == nil { unplacedSupports = [] }
            unplacedSupports?.insert(id)
        }
        remove(item)
    }

    mutating func syncInventory(in layout: LabLayout, topology: LabTopology?,
                                at position: SIMD3<Float>? = nil, yaw: Float = 0, placeMissing: Bool = true) {
        let mounted = (layout.rackMonitors ?? [:]).flatMap { rackID, monitors in
            monitors.map { (rackID, $0) }
        }.sorted { ($0.0, $0.1.row, $0.1.id.uuidString) < ($1.0, $1.1.row, $1.1.id.uuidString) }
        let mountedByID = Dictionary(mounted.map { ($0.1.item.name, $0.1.item) }, uniquingKeysWith: { first, _ in first })
        let accessories = layout.accessories ?? []
        let looseIDs = Set(accessories.map(\.id))
        let oldPieces = pieces
        let supports = Set(layout.placements.map(\.id))
        let floorSupports = Set(layout.placements.filter { $0.kind == .floor }.map(\.id))
        let devices = topology.map { Dictionary(uniqueKeysWithValues: $0.devices.map { ($0.id, $0.placementID) }) }
        for piece in oldPieces {
            if case .support(let id) = piece.id, !supports.contains(id) { remove(piece.id); continue }
            if case .device(let id) = piece.id, let devices,
               devices[id].map({ floorSupports.contains($0) }) ?? true { remove(piece.id); continue }
            if case .monitor(let id, _, _) = piece.id, let devices, devices[id] == nil { remove(piece.id); continue }
            if let mount = piece.monitorMount, layout.rackMonitors?[mount.rackID] != nil {
                if mountedByID[piece.id.name] != piece.id && !looseIDs.contains(piece.id) { remove(piece.id) }
            } else if layout.accessories != nil {
                switch piece.id {
                case .extra, .monitor:
                    if !looseIDs.contains(piece.id) && mountedByID[piece.id.name] != piece.id { remove(piece.id) }
                default: break
                }
            }
        }
        let reference = layout.placements.compactMap { support in
            piece(.support(support.id)).map { (support.position, support.yaw, $0) }
        }.first ?? accessories.compactMap { part in
            piece(part.id).map { (part.position, part.yaw, $0) }
        }.first
        let placedOrigin = reference.map { _, _, installed in
            let floor = installed.elevationBase ?? installed.position.y
            return SIMD3(installed.position.x, floor, installed.position.z)
        } ?? position
        if placeMissing, let origin = placedOrigin {
            let center = layout.floorCenter
            let original = reference?.0 ?? SIMD3(center.x, layout.floorHeight, center.y)
            let angle = reference.map { $0.2.yaw - $0.1 } ?? yaw
            let rotation = simd_quatf(angle: angle, axis: SIMD3(0, 1, 0))
            for placement in layout.placements where piece(.support(placement.id)) == nil
                && unplacedSupports?.contains(placement.id) != true {
                fitNewPiece(.init(id: .support(placement.id), position: origin + rotation.act(placement.position - original),
                                  yaw: placement.yaw + angle), in: layout, topology: topology)
            }
            for accessory in accessories where piece(accessory.id) == nil {
                var proposed = accessory
                proposed.position = origin + rotation.act(accessory.position - original)
                proposed.yaw += angle
                fitNewPiece(proposed, in: layout, topology: topology)
            }
        }
        for (rackID, monitor) in mounted where piece(.support(rackID)) != nil && piece(monitor.item) == nil {
            guard let rack = layout.placements.first(where: { $0.id == rackID }) else { continue }
            let preferred = oldPieces.first { $0.id.name == monitor.item.name }?.monitorMount
            let side = preferred?.side ?? monitor.side
            let row = preferred?.row ?? monitor.row
            for candidate in [side, side == .left ? .right : .left] {
                let rows = freeMonitorRows(on: rack, side: candidate, in: layout, topology: topology)
                guard let first = rows.first else { continue }
                set(RackMonitor(id: monitor.id, device: monitor.device, panel: monitor.panel,
                                side: candidate, row: rows.contains(row) ? row : first).piece(on: rack))
                break
            }
        }
    }

    private mutating func fitNewPiece(_ preferred: Piece, in layout: LabLayout, topology: LabTopology?) {
        for ring in 0...7 {
            for z in -ring...ring {
                for x in -ring...ring where max(abs(x), abs(z)) == ring {
                    var candidate = self
                    var piece = preferred
                    piece.position += SIMD3(Float(x) * 0.35, 0, Float(z) * 0.35)
                    candidate.set(piece)
                    if !candidate.conflicts(with: self, in: layout, topology: topology) {
                        self = candidate
                        return
                    }
                }
            }
        }
    }

    mutating func setWaypoints(_ points: [SIMD2<Float>], for linkID: String) {
        if waypoints == nil { waypoints = [:] }
        waypoints?[linkID] = points.isEmpty ? nil : points
    }

    func snappedWaypoint(_ position: SIMD3<Float>) -> SIMD2<Float> {
        SIMD2((position.x * 10).rounded(), (position.z * 10).rounded()) / 10
    }

    static func waypointPlaneHit(origin: SIMD3<Float>, direction: SIMD3<Float>, height: Float) -> SIMD3<Float>? {
        guard abs(direction.y) > 0.0001 else { return nil }
        let distance = (height - origin.y) / direction.y
        guard distance > 0 else { return nil }
        let hit = origin + distance * direction
        guard hit.x.isFinite, hit.z.isFinite else { return nil }
        return SIMD3(hit.x, height, hit.z)
    }

    func freeMonitorRows(on rack: LabPlacement, side: RackMount.Side, in layout: LabLayout, topology: LabTopology?) -> [Int] {
        guard let support = piece(.support(rack.id)) else { return [] }
        let count = Self.monitorRowCount(on: rack)
        let used = Set(pieces.compactMap { piece -> Int? in
            guard let mount = piece.monitorMount, mount.rackID == rack.id, mount.side == side else { return nil }
            return mount.row
        })
        let probe = Item.monitor(device: "", panel: .services, id: UUID())
        return (0..<count).filter { row in
            guard !used.contains(row) else { return false }
            var candidate = self
            candidate.set(.init(id: probe, position: support.position, yaw: support.yaw,
                                monitorMount: .init(rackID: rack.id, side: side, row: row)))
            return !candidate.conflicts(with: self, in: layout, topology: topology)
        }
    }

    func resolvedPieces(in layout: LabLayout) -> [Piece] {
        let placed = Dictionary(pieces.map { ($0.id, $0) }, uniquingKeysWith: { _, newest in newest })
        let racks = Dictionary(uniqueKeysWithValues: layout.placements.map { ($0.id, $0) })
        return pieces.compactMap { piece in
            guard let mount = piece.monitorMount else { return piece }
            guard let base = placed[.support(mount.rackID)], let rack = racks[mount.rackID] else { return nil }
            var mounted = piece
            mounted.position = base.world(Self.monitorOffset(on: rack, side: mount.side, row: mount.row))
            mounted.yaw = base.yaw
            return mounted
        }
    }

    func adjustmentPiece(_ item: Item, topology: LabTopology?) -> Piece? {
        if let placed = piece(item) { return placed }
        guard case .device(let id) = item, let device = topology?.devices.first(where: { $0.id == id }),
              let support = piece(.support(device.placementID)) else { return nil }
        return .init(id: item, position: support.world(device.offset - SIMD3(0, device.visualSize.y / 2, 0)),
                     yaw: support.yaw)
    }

    func connectionPorts(on device: LabTopology.Device, in topology: LabTopology,
                         from origin: LabTopology.Port?) -> [LabTopology.Port] {
        guard piece(.device(device.id)) != nil || piece(.support(device.placementID)) != nil else { return [] }
        if let origin {
            guard device.id != origin.deviceID, let medium = topology.medium(at: origin) else { return [] }
            return topology.freePorts(on: device, matching: medium)
        }
        return topology.freePorts(on: device)
    }

    func validateCableRoute(_ id: String, in project: LabProject, allowReview: Bool = false) throws {
        try validateCableRoutes([id], in: project, allowReview: allowReview)
    }

    func validateCableRoutes(_ ids: [String], in project: LabProject, allowReview: Bool = false) throws {
        let plan = cablePlan(in: project.topology, layout: project.layout)
        for id in ids {
            guard let route = plan.connections.first(where: { $0.link.id == id }), route.routed else {
                throw LabLayoutError.invalid("Deja espacio entre los equipos o prueba otra canaleta.")
            }
            if !allowReview && plan.overCapacityLinks.contains(id) {
                throw LabLayoutError.invalid("La canaleta está llena. Prueba otra altura o cambia el recorrido.")
            }
            guard allowReview || (route.bendRadius != nil && ((waypoints?[id] ?? []).isEmpty || route.usesWaypoints)) else {
                throw LabLayoutError.invalid("Deja espacio para las curvas del cable y los puntos de paso.")
            }
        }
    }

    mutating func apply3DChange(from original: LabPlacement, to edited: LabPlacement,
                                in layout: LabLayout, topology: LabTopology?) throws {
        let support = Item.support(original.id)
        guard original.id == edited.id, var piece = piece(support) else {
            throw LabLayoutError.invalid("Este equipo ya no está colocado en el montaje AR.")
        }
        let transform = simd_quatf(angle: piece.yaw - original.yaw, axis: SIMD3(0, 1, 0))
        let delta = edited.position - original.position
        piece.position += transform.act(SIMD3(delta.x, 0, delta.z))
        if Adjustment.forARPlacement(original).contains(.lift), delta.y != 0 {
            let floor = piece.elevationBase ?? piece.position.y
            piece.elevationBase = floor
            piece.position.y = max(floor, piece.position.y + delta.y)
        }
        piece.yaw = (piece.yaw + edited.yaw - original.yaw).truncatingRemainder(dividingBy: 2 * .pi)
        var updated = self
        updated.set(piece)
        guard !updated.conflicts(with: self, in: layout, topology: topology) else {
            throw LabLayoutError.invalid("El equipo chocaría con otro objeto del montaje AR. Elige otro montaje o desactiva la sincronización.")
        }
        self = updated
    }

    static let collisionHint = "Hay otro equipo en ese espacio."

    func conflicts(with previous: Self, in layout: LabLayout, topology: LabTopology?,
                   previousTopology: LabTopology? = nil, previousLayout: LabLayout? = nil,
                   allowingSeparation: Bool = false) -> Bool {
        func volumes(_ assembly: Self, _ layout: LabLayout, _ topology: LabTopology?) -> [(piece: Piece, box: LabPlacement, host: Item?)] {
            let placed = assembly.resolvedPieces(in: layout)
            let byID = Dictionary(uniqueKeysWithValues: placed.map { ($0.id, $0) })
            let embedded = (topology?.devices ?? []).compactMap { device -> (Piece, Item?)? in
                let host = Item.support(device.placementID)
                let id = Item.device(device.id)
                guard byID[id] == nil, let support = byID[host] else { return nil }
                return (.init(id: id, position: support.world(device.offset - SIMD3(0, device.visualSize.y / 2, 0)),
                              yaw: support.yaw), host)
            }
            return (placed.map { ($0, nil) } + embedded).compactMap { part, host in
                guard let size = Self.size(of: part.id, in: layout, topology: topology) else { return nil }
                return (part, .init(id: part.id.name, kind: .rack, title: "", position: part.position, yaw: part.yaw, size: size), host)
            }
        }
        func verticalDepth(_ a: LabPlacement, _ b: LabPlacement) -> Float {
            min(a.position.y + a.size.y - b.position.y, b.position.y + b.size.y - a.position.y)
        }
        func belongs(_ piece: Piece, to support: Piece) -> Bool {
            guard case .device(let device) = piece.id, case .support(let id) = support.id else { return false }
            return topology?.devices.contains { $0.id == device && $0.placementID == id } == true
        }
        let prior = Dictionary(uniqueKeysWithValues: volumes(previous, previousLayout ?? layout, previousTopology ?? topology)
            .map { ($0.piece.id, $0.box) })
        let parts = volumes(self, layout, topology)
        for (piece, a, host) in parts where prior[piece.id] != a {
            for (obstacle, b, otherHost) in parts where piece.id != obstacle.id {
                if host != nil && host == otherHost { continue }
                if belongs(piece, to: obstacle) || belongs(obstacle, to: piece) { continue }
                let vertical = verticalDepth(a, b)
                guard vertical > 0.001 else { continue }
                let horizontal = LabTopology.overlapDepth(a, b)
                guard horizontal > 0.00001 else { continue }
                if allowingSeparation, let oldA = prior[piece.id], let oldB = prior[obstacle.id] {
                    let oldVertical = verticalDepth(oldA, oldB)
                    let oldHorizontal = LabTopology.overlapDepth(oldA, oldB)
                    if vertical <= oldVertical + 0.00001, horizontal <= oldHorizontal + 0.00001,
                       vertical < oldVertical - 0.00001 || horizontal < oldHorizontal - 0.00001 { continue }
                }
                return true
            }
        }
        return false
    }

    static func size(of item: Item, in layout: LabLayout, topology: LabTopology?) -> SIMD3<Float>? {
        switch item {
        case .support(let id): layout.placements.first { $0.id == id }?.size
        case .device(let id): topology?.devices.first { $0.id == id }?.visualSize
        case .infrastructure(let id): layout.facility?.fixtures.first { $0.id == id }?.kind.size
        case .extra(let model, _): accessorySize(model)
        case .monitor: monitorSize
        }
    }

    mutating func placeAll(in layout: LabLayout, at position: SIMD3<Float>, yaw: Float) {
        let center = layout.floorCenter
        let origin = SIMD3(center.x, layout.floorHeight, center.y)
        let rotation = simd_quatf(angle: yaw, axis: SIMD3(0, 1, 0))
        for support in layout.placements where piece(.support(support.id)) == nil {
            set(.init(id: .support(support.id), position: position + rotation.act(support.position - origin), yaw: yaw + support.yaw))
        }
        if let facility = layout.facility {
            for fixture in facility.fixtures where piece(.infrastructure(fixture.id)) == nil {
                let offset = facility.world(fixture.position) - origin
                set(.init(id: .infrastructure(fixture.id), position: position + rotation.act(offset),
                          yaw: yaw + facility.yaw + fixture.yaw))
            }
        }
    }

    static func accessorySize(_ model: String) -> SIMD3<Float>? {
        switch model {
        case "test-desk": return SIMD3(1.5, 1.25, 0.76)
        case "battery-bank": return HardwareCatalog.renderSize("rack-r42612")
        default: return HardwareCatalog.reference(model).map { _ in HardwareCatalog.renderSize(model) }
        }
    }

    struct PowerFeedPlan {
        struct Lead {
            let circuit: Int
            let points: [SIMD3<Float>]
        }
        var leads: [Lead] = []
        var reviewRacks: Set<Item> = []
        var externalUPSSources: [Item: LabRackPower.Endpoint] = [:]
    }

    func powerFeedPlan(in layout: LabLayout, topology: LabTopology?) -> PowerFeedPlan {
        let mounted = Dictionary(grouping: topology?.devices.filter { piece(.device($0.id)) == nil } ?? [], by: \.placementID)
        let pieces = resolvedPieces(in: layout)
        let racks = pieces.filter { Self.isPowerRack($0.id, in: layout) }
        let looseUPS = pieces.filter {
            if case .extra(let model, _) = $0.id { return model == LabRackPower.upsModel || model == "battery-bank" }
            if case .device(let id) = $0.id { return topology?.devices.first { $0.id == id }?.visualModelID == LabRackPower.upsModel }
            return false
        }
        guard !racks.isEmpty, !looseUPS.isEmpty || powerOutlets?.isEmpty == false else { return .init() }
        let boxes = pieces.compactMap { part in
            Self.size(of: part.id, in: layout, topology: topology).map { CableFootprint(piece: part, size: $0) }
        }
        let boxesByItem = Dictionary(boxes.map { ($0.piece.id, $0) }, uniquingKeysWith: { _, latest in latest })
        func mountedEnd(_ endpoint: LabRackPower.Endpoint, on piece: Piece) -> LabRackPower.Endpoint {
            let end = endpoint.on(piece)
            guard let box = boxesByItem[piece.id], box.containsInterior(end.exit.xz) else { return end }
            let point = end.exit.xz, direction = end.normal.xz
            let edge = SIMD2(direction.x >= 0 ? box.max.x : box.min.x, direction.y >= 0 ? box.max.y : box.min.y)
            let x = abs(direction.x) > 0.0001 ? (edge.x - point.x) / direction.x : .infinity
            let z = abs(direction.y) > 0.0001 ? (edge.y - point.y) / direction.y : .infinity
            return .init(point: end.point, exit: end.exit + end.normal * (min(x, z) + 0.04), normal: end.normal)
        }
        let stripsByRack = Dictionary(racks.compactMap { rack -> (Item, [LabRackPower.Strip])? in
            guard let size = Self.size(of: rack.id, in: layout, topology: topology) else { return nil }
            let strips = LabRackPower.strips(for: size, configuration: layout.pduConfiguration(for: rack.id.name),
                                             devices: mounted[rack.id.name] ?? [], includesLeads: false)
            return (rack.id, strips)
        }, uniquingKeysWith: { _, latest in latest })
        // A freestanding UPS feeds one rack. A UPS mounted in that rack always takes precedence.
        let candidates = racks.filter { stripsByRack[$0.id]?.first?.upsID == nil }.flatMap { rack in
            looseUPS.map { ups in (rack, ups, simd_distance_squared(rack.position, ups.position)) }
        }.sorted { ($0.2, $0.0.id.name, $0.1.id.name) < ($1.2, $1.0.id.name, $1.1.id.name) }
        var assigned: [Item: Piece] = [:]
        var used = Set<Item>()
        var plan = PowerFeedPlan()
        for (rack, ups, _) in candidates where assigned[rack.id] == nil && !used.contains(ups.id) {
            assigned[rack.id] = ups
            used.insert(ups.id)
        }
        for rack in racks {
            guard let strips = stripsByRack[rack.id], let first = strips.first else { continue }
            var supply = mountedEnd(first.upstream, on: rack)
            var supplyBase = rack.elevationBase ?? rack.position.y
            if let ups = assigned[rack.id], let size = Self.size(of: ups.id, in: layout, topology: topology) {
                let center = if case .extra("battery-bank", _) = ups.id {
                    RackMount.center(LabRackPower.upsModel, rackDepth: size.z, slot: 13)
                } else { SIMD3<Float>(0, size.y / 2, 0) }
                var local: [PowerFeedPlan.Lead] = []
                for (index, strip) in strips.enumerated() {
                    let output = mountedEnd(LabRackPower.endpoint(LabRackPower.upsSocket(at: center, output: index), beyond: size.z / 2), on: ups)
                    guard let path = Self.powerRoute(from: mountedEnd(strip.upstream, on: rack), to: output,
                        floor: min(supplyBase, ups.elevationBase ?? ups.position.y), boxes: boxes) else { break }
                    local.append(.init(circuit: index, points: path))
                }
                if local.count == strips.count {
                    plan.leads += local
                    supply = mountedEnd(LabRackPower.endpoint(LabRackPower.upsSocket(at: center), beyond: size.z / 2), on: ups)
                    plan.externalUPSSources[rack.id] = supply
                    supplyBase = min(supplyBase, ups.elevationBase ?? ups.position.y)
                } else {
                    plan.reviewRacks.insert(rack.id)
                    continue
                }
            }
            guard let outlet = powerOutlets?[rack.id] else { continue }
            let point = outlet.position + outlet.normal * 0.012
            let wall = LabRackPower.Endpoint(point: point, exit: point + outlet.normal * 0.11, normal: outlet.normal)
            if let path = Self.powerRoute(from: supply, to: wall, floor: supplyBase, boxes: boxes),
               path.allSatisfy({ simd_dot($0 - outlet.position, outlet.normal) >= 0 }) {
                plan.leads.append(.init(circuit: 0, points: path))
            } else {
                plan.reviewRacks.insert(rack.id)
            }
        }
        return plan
    }

    private static func powerRoute(from start: LabRackPower.Endpoint, to end: LabRackPower.Endpoint,
                                   floor: Float, boxes: [CableFootprint]) -> [SIMD3<Float>]? {
        let radius = LabRackPower.bendRadius
        let level = floor + 0.012
        let from = start.exit.xz, to = end.exit.xz
        guard simd_distance_squared(from, to) > 0.0001,
              !boxes.contains(where: { $0.containsInterior(from) || $0.containsInterior(to) }) else { return nil }
        let tree = CableTree(boxes, additional: [from, to])
        guard let run = tree.route(through: [from, to]) else { return nil }
        func drop(_ end: LabRackPower.Endpoint) -> [SIMD3<Float>] {
            let point = end.exit.xz.atHeight(level)
            return end.exit.y >= level + 2 * radius ? [end.point, end.exit, point] : [end.point, point]
        }
        let middle = run.dropFirst().dropLast().map { $0.atHeight(level) }
        let corners = LabGeometry.cableCorners(drop(start) + middle + drop(end).reversed())
        return LabGeometry.cableBends(relaxShortJogs(corners, radius: radius), radius: radius, segmentsPerBend: 4)
    }

    func cablePlan(in topology: LabTopology, layout: LabLayout, virtualCeiling: Float? = nil) -> CablePlan {
        let pieces = resolvedPieces(in: layout)
        let placed = Dictionary(pieces.map { ($0.id, $0) }, uniquingKeysWith: { _, newest in newest })
        let devices = Dictionary(topology.devices.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let supports = Dictionary(uniqueKeysWithValues: layout.placements.map { ($0.id, $0) })
        let fixtures = Dictionary(uniqueKeysWithValues: (layout.facility?.fixtures ?? []).map { ($0.id, $0) })
        let bounds = pieces.compactMap { piece -> CableFootprint? in
            let size: SIMD3<Float>
            switch piece.id {
            case .support(let id):
                guard let support = supports[id] else { return nil }
                size = support.size
            case .device(let id):
                guard let device = devices[id] else { return nil }
                size = device.visualSize
            case .infrastructure(let id):
                guard let fixture = fixtures[id] else { return nil }
                size = fixture.kind.size
            case .extra(let model, _):
                guard let dimensions = Self.accessorySize(model) else { return nil }
                size = dimensions
            case .monitor:
                size = Self.monitorSize
            }
            return .init(piece: piece, size: size)
        }
        let byItem = Dictionary(bounds.map { ($0.piece.id, $0) }, uniquingKeysWith: { _, newest in newest })
        var risers: [Item: SIMD2<Float>] = [:]
        for box in bounds {
            let candidates = box.corners.filter { corner in
                !bounds.contains { $0.piece.id != box.piece.id && $0.containsInterior(corner) }
            }
            if case .support(let id) = box.piece.id, supports[id]?.kind == .rack {
                let rear = box.piece.world(SIMD3(box.size.x / 2, 0, box.size.z / 2)).xz
                let inverse = box.piece.rotation.inverse
                risers[box.piece.id] = candidates.filter {
                    inverse.act($0.atHeight(box.piece.position.y) - box.piece.position).z >= box.size.z / 2
                }.min { simd_distance_squared($0, rear) < simd_distance_squared($1, rear) }
            } else {
                let preferred = SIMD2(box.piece.world(SIMD3(1, 0, 0)).x, box.min.y)
                risers[box.piece.id] = candidates.min { simd_distance_squared($0, preferred) < simd_distance_squared($1, preferred) }
            }
        }
        struct RackPort {
            let face: RackMount.CableFace
            let side: RackMount.Side
            let lead: [SIMD3<Float>]
            let rearPost: SIMD3<Float>
        }
        struct End {
            let point: SIMD3<Float>
            let normal: SIMD3<Float>
            let root: Item
            let guide: SIMD2<Float>?
            let lead: [SIMD3<Float>]
            let rack: RackPort?
            let level: CableLevel
        }
        func rackPort(_ box: CableFootprint, contact: SIMD3<Float>, normal: SIMD3<Float>,
                      guide: SIMD2<Float>?) -> RackPort? {
            guard case .support(let id) = box.piece.id, supports[id]?.kind == .rack else { return nil }
            let rotation = box.piece.rotation.inverse
            let localNormal = rotation.act(normal)
            guard abs(localNormal.z) > 0.9 else { return nil }
            let local = rotation.act(contact - box.piece.position)
            let face: RackMount.CableFace = localNormal.z < 0 ? .front : .rear
            let guideSide = guide.map { rotation.act($0.atHeight(0) - box.piece.position).x } ?? 0
            let side: RackMount.Side = guideSide < 0 ? .left : .right
            let channel = face.channelDepth(in: box.size)
            guard (channel - local.z) * face.sign > 0.025 else { return nil }
            let turn = SIMD3(local.x, local.y, channel)
            let rail = SIMD3(side.sign * (box.size.x / 2 - RackMount.cableSideInset), local.y, channel)
            var rear = rail
            rear.z = RackMount.CableFace.rear.channelDepth(in: box.size)
            return .init(face: face, side: side,
                         lead: [contact, box.piece.world(turn), box.piece.world(rail)], rearPost: box.piece.world(rear))
        }
        func endpoint(_ id: String, _ port: String) -> End? {
            let item = Item.device(id)
            guard let device = devices[id], let local = try? LabScenePort.local(device, port) else { return nil }
            let solo = placed[item]
            guard let support = solo ?? placed[.support(device.placementID)], let box = byItem[support.id] else { return nil }
            let center = solo == nil ? device.offset : SIMD3(0, device.visualSize.y / 2, 0)
            let contact = support.world(center + local.point)
            let normal = support.rotation.act(local.normal)
            let guide = risers[support.id]
            let exit = box.lead(from: contact, normal: normal, toward: guide)
            return .init(point: contact, normal: normal, root: support.id, guide: guide, lead: exit,
                         rack: rackPort(box, contact: contact, normal: normal, guide: guide), level: level(for: item, on: support.id))
        }
        let pending = topology.pendingCableCircuits(in: layout)
        let links = topology.links.filter { !pending.contains($0.circuitID ?? $0.id) }
        // An older saved montage can have both devices placed individually, before their rack is added.
        var directTrunks: [String: LabTopology.Link] = [:]
        var bypassedSegments: Set<String> = []
        for trunk in links where trunk.autoPatchTrunk == true {
            let circuit = topology.circuit(for: trunk)
            guard let first = circuit.first, let last = circuit.last,
                  circuit.dropLast().contains(where: { endpoint($0.toDeviceID, $0.toPort) == nil }),
                  endpoint(first.fromDeviceID, first.fromPort) != nil,
                  endpoint(last.toDeviceID, last.toPort) != nil else { continue }
            var direct = trunk
            direct.fromDeviceID = first.fromDeviceID; direct.fromPort = first.fromPort
            direct.toDeviceID = last.toDeviceID; direct.toPort = last.toPort
            directTrunks[trunk.id] = direct
            bypassedSegments.formUnion(circuit.filter { $0.id != trunk.id }.map(\.id))
        }
        let connected = links.compactMap { segment -> (LabTopology.Link, End, End)? in
            guard !bypassedSegments.contains(segment.id) else { return nil }
            let link = directTrunks[segment.id] ?? segment
            guard link.medium != .powerA, link.medium != .powerB,
                  let a = endpoint(link.fromDeviceID, link.fromPort), let b = endpoint(link.toDeviceID, link.toPort) else { return nil }
            return (link, a, b)
        }
        guard !connected.isEmpty, let bottom = bounds.map({ $0.piece.position.y }).min(),
              let tallest = bounds.map(\.top).max() else { return .init() }
        let floor = bottom + 0.055
        let overhead = min(virtualCeiling.map { $0 - 0.055 } ?? .infinity, max(bottom + 2.15, tallest + 0.23))
        let tree = CableTree(bounds)
        let usedGuides = Set(connected.flatMap { [$0.1.guide, $0.2.guide].compactMap { $0 } })
        let paths = Dictionary(uniqueKeysWithValues: usedGuides.compactMap { guide in
            tree.path(from: guide).map { (guide, $0) }
        })
        var plan = CablePlan()
        plan.floor = bottom
        plan.overhead = overhead
        plan.anchors = bounds.map { .init(position: $0.piece.position, yaw: $0.piece.yaw, size: $0.size) }
        var channelPaths: [LabCablePacking.Path] = []
        struct TrunkEnd: Hashable {
            let root: Item
            let junction: SIMD3<Float>
        }
        var fixedPaths: [LabCablePacking.Path] = []
        var fixedConnections: [(link: LabTopology.Link, a: End, path: [SIMD3<Float>], b: End, mounted: (Bool, Bool))] = []
        var terminations: [TrunkEnd: LabCablePacking.Termination] = [:]
        struct RackFace: Hashable {
            let root: Item
            let face: RackMount.CableFace
            let depth: Int
        }
        struct RackDrop: Hashable {
            let track: RackFace
            let x: Int
        }
        struct DepthRun: Hashable {
            let root: Item
            let row: Int
            let face: RackMount.CableFace
            let from: Int
            let to: Int
            let portDepth: Int?
        }
        var patchRows: [RackFace: [Int: ClosedRange<Float>]] = [:]
        var rackRisers: [RackDrop: ClosedRange<Float>] = [:]
        var depthRuns: [DepthRun: (ports: ClosedRange<Float>, rows: ClosedRange<Float>)] = [:]
        var mountedLinks: [String: (start: Float, end: Float)] = [:]
        func registerRackSupport(root: Item, path: [SIMD3<Float>], ends: [End]) {
            guard let box = byItem[root] else { return }
            let inverse = box.piece.rotation.inverse
            let points = LabGeometry.cableCorners(path.map { inverse.act($0 - box.piece.position) })
            let contacts = ends.compactMap { end -> (point: SIMD3<Float>, face: RackMount.CableFace)? in
                end.rack.map { (inverse.act(end.point - box.piece.position), $0.face) }
            }
            func millimeters(_ value: Float) -> Int { Int((value * 1000).rounded()) }
            for (a, b) in zip(points, points.dropFirst()) {
                let delta = simd_abs(a - b)
                let center = (a + b) / 2
                let row = Int(((center.y - RackMount.base) / RackMount.unit + 0.0001).rounded(.down))
                let face: RackMount.CableFace = center.z < 0 ? .front : .rear
                let track = RackFace(root: root, face: face, depth: millimeters(center.z))
                if delta.x > 0.01, delta.y < 0.001, delta.z < 0.001 {
                    let heights = patchRows[track]?[row] ?? center.y...center.y
                    patchRows[track, default: [:]][row] = min(center.y, heights.lowerBound)...max(center.y, heights.upperBound)
                } else if delta.y > 0.025, delta.x < 0.001, delta.z < 0.001 {
                    let low = max(0.032, min(a.y, b.y)), high = min(box.size.y - 0.032, max(a.y, b.y))
                    guard high - low > 0.018 else { continue }
                    let drop = RackDrop(track: track, x: millimeters(center.x))
                    let heights = rackRisers[drop] ?? low...high
                    rackRisers[drop] = min(low, heights.lowerBound)...max(high, heights.upperBound)
                } else if delta.z > 0.055, delta.x < 0.001, delta.y < 0.001 {
                    let contact = contacts.first {
                        min(simd_distance_squared($0.point, a), simd_distance_squared($0.point, b)) < 0.000001
                    }
                    let sideBay = abs(center.x) > box.size.x / 2 - 0.052
                    guard contact != nil || sideBay else { continue }
                    let run = DepthRun(root: root, row: row, face: contact?.face ?? face,
                                       from: millimeters(min(a.z, b.z)), to: millimeters(max(a.z, b.z)),
                                       portDepth: contact.map { millimeters($0.point.z) })
                    let range = depthRuns[run] ?? (center.x...center.x, center.y...center.y)
                    depthRuns[run] = (min(center.x, range.ports.lowerBound)...max(center.x, range.ports.upperBound),
                                      min(center.y, range.rows.lowerBound)...max(center.y, range.rows.upperBound))
                }
            }
        }

        func registerFixedEnd(_ end: End, at junction: SIMD3<Float>) {
            guard let box = byItem[end.root], let lead = end.lead.last,
                  simd_distance_squared(lead.xz, junction.xz) < 0.000001 else { return }
            guard end.rack == nil else { return }
            let nominalTop = box.top - 0.11
            let nominalBottom = box.piece.position.y + 0.24
            let topEntry = junction.y > lead.y
            let y = topEntry ? min(junction.y, max(lead.y, nominalTop))
                : max(junction.y, min(lead.y, nominalBottom))
            let stop = junction.xz.atHeight(abs(y - junction.y) < 0.065 ? junction.y : y)
            let key = TrunkEnd(root: end.root, junction: junction)
            if let existing = terminations[key], abs(existing.point.y - junction.y) <= abs(stop.y - junction.y) { return }
            terminations[key] = .init(point: stop, yaw: box.piece.yaw, side: nil)
        }
        func rackFeed(_ end: End, joining junction: SIMD3<Float>) -> [SIMD3<Float>] {
            guard let port = end.rack, let box = byItem[end.root] else { return [] }
            let post = port.rearPost
            let exitsAbove = junction.y > post.y
            let entryY = exitsAbove ? min(junction.y, box.top + 0.009)
                : max(junction.y, box.piece.position.y + 0.07)
            let entry = post.xz.atHeight(entryY)
            let title = TrunkEnd(root: end.root, junction: entry)
            terminations[title] = .init(point: entry, yaw: box.piece.yaw, side: port.side)
            return [entry, post.xz.atHeight(junction.y)]
        }
        func height(_ level: CableLevel) -> Float { level == .floor ? floor : overhead }
        for (link, a, b) in connected {
            let radius = link.medium.referenceBendRadius
            let levelA = link.arRouteLevel ?? a.level, levelB = link.arRouteLevel ?? b.level
            let enoughHeight = levelA != .overhead && levelB != .overhead || overhead > tallest + 0.12
            let waypointHeight = levelA == levelB && a.root != b.root ? height(levelA) : nil
            var middle: [SIMD3<Float>] = []
            var routed = false
            var usesWaypoints = false
            let manual = waypoints?[link.id] ?? []
            func approach(_ lead: [SIMD3<Float>], to junction: SIMD3<Float>?) -> [SIMD3<Float>] {
                guard let junction, let last = lead.last, abs(junction.y - last.y) > 0.0001,
                      abs(junction.y - last.y) < 2 * radius + 0.004,
                      simd_distance_squared(junction.xz, last.xz) < 0.000001 else { return lead }
                // A short rise needs a ramp into the guide, with enough space to round both ends.
                var ramp = lead
                while ramp.count > 2, let last = ramp.last,
                      simd_distance_squared(junction.xz, last.xz) < 0.000001 { ramp.removeLast() }
                return ramp
            }
            func routePoints(_ tray: [SIMD3<Float>]) -> [SIMD3<Float>] {
                approach(a.lead, to: tray.first) + tray + approach(b.lead, to: tray.last).reversed()
            }
            func lead(_ end: End, junction: SIMD3<Float>?) -> [SIMD3<Float>] {
                guard let port = end.rack else { return approach(end.lead, to: junction) }
                guard let junction else { return port.lead }
                return port.lead + [port.rearPost, port.rearPost.xz.atHeight(junction.y)]
            }
            func trayOptions(_ tray: [SIMD3<Float>]) -> [[SIMD3<Float>]] {
                guard let start = tray.first, let end = tray.last else { return [tray] }
                func corners(from port: RackPort?, to point: SIMD3<Float>) -> [[SIMD3<Float>]] {
                    guard let post = port?.rearPost,
                          abs(post.x - point.x) > 0.001, abs(post.z - point.z) > 0.001 else { return [[]] }
                    return [[SIMD3(post.x, point.y, point.z)], [SIMD3(point.x, point.y, post.z)]]
                }
                return corners(from: a.rack, to: start).flatMap { entry in
                    corners(from: b.rack, to: end).map { entry + tray + $0 }
                }
            }
            func preferredPoints(_ tray: [SIMD3<Float>]) -> [SIMD3<Float>] {
                lead(a, junction: tray.first) + tray + lead(b, junction: tray.last).reversed()
            }
            func pathLength(_ points: [SIMD3<Float>]) -> Float {
                zip(points, points.dropFirst()).reduce(0) { $0 + simd_distance($1.0, $1.1) }
            }
            if a.root == b.root {
                routed = true
            } else if enoughHeight, let start = a.guide, let end = b.guide {
                if start == end && levelA == levelB {
                    routed = true
                } else if let first = paths[start], let second = paths[end] {
                    let routeA: [SIMD2<Float>], routeB: [SIMD2<Float>]
                    if levelA == levelB {
                        // Prune common tail once both branches have reached the same junction.
                        let indices = Dictionary(uniqueKeysWithValues: second.enumerated().map { ($0.element, $0.offset) })
                        let junction = first.enumerated().first { indices[$0.element] != nil }
                        routeA = junction.map { Array(first.prefix($0.offset + 1)) } ?? first
                        routeB = junction.flatMap { indices[$0.element] }.map { Array(second.prefix($0 + 1)) } ?? second
                    } else {
                        routeA = first + [tree.changeLevel]
                        routeB = second + [tree.changeLevel]
                    }
                    middle = routeA.map { $0.atHeight(height(levelA)) }
                        + routeB.reversed().map { $0.atHeight(height(levelB)) }
                    if levelA == levelB, (a.rack != nil || b.rack != nil),
                       let direct = tree.route(through: [start, end])?.map({ $0.atHeight(height(levelA)) }),
                       pathLength(direct) + 0.20 < pathLength(middle),
                       trayOptions(direct).contains(where: { LabGeometry.cableBends(preferredPoints($0), radius: radius) != nil }) {
                        middle = direct
                    }
                    routed = true
                }
                if !manual.isEmpty, manual.count <= 4, levelA == levelB, a.root != b.root,
                   manual.allSatisfy({ point in
                       point.x.isFinite && point.y.isFinite && !bounds.contains { $0.containsInterior(point) }
                   }),
                   let route = CableTree(bounds, additional: manual).route(through: [start] + manual + [end]) {
                    let alternative = route.map { $0.atHeight(height(levelA)) }
                    if trayOptions(alternative).contains(where: { LabGeometry.cableBends(preferredPoints($0), radius: radius) != nil }) {
                        middle = alternative
                        usesWaypoints = true
                        routed = true
                    }
                }
            }
            var mounted = (false, false)
            var leads = [a.lead, b.lead]
            var raw = routePoints(middle)
            var smooth: [SIMD3<Float>]?
            if routed {
                if a.root != b.root, !middle.isEmpty, a.rack != nil || b.rack != nil {
                    for option in trayOptions(middle) {
                        let orthogonal = preferredPoints(option)
                        guard let rounded = LabGeometry.cableBends(orthogonal, radius: radius) else { continue }
                        middle = option
                        raw = orthogonal
                        smooth = rounded
                        leads = [lead(a, junction: option.first), lead(b, junction: option.last)]
                        mounted = (a.rack != nil, b.rack != nil)
                        break
                    }
                } else if a.root == b.root, a.rack != nil || b.rack != nil {
                    let first = lead(a, junction: middle.first), second = lead(b, junction: middle.last)
                    var preferred = first + middle + second.reversed()
                    if a.root == b.root, let sideA = a.rack?.face, let sideB = b.rack?.face, sideA != sideB,
                       let postA = first.last, let postB = second.last {
                        // The side bay connects front and rear at a common level, clear of equipment.
                        let level = (postA.y + postB.y) / 2
                        preferred = first + [postA.xz.atHeight(level), postB.xz.atHeight(level)] + second.reversed()
                    }
                    var preferredPath = LabGeometry.cableBends(preferred, radius: radius)
                    if preferredPath == nil, a.root == b.root, let portA = a.rack, let portB = b.rack,
                       let box = byItem[a.root] {
                        // Adjacent units need a common horizontal level below the jacks to fit both bends.
                        let clearance = 2 * radius + 0.004
                        let y = min(a.point.y, b.point.y) - clearance
                        let postA = portA.lead[2], postB = portB.lead[2]
                        let lowRail = first + [postA.xz.atHeight(y), postB.xz.atHeight(y)] + second.reversed()
                        if let rounded = LabGeometry.cableBends(lowRail, radius: radius) {
                            preferred = lowRail
                            preferredPath = rounded
                        } else if portA.face == portB.face {
                            let shortA = Array(first.prefix(2)), shortB = Array(second.prefix(2))
                            let turnA = shortA[1], turnB = shortB[1]
                            let lowerA = turnA.xz.atHeight(y), lowerB = turnB.xz.atHeight(y)
                            let across = shortA + [lowerA, lowerB] + shortB.reversed()
                            if let rounded = LabGeometry.cableBends(across, radius: radius) {
                                preferred = across
                                preferredPath = rounded
                            } else {
                                // Use two depths at the side when ports are nearly aligned across adjacent units.
                                let inverse = box.piece.rotation.inverse
                                let x = inverse.act((turnA + turnB) / 2 - box.piece.position).x
                                let side: Float = x < 0 ? 1 : -1
                                let sideX = side * (box.size.x / 2 - RackMount.cableSideInset)
                                var sidePoint = inverse.act(lowerA - box.piece.position)
                                sidePoint.x = sideX
                                let acrossSide = box.piece.world(sidePoint)
                                let extraDepth = -a.normal * clearance
                                let loop = shortA + [lowerA, acrossSide, acrossSide + extraDepth,
                                                    lowerB + extraDepth, lowerB] + shortB.reversed()
                                if let rounded = LabGeometry.cableBends(loop, radius: radius) {
                                    preferred = loop
                                    preferredPath = rounded
                                }
                            }
                        }
                    }
                    if let preferredPath {
                        raw = preferred
                        smooth = preferredPath
                        leads = [first, second]
                        mounted = (a.rack != nil, b.rack != nil)
                    }
                }
                if smooth == nil {
                    smooth = LabGeometry.cableBends(raw, radius: radius)
                    if smooth == nil && !usesWaypoints && a.rack == nil && b.rack == nil {
                        raw = Self.relaxShortJogs(raw, radius: radius)
                        smooth = LabGeometry.cableBends(raw, radius: radius)
                    }
                }
            }
            if smooth == nil || (!manual.isEmpty && !usesWaypoints) { plan.reviewCount += 1 }
            let rackLeads = leads
            leads = routed ? leads.map { LabGeometry.cableBends($0, radius: radius) ?? $0 }
                : [a, b].map { [$0.point, $0.point + $0.normal * 0.07] }
            if let smooth {
                channelPaths.append(LabCablePacking.guidePath(.init(link: link, points: raw)))
                if mounted.0 || mounted.1 {
                    mountedLinks[link.id] = a.root == b.root && mounted.0 && mounted.1
                        ? (pathLength(smooth), 0)
                        : (mounted.0 ? pathLength(leads[0]) : 0, mounted.1 ? pathLength(leads[1]) : 0)
                }
                if a.root == b.root, mounted.0 || mounted.1 {
                    registerRackSupport(root: a.root, path: raw, ends: [a, b])
                } else {
                    if mounted.0 { registerRackSupport(root: a.root, path: rackLeads[0], ends: [a]) }
                    if mounted.1 { registerRackSupport(root: b.root, path: rackLeads[1], ends: [b]) }
                }
                if let first = middle.first, let last = middle.last {
                    if !mounted.0 { registerFixedEnd(a, at: first) }
                    if !mounted.1 { registerFixedEnd(b, at: last) }
                    fixedConnections.append((link, a, middle, b, mounted))
                }
            }
            let endpoints = [
                LabScenePort(deviceID: link.fromDeviceID, name: link.fromPort, point: a.point, normal: a.normal),
                LabScenePort(deviceID: link.toDeviceID, name: link.toPort, point: b.point, normal: b.normal)
            ]
            plan.connections.append(.init(link: link, endpoints: endpoints, points: smooth ?? [],
                                          leads: leads, routed: smooth != nil, bendRadius: smooth == nil ? nil : radius,
                                          usesWaypoints: usesWaypoints, waypointHeight: waypointHeight))
        }
        for connection in fixedConnections {
            let first = connection.path[0], last = connection.path[connection.path.count - 1]
            let entry = connection.mounted.0 ? rackFeed(connection.a, joining: first)
                : [terminations[.init(root: connection.a.root, junction: first)]?.point ?? first]
            let exit = connection.mounted.1 ? rackFeed(connection.b, joining: last)
                : [terminations[.init(root: connection.b.root, junction: last)]?.point ?? last]
            fixedPaths.append(.init(link: connection.link, points: entry + connection.path + exit.reversed()))
        }
        let roomRuns = LabCablePacking.runs(fixedPaths)
        let roomOffsets = LabCablePacking.offsets(for: fixedPaths, sharing: roomRuns)
        let roomLinks = Set(fixedPaths.map(\.link.id))
        let patchPaths = channelPaths.filter { !roomLinks.contains($0.link.id) }
        let patchOffsets = LabCablePacking.offsets(for: patchPaths, sharing: LabCablePacking.runs(patchPaths))
        let offsets = roomOffsets.merging(patchOffsets) { room, _ in room }
        let rackEntries = Set(terminations.values.filter(\.rack).map { $0.point.xz })
        for run in roomRuns {
            let rackFeed = simd_distance_squared(run.start.xz, run.end.xz) < 0.000001
                && rackEntries.contains { simd_distance_squared($0, run.start.xz) < 0.000001 }
            let guide = run.guide(offsets: offsets, offsetScale: rackFeed ? LabCablePacking.rackBundleScale : 1)
            plan.channels.append(guide)
            if guide.overCapacity { plan.overCapacityLinks.formUnion(run.links.map(\.id)) }
        }
        plan.terminations = Array(Set(terminations.values))
        func rackAnchor(_ item: Item) -> LabCablePacking.Anchor? {
            byItem[item].map { .init(position: $0.piece.position, yaw: $0.piece.yaw, size: $0.size) }
        }
        for (key, rows) in patchRows {
            guard let anchor = rackAnchor(key.root) else { continue }
            plan.organizers += rows.values.map {
                .init(rack: anchor, face: key.face, mount: .horizontal(rows: $0), routeDepth: Float(key.depth) / 1000)
            }
        }
        for (key, heights) in rackRisers {
            guard let anchor = rackAnchor(key.track.root) else { continue }
            plan.organizers.append(.init(rack: anchor, face: key.track.face,
                mount: .vertical(x: Float(key.x) / 1000, heights: heights), routeDepth: Float(key.track.depth) / 1000))
        }
        for (key, envelope) in depthRuns {
            guard let anchor = rackAnchor(key.root) else { continue }
            plan.organizers.append(.init(rack: anchor, face: key.face,
                mount: .depthRun(ports: envelope.ports, rows: envelope.rows, span: Float(key.from) / 1000...Float(key.to) / 1000),
                portDepth: key.portDepth.map { Float($0) / 1000 }))
        }
        for index in plan.connections.indices where plan.connections[index].routed {
            if let offset = offsets[plan.connections[index].link.id] {
                let connection = plan.connections[index]
                let mounted = mountedLinks[connection.link.id] ?? (0, 0)
                plan.connections[index].points = LabCablePacking.strand(connection.points, offset: offset,
                    mountedStart: mounted.start, mountedEnd: mounted.end)
            } else {
                plan.connections[index].points = []
                plan.connections[index].routed = false
                plan.overCapacityLinks.insert(plan.connections[index].link.id)
            }
        }
        return plan
    }

    private static func relaxShortJogs(_ raw: [SIMD3<Float>], radius: Float) -> [SIMD3<Float>] {
        var path = LabGeometry.cableCorners(raw)
        guard path.count >= 4 else { return path }
        for index in 1..<(path.count - 2) {
            let incoming = path[index] - path[index - 1]
            let jog = path[index + 1] - path[index]
            let outgoing = path[index + 2] - path[index + 1]
            guard simd_length(jog) < 2.1 * radius, simd_length(incoming) >= 3 * radius,
                  simd_length(outgoing) >= 3 * radius else { continue }
            let a = simd_normalize(incoming), b = simd_normalize(outgoing)
            guard simd_dot(a, b) > -0.1 else { continue }
            path[index] -= a * (1.8 * radius)
            path[index + 1] += b * (1.8 * radius)
        }
        return path
    }

    struct CablePlan {
        struct Connection {
            let link: LabTopology.Link
            let endpoints: [LabScenePort]
            var points: [SIMD3<Float>]
            let leads: [[SIMD3<Float>]]
            var routed: Bool
            let bendRadius: Float?
            let usesWaypoints: Bool
            let waypointHeight: Float?
        }
        var connections: [Connection] = []
        var channels: [LabCablePacking.Guide] = []
        var anchors: [LabCablePacking.Anchor] = []
        var terminations: [LabCablePacking.Termination] = []
        var organizers: [LabCablePacking.Organizer] = []
        var floor: Float = 0
        var overhead: Float = 0
        var overCapacityLinks: Set<String> = []
        var reviewCount = 0
    }

    private struct CableFootprint {
        let piece: Piece
        let size: SIMD3<Float>
        let min: SIMD2<Float>
        let max: SIMD2<Float>
        let top: Float

        init(piece: Piece, size: SIMD3<Float>) {
            self.piece = piece
            self.size = size
            let c = abs(cos(piece.yaw)), s = abs(sin(piece.yaw))
            let half = SIMD2(c * size.x + s * size.z, s * size.x + c * size.z) / 2 + SIMD2(repeating: 0.14)
            min = piece.position.xz - half
            max = piece.position.xz + half
            top = piece.position.y + size.y
        }

        var corners: [SIMD2<Float>] { [max, SIMD2(min.x, max.y), SIMD2(max.x, min.y), min] }

        func containsInterior(_ p: SIMD2<Float>) -> Bool {
            p.x > min.x && p.x < max.x && p.y > min.y && p.y < max.y
        }

        func lead(from contact: SIMD3<Float>, normal: SIMD3<Float>, toward guide: SIMD2<Float>?) -> [SIMD3<Float>] {
            guard let guide else { return [contact, contact + normal * 0.10] }
            let direction = normal.xz
            let point = contact.xz
            let stop = SIMD2(direction.x >= 0 ? max.x : min.x, direction.y >= 0 ? max.y : min.y)
            let x = abs(direction.x) > 0.0001 ? (stop.x - point.x) / direction.x : .infinity
            let z = abs(direction.y) > 0.0001 ? (stop.y - point.y) / direction.y : .infinity
            var exit = point + direction * Swift.max(0, Swift.min(x, z))
            if x <= z { exit.x = stop.x } else { exit.y = stop.y }
            let bend = x <= z ? SIMD2(exit.x, guide.y) : SIMD2(guide.x, exit.y)
            return [contact, exit.atHeight(contact.y), bend.atHeight(contact.y), guide.atHeight(contact.y)]
        }
    }

    // A single tree growing from the trunk makes branches converge and routes around placed furniture.
    private struct CableTree {
        let xs: [Float]
        let zs: [Float]
        let parents: [Int]
        let changeLevel: SIMD2<Float>
        let noRight: [Bool]
        let noDown: [Bool]

        init(_ boxes: [CableFootprint], additional: [SIMD2<Float>] = []) {
            let xs = Array(Set(boxes.flatMap { [$0.min.x, $0.max.x] } + additional.map(\.x))).sorted()
            let front = min(boxes.map { $0.min.y }.min()!, additional.map(\.y).min() ?? .infinity) - 0.30
            let zs = Array(Set(boxes.flatMap { [$0.min.y, $0.max.y] } + additional.map(\.y) + [front])).sorted()
            self.xs = xs
            self.zs = zs
            changeLevel = SIMD2((xs.first ?? 0) - 0.18, front)
            let width = xs.count
            var noRight = Array(repeating: false, count: width * zs.count)
            var noDown = noRight
            let col = Dictionary(uniqueKeysWithValues: xs.enumerated().map { ($0.element, $0.offset) })
            let row = Dictionary(uniqueKeysWithValues: zs.enumerated().map { ($0.element, $0.offset) })
            for box in boxes {
                let left = col[box.min.x]!, right = col[box.max.x]!
                let top = row[box.min.y]!, bottom = row[box.max.y]!
                for z in top..<bottom {
                    for x in left..<right {
                        let node = z * width + x
                        if z > top { noRight[node] = true }
                        if x > left { noDown[node] = true }
                    }
                }
            }
            self.noRight = noRight
            self.noDown = noDown
            parents = Self.search(width: width, noRight: noRight, noDown: noDown, roots: Array(xs.indices))
        }

        private static func search(width: Int, noRight: [Bool], noDown: [Bool],
                                   roots: [Int], excluded: Set<Int> = []) -> [Int] {
            var parents = Array(repeating: -1, count: noRight.count)
            var queue = roots
            for root in queue { parents[root] = root }
            var head = 0
            while head < queue.count {
                let node = queue[head]
                head += 1
                let column = node % width
                func visit(_ next: Int) {
                    guard parents[next] == -1, !excluded.contains(next) else { return }
                    parents[next] = node
                    queue.append(next)
                }
                if node + width < parents.count, !noDown[node] { visit(node + width) }
                if column > 0, !noRight[node - 1] { visit(node - 1) }
                if column < width - 1, !noRight[node] { visit(node + 1) }
                if node >= width, !noDown[node - width] { visit(node - width) }
            }
            return parents
        }

        func path(from point: SIMD2<Float>) -> [SIMD2<Float>]? {
            guard let node = index(of: point) else { return nil }
            return path(from: node, using: parents)
        }

        func route(through points: [SIMD2<Float>]) -> [SIMD2<Float>]? {
            let nodes = points.compactMap(index(of:))
            guard nodes.count == points.count, Set(nodes).count == nodes.count else { return nil }
            var route: [SIMD2<Float>] = []
            for (start, end) in zip(nodes, nodes.dropFirst()) {
                let used = Set(route.dropLast().compactMap(index(of:)))
                let parents = Self.search(width: xs.count, noRight: noRight, noDown: noDown,
                                          roots: [end], excluded: used.union(nodes.dropFirst().filter { $0 != start && $0 != end }))
                guard !used.contains(end), let next = path(from: start, using: parents) else { return nil }
                route += route.isEmpty ? next : Array(next.dropFirst())
            }
            return route
        }

        private func index(of point: SIMD2<Float>) -> Int? {
            guard let col = xs.firstIndex(of: point.x), let row = zs.firstIndex(of: point.y) else { return nil }
            return row * xs.count + col
        }

        private func path(from node: Int, using parents: [Int]) -> [SIMD2<Float>]? {
            guard parents[node] >= 0 else { return nil }
            var cursor = node
            var path = [SIMD2(xs[cursor % xs.count], zs[cursor / xs.count])]
            while parents[cursor] != cursor {
                cursor = parents[cursor]
                path.append(SIMD2(xs[cursor % xs.count], zs[cursor / xs.count]))
            }
            return path
        }
    }
}

private extension SIMD3 where Scalar == Float {
    nonisolated var xz: SIMD2<Float> { SIMD2(x, z) }
}

private extension SIMD2 where Scalar == Float {
    nonisolated func atHeight(_ height: Float) -> SIMD3<Float> { SIMD3(x, height, y) }
}

struct LabARAssemblyStore {
    private static let keyPrefix = "arAssemblies.v1."
    private let key: String
    private let defaults: UserDefaults

    init(scope: String, defaults: UserDefaults = .standard) {
        key = Self.keyPrefix + scope
        self.defaults = defaults
    }

    func all() throws -> [LabARAssembly] {
        guard let bytes = defaults.data(forKey: key) else { return [] }
        return try JSONDecoder().decode([LabARAssembly].self, from: bytes)
    }

    var preferredID: UUID? {
        get { defaults.string(forKey: key + ".preferred").flatMap(UUID.init(uuidString:)) }
        nonmutating set { defaults.set(newValue?.uuidString, forKey: key + ".preferred") }
    }

    @discardableResult
    func save(_ assembly: LabARAssembly) throws -> LabARAssembly {
        var list = try all()
        var montage = assembly
        if let index = list.firstIndex(where: { $0.id == assembly.id }) {
            list[index] = montage
        } else {
            montage.name = try availableName(assembly.name, in: list)
            list.insert(montage, at: 0)
        }
        defaults.set(try JSONEncoder().encode(list), forKey: key)
        return montage
    }

    @discardableResult
    func rename(_ id: UUID, to name: String) throws -> LabARAssembly {
        var list = try all()
        guard let index = list.firstIndex(where: { $0.id == id }) else {
            throw LabLayoutError.invalid("La ubicación ya no está guardada.")
        }
        list[index].name = try availableName(name, in: list.filter { $0.id != id })
        defaults.set(try JSONEncoder().encode(list), forKey: key)
        return list[index]
    }

    func delete(_ id: UUID, mapURL: (LabARAssembly) -> URL) throws {
        var list = try all()
        guard let index = list.firstIndex(where: { $0.id == id }) else { return }
        let assembly = list.remove(at: index)
        let bytes = try JSONEncoder().encode(list)
        // Editable laboratory copies can share a world map by assembly UUID.
        let sharedMap = defaults.dictionaryRepresentation().contains { otherKey, value in
            guard otherKey != key, otherKey.hasPrefix(Self.keyPrefix), let data = value as? Data else { return false }
            guard let others = try? JSONDecoder().decode([LabARAssembly].self, from: data) else { return true }
            return others.contains(where: { $0.id == id })
        }
        if !sharedMap {
            do {
                try FileManager.default.removeItem(at: mapURL(assembly))
            } catch let error as CocoaError where error.code == .fileNoSuchFile {
                // A location that was never calibrated has no map.
            }
        }
        defaults.set(bytes, forKey: key)
        if preferredID == id { preferredID = nil }
    }

    private func availableName(_ rawName: String, in list: [LabARAssembly]) throws -> String {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 60,
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw LabLayoutError.invalid("Escribe un nombre de hasta 60 caracteres en una sola línea.")
        }
        guard !list.contains(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) else {
            throw LabLayoutError.invalid("Ya existe un montaje con ese nombre en este laboratorio.")
        }
        return name
    }
}
