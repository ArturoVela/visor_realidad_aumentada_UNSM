import Foundation
import RealityKit

@main
struct Catalyst2960InspectionCheck {
    @MainActor static func main() async throws {
        let args = CommandLine.arguments.dropFirst()
        let source = URL(fileURLWithPath: args.first ?? "../Tools/CloudLab/models/switch-2960-v1.usdz")
        let data = try Data(contentsOf: source)
        precondition(Catalyst2960Asset.matchesRelease(data))
        var corrupt = data
        corrupt[corrupt.startIndex] ^= 1
        precondition(!Catalyst2960Asset.matchesRelease(corrupt))

        let model = try await Entity(contentsOf: source)
        let frame = Entity()
        frame.addChild(model)
        precondition(Catalyst2960Inspection.matchesPortAnchors(frame), "Los 26 puertos deben coincidir con la escena.")
        let port = frame.findEntity(named: "Port_01")!
        port.position.x += 0.002
        precondition(!Catalyst2960Inspection.matchesPortAnchors(frame), "Un puerto desplazado se debe rechazar.")

        let cache = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cache) }
        let cached = cache.appendingPathComponent(source.lastPathComponent)
        let offline = URL(string: "https://127.0.0.1:1/no-network")!
        do {
            _ = try await Catalyst2960Asset.localFile(in: cache, source: offline)
            preconditionFailure("Sin red y sin caché, la descarga debe fallar.")
        } catch is URLError {}
        precondition(!FileManager.default.fileExists(atPath: cached.path))
        if args.contains("--remote") {
            let received = try await Catalyst2960Asset.localFile(in: cache)
            precondition(received == cached)
        } else {
            try data.write(to: cached)
        }
        let reopened = try await Catalyst2960Asset.localFile(in: cache, source: offline)
        let reopenedBytes = try Data(contentsOf: reopened)
        precondition(reopenedBytes == data)
        print("USDZ válido, 26 anclajes, rechazo de corrupción y caché sin red comprobados.")
    }
}
