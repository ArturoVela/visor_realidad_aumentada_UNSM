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
}

nonisolated enum LabLayoutError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let message) = self { message } else { nil } }
}

nonisolated enum LabGeometry {
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
        let yaw = atan2(-u.y, u.x)
        let placements = selected.enumerated().map { index, item in
            let p = world(item.rect.center)
            return LabPlacement(id: "\(item.kind.rawValue)-\(index + 1)", kind: item.kind,
                title: item.kind == .rack ? "Rack genérico \(index + 1)" : "Puesto de trabajo \(index + 1)",
                position: SIMD3(p.x, floor.height, p.y), yaw: yaw, size: item.size)
        }
        if !placements.contains(where: { $0.kind == .rack }) { warnings.append("No cabe un rack con separaciones suficientes.") }
        if !placements.contains(where: { $0.kind == .workstation }) { warnings.append("No cabe un puesto con separaciones suficientes.") }
        return LabLayout(area: area, floorHeight: floor.height, floorPolygon: polygon,
                         placements: placements, warnings: warnings)
    }
}
