import CryptoKit
import Foundation
import Observation
import simd

nonisolated enum LabImport {
    private static let maximumBytes = 8 * 1024 * 1024
    private struct EditableDocument: Codable {
        let nexusEditableVersion: Int
        let project: LabProject
    }

    static func project(from data: Data, rackHeight: RackMount.Height? = nil) throws -> LabProject {
        guard !data.isEmpty, data.count <= maximumBytes else {
            throw LabLayoutError.invalid("El laboratorio debe ocupar entre 1 byte y 8 MiB.")
        }
        if let document = try? JSONDecoder().decode(EditableDocument.self, from: data) {
            guard document.nexusEditableVersion == 1, document.project.editableID != nil else {
                throw LabLayoutError.invalid("Versión de copia editable incompatible.")
            }
            try validateEditable(document.project)
            return try document.project.completingRackCabling()
        }
        var topology = try JSONDecoder().decode(LabTopology.self, from: data)
        topology.operationsProfile = nil
        topology.editableProfileID = nil
        try validateFields(topology)
        // Imported coordinates are not a measured room and never control placement.
        for index in topology.devices.indices {
            topology.devices[index].placementID = "unplaced"
            topology.devices[index].offset = .zero
        }
        try topology.validate()
        if let plan = topology.logicalPlan { try validatePlan(plan, devices: topology.devices) }
        return try physicalProject(topology, rackHeight: rackHeight)
    }

    private static func physicalProject(_ input: LabTopology, rackHeight: RackMount.Height?) throws -> LabProject {
        guard let reference = HardwareCatalog.item("rack-r42612")?.size else {
            throw LabLayoutError.invalid("Faltan dimensiones verificadas del rack de referencia.")
        }
        let rackSize = rackHeight?.size ?? reference
        let capacity = min(38, (rackHeight?.rawValue ?? 42) - 1)
        let maximumY = rackHeight == nil || rackHeight == .full ? 1.85 : rackSize.y - 0.035
        var topology = input
        let zones = zones(for: input)
        let zoneOrder = zones.keys.sorted()
        var furniture: [(zone: String, id: String, kind: LabPlacement.Kind, title: String)] = []
        let deskSize = SIMD3<Float>(2, 1.25, 0.92)
        var rackCount = 0, deskCount = 0

        // Reserve a rack beside each server zone and share a central bank for the other network equipment.
        var rackGroups: [String: [Int]] = [:]
        for zone in zoneOrder {
            guard let members = zones[zone] else { continue }
            let mounted = members.filter { deskSlots(topology.devices[$0]).isEmpty }
            let hasServer = mounted.contains { topology.devices[$0].visualModelID.hasPrefix("server-") }
            let rackZone = rackHeight == nil && hasServer ? zone : "Infraestructura de red"
            rackGroups[rackZone, default: []] += mounted

            var desks: [Set<String>] = []
            for index in members {
                let device = topology.devices[index]
                let slots = deskSlots(device)
                guard !slots.isEmpty else { continue }
                let model: String
                switch device.visualModelID {
                case "pt-access-point", "access-point", "camera-ip": model = "desk-network"
                default: model = device.visualModelID
                }
                let desk = desks.firstIndex { used in slots.indices.contains { !used.contains(model + ":" + String($0)) } }
                    ?? desks.count
                if desk == desks.count {
                    guard deskCount < 24 else { throw LabLayoutError.invalid("La importación necesita más de 24 puestos.") }
                    deskCount += 1
                    desks.append([])
                    let title = desk == 0 ? zone : "\(zone) · \(desk + 1)"
                    furniture.append((zone, "import-desk-\(deskCount)", .workstation, title))
                }
                let slot = slots.indices.first { !desks[desk].contains(model + ":" + String($0)) }!
                desks[desk].insert(model + ":" + String(slot))
                let deskID = deskCount - desks.count + desk + 1
                topology.devices[index].placementID = "import-desk-\(deskID)"
                topology.devices[index].offset = slots[slot]
            }
        }

        for zone in rackGroups.keys.sorted() {
            guard let indices = rackGroups[zone], !indices.isEmpty else { continue }
            var lowerUnits = 0, upperUnits = 0
            for index in indices {
                let device = topology.devices[index]
                let model = device.visualModelID
                let units = RackMount.units(model)
                let used = lowerUnits + upperUnits
                if used == 0 || used + units > capacity {
                    guard rackCount < 12 else { throw LabLayoutError.invalid("La importación necesita más de 12 racks.") }
                    rackCount += 1
                    lowerUnits = 0
                    upperUnits = 0
                    furniture.append((zone, "import-rack-\(rackCount)", .rack, "Rack \(rackCount) · \(zone)"))
                }
                let routesAbove = device.providesDHCP || model.hasPrefix("switch-")
                    || model.hasPrefix("router-") || model.hasPrefix("patch-")
                let slot = routesAbove ? capacity + 1 - upperUnits - units : lowerUnits + 1
                let center = RackMount.center(model, rackDepth: rackSize.z, slot: slot)
                let size = device.visualSize
                guard center.y + size.y / 2 <= maximumY, size.z <= rackSize.z - 0.16 else {
                    throw LabLayoutError.invalid("El equipo no cabe en el espacio útil del rack: \(device.name).")
                }
                topology.devices[index].placementID = "import-rack-\(rackCount)"
                topology.devices[index].offset = center
                // A free unit keeps labels and patch cords visible.
                if routesAbove { upperUnits += units + 1 }
                else { lowerUnits += units + 1 }
            }
        }

        furniture.sort { lhs, rhs in
            if lhs.zone != rhs.zone { return lhs.zone < rhs.zone }
            if lhs.kind != rhs.kind { return lhs.kind == .rack }
            return lhs.id.compare(rhs.id, options: .numeric) == .orderedAscending
        }
        let count = furniture.count
        let columns = min(6, max(1, Int(ceil(sqrt(Double(count))))))
        let rows = (count + columns - 1) / columns
        let cell = SIMD2<Float>(3.2, 3.6)
        let width = Float(columns) * cell.x, depth = Float(rows) * cell.y
        let placements = furniture.enumerated().map { index, entry in
            let row = index / columns, column = index % columns
            // Adjacent positions in a zone stay adjacent when it crosses a row.
            let x = row.isMultiple(of: 2) ? column : columns - 1 - column
            return LabPlacement(id: entry.id, kind: entry.kind, title: entry.title,
                position: SIMD3(-width / 2 + (Float(x) + 0.5) * cell.x, 0,
                                -depth / 2 + (Float(row) + 0.5) * cell.y),
                yaw: 0, size: entry.kind == .rack ? rackSize : deskSize)
        }
        let layout = LabLayout(area: width * depth, floorHeight: 0,
            floorPolygon: [SIMD2(-width / 2, -depth / 2), SIMD2(width / 2, -depth / 2),
                           SIMD2(width / 2, depth / 2), SIMD2(-width / 2, depth / 2)],
            placements: placements, warnings: [
                "Sala de referencia distribuida por áreas y conexiones de la topología.",
                "Las distancias y rutas de cable son estimaciones del montaje 3D.",
                "Configuración de Packet Tracer disponible para consulta. Nexus AR muestra el flujo ilustrativo."],
            importedRoom: true)
        try topology.validate(layout: layout)
        let room = try LabDemo.virtualRoom(width: width, depth: depth, height: 3.5)
        return try LabProject(room: room, layout: layout, topology: topology).completingRackCabling()
    }

    private static func zones(for topology: LabTopology) -> [String: [Int]] {
        let devices = Dictionary(uniqueKeysWithValues: topology.devices.map { ($0.id, $0) })
        var linksByDevice: [String: [LabTopology.Link]] = [:]
        for link in topology.links {
            linksByDevice[link.fromDeviceID, default: []].append(link)
            linksByDevice[link.toDeviceID, default: []].append(link)
        }
        var areasByDevice: [String: Int] = [:], areaTitles: [Int: String] = [:]
        if let plan = topology.logicalPlan {
            for (index, area) in plan.areas.enumerated() {
                let labels = plan.labels.filter { area.contains($0.position) }
                let heading = labels.first { $0.text.first?.isLetter == true } ?? labels.first
                areaTitles[index] = heading?.text.split(separator: "\n").first.map {
                    String($0.prefix(60)).replacingOccurrences(of: "&amp;", with: "&")
                } ?? "Área \(index + 1)"
            }
            for (id, point) in plan.devicePositions {
                areasByDevice[id] = plan.areas.indices.filter { plan.areas[$0].contains(point) }.min { lhs, rhs in
                    let a = plan.areas[lhs], b = plan.areas[rhs]
                    let da = a.upper - a.lower, db = b.upper - b.lower
                    return da.x * da.y < db.x * db.y
                }
            }
        }
        return Dictionary(grouping: topology.devices.indices) { index in
            let device = topology.devices[index]
            let links = linksByDevice[device.id, default: []]
            let neighbors = links.compactMap { devices[$0.fromDeviceID == device.id ? $0.toDeviceID : $0.fromDeviceID] }
            if let own = areasByDevice[device.id], let title = areaTitles[own] { return title }
            let accessAreas = Set(neighbors.filter { $0.modelID.hasPrefix("switch-") }.compactMap { areasByDevice[$0.id] })
            if accessAreas.count == 1, let area = accessAreas.first, let title = areaTitles[area] { return title }
            let adjacentAreas = Set(neighbors.compactMap { areasByDevice[$0.id] })
            if adjacentAreas.count == 1, let area = adjacentAreas.first, let title = areaTitles[area] { return title }

            var vlans = Set(links.flatMap(\.vlanIDs))
            if let vlan = device.vlan { vlans = [vlan] }
            let accessSwitch = neighbors.first { $0.modelID.hasPrefix("switch-") }
            if vlans.count == 1, let vlan = vlans.first {
                if let accessSwitch { return "VLAN \(vlan) · \(accessSwitch.name)" }
                return "VLAN \(vlan)"
            }
            if let accessSwitch { return "Red · \(accessSwitch.name)" }
            return deskSlots(device).isEmpty ? "Infraestructura de red" : "Zona común"
        }
    }

    private static func deskSlots(_ device: LabTopology.Device) -> [SIMD3<Float>] {
        let y: Float = 0.75 + device.visualSize.y / 2
        switch device.visualModelID {
        case "pc-optiplex7010": return [SIMD3(0.64, device.visualSize.y / 2 + 0.015, 0.02)]
        case "laptop-latitude5420": return [SIMD3(0.26, y, -0.12), SIMD3(0.66, y, -0.12)]
        case "pt-printer": return [SIMD3(-0.73, y, 0.14)]
        case "pt-tablet": return [SIMD3(-0.73, y, -0.29)]
        case "pt-smartphone": return [SIMD3(-0.47, y, -0.29)]
        case "pt-access-point", "access-point", "camera-ip": return [SIMD3(0.68, y, 0.28)]
        case "phone-7960": return [SIMD3(0.26, y, 0.28)]
        default: return []
        }
    }

    private static func validatePlan(_ plan: LabLogicalPlan, devices: [LabTopology.Device]) throws {
        func valid(_ point: SIMD2<Float>) -> Bool {
            point.x.isFinite && point.y.isFinite && abs(point.x) <= 1_000_000 && abs(point.y) <= 1_000_000
        }
        guard Set(plan.devicePositions.keys) == Set(devices.map(\.id)),
              plan.devicePositions.values.allSatisfy(valid), plan.areas.count <= 128, plan.labels.count <= 128,
              plan.areas.allSatisfy({ valid($0.lower) && valid($0.upper)
                  && $0.lower.x < $0.upper.x && $0.lower.y < $0.upper.y }),
              plan.labels.allSatisfy({ valid($0.position) && !$0.text.isEmpty && $0.text.utf8.count <= 512
                  && $0.text.unicodeScalars.allSatisfy { $0 == "\n" || !CharacterSet.controlCharacters.contains($0) } })
        else { throw LabLayoutError.invalid("Posiciones, áreas o etiquetas del plano lógico inválidas.") }
    }

    struct Entry: Identifiable, Sendable {
        let url: URL
        let name: String
        let date: Date
        var id: URL { url }
        var libraryKey: String { url.deletingLastPathComponent().lastPathComponent + "/" + url.lastPathComponent }
        var receivedFromMac: Bool { url.deletingLastPathComponent().lastPathComponent == "received" }
    }

    static func history(site: String) throws -> [Entry] {
        let directory = try library(site: site, create: false)
        var entries = try entries(in: directory)
        if site == "principal" {
            let legacy = directory.deletingLastPathComponent().appendingPathComponent("last-import.nexus.json")
            if let values = try? legacy.resourceValues(forKeys: [.contentModificationDateKey]),
               let date = values.contentModificationDate {
                entries.append(Entry(url: legacy, name: "Importación anterior", date: date))
            }
        }
        return entries.sorted { $0.date > $1.date }
    }

    static func received(excluding filenames: Set<String> = []) throws -> [Entry] {
        let directory = try library(site: "principal", create: false).deletingLastPathComponent()
            .appendingPathComponent("received", isDirectory: true)
        return try entries(in: directory, fromMac: true, excluding: filenames).sorted { $0.date > $1.date }
    }

    static func loadReceived(filename: String) throws -> LabProject {
        guard let entry = try received().first(where: { $0.url.lastPathComponent == filename }) else {
            throw LabLayoutError.invalid("El laboratorio recibido ya no está disponible.")
        }
        return try load(entry)
    }

    private static func entries(in directory: URL, fromMac: Bool = false,
                                excluding filenames: Set<String> = []) throws -> [Entry] {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey]
        let urls = try FileManager.default.fileExists(atPath: directory.path)
            ? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])
            : []
        return urls.compactMap { file -> Entry? in
            let filename = file.lastPathComponent
            guard !filenames.contains(filename), filename.hasSuffix(".nexus.json"),
                  let values = try? file.resourceValues(forKeys: keys),
                  values.isRegularFile == true, let date = values.contentModificationDate else { return nil }
            // CoreDevice writes directly into the container. Only list a transfer after its content matches its name.
            if fromMac {
                guard let data = try? read(file),
                      filename.hasPrefix(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() + "_")
                else { return nil }
            }
            let name = filename.dropFirst(fromMac ? 65 : 37).dropLast(".nexus.json".count)
            return Entry(url: file, name: String(name), date: date)
        }
    }

    static func loadLatest(site: String = "principal") throws -> LabProject {
        guard let entry = try history(site: site).first else { throw LabLayoutError.invalid("Este sitio todavía no tiene inventarios guardados.") }
        return try load(entry)
    }

    static func load(_ entry: Entry) throws -> LabProject {
        try project(from: read(entry.url))
    }

    private static func read(_ url: URL) throws -> Data {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let size = values.fileSize, size > 0, size <= maximumBytes else {
            throw LabLayoutError.invalid("El inventario guardado está vacío o supera 8 MiB.")
        }
        return try Data(contentsOf: url, options: .mappedIfSafe)
    }

    static func save(_ topology: LabTopology, site: String = "principal") throws -> URL {
        try validateFields(topology)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(topology)
        guard data.count <= maximumBytes else { throw LabLayoutError.invalid("El inventario supera 8 MiB.") }
        _ = try project(from: data)
        let directory = try library(site: site, create: true)
        let title = String(topology.name.prefix(36)).map { $0.isLetter || $0.isNumber || " -_".contains($0) ? $0 : "_" }
        let url = directory.appendingPathComponent(UUID().uuidString + "_" + String(title) + ".nexus.json")
        try data.write(to: url, options: .atomic)
        return url
    }

    static func createEditableCopy(of source: LabProject, site: String) throws -> (LabProject, Entry) {
        var copy = try source.completingRackCabling()
        let id = UUID()
        copy.editableID = id
        copy.topology.editableProfileID = id
        if source.editableID == nil { copy.topology.name = String(source.topology.name.prefix(138)) + " · copia editable" }
        let folder = try library(site: site, create: true)
        let title = copy.topology.name.prefix(72).map { $0.isLetter || $0.isNumber || " -_·".contains($0) ? $0 : "_" }
        let url = folder.appendingPathComponent(id.uuidString + "_" + String(title) + ".nexus.json")
        try writeEditable(copy, at: url)
        return (copy, Entry(url: url, name: copy.topology.name, date: .now))
    }

    static func saveEditable(_ project: LabProject, to entry: Entry) throws {
        guard let id = project.editableID, !entry.receivedFromMac, entry.url.lastPathComponent.hasPrefix(id.uuidString + "_"),
              let original = try? JSONDecoder().decode(EditableDocument.self, from: read(entry.url)),
              original.project.editableID == id else {
            throw LabLayoutError.invalid("Vuelve a abrir la copia editable desde Laboratorios.")
        }
        try writeEditable(project, at: entry.url)
    }

    private static func validateEditable(_ project: LabProject) throws {
        guard project.editableID != nil, project.topology.editableProfileID == project.editableID else {
            throw LabLayoutError.invalid("El identificador de la copia editable no coincide.")
        }
        try validateFields(project.topology, allowsEmpty: true)
        try project.topology.validate(layout: project.layout)
        var checked = project.topology
        for device in project.topology.devices {
            if let services = device.serverServices {
                try checked.configureServer(device.id, name: device.name, address: device.ipv4, vlan: device.vlan, services: services)
            }
        }
        if let plan = project.topology.logicalPlan { try validatePlan(plan, devices: project.topology.devices) }
        _ = try project.room.jsonData()
    }

    private static func writeEditable(_ project: LabProject, at url: URL) throws {
        try validateEditable(project)
        let document = EditableDocument(nexusEditableVersion: 1, project: project)
        let data = try JSONEncoder().encode(document)
        guard data.count <= maximumBytes else { throw LabLayoutError.invalid("La copia editable supera 8 MiB.") }
        try data.write(to: url, options: .atomic)
    }

    private static func library(site: String, create: Bool) throws -> URL {
        guard site == "principal" || UUID(uuidString: site) != nil else {
            throw LabLayoutError.invalid("Identificador de sitio inválido.")
        }
        let url = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: create)
            .appendingPathComponent("Labs", isDirectory: true).appendingPathComponent(site, isDirectory: true)
        if create { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        return url
    }

    private static func validateFields(_ topology: LabTopology, allowsEmpty: Bool = false) throws {
        guard allowsEmpty || !topology.devices.isEmpty, topology.devices.count <= 96, topology.links.count <= 192,
              topology.vlans.count <= 64, topology.notes.count <= 256,
              text(topology.name, maximum: 160), topology.notes.allSatisfy({ $0.utf8.count <= 1024 }) else {
            throw LabLayoutError.invalid("El laboratorio supera límites de equipos, conexiones o texto.")
        }
        for device in topology.devices {
            if let details = device.packetTracer {
                guard details.description.utf8.count <= 2048, details.interfaces.count <= 64,
                      details.dhcpPools.count <= 64, Set(details.interfaces.map(\.port)).count == details.interfaces.count,
                      details.interfaces.allSatisfy({
                          LabDemo.ports(device.modelID, includingSerial: true).contains($0.port)
                            && [$0.ipv4, $0.mask, $0.gateway, $0.ospfArea, $0.dhcpServer].compactMap { $0 }.allSatisfy { $0.utf8.count <= 64 }
                            && ($0.description?.utf8.count ?? 0) <= 2048
                      }),
                      details.dhcpPools.allSatisfy({
                          $0.name.utf8.count <= 120 && [$0.network, $0.mask, $0.start, $0.end, $0.gateway, $0.dns].allSatisfy { $0.utf8.count <= 64 }
                      }) else {
                    throw LabLayoutError.invalid("Configuración de red fuera de los límites: \(device.name).")
                }
            }
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
                  link.sourceCableType.map({ text($0, maximum: 64) }) ?? true,
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

@MainActor
@Observable final class SavedLaboratories {
    struct Folder: Identifiable, Codable, Sendable, Equatable {
        var id = UUID()
        var name: String
    }

    struct Details: Codable, Equatable, Sendable {
        var name: String?
        var folderID: UUID?
        var archived = false
        var deleted = false
        var enabled = true
        var inLibrary: Bool { !archived && !deleted }
    }

    private struct Index: Codable {
        var folders: [Folder] = []
        var items: [String: Details] = [:]
    }

    private let key = "savedLaboratories.v1"
    private let defaults: UserDefaults
    private let readable: Bool
    private var index: Index

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key) {
            let saved = try? JSONDecoder().decode(Index.self, from: data)
            index = saved ?? Index()
            readable = saved != nil
        } else {
            index = Index()
            readable = true
        }
    }

    var folders: [Folder] { index.folders.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } }
    var hiddenKeys: Set<String> { Set(index.items.filter { !$0.value.inLibrary }.keys) }

    func details(_ entry: LabImport.Entry) -> Details { index.items[entry.libraryKey] ?? Details() }
    func name(_ entry: LabImport.Entry) -> String { details(entry).name ?? entry.name }

    func rename(_ entry: LabImport.Entry, to text: String) throws {
        let title = try Self.validName(text)
        try change(entry) { $0.name = title }
    }

    func change(_ entry: LabImport.Entry, _ update: (inout Details) -> Void) throws {
        var next = index
        update(&next.items[entry.libraryKey, default: Details()])
        try save(next)
    }

    func saveFolder(_ input: String, id: UUID? = nil) throws {
        let name = try Self.validName(input)
        guard !index.folders.contains(where: {
            $0.id != id && $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
        }) else { throw LabLayoutError.invalid("Ya existe una carpeta con ese nombre.") }
        var next = index
        if let id, let existing = next.folders.firstIndex(where: { $0.id == id }) {
            next.folders[existing].name = name
        } else {
            next.folders.append(Folder(name: name))
        }
        try save(next)
    }

    func removeFolder(_ folder: Folder) throws {
        var next = index
        next.folders.removeAll { $0.id == folder.id }
        for key in next.items.keys where next.items[key]?.folderID == folder.id {
            next.items[key]?.folderID = nil
        }
        try save(next)
    }

    private func save(_ next: Index) throws {
        guard readable else { throw LabLayoutError.invalid("No se pudo leer el índice de laboratorios guardados.") }
        defaults.set(try JSONEncoder().encode(next), forKey: key)
        index = next
    }

    private static func validName(_ text: String) throws -> String {
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 80,
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { throw LabLayoutError.invalid("Escribe un nombre de hasta 80 caracteres en una sola línea.") }
        return name
    }
}
