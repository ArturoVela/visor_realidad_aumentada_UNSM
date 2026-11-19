import Foundation
import simd

nonisolated struct LabPlacement: Identifiable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case rack, workstation }
    let id: String
    let kind: Kind
    let title: String
    let position: SIMD3<Float>
    let yaw: Float
    let size: SIMD3<Float>
}

nonisolated struct LabLayout: Sendable {
    let area: Float
    let floorHeight: Float
    let floorPolygon: [SIMD2<Float>]
    let placements: [LabPlacement]
    let warnings: [String]
    var facility: TierFacility? = nil
}

nonisolated enum LabARScale: Int, CaseIterable, Sendable {
    case fullSize = 1, half = 2, fifth = 5, tenth = 10, twentieth = 20

    var title: String { "1:\(rawValue)" }
    var factor: Float { 1 / Float(rawValue) }
}

nonisolated struct LabARSpace: Sendable {
    let size: SIMD3<Double>
    var floorArea: Double { size.x * size.z }

    init?(virtualRoom room: RoomStructure, layout: LabLayout) {
        let floor = layout.floorPolygon
        guard floor.count >= 3,
              let left = floor.map(\.x).min(), let right = floor.map(\.x).max(),
              let front = floor.map(\.y).min(), let back = floor.map(\.y).max(),
              let height = room.surfaces.filter({ $0.kind == .wall })
                .compactMap({ $0.dimensions.dropFirst().first }).max() else { return nil }
        let dimensions = SIMD3(Double(right - left), Double(height), Double(back - front))
        guard [dimensions.x, dimensions.y, dimensions.z].allSatisfy({ $0.isFinite && $0 > 0 }) else { return nil }
        size = dimensions
    }

    private init(size: SIMD3<Double>) { self.size = size }

    func scaled(to scale: LabARScale) -> LabARSpace {
        LabARSpace(size: size / Double(scale.rawValue))
    }
}

nonisolated struct TierFacility: Equatable, Sendable {
    // Footprint of this template, including circulation allowance, in metres.
    static let width: Float = 14.6
    static let depth: Float = 10.8
    static let minimumHeight: Float = 3.1
    let origin: SIMD3<Float>
    let yaw: Float
    let height: Float
    var conduitHeight: Float { min(2.65, height - 0.43) }
    static let conduitAZ: Float = -3.96

    func world(_ point: SIMD3<Float>) -> SIMD3<Float> {
        origin + simd_quatf(angle: yaw, axis: SIMD3(0, 1, 0)).act(point)
    }

    func place(_ placement: LabPlacement) -> LabPlacement {
        LabPlacement(id: placement.id, kind: placement.kind, title: placement.title,
                     position: world(placement.position), yaw: placement.yaw + yaw, size: placement.size)
    }

    static func fit(room: RoomStructure, layout: LabLayout) throws -> TierFacility {
        let heights = try room.surfaces.filter { $0.kind == .wall }.map {
            try LabGeometry.matrix($0).columns.3.y + $0.dimensions[1] / 2 - layout.floorHeight
        }
        let height = heights.min() ?? 0
        let floor = layout.floorPolygon
        guard height >= minimumHeight, layout.area >= width * depth, floor.count >= 3 else { throw fitError }
        let edges = zip(floor, floor.dropFirst() + floor.prefix(1)).map { $1 - $0 }
        guard let longest = edges.max(by: { simd_length_squared($0) < simd_length_squared($1) }),
              simd_length_squared(longest) > 0.01 else { throw fitError }
        let base = atan2(-longest.y, longest.x)
        let openings = try room.surfaces.filter { $0.kind == .door || $0.kind == .opening }.map {
            try LabGeometry.matrix($0).columns.3
        }
        for turn in 0..<4 {
            let yaw = base + Float(turn) * .pi / 2
            let x = SIMD2(cos(yaw), -sin(yaw)), z = SIMD2(sin(yaw), cos(yaw))
            let xs = floor.map { simd_dot($0, x) }, zs = floor.map { simd_dot($0, z) }
            guard let xMin = xs.min(), let xMax = xs.max(), let zMin = zs.min(), let zMax = zs.max(),
                  xMax - xMin >= width, zMax - zMin >= depth else { continue }
            let center = x * ((xMax + xMin) / 2) + z * ((zMax + zMin) / 2)
            let corners = [SIMD2<Float>(-1, -1), SIMD2(1, -1), SIMD2(1, 1), SIMD2(-1, 1)].map {
                center + x * ($0.x * width / 2) + z * ($0.y * depth / 2)
            }
            guard corners.indices.allSatisfy({
                LabGeometry.traySpanFits(from: corners[$0], to: corners[($0 + 1) % 4], within: floor)
            }) else { continue }
            // A nearby opening must lead to the clear operator side, away from the technical bays.
            let hasAccess = openings.contains {
                let delta = SIMD2($0.x, $0.z) - center
                return simd_dot(delta, z) > depth / 2 - 0.75
            }
            if hasAccess {
                return TierFacility(origin: SIMD3(center.x, layout.floorHeight, center.y), yaw: yaw, height: height)
            }
        }
        throw fitError
    }

    private static var fitError: LabLayoutError {
        .invalid("La plantilla necesita una zona libre de al menos 14,6 × 10,8 m, 3,1 m de altura y acceso por operación. Usa el cuarto 3D para revisar el contorno.")
    }
}

nonisolated enum LabLayoutError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let message) = self { message } else { nil } }
}

nonisolated enum LabGeometry {
    static func orbitDistance(for points: [SIMD3<Float>], target: SIMD3<Float>, rotation: simd_quatf,
                              aspect: Float, verticalField: Float) -> Float {
        let vertical = tan(verticalField * .pi / 360) * 0.86
        let horizontal = vertical * aspect
        let inverse = rotation.inverse
        return points.reduce(Float(2.4)) { distance, point in
            let local = inverse.act(point - target)
            return max(distance, local.z + max(0.12, abs(local.x) / horizontal, abs(local.y) / vertical))
        }
    }

    static func matrix(_ surface: RoomStructure.Surface) throws -> simd_float4x4 {
        let a = surface.transformColumnMajor
        guard a.count == 16, a.allSatisfy(\.isFinite),
              surface.dimensions.count == 3,
              surface.dimensions.allSatisfy({ $0.isFinite && $0 >= 0 }),
              surface.dimensions.contains(where: { $0 > 0 }),
              abs(a[3]) < 0.0001, abs(a[7]) < 0.0001,
              abs(a[11]) < 0.0001, abs(a[15] - 1) < 0.0001
        else { throw LabLayoutError.invalid("Superficie con matriz o dimensiones inválidas: \(surface.id).") }
        let m = simd_float4x4(columns: (
            SIMD4(a[0], a[1], a[2], a[3]), SIMD4(a[4], a[5], a[6], a[7]),
            SIMD4(a[8], a[9], a[10], a[11]), SIMD4(a[12], a[13], a[14], a[15])))
        let r = simd_float3x3(columns: (SIMD3(a[0], a[1], a[2]), SIMD3(a[4], a[5], a[6]),
                                       SIMD3(a[8], a[9], a[10])))
        guard (0..<3).allSatisfy({ abs(simd_length(r[$0]) - 1) < 0.01 }),
              abs(simd_dot(r[0], r[1])) < 0.01, abs(simd_dot(r[0], r[2])) < 0.01,
              abs(simd_dot(r[1], r[2])) < 0.01, abs(simd_determinant(r) - 1) < 0.01
        else { throw LabLayoutError.invalid("La transformación no es rígida y dextrógira: \(surface.id).") }
        return m
    }

    static func worldPoint(_ surface: RoomStructure.Surface, _ point: SIMD3<Float>) throws -> SIMD3<Float> {
        guard point.x.isFinite, point.y.isFinite, point.z.isFinite else {
            throw LabLayoutError.invalid("Vértice no finito.")
        }
        let p = try matrix(surface) * SIMD4(point, 1)
        return SIMD3(p.x, p.y, p.z)
    }

    static func contains(_ p: SIMD2<Float>, polygon: [SIMD2<Float>]) -> Bool {
        guard polygon.count >= 3, p.x.isFinite, p.y.isFinite else { return false }
        var inside = false
        for i in polygon.indices {
            let a = polygon[i], b = polygon[(i + 1) % polygon.count]
            if pointDistance(p, a, b) < 0.00001 { return true }
            if (a.y > p.y) != (b.y > p.y),
               p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
        }
        return inside
    }

    static func traySpanFits(from a: SIMD2<Float>, to b: SIMD2<Float>, within polygon: [SIMD2<Float>]) -> Bool {
        contains(a, polygon: polygon) && contains(b, polygon: polygon) &&
            polygon.indices.allSatisfy {
                segmentDistance(a, b, polygon[$0], polygon[($0 + 1) % polygon.count]) >= 0.065
            }
    }

    static func trayPath(from a: SIMD2<Float>, to b: SIMD2<Float>, within polygon: [SIMD2<Float>]) -> [SIMD2<Float>]? {
        guard contains(a, polygon: polygon), contains(b, polygon: polygon) else { return nil }
        func fits(_ start: SIMD2<Float>, _ end: SIMD2<Float>) -> Bool {
            traySpanFits(from: start, to: end, within: polygon)
        }
        if fits(a, b) { return [a, b] }
        // shortcut: one interior bend covers simple cutouts. Rooms requiring more bends need an authored tray route.
        let direction: Float = signedArea(polygon) > 0 ? 1 : -1
        func inward(_ edge: SIMD2<Float>) -> SIMD2<Float> {
            SIMD2(-edge.y, edge.x) * direction / max(simd_length(edge), 0.0001)
        }
        var best: SIMD2<Float>?
        var length = Float.infinity
        for i in polygon.indices {
            let corner = polygon[i]
            let before = inward(corner - polygon[(i + polygon.count - 1) % polygon.count])
            let after = inward(polygon[(i + 1) % polygon.count] - corner)
            let bend = corner + (before + after) * 0.18
            let distance = simd_distance(a, bend) + simd_distance(b, bend)
            if distance < length, fits(a, bend), fits(bend, b) { best = bend; length = distance }
        }
        return best.map { [a, $0, b] }
    }

    static func cableBends(_ points: [SIMD3<Float>], radius: Float, segmentsPerBend: Int = 6) -> [SIMD3<Float>]? {
        guard radius.isFinite, radius > 0, (2...12).contains(segmentsPerBend) else { return nil }
        var path: [SIMD3<Float>] = []
        for point in points where path.last.map({ simd_distance($0, point) > 0.0001 }) ?? true {
            if path.count >= 2 {
                let incoming = simd_normalize(path[path.count - 1] - path[path.count - 2])
                let outgoing = simd_normalize(point - path[path.count - 1])
                if simd_dot(incoming, outgoing) > 0.9999 { path.removeLast() }
            }
            path.append(point)
        }
        guard path.count > 2 else { return path }
        var arcs: [[SIMD3<Float>]] = [[path[0]]]
        var previousTrim: Float = 0
        for i in 1..<(path.count - 1) {
            let incoming = path[i] - path[i - 1], outgoing = path[i + 1] - path[i]
            let u = simd_normalize(incoming), v = simd_normalize(outgoing)
            let cosine = simd_dot(u, v)
            guard cosine > -0.9999 else { return nil }
            let angle = acos(min(1, cosine))
            let trim = radius * tan(angle / 2)
            guard previousTrim + trim <= simd_length(incoming) + 0.0001,
                  trim <= simd_length(outgoing) + 0.0001 else { return nil }
            let axis = simd_normalize(simd_cross(u, v))
            let radial = -simd_cross(axis, u) * radius
            let center = path[i] - u * trim - radial
            arcs.append((0...segmentsPerBend).map { sample in
                center + simd_quatf(angle: angle * Float(sample) / Float(segmentsPerBend), axis: axis).act(radial)
            })
            previousTrim = trim
        }
        return arcs.flatMap { $0 } + [path[path.count - 1]]
    }

    static func triangulate(_ polygon: [SIMD2<Float>]) throws -> [Int32] {
        guard (3...2048).contains(polygon.count), polygon.allSatisfy({ $0.x.isFinite && $0.y.isFinite }),
              abs(signedArea(polygon)) > 0.0001 else {
            throw LabLayoutError.invalid("Polígono de suelo vacío, degenerado o demasiado complejo.")
        }
        for i in polygon.indices {
            for j in polygon.indices where j > i + 1 && !(i == 0 && j == polygon.count - 1) {
                if segmentDistance(polygon[i], polygon[(i + 1) % polygon.count],
                                   polygon[j], polygon[(j + 1) % polygon.count]) < 0.000001 {
                    throw LabLayoutError.invalid("Suelo autointersectado: corrige la captura.")
                }
            }
        }
        let direction: Float = signedArea(polygon) > 0 ? 1 : -1
        var remaining = Array(polygon.indices), triangles: [Int32] = []
        while remaining.count > 3 {
            var clipped = false
            for k in remaining.indices {
                let i = remaining[(k + remaining.count - 1) % remaining.count]
                let j = remaining[k], l = remaining[(k + 1) % remaining.count]
                let a = polygon[i], b = polygon[j], c = polygon[l]
                let turn = cross(b - a, c - b) * direction
                if abs(turn) < 0.000001 { remaining.remove(at: k); clipped = true; break }
                guard turn > 0 else { continue }
                let occupied = remaining.contains { n in
                    n != i && n != j && n != l
                        && cross(b - a, polygon[n] - a) * direction >= -0.000001
                        && cross(c - b, polygon[n] - b) * direction >= -0.000001
                        && cross(a - c, polygon[n] - c) * direction >= -0.000001
                }
                if !occupied {
                    triangles += [Int32(i), Int32(j), Int32(l)]
                    remaining.remove(at: k); clipped = true; break
                }
            }
            guard clipped else { throw LabLayoutError.invalid("No se pudo triangular el suelo capturado.") }
        }
        triangles += remaining.map(Int32.init)
        return triangles
    }

    fileprivate static func cross(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float { a.x * b.y - a.y * b.x }
    fileprivate static func signedArea(_ p: [SIMD2<Float>]) -> Float {
        p.indices.reduce(0) { $0 + cross(p[$1], p[($1 + 1) % p.count]) } / 2
    }
    fileprivate static func pointDistance(_ p: SIMD2<Float>, _ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float {
        let d = b - a, length = simd_length_squared(d)
        return simd_distance(p, a + d * (length > 0 ? min(1, max(0, simd_dot(p - a, d) / length)) : 0))
    }
    fileprivate static func segmentDistance(_ a: SIMD2<Float>, _ b: SIMD2<Float>,
                                            _ c: SIMD2<Float>, _ d: SIMD2<Float>) -> Float {
        let ab = b - a, cd = d - c, denominator = cross(ab, cd)
        if abs(denominator) > 0.000001 {
            let t = cross(c - a, cd) / denominator, u = cross(c - a, ab) / denominator
            if t >= 0 && t <= 1 && u >= 0 && u <= 1 { return 0 }
        }
        return min(pointDistance(a, c, d), pointDistance(b, c, d),
                   pointDistance(c, a, b), pointDistance(d, a, b))
    }
}

nonisolated enum LabLayoutPlanner {
    private struct Rect {
        let center: SIMD2<Float>
        let half: SIMD2<Float>
        var corners: [SIMD2<Float>] {
            [center + SIMD2(-half.x, -half.y), center + SIMD2(half.x, -half.y),
             center + half, center + SIMD2(-half.x, half.y)]
        }
        func distance(to other: Rect) -> Float {
            simd_length(simd_max(simd_abs(center - other.center) - half - other.half, .zero))
        }
    }

    static func plan(room: RoomStructure) throws -> LabLayout {
        guard room.schemaVersion == 1, room.units == "meters", room.coordinateSystem.hasPrefix("RoomPlan native") else {
            throw LabLayoutError.invalid("Formato, unidades o coordenadas de captura no admitidos.")
        }
        guard room.surfaces.count <= 4096 else { throw LabLayoutError.invalid("Captura demasiado grande.") }
        var floors: [(polygon: [SIMD2<Float>], height: Float)] = [], warnings: [String] = []
        var walls: [(surface: RoomStructure.Surface, matrix: simd_float4x4)] = []
        var access: [(a: SIMD2<Float>, b: SIMD2<Float>, clearance: Float)] = []
        for surface in room.surfaces {
            let m = try LabGeometry.matrix(surface)
            if surface.kind == .floor {
                guard surface.curve == nil, abs(m.columns.2.y) > 0.995,
                      surface.polygonCorners.count >= 3 else {
                    warnings.append("Suelo descartado: necesita polígono plano horizontal completo."); continue
                }
                let world = try surface.polygonCorners.map { point -> SIMD3<Float> in
                    guard point.count == 3 else { throw LabLayoutError.invalid("Vértice de suelo incompleto.") }
                    return try LabGeometry.worldPoint(surface, SIMD3(point[0], point[1], point[2]))
                }
                let height = world.reduce(0) { $0 + $1.y } / Float(world.count)
                guard world.allSatisfy({ abs($0.y - height) <= 0.03 }) else {
                    warnings.append("Suelo descartado: desnivel superior a 3 cm."); continue
                }
                let polygon = world.map { SIMD2($0.x, $0.z) }
                do {
                    _ = try LabGeometry.triangulate(polygon)
                    floors.append((polygon, height))
                } catch { warnings.append("Suelo descartado: \(error.localizedDescription)") }
            } else {
                guard surface.curve == nil else { throw LabLayoutError.invalid("Paredes o huecos curvos no admitidos todavía.") }
                guard abs(m.columns.1.y) > 0.995, surface.dimensions[0] > 0,
                      surface.dimensions[1] > 0 else {
                    throw LabLayoutError.invalid("Pared o hueco inclinado/incompleto no admitido.")
                }
                if surface.kind == .wall { walls.append((surface, m)) }
                if [.door, .opening, .window].contains(surface.kind) {
                    let a = m * SIMD4(-surface.dimensions[0] / 2, 0, 0, 1)
                    let b = m * SIMD4(surface.dimensions[0] / 2, 0, 0, 1)
                    access.append((SIMD2(a.x, a.z), SIMD2(b.x, b.z), surface.kind == .window ? 0.3 : 0.8))
                }
            }
        }
        guard !walls.isEmpty, let floor = floors.max(by: {
            abs(LabGeometry.signedArea($0.polygon)) < abs(LabGeometry.signedArea($1.polygon))
        }) else { throw LabLayoutError.invalid("Se necesitan paredes y un suelo con polígono horizontal válido. " + warnings.joined(separator: " ")) }
        let polygon = floor.polygon, area = abs(LabGeometry.signedArea(polygon))
        if floors.count > 1 { warnings.append("Se utiliza únicamente el mayor suelo; otros niveles no se equipan.") }
        let edge = polygon.indices.max { i, j in
            simd_length_squared(polygon[(i + 1) % polygon.count] - polygon[i])
                < simd_length_squared(polygon[(j + 1) % polygon.count] - polygon[j])
        }!
        var u = simd_normalize(polygon[(edge + 1) % polygon.count] - polygon[edge])
        if u.x < 0 || (abs(u.x) < 0.0001 && u.y < 0) { u = -u }
        let v = SIMD2(-u.y, u.x)
        func uv(_ p: SIMD2<Float>) -> SIMD2<Float> { SIMD2(simd_dot(p, u), simd_dot(p, v)) }
        func world(_ p: SIMD2<Float>) -> SIMD2<Float> { u * p.x + v * p.y }
        let projected = polygon.map(uv)
        let lower = projected.reduce(SIMD2(repeating: Float.infinity)) { simd_min($0, $1) }
        let upper = projected.reduce(SIMD2(repeating: -Float.infinity)) { simd_max($0, $1) }
        guard (upper - lower).max() <= 100 else { throw LabLayoutError.invalid("Cuarto fuera del límite de 100 m.") }
        func fits(_ rect: Rect, margin: Float = 0.08) -> Bool {
            let corners = rect.corners.map(world)
            guard corners.allSatisfy({ LabGeometry.contains($0, polygon: polygon) }) else { return false }
            for i in polygon.indices {
                for j in corners.indices where LabGeometry.segmentDistance(
                    polygon[i], polygon[(i + 1) % polygon.count], corners[j], corners[(j + 1) % 4]) < margin {
                    return false
                }
            }
            return true
        }
        let rackSize = SIMD3<Float>(0.597, 2.013, 1.266), deskSize = SIMD3<Float>(1.2, 1.25, 0.75)
        let centerV = (lower.y + upper.y) / 2 + (rackSize.z - deskSize.z) / 2
        // ponytail: one straight aisle; shaped corridors need a later routing planner, never filled gaps.
        let aisle = Rect(center: SIMD2((lower.x + upper.x) / 2, centerV),
                         half: SIMD2(max(0, (upper.x - lower.x) / 2 - 0.45), 0.4))
        guard aisle.half.x >= 0.4, fits(aisle, margin: 0.02) else {
            return LabLayout(area: area, floorHeight: floor.height, floorPolygon: polygon, placements: [],
                             warnings: warnings + ["No cabe un pasillo central recto de 0,8 m; ajusta distribución o captura."])
        }
        let ceiling = walls.map { $0.matrix.columns.3.y + $0.surface.dimensions[1] / 2 }.min()! - floor.height
        let rackLimit = ceiling >= rackSize.y + 0.05 ? min(6, max(1, Int(area / 5))) : 0
        let deskLimit = ceiling >= deskSize.y + 0.05 ? min(2, max(1, Int(area / 6))) : 0
        if rackLimit == 0 { warnings.append("Altura capturada insuficiente para rack de 2,013 m.") }
        let step = max(0.15, sqrt((upper.x - lower.x) * (upper.y - lower.y) / 2000))
        func candidates(_ size: SIMD3<Float>) -> [Rect] {
            let half = SIMD2(size.x / 2, size.z / 2)
            var result: [Rect] = []
            for i in 0...Int((upper.x - lower.x) / step) {
                let rows = [lower.y + half.y + 0.081, upper.y - half.y - 0.081]
                    + (0...Int((upper.y - lower.y) / step)).map { lower.y + Float($0) * step }
                for row in rows {
                    let rect = Rect(center: SIMD2(lower.x + Float(i) * step, row), half: half)
                    guard abs(rect.center.y - centerV) - half.y >= 0.4, fits(rect) else { continue }
                    let corners = rect.corners.map(world)
                    let blocked = access.contains { entry in
                        corners.indices.contains { k in
                            LabGeometry.segmentDistance(entry.a, entry.b, corners[k], corners[(k + 1) % 4]) < entry.clearance
                        } || LabGeometry.contains(entry.a, polygon: corners)
                    }
                    if !blocked { result.append(rect) }
                }
            }
            return result.sorted {
                let da = min($0.center.y - lower.y - half.y, upper.y - $0.center.y - half.y)
                let db = min($1.center.y - lower.y - half.y, upper.y - $1.center.y - half.y)
                return abs(da - db) > 0.0001 ? da < db : $0.center.x < $1.center.x
            }
        }
        let racks = rackLimit > 0 ? candidates(rackSize) : [], desks = deskLimit > 0 ? candidates(deskSize) : []
        var selected: [(kind: LabPlacement.Kind, rect: Rect, size: SIMD3<Float>)] = []
        // ponytail: bounded greedy placement, not a packing optimum; keep real sizes and reject unsafe fits.
        if let pair = racks.prefix(128).lazy.compactMap({ rack in
            desks.prefix(512).first(where: { rack.distance(to: $0) >= 0.8 }).map { (rack, $0) }
        }).first {
            selected = [(.rack, pair.0, rackSize), (.workstation, pair.1, deskSize)]
        }
        for (kind, options, limit, size) in [(LabPlacement.Kind.rack, racks, rackLimit, rackSize),
                                            (.workstation, desks, deskLimit, deskSize)] {
            for rect in options {
                if selected.filter({ $0.kind == kind }).count >= limit { break }
                if selected.allSatisfy({ $0.rect.distance(to: rect) >= 0.8 }) { selected.append((kind, rect, size)) }
            }
        }
        let axisYaw = atan2(-u.y, u.x)
        let placements = selected.enumerated().map { index, item in
            let p = world(item.rect.center)
            return LabPlacement(id: "\(item.kind.rawValue)-\(index + 1)", kind: item.kind,
                title: item.kind == .rack ? "Rack genérico \(index + 1)" : "Puesto de trabajo \(index + 1)",
                position: SIMD3(p.x, floor.height, p.y),
                yaw: axisYaw + (item.rect.center.y < centerV ? .pi : 0), size: item.size)
        }
        if !placements.contains(where: { $0.kind == .rack }) { warnings.append("No cabe un rack con separaciones suficientes.") }
        if !placements.contains(where: { $0.kind == .workstation }) { warnings.append("No cabe un puesto con separaciones suficientes.") }
        return LabLayout(area: area, floorHeight: floor.height, floorPolygon: polygon,
                         placements: placements, warnings: warnings)
    }
}

nonisolated enum LabMonitorMount {
    static let displayWidth: Float = 0.310
    static let displayHeight: Float = 0.1744
    static let sideOffset: Float = 0.240
    static let inset: Float = 0.028
    static let bezel: Float = 0.018
    static let faceSize = CGSize(width: 320, height: 180)
    static let heading = CGRect(x: 14, y: 8, width: 292, height: 62)

    static func chartFrame(at column: Int) -> CGRect {
        CGRect(x: 14 + CGFloat(column) * 150, y: 76, width: 142, height: 53)
    }

    static func captionFrame(at column: Int) -> CGRect {
        chartFrame(at: column).offsetBy(dx: 0, dy: 57)
    }

    static func centerX(for rackWidth: Float, side: Float) -> Float {
        side * (rackWidth / 2 + sideOffset)
    }
}

nonisolated struct LabWalkPose: Equatable {
    var position: SIMD3<Float>
    var yaw: Float
    var pitch: Float = -0.14

    var rotation: simd_quatf {
        simd_quatf(angle: yaw, axis: SIMD3(0, 1, 0)) * simd_quatf(angle: pitch, axis: SIMD3(1, 0, 0))
    }

    static func start(in layout: LabLayout) -> Self {
        let floor = layout.floorPolygon
        let center = floor.reduce(.zero, +) / Float(max(1, floor.count))
        if let rack = layout.placements.first(where: { $0.kind == .rack }) {
            for gap: Float in [1.6, 1.15, 0.75, 0.35] {
                let front = SIMD2(-sin(rack.yaw), -cos(rack.yaw))
                let point = SIMD2(rack.position.x, rack.position.z) + front * (rack.size.z / 2 + gap)
                if permits(point, in: layout) {
                    let pitch = atan2(rack.size.y * 0.55 - 1.58, rack.size.z / 2 + gap)
                    return .init(position: SIMD3(point.x, layout.floorHeight + 1.58, point.y), yaw: rack.yaw + .pi, pitch: pitch)
                }
            }
        }
        // Interior triangle centers work even when a concave room's centroid is outside.
        let triangles = (try? LabGeometry.triangulate(floor)) ?? []
        let candidates = [center] + stride(from: 0, to: triangles.count, by: 3).map { i in
            (floor[Int(triangles[i])] + floor[Int(triangles[i + 1])] + floor[Int(triangles[i + 2])]) / 3
        }
        let point = candidates.first { permits($0, in: layout) } ?? candidates.first { LabGeometry.contains($0, polygon: floor) } ?? center
        return .init(position: SIMD3(point.x, layout.floorHeight + 1.58, point.y), yaw: 0)
    }

    func inspecting(_ point: SIMD3<Float>, fromSide normal: SIMD3<Float>, in layout: LabLayout) -> Self {
        let facing = SIMD2(normal.x, normal.z)
        guard simd_length_squared(facing) > 0.01 else { return aimed(at: point) }
        let outward = simd_normalize(facing)
        let across = SIMD2(-outward.y, outward.x)
        let target = SIMD2(point.x, point.z)
        let eye = min(layout.floorHeight + 1.58, max(layout.floorHeight + 0.92, point.y + 0.22))
        for distance: Float in [0.95, 1.25, 1.65, 0.65, 2.25] {
            for offset: Float in [0, 0.26, -0.26, 0.60, -0.60] {
                let candidate = target + outward * distance + across * offset
                guard Self.permits(candidate, in: layout),
                      LabGeometry.traySpanFits(from: candidate, to: target, within: layout.floorPolygon) else { continue }
                return Self(position: SIMD3(candidate.x, eye, candidate.y), yaw: yaw).aimed(at: point)
            }
        }
        return aimed(at: point)
    }

    func aimed(at target: SIMD3<Float>) -> Self {
        let delta = target - position
        let horizontal = simd_length(SIMD2(delta.x, delta.z))
        guard horizontal > 0.001 else { return self }
        return .init(position: position, yaw: atan2(-delta.x, -delta.z),
                     pitch: min(1.35, max(-1.35, atan2(delta.y, horizontal))))
    }

    mutating func look(horizontal: Float, vertical: Float) {
        yaw = (yaw + horizontal).truncatingRemainder(dividingBy: 2 * .pi)
        pitch = min(1.35, max(-1.35, pitch + vertical))
    }

    mutating func walk(_ axes: SIMD2<Float>, seconds: Float, in layout: LabLayout) {
        let step = axes * (min(0.05, max(0, seconds)) * 1.35 / max(1, simd_length(axes)))
        let delta = SIMD2(cos(yaw), -sin(yaw)) * step.x + SIMD2(-sin(yaw), -cos(yaw)) * step.y
        let x = SIMD2(position.x + delta.x, position.z)
        if Self.permits(x, in: layout) { position.x = x.x }
        let z = SIMD2(position.x, position.z + delta.y)
        if Self.permits(z, in: layout) { position.z = z.y }
    }

    static func canTravel(from a: SIMD3<Float>, to b: SIMD3<Float>, in layout: LabLayout) -> Bool {
        let first = SIMD2(a.x, a.z), last = SIMD2(b.x, b.z)
        let steps = max(1, Int(ceil(simd_distance(first, last) / 0.16)))
        return (0...steps).allSatisfy { permits(first + (last - first) * (Float($0) / Float(steps)), in: layout) }
    }

    static func permits(_ point: SIMD2<Float>, in layout: LabLayout) -> Bool {
        let floor = layout.floorPolygon
        let clearance: Float = 0.15
        guard LabGeometry.contains(point, polygon: floor),
              floor.indices.allSatisfy({
                  LabGeometry.pointDistance(point, floor[$0], floor[($0 + 1) % floor.count]) >= clearance
              }) else { return false }
        if layout.placements.contains(where: { placement in
            let rotation = simd_quatf(angle: -placement.yaw, axis: SIMD3(0, 1, 0))
            let local = rotation.act(SIMD3(point.x, layout.floorHeight, point.y) - placement.position)
            let footprint = abs(local.x) < placement.size.x / 2 + clearance && abs(local.z) < placement.size.z / 2 + clearance
            let sideMonitor = placement.kind == .rack && (layout.facility != nil || placement.id == "home-rack")
                && abs(abs(local.x) - (placement.size.x / 2 + LabMonitorMount.sideOffset)) < 0.31
                && abs(local.z + placement.size.z / 2 - LabMonitorMount.inset) < 0.21
            return footprint || sideMonitor
        }) { return false }
        if let facility = layout.facility {
            let local = simd_quatf(angle: -facility.yaw, axis: SIMD3(0, 1, 0))
                .act(SIMD3(point.x, layout.floorHeight, point.y) - facility.origin)
            // The technical enclosure is visible beyond the data hall partition.
            if local.z < -3.4 && local.z > -5.36 && abs(local.x) < 7.44 { return false }
            let operatorWall = abs(local.z - 2.67) < 0.21
                && ((-5.50...4.40).contains(local.x) || (5.60...6.76).contains(local.x))
            let sideWall = abs(abs(local.x) - 5.17) < 0.21 && (-4.70 ... -1.12).contains(local.z)
            if operatorWall || sideWall { return false }
        }
        return true
    }
}


nonisolated struct LabTrafficRoute {
    private struct Span {
        let from: SIMD3<Float>
        let to: SIMD3<Float>
        let start: Float
        let end: Float
    }

    private let spans: [Span]
    let length: Float

    init?(_ cablePaths: [[SIMD3<Float>]]) {
        var spans: [Span] = []
        var traveled: Float = 0
        // Only visible cable contributes distance. A passive panel joins its opposite faces internally.
        for path in cablePaths {
            for (from, to) in zip(path, path.dropFirst()) {
                let distance = simd_distance(from, to)
                guard distance > 0.0001 else { continue }
                spans.append(Span(from: from, to: to, start: traveled, end: traveled + distance))
                traveled += distance
            }
        }
        guard !spans.isEmpty else { return nil }
        self.spans = spans
        length = traveled
    }

    static func markerRadius(cableRadius: Float, depth: Float, projectedPointsAtOneMeter: Float) -> Float {
        let modelRadius = cableRadius * 1.55
        guard projectedPointsAtOneMeter > 0 else { return modelRadius }
        return min(modelRadius, max(0, depth) * 1.8 / projectedPointsAtOneMeter)
    }

    func point(at fraction: Float) -> SIMD3<Float> {
        let distance = min(1, max(0, fraction)) * length
        var lower = 0, upper = spans.count - 1
        while lower < upper {
            let middle = (lower + upper) / 2
            if distance < spans[middle].end { upper = middle }
            else { lower = middle + 1 }
        }
        let span = spans[lower]
        let t = (distance - span.start) / (span.end - span.start)
        return simd_mix(span.from, span.to, SIMD3(repeating: t))
    }
}

nonisolated struct LabFacilityTrial: Identifiable, Codable, Sendable {
    enum Scenario: String, Codable, CaseIterable, Sendable {
        case maintenance = "Mantenimiento de alimentación"
        case transfer = "Transferencia a grupo electrógeno"
        case cooling = "Continuidad térmica"

        var system: String {
            switch self {
            case .maintenance: "Potencia A/B y UPS"
            case .transfer: "Generación, UPS y transferencia"
            case .cooling: "Ventilación y refrigeración A/B"
            }
        }
    }

    var id = UUID()
    var date = Date()
    let scenario: Scenario
    let path: String
    let loadKW: Double
    let availableKW: Double
    let transferSeconds: Double
    let batteryMinutes: Double
    let note: String

    var passed: Bool {
        availableKW >= loadKW
            && (scenario != .transfer || batteryMinutes * 60 >= transferSeconds)
    }
}
