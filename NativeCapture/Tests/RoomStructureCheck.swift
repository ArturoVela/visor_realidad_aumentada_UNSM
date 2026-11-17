import Foundation

@main
struct RoomStructureCheck {
    static func main() throws {
        let identity: [Float] = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 2, 0, 3, 1]
        func wall(matrix: [Float] = identity) -> RoomStructure.Surface {
            .init(id: UUID(), kind: .wall, confidence: "high", dimensions: [4, 2.5, 0],
                  transformColumnMajor: matrix, polygonCorners: [[-2, -1.25, 0], [2, 1.25, 0]],
                  parentID: nil, doorIsOpen: nil, curve: nil)
        }
        let structure = RoomStructure(roomID: UUID(), surfaces: [wall()])
        let data = try structure.jsonData()
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        precondition(object["schemaVersion"] as? Int == 1)
        precondition(object["units"] as? String == "meters")
        precondition(object["objects"] == nil, "Mobiliario no pertenece al contrato estructural")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(RoomStructure.self, from: data)
        precondition(decoded.surfaces[0].transformColumnMajor == identity, "Conservar orden de columnas")
        precondition(decoded.surfaces[0].dimensions == [4, 2.5, 0], "Permitir espesor plano cero")
        do {
            _ = try RoomStructure(roomID: UUID(), surfaces: []).jsonData()
            preconditionFailure("Debe rechazar captura sin paredes")
        } catch RoomStructure.ExportError.noWalls {}
        do {
            _ = try RoomStructure(roomID: UUID(), surfaces: [wall(matrix: [1, 2])]).jsonData()
            preconditionFailure("Debe rechazar matriz truncada")
        } catch RoomStructure.ExportError.invalidSurface {}
        var nonFinite = identity
        nonFinite[0] = .nan
        do {
            _ = try RoomStructure(roomID: UUID(), surfaces: [wall(matrix: nonFinite)]).jsonData()
            preconditionFailure("Debe rechazar coordenadas no finitas")
        } catch RoomStructure.ExportError.invalidSurface {}
        print("PASS: JSON estructural v1, columnas, dimensiones, sin objetos y geometría inválida")
    }
}
