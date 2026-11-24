import Foundation

// MARK: - Spoken text

/// Normalizes Spanish speech so "la PC uno", "pc-1" and "PC1" compare equal.
nonisolated enum LabSpeechText {
    private static let numbers = ["cero": "0", "uno": "1", "dos": "2", "tres": "3", "cuatro": "4", "cinco": "5",
                                  "seis": "6", "siete": "7", "ocho": "8", "nueve": "9", "diez": "10",
                                  "once": "11", "doce": "12", "primero": "1", "primer": "1", "segundo": "2", "tercero": "3"]
    private static let words = ["camara": "cam", "camaras": "cam", "cortafuegos": "fw", "firewall": "fw", "firewalls": "fw",
                                "switch": "sw", "switches": "sw", "suiche": "sw", "suich": "sw", "conmutador": "sw",
                                "router": "rtr", "routers": "rtr", "enrutador": "rtr", "ruteador": "rtr",
                                "computadora": "pc", "computador": "pc", "ordenador": "pc", "compu": "pc",
                                "portatil": "laptop", "notebook": "laptop", "servidores": "servidor", "server": "servidor",
                                "telefonos": "telefono", "celular": "telefono", "impresoras": "impresora"]
    private static let phrases = [("punto de acceso", " ap "), ("access point", " ap "), ("wi fi", " ap "), ("wifi", " ap "),
                                  (" punto ", " ")]

    /// Lowercase, without accents or punctuation, with single spaces.
    static func plain(_ text: String) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "es"))
            .lowercased()
        let cleaned = String(folded.map { $0.isLetter || $0.isNumber ? $0 : " " })
        return cleaned.split(separator: " ").joined(separator: " ")
    }

    /// Tokens for device matching: digits split from letters, number words as digits and common aliases.
    static func tokens(_ text: String) -> [String] {
        var value = " " + plain(text) + " "
        for (phrase, replacement) in phrases { value = value.replacingOccurrences(of: phrase, with: replacement) }
        var spaced = ""
        var previous: Character?
        for character in value {
            if let previous, previous.isNumber != character.isNumber, previous != " ", character != " " { spaced.append(" ") }
            spaced.append(character)
            previous = character
        }
        return spaced.split(separator: " ").map { token in
            let word = String(token)
            return numbers[word] ?? words[word] ?? word
        }
    }

    /// True when every word of `phrase` appears together in `text` (both already `plain`).
    static func contains(_ text: String, _ phrase: String) -> Bool {
        (" " + text + " ").contains(" " + phrase + " ")
    }
}

// MARK: - Devices

nonisolated enum LabDeviceKind {
    /// Short Spanish noun for a device, for answers and matching.
    static func noun(_ device: LabTopology.Device) -> String {
        let model = device.modelID
        if device.isAccessPoint { return "punto de acceso Wi-Fi" }
        if model.contains("firewall") { return "firewall" }
        if model.hasPrefix("switch-") || model == "pt-switch" { return "switch" }
        if model.hasPrefix("router-") || model == "pt-router" { return "router" }
        if model.hasPrefix("server-") || model == "pt-server" { return "servidor" }
        if model.hasPrefix("laptop-") || model == "pt-laptop" { return "laptop" }
        if model.hasPrefix("pc-") || model == "pt-desktop" { return "computadora" }
        if model.hasPrefix("phone-") { return "teléfono IP" }
        if model == "pt-smartphone" { return "celular" }
        if model.hasPrefix("camera") { return "cámara IP" }
        if model.contains("printer") { return "impresora" }
        if model.hasPrefix("patch-") { return "patch panel" }
        if model.contains("raspberry") { return "Raspberry Pi" }
        return "equipo"
    }

    /// Token that a spoken phrase uses for this kind of device.
    static func token(_ device: LabTopology.Device) -> String? {
        switch noun(device) {
        case "punto de acceso Wi-Fi": "ap"
        case "firewall": "fw"
        case "switch": "sw"
        case "router": "rtr"
        case "servidor": "servidor"
        case "laptop": "laptop"
        case "computadora": "pc"
        case "teléfono IP", "celular": "telefono"
        case "cámara IP": "cam"
        case "impresora": "impresora"
        default: nil
        }
    }

    static func isPassive(_ device: LabTopology.Device) -> Bool { device.modelID.hasPrefix("patch-") || device.isFanTray }
}

/// Finds the device a person means from a spoken fragment.
nonisolated struct LabDeviceMatcher {
    struct Match {
        let device: LabTopology.Device
        let score: Double
    }

    static let threshold = 2.0

    private struct Candidate {
        let device: LabTopology.Device
        let tokens: [String]
        let core: String
        let kind: String?
        let ip: [String]

        init(_ device: LabTopology.Device) {
            self.device = device
            tokens = LabSpeechText.tokens(device.name.components(separatedBy: "·").first ?? device.name)
            core = tokens.joined()
            kind = LabDeviceKind.token(device)
            ip = device.ipv4.map { LabSpeechText.tokens($0) } ?? []
        }
    }

    private let candidates: [Candidate]

    init(_ topology: LabTopology) {
        candidates = topology.devices.filter { !LabDeviceKind.isPassive($0) }.map(Candidate.init)
    }

    func best(in tokens: [String], excluding excluded: Set<String> = []) -> Match? {
        guard !tokens.isEmpty else { return nil }
        let words = Set(tokens)
        var joined = Set<String>()
        for start in tokens.indices {
            var value = ""
            for end in start..<min(tokens.count, start + 5) {
                value += tokens[end]
                joined.insert(value)
            }
        }
        var winner: Match?
        for candidate in candidates where !excluded.contains(candidate.device.id) {
            var score = 0.0
            for token in Set(candidate.tokens) {
                if words.contains(token) {
                    score += token.first?.isNumber == true ? 1.5 : (token.count >= 2 ? 2 : 0.4)
                } else {
                    score -= 0.3
                }
            }
            // Saying a multi-word name in full ("servidor a 1") beats partial matches; one-word names already scored above.
            if candidate.tokens.count >= 2, joined.contains(candidate.core) { score += 3 + 0.5 * Double(candidate.tokens.count) }
            if let kind = candidate.kind, words.contains(kind) { score += 1 }
            if candidate.ip.count == 4, Self.contains(tokens, candidate.ip) { score += 10 }
            if score > (winner?.score ?? -.infinity) { winner = Match(device: candidate.device, score: score) }
        }
        guard let winner, winner.score >= Self.threshold else { return nil }
        return winner
    }

    func best(in text: String, excluding excluded: Set<String> = []) -> Match? {
        best(in: LabSpeechText.tokens(text), excluding: excluded)
    }

    /// Two devices in one sentence: "de la PC 1 al servidor", "¿el switch llega al router?".
    func pair(in text: String) -> (LabTopology.Device, LabTopology.Device)? {
        let tokens = LabSpeechText.tokens(text)
        let connectors: Set<String> = ["a", "al", "hasta", "hacia", "con", "y", "entre", "contra"]
        var winner: (LabTopology.Device, LabTopology.Device, Double)?
        for index in tokens.indices where connectors.contains(tokens[index]) && index > 0 && index < tokens.count - 1 {
            guard let left = best(in: Array(tokens[..<index])),
                  let right = best(in: Array(tokens[(index + 1)...]), excluding: [left.device.id]) else { continue }
            let score = left.score + right.score
            if score > (winner?.2 ?? -.infinity) { winner = (left.device, right.device, score) }
        }
        return winner.map { ($0.0, $0.1) }
    }

    private static func contains(_ tokens: [String], _ sequence: [String]) -> Bool {
        guard sequence.count <= tokens.count else { return false }
        return (0...(tokens.count - sequence.count)).contains { Array(tokens[$0..<($0 + sequence.count)]) == sequence }
    }
}

// MARK: - Intents

nonisolated enum LabAssistantIntent: Equatable, Sendable {
    case ping(source: String, destination: String)
    case locate(String)
    case describe(String)
    case power(String, on: Bool)
    case summary
    case sendPacket
    case challenge
    case help
    case unknownDevice
    case unknown
}

/// Understands short Spanish commands without a language model.
nonisolated enum LabAssistantParser {
    private static let challengeWords = ["reto", "juego", "jugar", "desafio", "encuentra la falla", "adivina"]
    private static let packetWords = ["envia un paquete", "manda un paquete", "lanza un paquete", "enviar un paquete",
                                      "envia otro paquete", "otro paquete", "muestrame un paquete", "simula un paquete"]
    private static let summaryWords = ["resumen", "cuantos equipos", "como esta la red", "estado de la red", "que hay en",
                                       "que equipos hay", "describe la red", "como esta el laboratorio", "que tiene la red"]
    private static let helpWords = ["ayuda", "que puedes hacer", "que sabes hacer", "como funcionas", "quien eres", "que eres"]
    private static let greetingWords = ["hola", "buenas", "buenos dias", "buenas tardes", "buenas noches", "hey nexus", "oye nexus"]
    private static let offWords = ["apaga", "apagar", "desconecta", "desconectar", "desenchufa", "corta", "rompe",
                                   "malogra", "tumba", "averia", "falla el", "falla la", "simula una falla en"]
    private static let onWords = ["enciende", "encender", "prende", "prender", "repara", "reparar", "arregla", "arreglar",
                                  "reconecta", "levanta", "restaura"]
    private static let pingWords = ["ping", "llega", "llegan", "comunica", "comunican", "conecta", "conectan", "conexion",
                                    "alcanza", "habla con", "hablan", "se ve con", "se ven", "responde", "funciona la red entre",
                                    "puede ver", "pueden verse", "internet"]
    private static let locateWords = ["donde", "muestrame", "muestra", "busca", "ensename", "ubica", "llevame", "ve a",
                                      "ver el", "ver la", "enfoca", "mira el", "mira la", "senala"]
    private static let describeWords = ["que es", "que hace", "para que sirve", "informacion", "cuentame", "explica",
                                        "explicame", "detalles", "datos de", "ip de", "que ip"]

    static func parse(_ text: String, topology: LabTopology) -> LabAssistantIntent {
        let plain = LabSpeechText.plain(text)
        func has(_ words: [String]) -> Bool { words.contains { LabSpeechText.contains(plain, $0) } }
        let matcher = LabDeviceMatcher(topology)

        if has(challengeWords) { return .challenge }
        if has(onWords), let device = matcher.best(in: text)?.device { return .power(device.id, on: true) }
        if has(offWords), let device = matcher.best(in: text)?.device { return .power(device.id, on: false) }
        if let pair = matcher.pair(in: text), has(pingWords) || has(["entre", "desde"]) {
            return .ping(source: pair.0.id, destination: pair.1.id)
        }
        if has(packetWords) { return .sendPacket }
        if has(summaryWords) { return .summary }
        if has(helpWords) { return .help }
        let device = matcher.best(in: text)?.device
        if has(describeWords), let device { return .describe(device.id) }
        if let device { return has(locateWords) || !has(pingWords) ? .locate(device.id) : .describe(device.id) }
        if has(locateWords + describeWords + offWords + onWords + pingWords) { return .unknownDevice }
        if has(greetingWords) { return .help }
        return .unknown
    }
}

// MARK: - Answers

/// Short spoken answers for people without networking background.
nonisolated enum LabAssistantNarrator {
    static func list(_ names: [String]) -> String {
        switch names.count {
        case 0: ""
        case 1: names[0]
        default: names.dropLast().joined(separator: ", ") + " y " + names[names.count - 1]
        }
    }

    static func ping(_ diagnosis: LabTopology.PingDiagnosis, from source: LabTopology.Device,
                     to destination: LabTopology.Device) -> String {
        if let issue = diagnosis.issue {
            let stop = diagnosis.blockedDevice?.name ?? diagnosis.path?.devices.last?.name
            let reached = stop.map { " El paquete salió de \(source.name) pero se detuvo en \($0)." } ?? ""
            return "No, \(source.name) no llega a \(destination.name).\(reached) Motivo: \(issue). Míralo en rojo en la escena."
        }
        guard let path = diagnosis.path else { return "No encontré un camino entre \(source.name) y \(destination.name)." }
        let middle = path.devices.dropFirst().dropLast().filter { !LabDeviceKind.isPassive($0) }.map(\.name)
        let via = middle.isEmpty ? " directamente" : " pasando por " + list(Array(middle.prefix(3)))
            + (middle.count > 3 ? " y \(middle.count - 3) equipos más" : "")
        let mean = diagnosis.sample.mean ?? 0
        let ms = mean.formatted(.number.precision(.fractionLength(1)).locale(Locale(identifier: "es")))
        return "¡Sí! El paquete viaja de \(source.name) a \(destination.name)\(via). Ida y vuelta en unos \(ms) milisegundos."
    }

    static func describe(_ device: LabTopology.Device, in topology: LabTopology, poweredOff: Set<String>,
                         place: String?) -> String {
        var parts = ["\(device.name) es \(article(for: device)) \(LabDeviceKind.noun(device))"]
        if let product = HardwareCatalog.reference(device.visualModelID)?.name, product != device.name {
            parts[0] += " (\(product))"
        }
        if let place { parts[0] += ", ubicado en \(place)" }
        parts[0] += "."
        if let ip = device.ipv4 {
            var address = "Su dirección IP es \(ip)"
            if let vlan = device.vlan {
                let name = topology.vlans.first { $0.id == vlan }?.name
                address += ", en la VLAN \(vlan)" + (name.map { " de \($0)" } ?? "")
            }
            parts.append(address + ".")
        }
        if !device.services.isEmpty { parts.append("Ofrece " + list(Array(device.services.prefix(3))) + ".") }
        let neighbors = self.neighbors(of: device, in: topology)
        if !neighbors.isEmpty { parts.append("Está conectado a " + list(Array(neighbors.prefix(3))) + ".") }
        if isOff(device, poweredOff) { parts.append("Ahora mismo está apagado.") }
        return parts.joined(separator: " ")
    }

    static func located(_ device: LabTopology.Device, place: String?) -> String {
        "Ahí está \(device.name), \(article(for: device)) \(LabDeviceKind.noun(device))" + (place.map { ", en \($0)" } ?? "") + "."
    }

    static func power(_ device: LabTopology.Device, on: Bool, in topology: LabTopology) -> String {
        if on { return "Listo, encendí \(device.name). Sus cables vuelven a tener luz y el tráfico se recupera." }
        let neighbors = self.neighbors(of: device, in: topology)
        let impact = neighbors.isEmpty ? "" : " Perdieron su conexión directa " + list(Array(neighbors.prefix(4))) + "."
        return "Apagué \(device.name).\(impact) Pídeme un ping para ver dónde se corta el paquete."
    }

    static func summary(_ topology: LabTopology, poweredOff: Set<String>) -> String {
        let active = topology.devices.filter { !LabDeviceKind.isPassive($0) }
        var counts: [String: Int] = [:]
        for device in active { counts[LabDeviceKind.noun(device), default: 0] += 1 }
        let ranked = counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.prefix(4)
            .map { "\($0.value) \(plural($0.key, $0.value))" }
        var text = "Este laboratorio tiene \(active.count) equipos unidos por \(topology.links.count) cables"
        if !topology.vlans.isEmpty { text += " y \(topology.vlans.count) redes virtuales" }
        text += ": " + list(ranked) + "."
        let off = active.filter { isOff($0, poweredOff) }
        text += off.isEmpty ? " Todo está encendido." : " Ahora hay \(off.count) \(off.count == 1 ? "equipo apagado" : "equipos apagados"): "
            + list(Array(off.prefix(3).map(\.name))) + "."
        return text
    }

    static func help(examples: [String]) -> String {
        "Soy Nexus, el guía de este laboratorio. Puedes preguntarme, por ejemplo: " + list(examples.prefix(3).map { "«\($0)»" }) + "."
    }

    static func notFound(_ topology: LabTopology) -> String {
        let names = topology.devices.filter { !LabDeviceKind.isPassive($0) }.prefix(3).map(\.name)
        return "No reconocí ese equipo. Prueba con su nombre, por ejemplo " + list(Array(names)) + "."
    }

    static let unknown = "No te entendí. Prueba con «¿Dónde está el firewall?» o «¿La PC 1 llega al servidor?»."

    static func neighbors(of device: LabTopology.Device, in topology: LabTopology) -> [String] {
        let devices = Dictionary(topology.devices.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [String] = []
        for link in topology.links where link.fromDeviceID == device.id || link.toDeviceID == device.id {
            // A circuit follows the cable through patch panels to the equipment on the other side.
            for piece in topology.circuit(for: link) {
                for id in [piece.fromDeviceID, piece.toDeviceID] where id != device.id {
                    guard let other = devices[id], !LabDeviceKind.isPassive(other), !result.contains(other.name) else { continue }
                    result.append(other.name)
                }
            }
        }
        return result
    }

    static func isOff(_ device: LabTopology.Device, _ poweredOff: Set<String>) -> Bool {
        poweredOff.contains(device.id) || poweredOff.contains(device.placementID)
    }

    private static func article(for device: LabTopology.Device) -> String {
        ["computadora", "laptop", "cámara IP", "impresora", "Raspberry Pi"].contains(LabDeviceKind.noun(device)) ? "una" : "un"
    }

    private static func plural(_ noun: String, _ count: Int) -> String {
        guard count != 1 else { return noun }
        switch noun {
        case "punto de acceso Wi-Fi": return "puntos de acceso Wi-Fi"
        case "teléfono IP": return "teléfonos IP"
        case "cámara IP": return "cámaras IP"
        case "servidor": return "servidores"
        case "router": return "routers"
        case "switch": return "switches"
        case "firewall": return "firewalls"
        case "Raspberry Pi": return "Raspberry Pi"
        default: return noun.hasSuffix("s") ? noun : noun + "s"
        }
    }
}
