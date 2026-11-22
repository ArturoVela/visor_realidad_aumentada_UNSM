import Foundation
import simd

@main
struct LabPublicationCheck {
    static func main() async throws {
        guard let path = CommandLine.arguments.dropFirst().first else {
            throw LabLayoutError.invalid("Indica el .nexus.json exportado de Project #2.")
        }
        let raw = try Data(contentsOf: URL(fileURLWithPath: path))
        let topology = try JSONDecoder().decode(LabTopology.self, from: raw)
        guard let server = topology.devices.first(where: { $0.name == "DHCP 1" }) else {
            throw LabLayoutError.invalid("La prueba necesita el equipo DHCP 1.")
        }
        let code = "UNSM-LAB-SRV-01"
        let recognized = try LabPublication.asset(fromQR: LabPublication.qrPayload(for: code))
        precondition(recognized == code)
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = LabPublicationCache(directory: directory)
        let topologyJSON = try JSONSerialization.jsonObject(with: raw)
        func release(_ version: Int, _ device: String = server.id, publishedAt: String = "2026-11-20T14:00:00Z") throws -> Data {
            try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "asset": code, "version": version,
                                                        "deviceID": device, "publishedAt": publishedAt, "topology": topologyJSON])
        }
        let first = try await cache.store(release(1), for: code, scope: "a")
        let second = try await cache.store(release(2), for: code, scope: "a")
        precondition(first.release.deviceID == server.id && first.release.version == 1)
        precondition(second.release.version == 2 && second.project.topology.name.hasSuffix("v2"))
        let stale = try await cache.store(release(1), for: code, scope: "a")
        precondition(stale.release.version == 2 && stale.fromCache)
        let identical = try await cache.store(release(2), for: code, scope: "a")
        precondition(identical.release.version == 2 && !identical.fromCache)
        do {
            _ = try await cache.store(release(2, publishedAt: "2026-11-20T15:00:00Z"), for: code, scope: "a")
            preconditionFailure("La misma versión aceptó datos distintos.")
        } catch is LabLayoutError {}
        do {
            _ = try await cache.store(release(3, "missing"), for: code, scope: "a")
            preconditionFailure("Se guardó una asociación inválida.")
        } catch is LabLayoutError {}
        do {
            _ = try await cache.open(code, scope: "otra-cuenta")
            preconditionFailure("Otra cuenta pudo abrir una publicación local ajena.")
        } catch is LabLayoutError {}
        let offline = try await cache.open(recognized, scope: "a")
        precondition(offline.release.version == 2 && offline.fromCache)
        if let demoPath = CommandLine.arguments.dropFirst(2).first {
            let demo = try LabPublication.decode(LabPublication.read(URL(fileURLWithPath: demoPath)))
            let project = try demo.project()
            let racks = project.layout.placements.filter { $0.kind == .rack }
            precondition(demo.demo == true && demo.rackUnits == 12)
            precondition(racks.count == 1 && racks[0].size == RackMount.Height.compact.size)
            precondition(project.topology.devices.filter { $0.placementID == racks[0].id && !$0.modelID.hasPrefix("patch-") }.count == 3)
            precondition(project.topology.devices.filter { !$0.modelID.hasPrefix("patch-") }.count == 5)
            precondition(project.topology.links.filter { $0.circuitID == nil || $0.circuitID == $0.id }.count == 4)
            let plan = try LabCablePlan.make(project.topology, room: project.room, layout: project.layout)
            precondition(plan.segments.count == 4 && plan.reviewCount == 0)
            precondition(Set(plan.organizers.map(\.face)) == [.front, .rear])
            precondition(plan.organizers.allSatisfy { $0.rack.position == racks[0].position })
            let inlet = plan.terminations.first(where: \.rack)!
            precondition(abs(inlet.point.y - (racks[0].position.y + racks[0].size.y)) < 0.014)
            precondition(plan.guides.contains { min(simd_distance($0.start, inlet.point),
                simd_distance($0.end, inlet.point)) < 0.001 })
        }
        print("PASS: QR estable, publicación local sin regresiones de versión, validación y caché por cuenta.")
    }
}
