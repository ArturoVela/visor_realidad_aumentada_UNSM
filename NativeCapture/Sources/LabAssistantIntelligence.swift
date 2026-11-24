import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Entry point for the on-device language model. Returns nil when Apple Intelligence is not usable,
/// and the assistant then answers with its Spanish command parser.
enum LabAssistantIntelligence {
    static func makeResponder(executor: LabAssistantExecutor) -> (any LabAssistantResponder)? {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), LabAssistantBrain.isAvailable {
            return LabAssistantBrain(executor: executor)
        }
        #endif
        return nil
    }
}

#if canImport(FoundationModels)

@available(iOS 26.0, *)
final class LabAssistantBrain: LabAssistantResponder {
    static var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    private let executor: LabAssistantExecutor
    private var session: LanguageModelSession?

    init(executor: LabAssistantExecutor) {
        self.executor = executor
    }

    func reset() { session = nil }

    func respond(to text: String) async throws -> String {
        let session = self.session ?? makeSession()
        self.session = session
        let response = try await session.respond(to: text)
        return response.content
    }

    private func makeSession() -> LanguageModelSession {
        let tools: [any Tool] = [
            LabLookUpTool(executor: executor),
            LabPingTool(executor: executor),
            LabShowTool(executor: executor),
            LabPowerTool(executor: executor),
            LabStatusTool(executor: executor),
        ]
        let instructions = """
        Eres Nexus, el guía por voz de un laboratorio de redes en 3D que estudiantes de la Universidad Nacional de San Martín \
        presentan en una feria. Hablas con visitantes que no conocen de redes.
        Responde siempre en español, con calidez, en un máximo de tres frases cortas, sin listas, sin formato y sin emojis.
        Para cualquier dato del laboratorio usa las herramientas. Nunca inventes equipos, direcciones IP ni resultados.
        Si preguntan si dos equipos se comunican o tienen conexión, usa probarConexion: la escena muestra el viaje del paquete.
        Si piden ver o ubicar un equipo, usa mostrarEquipo. Si piden apagar, romper, encender o reparar un equipo, usa cambiarEnergia.
        Para preguntas sobre un equipo usa buscarEquipo, y para el estado general usa estadoDeLaRed.
        Explica con comparaciones cotidianas: un switch reparte los mensajes dentro de un edificio, un router es la oficina de \
        correos entre barrios, un firewall es el guardia de la puerta y una VLAN es un piso separado del mismo edificio.
        Equipos de este laboratorio: \(executor.catalog())
        """
        return LanguageModelSession(tools: tools, instructions: instructions)
    }
}

@available(iOS 26.0, *)
nonisolated struct LabLookUpTool: Tool {
    let name = "buscarEquipo"
    let description = "Da la información de un equipo del laboratorio: tipo, ubicación, IP, VLAN, servicios y conexiones."
    let executor: LabAssistantExecutor

    @Generable
    nonisolated struct Arguments {
        @Guide(description: "Nombre o tipo del equipo, por ejemplo PC-1, Servidor A.1 o firewall")
        var equipo: String
    }

    @concurrent func call(arguments: Arguments) async throws -> String {
        await executor.lookUp(arguments.equipo)
    }
}

@available(iOS 26.0, *)
nonisolated struct LabPingTool: Tool {
    let name = "probarConexion"
    let description = "Hace un ping entre dos equipos, anima el paquete en la escena 3D y explica si llega o dónde se corta."
    let executor: LabAssistantExecutor

    @Generable
    nonisolated struct Arguments {
        @Guide(description: "Equipo de origen")
        var origen: String
        @Guide(description: "Equipo de destino")
        var destino: String
    }

    @concurrent func call(arguments: Arguments) async throws -> String {
        await executor.ping(from: arguments.origen, to: arguments.destino)
    }
}

@available(iOS 26.0, *)
nonisolated struct LabShowTool: Tool {
    let name = "mostrarEquipo"
    let description = "Mueve la cámara de la escena 3D hasta un equipo y lo resalta."
    let executor: LabAssistantExecutor

    @Generable
    nonisolated struct Arguments {
        @Guide(description: "Nombre o tipo del equipo que hay que mostrar")
        var equipo: String
    }

    @concurrent func call(arguments: Arguments) async throws -> String {
        await executor.show(arguments.equipo)
    }
}

@available(iOS 26.0, *)
nonisolated struct LabPowerTool: Tool {
    let name = "cambiarEnergia"
    let description = "Apaga o enciende un equipo para simular una falla o repararla. Devuelve qué conexiones se afectan."
    let executor: LabAssistantExecutor

    @Generable
    nonisolated struct Arguments {
        @Guide(description: "Nombre o tipo del equipo")
        var equipo: String
        @Guide(description: "true para encender o reparar, false para apagar o simular una falla")
        var encender: Bool
    }

    @concurrent func call(arguments: Arguments) async throws -> String {
        await executor.setPower(arguments.equipo, on: arguments.encender)
    }
}

@available(iOS 26.0, *)
nonisolated struct LabStatusTool: Tool {
    let name = "estadoDeLaRed"
    let description = "Resume el laboratorio: cuántos equipos y cables hay, de qué tipo y cuáles están apagados."
    let executor: LabAssistantExecutor

    @Generable
    nonisolated struct Arguments {
        @Guide(description: "Qué quiere saber la persona sobre la red, en pocas palabras")
        var tema: String
    }

    @concurrent func call(arguments: Arguments) async throws -> String {
        await executor.summary()
    }
}

#endif
