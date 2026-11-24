import AVFoundation
import Foundation
import Observation
import Speech

// MARK: - Actions on the laboratory

/// What the assistant can read and do in the open laboratory. The screen supplies live closures.
struct LabAssistantContext {
    var topology: () -> LabTopology?
    var poweredOff: () -> Set<String>
    var place: (LabTopology.Device) -> String?
    var showPing: (String, String) -> Void
    var locate: (String) -> Void
    var setPower: (String, Bool) -> Void
    var sendPacket: () -> Void
    var startChallenge: () -> Void
}

/// Runs assistant requests against the laboratory and returns a short spoken answer.
/// Both the command parser and the Apple Intelligence tools go through these methods.
final class LabAssistantExecutor {
    var context: LabAssistantContext?

    private var topology: LabTopology? { context?.topology() }
    private var poweredOff: Set<String> { context?.poweredOff() ?? [] }

    func handle(_ text: String) -> String {
        guard let topology else { return "Abre un laboratorio para que pueda ayudarte." }
        return perform(LabAssistantParser.parse(text, topology: topology), in: topology)
    }

    func perform(_ intent: LabAssistantIntent, in topology: LabTopology) -> String {
        func device(_ id: String) -> LabTopology.Device? { topology.devices.first { $0.id == id } }
        switch intent {
        case .ping(let source, let destination):
            guard let source = device(source), let destination = device(destination) else { return LabAssistantNarrator.unknown }
            return ping(source, destination, in: topology)
        case .locate(let id):
            guard let device = device(id) else { return LabAssistantNarrator.notFound(topology) }
            context?.locate(device.id)
            return LabAssistantNarrator.located(device, place: context?.place(device))
        case .describe(let id):
            guard let device = device(id) else { return LabAssistantNarrator.notFound(topology) }
            context?.locate(device.id)
            return LabAssistantNarrator.describe(device, in: topology, poweredOff: poweredOff, place: context?.place(device))
        case .power(let id, let on):
            guard let device = device(id) else { return LabAssistantNarrator.notFound(topology) }
            return power(device, on: on, in: topology)
        case .summary:
            return LabAssistantNarrator.summary(topology, poweredOff: poweredOff)
        case .sendPacket:
            context?.sendPacket()
            return "Ahí va un paquete. Síguelo con la mirada: cada parada es un equipo de la red."
        case .challenge:
            context?.startChallenge()
            return "¡Empieza el reto! Un equipo se averió. Sigue el paquete y toca el equipo dañado antes de 60 segundos."
        case .help:
            return LabAssistantNarrator.help(examples: suggestions())
        case .unknownDevice:
            return LabAssistantNarrator.notFound(topology)
        case .unknown:
            return LabAssistantNarrator.unknown
        }
    }

    // MARK: Tool entry points (names come from speech or from the language model)

    func lookUp(_ query: String) -> String {
        guard let topology else { return "No hay un laboratorio abierto." }
        guard let device = LabDeviceMatcher(topology).best(in: query)?.device else { return LabAssistantNarrator.notFound(topology) }
        return LabAssistantNarrator.describe(device, in: topology, poweredOff: poweredOff, place: context?.place(device))
    }

    func ping(from source: String, to destination: String) -> String {
        guard let topology else { return "No hay un laboratorio abierto." }
        let matcher = LabDeviceMatcher(topology)
        guard let origin = matcher.best(in: source)?.device else { return "No encontré el equipo «\(source)». " + LabAssistantNarrator.notFound(topology) }
        guard let target = matcher.best(in: destination, excluding: [origin.id])?.device else {
            return "No encontré el equipo «\(destination)». " + LabAssistantNarrator.notFound(topology)
        }
        return ping(origin, target, in: topology)
    }

    func show(_ query: String) -> String {
        guard let topology else { return "No hay un laboratorio abierto." }
        guard let device = LabDeviceMatcher(topology).best(in: query)?.device else { return LabAssistantNarrator.notFound(topology) }
        context?.locate(device.id)
        return LabAssistantNarrator.located(device, place: context?.place(device))
    }

    func setPower(_ query: String, on: Bool) -> String {
        guard let topology else { return "No hay un laboratorio abierto." }
        guard let device = LabDeviceMatcher(topology).best(in: query)?.device else { return LabAssistantNarrator.notFound(topology) }
        return power(device, on: on, in: topology)
    }

    func summary() -> String {
        guard let topology else { return "No hay un laboratorio abierto." }
        return LabAssistantNarrator.summary(topology, poweredOff: poweredOff)
    }

    /// Compact device list for the language model instructions.
    func catalog(limit: Int = 45) -> String {
        guard let topology else { return "" }
        let devices = topology.devices.filter { !LabDeviceKind.isPassive($0) }
        var lines = devices.prefix(limit).map { "\($0.name) (\(LabDeviceKind.noun($0)))" }
        if devices.count > limit { lines.append("y \(devices.count - limit) equipos más") }
        return lines.joined(separator: "; ")
    }

    /// Example questions built from the real device names of this laboratory.
    func suggestions() -> [String] {
        guard let topology else { return [] }
        var generator = SystemRandomNumberGenerator()
        var result: [String] = []
        let routes = LabFairPlanner.routes(in: topology, poweredOff: poweredOff, attempts: 30, limit: 3, using: &generator)
        if let route = LabFairPlanner.showcase(routes, using: &generator) {
            result.append("¿\(spoken(route.source)) llega a \(spoken(route.destination))?")
            if let middle = route.path.devices.dropFirst().dropLast().first(where: { !LabDeviceKind.isPassive($0) }) {
                result.append("Apaga \(spoken(middle))")
            }
        }
        let active = topology.devices.filter { !LabDeviceKind.isPassive($0) }
        if let guardian = active.first(where: { ["firewall", "router"].contains(LabDeviceKind.noun($0)) }) ?? active.first {
            result.append("¿Qué hace \(spoken(guardian))?")
        }
        result.append("¿Cómo está la red?")
        return result
    }

    private func spoken(_ device: LabTopology.Device) -> String {
        (device.name.components(separatedBy: "·").first ?? device.name).trimmingCharacters(in: .whitespaces)
    }

    private func ping(_ source: LabTopology.Device, _ destination: LabTopology.Device, in topology: LabTopology) -> String {
        let diagnosis = topology.diagnosePing(from: source, to: destination, poweredOff: poweredOff)
        context?.showPing(source.id, destination.id)
        return LabAssistantNarrator.ping(diagnosis, from: source, to: destination)
    }

    private func power(_ device: LabTopology.Device, on: Bool, in topology: LabTopology) -> String {
        let isOff = LabAssistantNarrator.isOff(device, poweredOff)
        if on && !isOff { return "\(device.name) ya está encendido." }
        if !on && isOff { return "\(device.name) ya estaba apagado." }
        context?.setPower(device.id, on)
        return LabAssistantNarrator.power(device, on: on, in: topology)
    }
}

// MARK: - Speech capture

/// Microphone and speech recognizer. Audio callbacks run off the main thread, so this type is nonisolated.
nonisolated final class LabSpeechCapture: @unchecked Sendable {
    enum CaptureError: Error { case unavailable, noInput }

    private let engine = AVAudioEngine()
    private let recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let lock = NSLock()

    init() {
        let preferred = [Locale.current.identifier, "es-MX", "es-US", "es-ES", "es-CO", "es-CL"].filter { $0.hasPrefix("es") }
        recognizer = preferred.lazy.compactMap { SFSpeechRecognizer(locale: Locale(identifier: $0)) }.first
    }

    static func authorize() async -> Bool {
        let status = await withCheckedContinuation { (continuation: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard status == .authorized else { return false }
        return await AVAudioApplication.requestRecordPermission()
    }

    /// Starts listening. `update` receives the transcript so far and whether it is final.
    func start(update: @escaping @Sendable (String, Bool) -> Void) throws {
        cancel()
        guard let recognizer, recognizer.isAvailable else { throw CaptureError.unavailable }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker])
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        nonisolated(unsafe) let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .search
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw CaptureError.noInput }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in request.append(buffer) }
        engine.prepare()
        try engine.start()

        let task = recognizer.recognitionTask(with: request) { result, error in
            if let result {
                update(result.bestTranscription.formattedString, result.isFinal)
            } else if error != nil {
                update("", true)
            }
        }
        lock.withLock {
            self.request = request
            self.task = task
        }
    }

    /// Stops the microphone and lets the recognizer deliver its final result.
    func finish() {
        stopEngine()
        lock.withLock {
            request?.endAudio()
            request = nil
        }
    }

    func cancel() {
        stopEngine()
        lock.withLock {
            request?.endAudio()
            task?.cancel()
            request = nil
            task = nil
        }
    }

    private func stopEngine() {
        if engine.isRunning {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
    }
}

// MARK: - Conversation

/// A language model that can answer with tools. Implemented with Apple Intelligence when available.
protocol LabAssistantResponder: AnyObject {
    func respond(to text: String) async throws -> String
    func reset()
}

@Observable
final class LabAssistantModel {
    enum Phase: Equatable { case idle, listening, thinking, speaking }

    private(set) var phase: Phase = .idle
    /// Live transcript while listening.
    private(set) var transcript = ""
    private(set) var question = ""
    private(set) var answer = ""
    private(set) var notice: String?
    private(set) var suggestions: [String] = []
    var speaksAnswers = true
    /// The presenter can switch to command mode if the language model is unavailable or slow.
    var prefersIntelligence = true

    let executor = LabAssistantExecutor()
    @ObservationIgnored private let capture = LabSpeechCapture()
    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()
    @ObservationIgnored private var silenceTask: Task<Void, Never>?
    @ObservationIgnored private var speakingTask: Task<Void, Never>?
    @ObservationIgnored private var responder: (any LabAssistantResponder)?

    var intelligenceAvailable: Bool { responder != nil }
    var usesIntelligence: Bool { intelligenceAvailable && prefersIntelligence }

    /// Call when the panel opens: binds the laboratory and prepares the model session.
    func prepare(_ context: LabAssistantContext) {
        executor.context = context
        responder = LabAssistantIntelligence.makeResponder(executor: executor)
        suggestions = executor.suggestions()
        notice = nil
        if answer.isEmpty {
            answer = "¡Hola! Soy Nexus. Toca el micrófono y pregúntame por cualquier equipo de este laboratorio."
        }
    }

    func close() {
        silenceTask?.cancel()
        speakingTask?.cancel()
        capture.cancel()
        synthesizer.stopSpeaking(at: .immediate)
        phase = .idle
        transcript = ""
    }

    func microphoneTapped() {
        switch phase {
        case .idle: Task { await startListening() }
        case .listening: finishListening()
        case .speaking:
            synthesizer.stopSpeaking(at: .immediate)
            phase = .idle
        case .thinking: break
        }
    }

    func ask(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, phase != .thinking else { return }
        if phase == .listening { capture.cancel() }
        synthesizer.stopSpeaking(at: .immediate)
        question = text
        transcript = ""
        notice = nil
        phase = .thinking
        Task {
            let response = await self.reply(to: text)
            answer = response
            suggestions = executor.suggestions()
            speak(response)
        }
    }

    // MARK: Listening

    private func startListening() async {
        notice = nil
        guard await LabSpeechCapture.authorize() else {
            notice = "Activa el micrófono y el reconocimiento de voz para Nexus AR en Ajustes. También puedes escribir tu pregunta."
            return
        }
        synthesizer.stopSpeaking(at: .immediate)
        transcript = ""
        do {
            try capture.start { [weak self] text, isFinal in
                Task { @MainActor in self?.heard(text, isFinal: isFinal) }
            }
            phase = .listening
            waitForSilence(seconds: 7)
        } catch {
            notice = "No pude usar el micrófono aquí. Escribe tu pregunta."
            phase = .idle
        }
    }

    private func heard(_ text: String, isFinal: Bool) {
        guard phase == .listening else { return }
        if !text.isEmpty { transcript = text }
        if isFinal { finishListening() } else { waitForSilence(seconds: 1.6) }
    }

    /// Ends the turn after a pause, so the visitor does not need to press the button again.
    private func waitForSilence(seconds: Double) {
        silenceTask?.cancel()
        silenceTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            guard let self, self.phase == .listening else { return }
            self.finishListening()
        }
    }

    private func finishListening() {
        silenceTask?.cancel()
        capture.finish()
        let text = transcript
        phase = .idle
        if text.trimmingCharacters(in: .whitespaces).isEmpty {
            notice = "No te escuché. Acércate al iPhone y vuelve a intentarlo."
        } else {
            ask(text)
        }
    }

    // MARK: Answering

    private func reply(to text: String) async -> String {
        if usesIntelligence, let responder {
            do {
                let reply = Self.clean(try await responder.respond(to: text))
                if !reply.isEmpty { return reply }
            } catch {
                // A fresh session avoids a full context window; the parser answers this turn.
                responder.reset()
            }
        }
        return executor.handle(text)
    }

    private func speak(_ text: String) {
        guard speaksAnswers else {
            phase = .idle
            return
        }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? session.setActive(true)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Self.voice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.04
        utterance.pitchMultiplier = 1.02
        phase = .speaking
        synthesizer.speak(utterance)
        speakingTask?.cancel()
        speakingTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            while let self, self.synthesizer.isSpeaking, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
            }
            guard let self, !Task.isCancelled, self.phase == .speaking else { return }
            self.phase = .idle
        }
    }

    /// Best Spanish voice installed, preferring Latin American accents.
    private static let voice: AVSpeechSynthesisVoice? = {
        let order = ["es-MX", "es-US", "es-CO", "es-419", "es-ES"]
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("es") }
        return voices.max { a, b in
            let rankA = (order.firstIndex(of: a.language).map { order.count - $0 } ?? 0) + a.quality.rawValue * 10
            let rankB = (order.firstIndex(of: b.language).map { order.count - $0 } ?? 0) + b.quality.rawValue * 10
            return rankA < rankB
        } ?? AVSpeechSynthesisVoice(language: "es-MX")
    }()

    static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: "#", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
