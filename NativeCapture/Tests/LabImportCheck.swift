import Foundation
import simd

@main
struct LabImportCheck {
    static func main() throws {
        let fixture = makeFixture()
        let data = try JSONEncoder().encode(fixture)
        let project = try LabImport.project(from: data)
        try project.topology.validate(layout: project.layout)
        precondition(project.topology.links == fixture.links && project.topology.vlans == fixture.vlans)
        precondition(project.topology.notes == fixture.notes)
        precondition(project.layout.placements.count == 3)
        precondition(project.layout.placements.filter { $0.kind == .rack }.count == 1)
        precondition(project.layout.placements.filter { $0.kind == .workstation }.count == 2)
        precondition(project.layout.floorHeight == 0 && project.room.source.contains("sintética"))
        for (before, after) in zip(fixture.devices, project.topology.devices) {
            var expected = before; expected.placementID = after.placementID; expected.offset = after.offset
            precondition(after == expected, "Conservar IP, VLAN, puertos, servicios, sourceModel y configuración.")
            precondition(after.placementID != "unplaced" && after.offset != before.offset, "Ignorar coordenadas importadas.")
        }
        for i in project.layout.placements.indices {
            let a = project.layout.placements[i]
            for x in [-a.size.x / 2, a.size.x / 2] { for z in [-a.size.z / 2, a.size.z / 2] {
                precondition(LabGeometry.contains(SIMD2(a.position.x + x, a.position.z + z), polygon: project.layout.floorPolygon))
            } }
            for j in project.layout.placements.indices where j > i {
                let b = project.layout.placements[j]
                let gap = simd_max(simd_abs(SIMD2(a.position.x - b.position.x, a.position.z - b.position.z))
                    - SIMD2((a.size.x + b.size.x) / 2, (a.size.z + b.size.z) / 2), .zero)
                precondition(simd_length(gap) >= 0.7999, "Huellas separadas al menos 0,8 m.")
            }
        }
        let rack = project.layout.placements.first { $0.kind == .rack }!
        let mounted = project.topology.devices.filter { $0.placementID == rack.id }
        precondition(rack.size == SIMD3<Float>(0.597, 2.013, 1.266))
        for device in mounted {
            let size = HardwareCatalog.renderSize(device.modelID)
            let slot = RackMount.slot(device.modelID, near: device.offset.y)
            precondition(slot > 0 && slot + RackMount.units(device.modelID) <= 42)
            precondition(device.offset == RackMount.center(device.modelID, rackDepth: rack.size.z, slot: slot))
            precondition(abs(device.offset.x) + size.x / 2 <= rack.size.x / 2)
            precondition(abs(device.offset.z) + size.z / 2 <= rack.size.z / 2)
        }
        let roundtrip = try LabImport.project(from: JSONEncoder().encode(project.topology))
        precondition(roundtrip.topology == project.topology, "Reasignación determinista y conservación JSON.")
        precondition(roundtrip.layout.placements == project.layout.placements)
        var dense = fixture
        dense.links = []
        dense.devices = (0..<96).map { index in
            var device = fixture.devices[3]; device.id = "router-\(index)"; device.ipv4 = nil; return device
        }
        let denseProject = try LabImport.project(from: JSONEncoder().encode(dense))
        precondition(denseProject.layout.placements.count <= 12)
        for placement in denseProject.layout.placements {
            let devices = denseProject.topology.devices.filter { $0.placementID == placement.id }.sorted { $0.offset.y < $1.offset.y }
            for pair in zip(devices, devices.dropFirst()) {
                precondition(pair.1.offset.y - pair.0.offset.y > 0.0889, "Separar routers de 2 U.")
            }
        }
        var extraRouter = dense.devices[0]; extraRouter.id = "router-97"
        dense.devices.append(extraRouter)
        reject("Más de 96 dispositivos") { _ = try LabImport.project(from: JSONEncoder().encode(dense)) }

        reject("Archivo mayor de 8 MiB") { _ = try LabImport.project(from: Data(repeating: 32, count: 8 * 1024 * 1024 + 1)) }
        try rejectMutation(fixture, "Modelo desconocido") { $0.devices[0].modelID = "unknown-model" }
        try rejectMutation(fixture, "Rack pasivo no es equipo activo") { $0.devices[0].modelID = "rack-r42612" }
        try rejectMutation(fixture, "Identificador duplicado") { $0.devices[1].id = $0.devices[0].id }
        try rejectMutation(fixture, "Configuración excesiva") { $0.devices[0].configuration = String(repeating: "x", count: 65537) }
        try rejectMutation(fixture, "Autoenlace") { $0.links[0].toDeviceID = $0.links[0].fromDeviceID }
        try rejectMutation(fixture, "IPv4 inválida") { $0.devices[0].ipv4 = "999.168.1.1" }
        try rejectMutation(fixture, "Puerto desconocido") { $0.devices[0].ports.append("InventedPort0") }
        try rejectMutation(fixture, "ID largo") { $0.devices[0].id = String(repeating: "a", count: 65) }
        var crowded = fixture
        crowded.links = []
        crowded.devices = (0..<25).map { index in
            var device = fixture.devices[0]; device.id = "pc-\(index)"; return device
        }
        reject("Más de 24 PCs necesita más puestos") { _ = try LabImport.project(from: JSONEncoder().encode(crowded)) }
        var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        var devices = object["devices"] as! [[String: Any]]
        devices[0]["offset"] = ["NaN", 0, 0] as [Any]; object["devices"] = devices
        reject("NaN JSON") { _ = try LabImport.project(from: JSONSerialization.data(withJSONObject: object)) }
        if CommandLine.arguments.count > 1 {
            let exported = try LabImport.project(from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
            try exported.topology.validate(layout: exported.layout)
            precondition(!exported.topology.devices.isEmpty)
            print("Exportación .pkt real: \(exported.topology.devices.count) equipos, \(exported.topology.links.count) enlaces, \(exported.layout.placements.count) soportes")
        }
        print("PASS: importación JSON, coordenadas descartadas, 2 PCs+switch+router, huellas, enlaces/config preservados y rechazos de entrada inválida")
    }

    private static func makeFixture() -> LabTopology {
        func device(_ id: String, _ model: String, _ ip: String) -> LabTopology.Device {
            .init(id: id, name: id, modelID: model, placementID: "unplaced", offset: SIMD3(10000, -20000, 30000),
                  ipv4: ip, vlan: 10, services: id == "pc-1" ? ["HTTP"] : [], ports: LabDemo.ports(model),
                  sourceModel: model == "pc-optiplex7010" ? "PC-PT" : "Cisco de prueba",
                  configuration: "hostname \(id)\n! configuración conservada\n",
                  sourcePortNames: model == "pc-optiplex7010" ? ["Ethernet": "FastEthernet0"] : nil)
        }
        return LabTopology(name: "Fixture de importación", devices: [
            device("pc-1", "pc-optiplex7010", "192.168.10.10"), device("pc-2", "pc-optiplex7010", "192.168.10.11"),
            device("sw-1", "switch-2960", "192.168.10.2"), device("rt-1", "router-1941", "192.168.10.1")],
            links: [
                .init(id: "pc1-sw", fromDeviceID: "pc-1", fromPort: "Ethernet", toDeviceID: "sw-1", toPort: "FastEthernet0/1", medium: .copper, vlanIDs: [10]),
                .init(id: "pc2-sw", fromDeviceID: "pc-2", fromPort: "Ethernet", toDeviceID: "sw-1", toPort: "FastEthernet0/2", medium: .copper, vlanIDs: [10]),
                .init(id: "sw-rt", fromDeviceID: "sw-1", fromPort: "GigabitEthernet0/1", toDeviceID: "rt-1", toPort: "GigabitEthernet0/0", medium: .copper, vlanIDs: [10])],
            vlans: [.init(id: 10, name: "Pruebas", subnet: "192.168.10.0/24")], notes: ["Datos sintéticos propios."])
    }

    private static func rejectMutation(_ fixture: LabTopology, _ message: String, _ mutation: (inout LabTopology) -> Void) throws {
        var value = fixture; mutation(&value)
        reject(message) { _ = try LabImport.project(from: JSONEncoder().encode(value)) }
    }

    private static func reject(_ message: String, _ operation: () throws -> Void) {
        do { try operation(); preconditionFailure("Se aceptó entrada inválida: \(message)") }
        catch { }
    }
}
