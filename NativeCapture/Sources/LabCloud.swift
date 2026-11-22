import CryptoKit
import Foundation
import Security

nonisolated struct LabCloud: Codable, Sendable {
    enum Role: String, Codable, CaseIterable, Sendable {
        case admin, docente, estudiante
        var name: String { self == .admin ? "Administrador" : rawValue.capitalized }
    }

    struct Session: Codable, Sendable {
        let email: String
        let token: String
        var role: Role
        let refreshToken: String
        let expiresAt: TimeInterval
        let refreshExpiresAt: TimeInterval
        let sessionID: UUID

        var isOwner: Bool { role == .admin && email == "dev@velaarturo.com" }
    }

    enum RequestKind: String, Codable, Identifiable, Sendable {
        case alta, restablecer

        var id: Self { self }
        var title: String { self == .alta ? "Solicitar cuenta" : "Restablecer PIN" }
        var reason: String { self == .alta ? "Nueva cuenta" : "Restablecer PIN" }
    }

    struct AccessRequest: Identifiable, Decodable, Sendable {
        let id: UUID
        let email: String
        let kind: RequestKind
    }

    struct Account: Decodable, Sendable {
        let email: String
        let pin: String
    }

    struct User: Identifiable, Decodable, Sendable {
        let id: UUID
        let email: String
        let role: Role
        let active: Bool
    }

    struct Node: Identifiable, Decodable, Sendable {
        let id: UUID
        let kind: Kind
        let name: String
        let code: String?
        let version: Int?
        let rackUnits: Int?
    }

    enum Kind: Int, Codable, Sendable {
        case classroom, room, rack, server
        var child: Self? { Self(rawValue: rawValue + 1) }
        var item: String {
            switch self {
            case .classroom: "aula"
            case .room: "sala"
            case .rack: "rack"
            case .server: "servidor"
            }
        }
        var addLabel: String {
            switch self {
            case .classroom: "Añadir aula"
            case .room: "Añadir sala"
            case .rack: "Añadir rack"
            case .server: "Añadir servidor"
            }
        }
    }

    struct Failure: LocalizedError {
        let status: Int
        let message: String
        var errorDescription: String? { message }
    }

    private struct Login: Encodable { let email: String; let pin: String }
    private struct Access: Encodable { let email: String; let kind: RequestKind }
    private struct Approval: Encodable { let role: Role? }
    private struct Refresh: Encodable { let refreshToken: String; let requestID: String; let sessionID: String }
    private struct Logout: Encodable { let refreshToken: String }
    private struct NewNode: Encodable { let parentID: String?; let name: String; let rackUnits: Int? }
    private struct Permission: Encodable { let role: Role; let active: Bool }
    private struct CurrentAccount: Decodable { let role: Role }
    private struct ReleaseReceipt: Decodable { let version: Int }
    private struct ErrorBody: Decodable { let message: String }

    let base: URL
    var session: Session
    private var pendingRotation: UUID? = nil

    private static let production = URL(string: "https://nexus-lab-catalog.withered-hat-79c9.workers.dev")!
    private static let credentials = Credentials()

    private static var catalogURL: URL {
        #if DEBUG && targetEnvironment(simulator)
        if let address = ProcessInfo.processInfo.environment["NEXUS_CATALOG_URL"],
           let value = try? endpoint(address), ["localhost", "127.0.0.1"].contains(value.host ?? "") { return value }
        #endif
        return production
    }

    private var cacheScope: String {
        SHA256.hash(data: Data((base.absoluteString + "\n" + session.email).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func endpoint(_ input: String) throws -> URL {
        guard var parts = URLComponents(string: input.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil, parts.path.isEmpty || parts.path == "/" else {
            throw LabLayoutError.invalid("Introduce el dominio HTTPS del catálogo, sin rutas ni parámetros.")
        }
        let scheme = parts.scheme?.lowercased()
        #if DEBUG && targetEnvironment(simulator)
        let isLocal = (host == "127.0.0.1" || host == "localhost") && scheme == "http"
        #else
        let isLocal = false
        #endif
        guard scheme == "https" || isLocal else { throw LabLayoutError.invalid("El catálogo requiere HTTPS.") }
        parts.scheme = scheme
        parts.host = host.lowercased()
        parts.path = ""
        guard let url = parts.url else { throw LabLayoutError.invalid("Dominio del catálogo inválido.") }
        return url
    }

    static func signIn(email: String, pin: String) async throws -> Self {
        let base = catalogURL
        let body = try JSONEncoder().encode(Login(email: email, pin: pin))
        let data = try await send(to: base, path: "api/login", method: "POST", json: body)
        return .init(base: base, session: try JSONDecoder().decode(Session.self, from: data))
    }

    static func requestAccess(email: String, kind: RequestKind) async throws {
        let body = try JSONEncoder().encode(Access(email: email, kind: kind))
        _ = try await send(to: catalogURL, path: "api/access-requests", method: "POST", json: body)
    }

    func pendingRequests() async throws -> [AccessRequest] {
        let data = try await request("api/access-requests")
        return try JSONDecoder().decode([AccessRequest].self, from: data)
    }

    func approve(_ entry: AccessRequest, role: Role?) async throws -> Account {
        let body = try JSONEncoder().encode(Approval(role: role))
        let data = try await request("api/access-requests/\(entry.id.uuidString.lowercased())", method: "POST", json: body)
        return try JSONDecoder().decode(Account.self, from: data)
    }

    func dismiss(_ entry: AccessRequest) async throws {
        _ = try await request("api/access-requests/\(entry.id.uuidString.lowercased())", method: "DELETE")
    }

    func children(of parent: UUID?) async throws -> [Node] {
        let query = parent.map { [URLQueryItem(name: "parent", value: $0.uuidString.lowercased())] } ?? []
        let data = try await request("api/nodes", query: query)
        return try JSONDecoder().decode([Node].self, from: data)
    }

    func create(name: String, parent: UUID?, rackUnits: Int? = nil) async throws -> Node {
        let body = try JSONEncoder().encode(NewNode(parentID: parent?.uuidString.lowercased(), name: name, rackUnits: rackUnits))
        let data = try await request("api/nodes", method: "POST", json: body)
        return try JSONDecoder().decode(Node.self, from: data)
    }

    func users() async throws -> [User] {
        let data = try await request("api/users")
        return try JSONDecoder().decode([User].self, from: data)
    }

    func updateUser(_ account: User, role: Role, active: Bool) async throws -> User {
        let body = try JSONEncoder().encode(Permission(role: role, active: active))
        let data = try await request("api/users/\(account.id.uuidString.lowercased())",
                                       method: "PATCH", json: body)
        return try JSONDecoder().decode(User.self, from: data)
    }

    func refreshedSession() async throws -> Self {
        let data = try await request("api/session")
        let role = try JSONDecoder().decode(CurrentAccount.self, from: data).role
        return try await Self.credentials.updateRole(role, for: self)
    }

    func latest(_ code: String) async throws -> LabPublicationCache.Opened {
        let code = try LabPublication.validateAsset(code)
        let cache = LabPublicationCache.shared
        do {
            let data = try await request("api/assets/\(code)/latest", limit: LabPublication.maximumBytes)
            do { return try await cache.store(data, for: code, scope: cacheScope) }
            catch is CancellationError { throw CancellationError() }
            catch {
                if let saved = try? await cache.open(code, scope: cacheScope) { return saved }
                throw error
            }
        } catch let network as URLError where [.notConnectedToInternet, .networkConnectionLost, .timedOut,
                                               .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed].contains(network.code) {
            return try await cache.open(code, scope: cacheScope)
        }
    }

    func publish(_ url: URL, to code: String, device: String, requestID: UUID) async throws -> Int {
        let code = try LabPublication.validateAsset(code)
        guard url.pathExtension.lowercased() == "pkt" else { throw LabLayoutError.invalid("Elige un archivo .pkt de Packet Tracer.") }
        let bytes = try await Self.readPacketTracer(url)
        let safe = CharacterSet.alphanumerics.intersection(CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"))
        guard let selector = device.addingPercentEncoding(withAllowedCharacters: safe) else {
            throw LabLayoutError.invalid("El nombre del equipo no es válido.")
        }
        let response = try await request("api/assets/\(code)/releases", method: "POST",
                                           packet: bytes, headers: ["X-Nexus-Device": selector, "X-Nexus-Verified": "1",
                                                                     "X-Nexus-Upload-ID": requestID.uuidString])
        return try JSONDecoder().decode(ReleaseReceipt.self, from: response).version
    }

    @concurrent private static func readPacketTracer(_ url: URL) async throws -> Data {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let info = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        let limit = 16 * 1024 * 1024
        guard info.isRegularFile == true, let size = info.fileSize, (1...limit).contains(size) else {
            throw LabLayoutError.invalid("El archivo .pkt debe ocupar entre 1 byte y 16 MiB.")
        }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        guard let bytes = try file.read(upToCount: limit + 1), (1...limit).contains(bytes.count) else {
            throw LabLayoutError.invalid("El archivo .pkt debe ocupar entre 1 byte y 16 MiB.")
        }
        return bytes
    }

    func remember() async throws { try await Self.credentials.install(self) }

    func signOut() async {
        let latest = await Self.credentials.remove(self)
        if let body = try? JSONEncoder().encode(Logout(refreshToken: latest.session.refreshToken)) {
            _ = try? await Self.send(to: latest.base, path: "api/session/logout", method: "POST", json: body)
        }
    }

    func forget() async { _ = await Self.credentials.remove(self) }

    private func request(_ path: String, method: String = "GET", query: [URLQueryItem] = [],
                         json: Data? = nil, packet: Data? = nil, headers: [String: String] = [:],
                         limit: Int = 512 * 1024) async throws -> Data {
        let current = try await Self.credentials.valid(self)
        do {
            return try await Self.send(to: base, path: path, token: current.session.token, method: method,
                                       query: query, json: json, packet: packet, headers: headers, limit: limit)
        } catch let failure as Failure where failure.status == 401 {
            let fresh = try await Self.credentials.valid(self, rejecting: current.session.token)
            return try await Self.send(to: base, path: path, token: fresh.session.token, method: method,
                                       query: query, json: json, packet: packet, headers: headers, limit: limit)
        }
    }

    private actor Credentials {
        private var current = LabCloud.savedSession()
        private var flight: Task<LabCloud, Error>?

        func install(_ cloud: LabCloud) throws {
            flight?.cancel()
            flight = nil
            current = cloud
            try cloud.saveSession()
        }

        func remove(_ cloud: LabCloud) -> LabCloud {
            guard let current, current.session.sessionID == cloud.session.sessionID else { return cloud }
            self.current = nil
            flight?.cancel()
            flight = nil
            LabCloud.clearSession()
            return current
        }

        func updateRole(_ role: Role, for cloud: LabCloud) throws -> LabCloud {
            var updated = try matching(cloud)
            if updated.session.role != role {
                updated.session.role = role
                current = updated
                try? updated.saveSession()
            }
            return updated
        }

        private func matching(_ cloud: LabCloud) throws -> LabCloud {
            guard let current, current.session.sessionID == cloud.session.sessionID,
                  current.session.refreshExpiresAt > Date().timeIntervalSince1970 else {
                throw Failure(status: 401, message: "La sesión venció. Vuelve a iniciar sesión.")
            }
            return current
        }

        func valid(_ cloud: LabCloud, rejecting rejectedToken: String? = nil) async throws -> LabCloud {
            var saved = try matching(cloud)
            if let flight { return try await flight.value }
            if saved.session.expiresAt > Date().timeIntervalSince1970 + 20, rejectedToken != saved.session.token {
                return saved
            }
            let nonce = saved.pendingRotation ?? UUID()
            saved.pendingRotation = nonce
            current = saved
            try? saved.saveSession()
            let task = Task { [saved] in
                defer {
                    if current?.session.sessionID == saved.session.sessionID { flight = nil }
                }
                do {
                    let body = try JSONEncoder().encode(Refresh(refreshToken: saved.session.refreshToken,
                                                               requestID: nonce.uuidString.lowercased(),
                                                               sessionID: saved.session.sessionID.uuidString.lowercased()))
                    let data = try await LabCloud.send(to: saved.base, path: "api/session/refresh", method: "POST", json: body)
                    let session = try JSONDecoder().decode(Session.self, from: data)
                    try Task.checkCancellation()
                    _ = try matching(saved)
                    let updated = LabCloud(base: saved.base, session: session)
                    current = updated
                    try? updated.saveSession()
                    return updated
                } catch let failure as Failure where failure.status == 401 {
                    _ = remove(saved)
                    throw failure
                }
            }
            flight = task
            return try await task.value
        }
    }

    private static let http = URLSession(configuration: .ephemeral, delegate: NoRedirect(), delegateQueue: nil)

    private static func send(to base: URL, path: String, token: String? = nil, method: String = "GET",
                             query: [URLQueryItem] = [], json: Data? = nil, packet: Data? = nil,
                             headers: [String: String] = [:], limit: Int = 512 * 1024) async throws -> Data {
        var parts = URLComponents(url: base.appending(path: path), resolvingAgainstBaseURL: false)
        if !query.isEmpty { parts?.queryItems = query }
        guard let url = parts?.url else { throw LabLayoutError.invalid("Ruta de catálogo inválida.") }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = method
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        if let json {
            request.httpBody = json
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let packet {
            request.httpBody = packet
            request.timeoutInterval = 110
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        }
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let (bytes, response) = try await http.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        let accepted = (200..<300).contains(httpResponse.statusCode)
        let maximum = accepted ? limit : 4096
        guard response.expectedContentLength <= maximum else { throw URLError(.dataLengthExceedsMaximum) }
        var result = Data()
        for try await byte in bytes {
            guard result.count < maximum else { throw URLError(.dataLengthExceedsMaximum) }
            result.append(byte)
        }
        guard accepted else {
            let message = (try? JSONDecoder().decode(ErrorBody.self, from: result))?.message ?? "El catálogo no respondió correctamente."
            throw Failure(status: httpResponse.statusCode, message: message)
        }
        return result
    }

    nonisolated private final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? { nil }
    }

    private static let authQuery = [kSecClass as String: kSecClassGenericPassword as String,
                                    kSecAttrService as String: "org.unsm.NexusRoomCapture.cloudlab",
                                    kSecAttrAccount as String: "session"]

    static func savedSession() -> Self? {
        var result: CFTypeRef?
        var lookup: [String: Any] = authQuery
        lookup[kSecReturnData as String] = true
        guard SecItemCopyMatching(lookup as CFDictionary, &result) == errSecSuccess, let bytes = result as? Data else { return nil }
        guard let saved = try? JSONDecoder().decode(Self.self, from: bytes), saved.base == catalogURL,
              saved.session.refreshExpiresAt > Date().timeIntervalSince1970 else {
            clearSession()
            return nil
        }
        return saved
    }

    func saveSession() throws {
        let data = try JSONEncoder().encode(self)
        let changes = [kSecValueData as String: data]
        var status = SecItemUpdate(Self.authQuery as CFDictionary, changes as CFDictionary)
        if status == errSecItemNotFound {
            var item: [String: Any] = Self.authQuery
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw LabLayoutError.invalid("No se pudo guardar la sesión en el llavero del iPhone.") }
    }

    static func clearSession() { SecItemDelete(authQuery as CFDictionary) }
}
