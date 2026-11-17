import Foundation

nonisolated struct RoomStructure: Codable, Sendable {
    let schemaVersion: Int
    let source: String
    let units: String
    let coordinateSystem: String
    let roomID: UUID
    let capturedAt: Date
    let surfaces: [Surface]

    struct Surface: Codable, Sendable {
        enum Kind: String, Codable, Sendable { case wall, door, window, opening, floor }
        let id: UUID
        let kind: Kind
        let confidence: String
        let dimensions: [Float]
        let transformColumnMajor: [Float]
        let polygonCorners: [[Float]]
        let parentID: UUID?
        let doorIsOpen: Bool?
        let curve: Curve?
    }

    struct Curve: Codable, Sendable {
        let center: [Float]
        let radius: Float
        let startAngleRadians: Double
        let endAngleRadians: Double
    }

    enum ExportError: LocalizedError {
        case noWalls, invalidSurface(UUID)
        var errorDescription: String? {
            switch self {
            case .noWalls: "Captura sin paredes. Vuelve a escanear el cuarto."
            case .invalidSurface(let id): "Geometría inválida en superficie \(id). Repite la captura."
            }
        }
    }

    init(roomID: UUID, surfaces: [Surface], capturedAt: Date = .now, source: String = "Apple RoomPlan") {
        schemaVersion = 1
        self.source = source
        units = "meters"
        coordinateSystem = "RoomPlan native, right-handed, Y-up, session-local; no Unity conversion"
        self.roomID = roomID
        self.surfaces = surfaces
        self.capturedAt = capturedAt
    }

    func jsonData() throws -> Data {
        guard surfaces.contains(where: { $0.kind == .wall }) else { throw ExportError.noWalls }
        for surface in surfaces {
            let matrix = surface.transformColumnMajor
            guard surface.dimensions.count == 3,
                  surface.dimensions.allSatisfy({ $0.isFinite && $0 >= 0 }),
                  surface.dimensions.contains(where: { $0 > 0 }),
                  matrix.count == 16, matrix.allSatisfy(\.isFinite),
                  abs(matrix[3]) < 0.0001, abs(matrix[7]) < 0.0001,
                  abs(matrix[11]) < 0.0001, abs(matrix[15] - 1) < 0.0001,
                  surface.polygonCorners.allSatisfy({ $0.count == 3 && $0.allSatisfy(\.isFinite) })
            else { throw ExportError.invalidSurface(surface.id) }
            if let curve = surface.curve {
                guard curve.center.count == 2, curve.center.allSatisfy(\.isFinite),
                      curve.radius.isFinite, curve.radius > 0,
                      curve.startAngleRadians.isFinite, curve.endAngleRadians.isFinite
                else { throw ExportError.invalidSurface(surface.id) }
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    func save() throws -> URL {
        let data = try jsonData()
        let documents = try FileManager.default.url(
            for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let directory = documents.appendingPathComponent("Captures", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("room-\(UUID().uuidString).json")
        try data.write(to: url, options: .atomic)
        return url
    }
}
