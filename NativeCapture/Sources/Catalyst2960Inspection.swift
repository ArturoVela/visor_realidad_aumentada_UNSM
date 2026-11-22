import Combine
import CryptoKit
import RealityKit
import SwiftUI
import simd

nonisolated enum Catalyst2960Asset {
    static let modelID = "switch-2960"
    static let url = URL(string: "https://nexus-ar-models.withered-hat-79c9.workers.dev/models/switch-2960/v1.usdz")!
    static let size = 394_571
    static let checksum = "0bc3c39016aa231b99793d756914e08a0d43310f08f219253ef679e0ea5aa61d"

    static func matchesRelease(_ data: Data) -> Bool {
        guard data.count == size else { return false }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == checksum
    }

    @concurrent static func localFile(
        in directory: URL = URL.cachesDirectory.appendingPathComponent("NexusARModels", isDirectory: true),
        session: URLSession = .shared,
        source: URL = url
    ) async throws -> URL {
        let file = directory.appendingPathComponent("switch-2960-v1.usdz")
        if let length = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, length == size,
           let cached = try? Data(contentsOf: file), matchesRelease(cached) { return file }

        let request = URLRequest(url: source, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 18)
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              http.url == source, http.mimeType == "model/vnd.usdz+zip",
              http.expectedContentLength == -1 || http.expectedContentLength == Int64(size) else {
            throw URLError(.badServerResponse)
        }
        var data = Data(capacity: size)
        for try await byte in bytes {
            guard data.count < size else { throw URLError(.dataLengthExceedsMaximum) }
            data.append(byte)
        }
        guard matchesRelease(data) else { throw URLError(.cannotDecodeContentData) }
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
        return file
    }
}

struct Catalyst2960Detail {
    let deviceID: String
    let entity: Entity
}

@MainActor @Observable
final class Catalyst2960Inspection {
    enum Phase { case loading, ready, unavailable }

    private(set) var attempt = 0
    private(set) var detail: Catalyst2960Detail?
    private var deviceID: String?
    private var phase = Phase.loading
    @ObservationIgnored private var generation = 0

    func phase(for id: String) -> Phase { deviceID == id ? phase : .loading }

    func retry() { attempt += 1 }

    func load(for id: String?) async {
        guard !Task.isCancelled else { return }
        generation += 1
        let requested = generation
        deviceID = id
        detail = nil
        phase = .loading
        guard let id else { return }

        do {
            let file = try await Catalyst2960Asset.localFile()
            try Task.checkCancellation()
            let model: Entity
            #if os(iOS)
            if #available(iOS 18.0, *) {
                model = try await Entity(contentsOf: file)
            } else {
                model = try await Self.loadLegacy(file)
            }
            #else
            model = try await Entity(contentsOf: file)
            #endif
            try Task.checkCancellation()
            let frame = Entity()
            frame.addChild(model)
            guard Self.matchesPortAnchors(frame) else { throw URLError(.cannotDecodeContentData) }
            guard generation == requested else { return }
            detail = Catalyst2960Detail(deviceID: id, entity: frame)
            phase = .ready
        } catch {
            guard !Task.isCancelled, generation == requested else { return }
            phase = .unavailable
            #if DEBUG
            print("Catalyst 2960 detail: \(error.localizedDescription)")
            #endif
        }
    }

    #if os(iOS)
    private static func loadLegacy(_ file: URL) async throws -> Entity {
        let (stream, continuation) = AsyncThrowingStream<Entity, Error>.makeStream()
        let subscription = Entity.loadAsync(contentsOf: file).sink { completion in
            switch completion {
            case .finished: continuation.finish()
            case .failure(let error): continuation.finish(throwing: error)
            }
        } receiveValue: { model in
            continuation.yield(model)
        }
        defer { subscription.cancel() }
        for try await model in stream { return model }
        try Task.checkCancellation()
        throw URLError(.cannotDecodeContentData)
    }
    #endif

    static func matchesPortAnchors(_ frame: Entity) -> Bool {
        let id = Catalyst2960Asset.modelID
        let expectedSize = HardwareCatalog.renderSize(id)
        let bounds = frame.visualBounds(relativeTo: frame)
        let delta = simd_abs(bounds.extents - expectedSize)
        guard delta.x < 0.004, delta.y < 0.005, delta.z < 0.016 else { return false }
        return LabDemo.ports(id).enumerated().allSatisfy { index, name in
            guard let port = LabScenePort.networkPanel(id, port: name),
                  let marker = frame.findEntity(named: String(format: "Port_%02d", index + 1)) else { return false }
            return simd_distance(marker.position(relativeTo: frame), port.point) < 0.0005
        }
    }
}

struct Catalyst2960Status: View {
    let inspection: Catalyst2960Inspection
    let deviceID: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let phase = inspection.phase(for: deviceID)
        Group {
            switch phase {
            case .loading:
                ProgressView("Cargando detalle 3D…")
                    .accessibilityIdentifier("lab.catalyst.loading")
            case .ready:
                Label("Modelo detallado listo", systemImage: "checkmark.circle")
                    .accessibilityIdentifier("lab.catalyst.ready")
            case .unavailable:
                VStack(alignment: .leading, spacing: 4) {
                    Label("Mostrando el modelo ligero", systemImage: "cube")
                    Button("Reintentar descarga", systemImage: "arrow.clockwise") { inspection.retry() }
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("lab.catalyst.retry")
                }
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: phase)
    }
}
