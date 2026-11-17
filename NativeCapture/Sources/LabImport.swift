import Foundation
import simd

nonisolated enum LabImport {
    private static let maximumBytes = 8 * 1024 * 1024
    private static let rackUnit: Float = 0.04445

    static func project(from data: Data) throws -> LabProject {
        guard !data.isEmpty, data.count <= maximumBytes else {
            throw LabLayoutError.invalid("El laboratorio debe ocupar entre 1 byte y 8 MiB.")
        }
        var topology = try JSONDecoder().decode(LabTopology.self, from: data)
        try validateFields(topology)
        // Imported coordinates are not a measured room and never control placement.
        for index in topology.devices.indices {
            topology.devices[index].placementID = "unplaced"
            topology.devices[index].offset = .zero
        }
        try topology.validate()
        guard let rackSize = HardwareCatalog.item("rack-r42612")?.size else {
            throw LabLayoutError.invalid("Faltan dimensiones verificadas del rack de referencia.")
        }
        var usedRackUnits: [Int] = [], workstations: [String: Int] = [:]
        for index in topology.devices.indices {
            let model = topology.devices[index].modelID
            if isWorkstation(model) {
                let desk = workstations[model, default: 0]
                guard desk < 24 else { throw LabLayoutError.invalid("La importación necesita más de 24 puestos.") }
                workstations[model] = desk + 1
                topology.devices[index].placementID = "import-desk-\(desk + 1)"
                switch model {
                case "pc-optiplex7010":
                    let height = HardwareCatalog.item(model)?.size?.y ?? 0.36
                    topology.devices[index].offset = SIMD3(0.44, height / 2 + 0.015, 0)
                case "laptop-latitude5420": topology.devices[index].offset = SIMD3(0.37, 0.77, -0.13)
                default: topology.devices[index].offset = SIMD3(-0.47, 0.79, 0.13)
                }
            } else {
                let units = model == "router-1941" || model == "router-2911" ? 2 : 1
                var rack = max(0, usedRackUnits.count - 1)
                if usedRackUnits.isEmpty || usedRackUnits[rack] + units > 38 {
                    guard usedRackUnits.count < 12 else { throw LabLayoutError.invalid("La importación necesita más de 12 racks.") }
                    usedRackUnits.append(0); rack = usedRackUnits.count - 1
                }
                let height = HardwareCatalog.item(model)?.size?.y ?? rackUnit
                let depth = HardwareCatalog.item(model)?.size?.z ?? (model == "server-c220m5" ? 0.787 : 0.30)
                let center = 0.15 + Float(usedRackUnits[rack]) * rackUnit + height / 2
                guard center - height / 2 >= 0.1499, center + height / 2 <= 1.85,
                      depth > 0, depth <= rackSize.z - 0.10 else {
                    throw LabLayoutError.invalid("El equipo no cabe en el espacio útil del rack: \(topology.devices[index].name).")
                }
                topology.devices[index].placementID = "import-rack-\(rack + 1)"
                topology.devices[index].offset = SIMD3(0, center, -rackSize.z / 2 + 0.07 + depth / 2)
                // ponytail: one empty U keeps educational labels readable; denser packing needs a label policy.
                usedRackUnits[rack] += units + 1
            }
        }
        let deskCount = workstations.values.max() ?? 0
        let count = usedRackUnits.count + deskCount
        let columns = min(6, max(1, Int(ceil(sqrt(Double(count))))))
        let rows = (count + columns - 1) / columns
        let width = Float(columns) * 3, depth = Float(rows) * 3.6
        var placements: [LabPlacement] = []
        for index in 0..<count {
            let rack = index < usedRackUnits.count
            let number = rack ? index + 1 : index - usedRackUnits.count + 1
            placements.append(LabPlacement(id: "import-\(rack ? "rack" : "desk")-\(number)",
                kind: rack ? .rack : .workstation, title: "\(rack ? "Rack" : "Puesto") importado \(number)",
                position: SIMD3(-width / 2 + (Float(index % columns) + 0.5) * 3, 0,
                                -depth / 2 + (Float(index / columns) + 0.5) * 3.6),
                yaw: 0, size: rack ? rackSize : SIMD3(1.2, 1.25, 0.75)))
        }
        let layout = LabLayout(area: width * depth, floorHeight: 0,
            floorPolygon: [SIMD2(-width / 2, -depth / 2), SIMD2(width / 2, -depth / 2),
                           SIMD2(width / 2, depth / 2), SIMD2(-width / 2, depth / 2)],
            placements: placements, warnings: [
                "Sala sintética calculada para la topología importada; no es una medición del entorno real.",
                "Se descartan posiciones externas y se reservan celdas de 3 × 3,6 m; la distribución no certifica una instalación.",
                "La configuración importada se conserva como texto; no se ejecuta Cisco IOS ni se simulan sus servicios."])
        try topology.validate(layout: layout)
        let room = try LabDemo.virtualRoom(width: width, depth: depth, height: 3.5)
        return LabProject(room: room, layout: layout, topology: topology)
    }

    static func loadLatest() throws -> LabProject {
        let url = try lastURL(createDirectory: false)
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let size = values.fileSize, size > 0, size <= maximumBytes else {
            throw LabLayoutError.invalid("El laboratorio guardado está vacío o supera 8 MiB.")
        }
        return try project(from: Data(contentsOf: url, options: .mappedIfSafe))
    }

    static func save(_ topology: LabTopology) throws -> URL {
        try validateFields(topology)
        // Run the same distribution/validation as import before replacing the saved laboratory.
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(topology)
        _ = try project(from: data)
        let url = try lastURL(createDirectory: true)
        try data.write(to: url, options: .atomic)
        return url
    }

    private static func lastURL(createDirectory: Bool) throws -> URL {
        let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
            appropriateFor: nil, create: createDirectory)
        let directory = documents.appendingPathComponent("Labs", isDirectory: true)
        if createDirectory { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        return directory.appendingPathComponent("last-import.nexus.json")
    }

    private static func isWorkstation(_ model: String) -> Bool {
        ["pc-optiplex7010", "laptop-latitude5420", "phone-7960"].contains(model)
    }

    private static func validateFields(_ topology: LabTopology) throws {
        guard !topology.devices.isEmpty, topology.devices.count <= 96, topology.links.count <= 192,
              topology.vlans.count <= 64, topology.notes.count <= 256,
              text(topology.name, maximum: 160), topology.notes.allSatisfy({ $0.utf8.count <= 1024 }) else {
            throw LabLayoutError.invalid("El laboratorio supera límites de equipos, conexiones o texto.")
        }
        for device in topology.devices {
            guard text(device.id, maximum: 64), text(device.modelID, maximum: 64),
                  text(device.name, maximum: 160), text(device.placementID, maximum: 64),
                  device.ports.count <= 64, device.ports.allSatisfy({ text($0, maximum: 64) }),
                  device.services.count <= 32, device.services.allSatisfy({ text($0, maximum: 120) }),
                  device.ipv4.map({ text($0, maximum: 64) }) ?? true,
                  device.sourceModel.map({ text($0, maximum: 64) }) ?? true,
                  device.configuration.map({ $0.utf8.count <= 65536 }) ?? true,
                  (0..<3).allSatisfy({ device.offset[$0].isFinite }) else {
                throw LabLayoutError.invalid("Identificadores, puertos o configuración fuera de límites: \(device.name).")
            }
        }
        for link in topology.links {
            guard [link.id, link.fromDeviceID, link.toDeviceID, link.fromPort, link.toPort].allSatisfy({ text($0, maximum: 64) }),
                  link.vlanIDs.count <= 64 else { throw LabLayoutError.invalid("Extremos o VLAN de enlace fuera de límites.") }
        }
        for vlan in topology.vlans {
            guard text(vlan.name, maximum: 120), text(vlan.subnet, maximum: 64, allowEmpty: true) else {
                throw LabLayoutError.invalid("Nombre o subred VLAN fuera de límites.")
            }
        }
    }

    private static func text(_ value: String, maximum: Int, allowEmpty: Bool = false) -> Bool {
        value.utf8.count <= maximum && (allowEmpty || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            && !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }
}
