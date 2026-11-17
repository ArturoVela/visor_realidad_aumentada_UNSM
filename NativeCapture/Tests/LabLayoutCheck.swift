import Foundation
import simd

@main
struct LabLayoutCheck {
    static let identity: [Float] = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 1.5, 0, 1]
    static func surface(_ kind: RoomStructure.Surface.Kind, dimensions: [Float], matrix: [Float],
                        corners: [[Float]] = []) -> RoomStructure.Surface {
        .init(id: UUID(), kind: kind, confidence: "high", dimensions: dimensions,
              transformColumnMajor: matrix, polygonCorners: corners, parentID: nil, doorIsOpen: nil, curve: nil)
    }
    static func room(_ polygon: [SIMD2<Float>], height: Float = 3,
                     extra: [RoomStructure.Surface] = []) -> RoomStructure {
        var wallMatrix = identity
        wallMatrix[13] = height / 2
        let floor = surface(.floor, dimensions: [5, 5, 0],
                            matrix: [1, 0, 0, 0, 0, 0, -1, 0, 0, 1, 0, 0, 0, 0, 0, 1],
                            corners: polygon.map { [$0.x, -$0.y, 0] })
        return RoomStructure(roomID: UUID(), surfaces: [
            surface(.wall, dimensions: [5, height, 0], matrix: wallMatrix), floor
        ] + extra)
    }
    static func corners(_ p: LabPlacement) -> [SIMD2<Float>] {
        let u = SIMD2(cos(p.yaw), -sin(p.yaw)), v = SIMD2(sin(p.yaw), cos(p.yaw))
        let center = SIMD2(p.position.x, p.position.z)
        return [SIMD2<Float>(-1, -1), SIMD2(1, -1), SIMD2(1, 1), SIMD2(-1, 1)].map {
            center + u * ($0.x * p.size.x / 2) + v * ($0.y * p.size.z / 2)
        }
    }
    static func check(_ layout: LabLayout) {
        precondition(layout.placements.filter { $0.kind == .rack }.count <= 6)
        precondition(layout.placements.filter { $0.kind == .workstation }.count <= 2)
        for p in layout.placements {
            precondition(abs(p.position.y - layout.floorHeight) < 0.0001)
            precondition(corners(p).allSatisfy { LabGeometry.contains($0, polygon: layout.floorPolygon) })
            precondition(p.size == (p.kind == .rack ? SIMD3(0.597, 2.013, 1.266) : SIMD3(1.2, 1.25, 0.75)))
        }
        for i in layout.placements.indices {
            for j in layout.placements.indices where j > i {
                let a = layout.placements[i], b = layout.placements[j]
                let u = SIMD2(cos(a.yaw), -sin(a.yaw)), v = SIMD2(sin(a.yaw), cos(a.yaw))
                let delta = SIMD2(a.position.x - b.position.x, a.position.z - b.position.z)
                let gap = simd_max(SIMD2(abs(simd_dot(delta, u)), abs(simd_dot(delta, v)))
                                  - SIMD2((a.size.x + b.size.x) / 2, (a.size.z + b.size.z) / 2), .zero)
                precondition(simd_length(gap) >= 0.7999, "Huellas deben tener separación de 0,8 m")
            }
        }
    }
    static func mustReject(_ operation: () throws -> Void) {
        do { try operation(); preconditionFailure("Dato inválido aceptado") } catch {}
    }

    static func main() throws {
        let rectangle: [SIMD2<Float>] = [SIMD2(0, 0), SIMD2(5, 0), SIMD2(5, 3.2), SIMD2(0, 3.2)]
        let base = room(rectangle)
        let layout = try LabLayoutPlanner.plan(room: base)
        check(layout)
        precondition(layout.placements.contains { $0.kind == .rack })
        precondition(layout.placements.contains { $0.kind == .workstation })
        let repeated = try LabLayoutPlanner.plan(room: base)
        precondition(layout.placements == repeated.placements)
        let concave: [SIMD2<Float>] = [SIMD2(0, 0), SIMD2(5, 0), SIMD2(5, 2),
                                       SIMD2(2, 2), SIMD2(2, 5), SIMD2(0, 5)]
        let indices = try LabGeometry.triangulate(concave)
        var area: Float = 0
        for i in stride(from: 0, to: indices.count, by: 3) {
            let a = concave[Int(indices[i])], b = concave[Int(indices[i + 1])], c = concave[Int(indices[i + 2])]
            precondition(LabGeometry.contains((a + b + c) / 3, polygon: concave))
            let ab = b - a, ac = c - a
            area += abs(ab.x * ac.y - ab.y * ac.x) / 2
        }
        precondition(abs(area - 16) < 0.0001, "Triángulos deben cubrir área cóncava sin rellenar hueco")
        precondition(!LabGeometry.contains(SIMD2(4, 4), polygon: concave))
        check(try LabLayoutPlanner.plan(room: room(concave)))
        let tiny = try LabLayoutPlanner.plan(room: room([SIMD2(0, 0), SIMD2(1.4, 0), SIMD2(1.4, 1.4), SIMD2(0, 1.4)]))
        precondition(tiny.placements.isEmpty && !tiny.warnings.isEmpty)
        let low = try LabLayoutPlanner.plan(room: room(rectangle, height: 1))
        precondition(low.placements.isEmpty && !low.warnings.isEmpty)
        var doorMatrix = identity
        doorMatrix[12] = 2; doorMatrix[13] = 1.1
        let doorway = surface(.opening, dimensions: [1, 2.2, 0], matrix: doorMatrix)
        let access = try LabLayoutPlanner.plan(room: room(rectangle, extra: [doorway]))
        check(access)
        for p in access.placements {
            let points = corners(p), minX = points.map(\.x).min()!, maxX = points.map(\.x).max()!
            let minZ = points.map(\.y).min()!, maxZ = points.map(\.y).max()!
            let dx = max(0, 1.5 - maxX, minX - 2.5), dz = max(0, minZ, -maxZ)
            precondition(hypot(dx, dz) >= 0.7999, "No bloquear acceso")
        }
        var invalid = identity
        invalid[0] = 2
        mustReject { _ = try LabGeometry.matrix(surface(.wall, dimensions: [4, 3, 0], matrix: invalid)) }
        invalid = identity; invalid[0] = .nan
        mustReject { _ = try LabGeometry.matrix(surface(.wall, dimensions: [4, 3, 0], matrix: invalid)) }
        mustReject { _ = try LabLayoutPlanner.plan(room: RoomStructure(roomID: UUID(), surfaces: [])) }
        mustReject { _ = try LabGeometry.triangulate([SIMD2(0, 0), SIMD2(2, 2), SIMD2(0, 2), SIMD2(2, 0)]) }
        var json = try JSONSerialization.jsonObject(with: base.jsonData()) as! [String: Any]
        json["schemaVersion"] = 2
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let future = try decoder.decode(RoomStructure.self, from: JSONSerialization.data(withJSONObject: json))
        mustReject { _ = try LabLayoutPlanner.plan(room: future) }
        json["schemaVersion"] = 1; json["units"] = "feet"
        let wrongUnits = try decoder.decode(RoomStructure.self, from: JSONSerialization.data(withJSONObject: json))
        mustReject { _ = try LabLayoutPlanner.plan(room: wrongUnits) }
        if CommandLine.arguments.count > 1 {
            let real = try decoder.decode(RoomStructure.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
            let realLayout = try LabLayoutPlanner.plan(room: real)
            check(realLayout)
            print("Real capture: \(realLayout.area) m², \(realLayout.placements.filter { $0.kind == .rack }.count) racks, \(realLayout.placements.filter { $0.kind == .workstation }.count) puestos; \(realLayout.warnings)")
        }
        print("PASS: suelo cóncavo, triangulación, huellas, 0.8m, accesos, alturas, límites, determinismo y rechazo de datos")
    }
}
