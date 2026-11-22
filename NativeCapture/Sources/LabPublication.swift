import Foundation

nonisolated struct LabPublication: Decodable, Equatable, Sendable {
    static let maximumBytes = 8 * 1024 * 1024
    private static let qrPrefix = "nexusar:v1:"

    let schemaVersion: Int
    let asset: String
    let version: Int
    let publishedAt: Date
    let deviceID: String
    let topology: LabTopology
    let rackUnits: Int?
    let demo: Bool?

    static func qrPayload(for asset: String) -> String { qrPrefix + asset }

    static func validateAsset(_ input: String) throws -> String {
        let code = input.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let bytes = code.utf8
        guard code.hasPrefix("UNSM-LAB-"), (10...48).contains(bytes.count),
              bytes.last != 45, !code.contains("--"),
              bytes.allSatisfy({ (65...90).contains($0) || (48...57).contains($0) || $0 == 45 }) else {
            throw LabLayoutError.invalid("Usa el código de un equipo de prácticas. Ejemplo UNSM-LAB-SRV-01.")
        }
        return code
    }

    static func asset(fromQR payload: String) throws -> String {
        guard payload.hasPrefix(qrPrefix) else { throw LabLayoutError.invalid("Escanea una etiqueta de Nexus AR.") }
        return try validateAsset(String(payload.dropFirst(qrPrefix.count)))
    }

    static func read(_ url: URL) throws -> Data {
        let info = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard info.isRegularFile == true, let size = info.fileSize, (1...maximumBytes).contains(size) else {
            throw LabLayoutError.invalid("La publicación debe ocupar entre 1 byte y 8 MiB.")
        }
        return try Data(contentsOf: url)
    }

    static func decode(_ data: Data, for asset: String? = nil) throws -> Self {
        guard (1...maximumBytes).contains(data.count) else { throw LabLayoutError.invalid("Tamaño de publicación inválido.") }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let release = try decoder.decode(Self.self, from: data)
        guard release.schemaVersion == 1, (1...Int(Int32.max)).contains(release.version),
              try validateAsset(release.asset) == release.asset, asset == nil || release.asset == asset else {
            throw LabLayoutError.invalid("La publicación no coincide con la etiqueta o usa una versión incompatible.")
        }
        return release
    }

    func project() throws -> LabProject {
        guard topology.devices.contains(where: { $0.id == deviceID && $0.sourceModel?.isEmpty == false }) else {
            throw LabLayoutError.invalid("El equipo de la etiqueta debe existir en la topología exportada de Packet Tracer.")
        }
        let rackHeight = rackUnits.flatMap(RackMount.Height.init(rawValue:))
        guard rackUnits == nil || rackHeight != nil else {
            throw LabLayoutError.invalid("La capacidad del rack de la publicación es inválida.")
        }
        var project = try LabImport.project(from: JSONEncoder().encode(topology), rackHeight: rackHeight)
        let suffix = " · v\(version)"
        project.topology.name = String(project.topology.name.prefix(160 - suffix.count)) + suffix
        return project
    }
}

actor LabPublicationCache {
    struct Opened: Sendable {
        let release: LabPublication
        let project: LabProject
        let fromCache: Bool
    }

    static let shared = LabPublicationCache(directory: URL.applicationSupportDirectory.appending(path: "PublishedLabs"))
    let directory: URL

    init(directory: URL) { self.directory = directory }

    func open(_ input: String, scope: String = "") throws -> Opened {
        let asset = try LabPublication.validateAsset(input)
        let url = location(of: asset, scope: scope)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw LabLayoutError.invalid("No hay una versión descargada de \(asset). Configura el catálogo o importa la publicación.")
        }
        let cached = try LabPublication.decode(LabPublication.read(url), for: asset)
        return .init(release: cached, project: try cached.project(), fromCache: true)
    }

    func store(_ data: Data, for asset: String? = nil, scope: String = "") throws -> Opened {
        try Task.checkCancellation()
        let incoming = try LabPublication.decode(data, for: asset)
        let url = location(of: incoming.asset, scope: scope)
        if let cached = try? LabPublication.decode(LabPublication.read(url), for: incoming.asset) {
            if cached.version > incoming.version {
                return .init(release: cached, project: try cached.project(), fromCache: true)
            }
            if cached.version == incoming.version {
                guard incoming == cached else {
                    throw LabLayoutError.invalid("Esta versión ya existe con otro contenido. Publica un número nuevo.")
                }
                return .init(release: cached, project: try cached.project(), fromCache: false)
            }
        }
        let project = try incoming.project()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        return .init(release: incoming, project: project, fromCache: false)
    }

    private func location(of asset: String, scope: String) -> URL {
        let folder = scope.isEmpty ? directory : directory.appending(path: scope)
        return folder.appending(path: asset + ".json")
    }
}
