import Foundation

/// Standalone check for Nexus: Spanish speech normalization, device matching, intents and answers.
@main
struct LabAssistantCheck {
    static func main() throws {
        checkNormalization()
        let demos = [("VLAN", try LabDemo.vlanLab()), ("Tier IV", try LabDemo.dataCenter()), ("HomeLab", try LabDemo.homeLab())]
        for (label, project) in demos {
            checkDevices(project.topology, label: label)
            checkCommands(project.topology, label: label)
            checkAnswers(project.topology, label: label)
        }
        print("LabAssistantCheck: OK")
    }

    static func checkNormalization() {
        precondition(LabSpeechText.tokens("la PC uno") == ["la", "pc", "1"])
        precondition(LabSpeechText.tokens("PC-1") == LabSpeechText.tokens("pc 1"))
        precondition(LabSpeechText.tokens("PC1") == ["pc", "1"])
        precondition(LabSpeechText.tokens("Servidor A punto uno") == LabSpeechText.tokens("Servidor A.1"))
        precondition(LabSpeechText.tokens("el Cortafuegos") == ["el", "fw"])
        precondition(LabSpeechText.tokens("punto de acceso") == ["ap"])
        precondition(LabSpeechText.plain("¿Dónde está la Cámara?") == "donde esta la camara")
        precondition(LabSpeechText.contains("apaga el switch", "apaga"))
        precondition(!LabSpeechText.contains("apagado", "apaga"))
    }

    private static func core(_ device: LabTopology.Device) -> String {
        LabSpeechText.tokens(device.name.components(separatedBy: "·").first ?? device.name).joined(separator: " ")
    }

    private static func same(_ id: String, as expected: LabTopology.Device, in topology: LabTopology) -> Bool {
        guard let found = topology.devices.first(where: { $0.id == id }) else { return false }
        return found.id == expected.id || core(found) == core(expected)
    }

    /// Saying a device's own name must find it (or another device with the same spoken name).
    static func checkDevices(_ topology: LabTopology, label: String) {
        let devices = topology.devices.filter { !LabDeviceKind.isPassive($0) }
        precondition(!devices.isEmpty, "\(label): sin equipos")
        var misses: [String] = []
        for device in devices {
            let spoken = device.name.components(separatedBy: "·").first ?? device.name
            guard case .locate(let id) = LabAssistantParser.parse("¿Dónde está \(spoken)?", topology: topology),
                  same(id, as: device, in: topology) else {
                misses.append(device.name)
                continue
            }
        }
        let accuracy = Double(devices.count - misses.count) / Double(devices.count)
        precondition(accuracy >= 0.9, "\(label): Nexus no reconoce \(misses.count) de \(devices.count) equipos: \(misses.prefix(8))")
        if !misses.isEmpty { print("\(label): nombres ambiguos para la voz: \(misses.prefix(5))") }
    }

    static func checkCommands(_ topology: LabTopology, label: String) {
        func parse(_ text: String) -> LabAssistantIntent { LabAssistantParser.parse(text, topology: topology) }
        precondition(parse("¿Cómo está la red?") == .summary)
        precondition(parse("Quiero jugar el reto") == .challenge)
        precondition(parse("Envía un paquete") == .sendPacket)
        precondition(parse("¿Qué puedes hacer?") == .help)
        precondition(parse("hola") == .help)
        precondition(parse("cuéntame un chiste") == .unknown || parse("cuéntame un chiste") == .unknownDevice)
        precondition(parse("apaga el refrigerador de la cocina") == .unknownDevice || {
            if case .power = parse("apaga el refrigerador de la cocina") { return true } else { return false }
        }())

        var generator = SystemRandomNumberGenerator()
        let routes = LabFairPlanner.routes(in: topology, poweredOff: [], attempts: 40, limit: 4, using: &generator)
        precondition(!routes.isEmpty, "\(label): sin rutas")
        for route in routes {
            let a = route.source.name.components(separatedBy: "·").first ?? route.source.name
            let b = route.destination.name.components(separatedBy: "·").first ?? route.destination.name
            guard case .ping(let source, let destination) = parse("¿\(a) llega a \(b)?") else {
                preconditionFailure("\(label): no entendí el ping de \(a) a \(b)")
            }
            precondition(same(source, as: route.source, in: topology) && same(destination, as: route.destination, in: topology),
                         "\(label): ping mal interpretado entre \(a) y \(b)")
            if let middle = route.path.devices.dropFirst().dropLast().first(where: { !LabDeviceKind.isPassive($0) }) {
                let name = middle.name.components(separatedBy: "·").first ?? middle.name
                guard case .power(let id, on: false) = parse("Apaga \(name)") else { preconditionFailure("\(label): apagar \(name)") }
                precondition(same(id, as: middle, in: topology))
                guard case .power(_, on: true) = parse("Enciende \(name) otra vez") else { preconditionFailure("\(label): encender") }
            }
        }
    }

    static func checkAnswers(_ topology: LabTopology, label: String) {
        let summary = LabAssistantNarrator.summary(topology, poweredOff: [])
        precondition(summary.contains("equipos") && summary.contains("Todo está encendido"), summary)
        guard let device = topology.devices.first(where: { $0.ipv4 != nil && !LabDeviceKind.isPassive($0) }) else { return }
        let description = LabAssistantNarrator.describe(device, in: topology, poweredOff: [device.id], place: "Rack 1")
        precondition(description.contains(device.name) && description.contains(device.ipv4!) && description.contains("apagado"),
                     description)
        let off = LabAssistantNarrator.summary(topology, poweredOff: [device.id])
        precondition(off.contains(device.name), off)

        var generator = SystemRandomNumberGenerator()
        guard let route = LabFairPlanner.routes(in: topology, poweredOff: [], using: &generator).first else { return }
        let ok = topology.diagnosePing(from: route.source, to: route.destination, poweredOff: [])
        precondition(LabAssistantNarrator.ping(ok, from: route.source, to: route.destination).hasPrefix("¡Sí!"))
        if let middle = route.path.devices.dropFirst().dropLast().first(where: { !LabDeviceKind.isPassive($0) }) {
            let broken = topology.diagnosePing(from: route.source, to: route.destination, poweredOff: [middle.id])
            if broken.issue != nil {
                precondition(LabAssistantNarrator.ping(broken, from: route.source, to: route.destination).hasPrefix("No,"))
            }
            precondition(!LabAssistantNarrator.neighbors(of: middle, in: topology).isEmpty, "\(label): \(middle.name) sin vecinos")
        }
        precondition(LabAssistantNarrator.list(["A", "B", "C"]) == "A, B y C")
    }
}
