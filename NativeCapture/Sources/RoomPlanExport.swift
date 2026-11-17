import Foundation
import RoomPlan

extension RoomStructure {
    init(room: CapturedRoom) {
        let groups: [(Surface.Kind, [CapturedRoom.Surface])] = [
            (.wall, room.walls), (.door, room.doors), (.window, room.windows),
            (.opening, room.openings), (.floor, room.floors)
        ]
        let surfaces = groups.flatMap { kind, surfaces in
            surfaces.map { surface in
                let matrix = surface.transform
                let columns = [matrix.columns.0, matrix.columns.1, matrix.columns.2, matrix.columns.3]
                let confidence: String
                switch surface.confidence {
                case .high: confidence = "high"
                case .medium: confidence = "medium"
                case .low: confidence = "low"
                @unknown default: confidence = "unknown"
                }
                let doorIsOpen: Bool?
                if case .door(let isOpen) = surface.category { doorIsOpen = isOpen }
                else { doorIsOpen = nil }
                let curve = surface.curve.map { curve in
                    Curve(center: [curve.center.x, curve.center.y], radius: curve.radius,
                          startAngleRadians: curve.startAngle.converted(to: .radians).value,
                          endAngleRadians: curve.endAngle.converted(to: .radians).value)
                }
                return Surface(
                    id: surface.identifier, kind: kind, confidence: confidence,
                    dimensions: [surface.dimensions.x, surface.dimensions.y, surface.dimensions.z],
                    transformColumnMajor: columns.flatMap { [$0.x, $0.y, $0.z, $0.w] },
                    polygonCorners: surface.polygonCorners.map { [$0.x, $0.y, $0.z] },
                    parentID: surface.parentIdentifier, doorIsOpen: doorIsOpen, curve: curve)
            }
        }
        self.init(roomID: room.identifier, surfaces: surfaces)
    }
}
