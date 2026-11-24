import SwiftUI

/// Voice assistant panel: the visitor talks to the laboratory and the scene reacts.
struct LabAssistantPanel: View {
    @Bindable var model: LabAssistantModel
    let onClose: () -> Void

    @State private var typed = ""
    @FocusState private var typing: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            conversation
            HStack(alignment: .center, spacing: 14) {
                microphone
                VStack(alignment: .leading, spacing: 6) {
                    Text(status).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                        .contentTransition(.opacity)
                    HStack(spacing: 6) {
                        TextField("O escribe tu pregunta", text: $typed)
                            .textFieldStyle(.roundedBorder)
                            .submitLabel(.send)
                            .focused($typing)
                            .onSubmit(sendTyped)
                        Button(action: sendTyped) {
                            Label("Enviar", systemImage: "arrow.up.circle.fill").labelStyle(.iconOnly).font(.title2)
                        }
                        .disabled(typed.trimmingCharacters(in: .whitespaces).isEmpty || model.phase == .thinking)
                    }
                }
            }
            if !model.suggestions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(model.suggestions, id: \.self) { suggestion in
                            Button { model.ask(suggestion) } label: {
                                Text(suggestion).font(.footnote).lineLimit(1)
                                    .padding(.horizontal, 10).padding(.vertical, 7)
                                    .background(Color.accentColor.opacity(0.12), in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .disabled(model.phase == .thinking)
                        }
                    }
                }
            }
            if let notice = model.notice {
                Label(notice, systemImage: "exclamationmark.bubble").font(.footnote).foregroundStyle(.orange)
            }
        }
        .padding(14)
        .frame(maxWidth: 520, alignment: .leading)
        .modifier(ViewerSurface(radius: 22, material: .thick))
        .animation(.snappy(duration: 0.2), value: model.phase)
        .animation(.snappy(duration: 0.2), value: model.answer)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform.circle.fill").font(.title2).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("Nexus").font(.headline)
                Text(model.usesIntelligence ? "IA de Apple en el iPhone · sin internet" : "Comandos de voz · sin internet")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if model.intelligenceAvailable {
                Toggle(isOn: $model.prefersIntelligence) {
                    Label("Usar IA", systemImage: "sparkles").labelStyle(.iconOnly)
                }
                .toggleStyle(.button)
                .accessibilityLabel("Usar Apple Intelligence")
            }
            Toggle(isOn: $model.speaksAnswers) {
                Label("Respuesta en voz alta", systemImage: model.speaksAnswers ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    .labelStyle(.iconOnly)
            }
            .toggleStyle(.button)
            Button {
                model.close()
                onClose()
            } label: {
                Label("Cerrar Nexus", systemImage: "xmark").labelStyle(.iconOnly).frame(width: 32, height: 32)
            }
        }
    }

    @ViewBuilder private var conversation: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.phase == .listening {
                Text(model.transcript.isEmpty ? "Te escucho…" : "«\(model.transcript)»")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(model.transcript.isEmpty ? .secondary : .primary)
                    .contentTransition(.interpolate)
            } else {
                if !model.question.isEmpty {
                    Text("«\(model.question)»").font(.callout).italic().foregroundStyle(.secondary).lineLimit(2)
                }
                HStack(alignment: .top, spacing: 8) {
                    if model.phase == .thinking {
                        ProgressView().controlSize(.small)
                        Text("Pensando…").font(.body).foregroundStyle(.secondary)
                    } else {
                        Text(model.answer).font(.body).fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var microphone: some View {
        Button(action: model.microphoneTapped) {
            ZStack {
                if model.phase == .listening && !reduceMotion {
                    Circle().stroke(Color.red.opacity(0.6), lineWidth: 3)
                        .phaseAnimator([false, true]) { ring, expanded in
                            ring.scaleEffect(expanded ? 1.45 : 1).opacity(expanded ? 0 : 0.8)
                        } animation: { _ in .easeOut(duration: 1.1) }
                }
                Circle().fill(model.phase == .listening ? Color.red : Color.accentColor)
                Group {
                    switch model.phase {
                    case .idle: Image(systemName: "mic.fill")
                    case .listening: Image(systemName: "waveform").symbolEffect(.variableColor.iterative, isActive: !reduceMotion)
                    case .thinking: ProgressView().tint(.white)
                    case .speaking: Image(systemName: "speaker.wave.2.fill").symbolEffect(.variableColor.iterative, isActive: !reduceMotion)
                    }
                }
                .font(.title.weight(.semibold))
                .foregroundStyle(.white)
            }
            .frame(width: 68, height: 68)
        }
        .buttonStyle(.plain)
        .disabled(model.phase == .thinking)
        .accessibilityLabel(microphoneLabel)
    }

    private var status: String {
        switch model.phase {
        case .idle: "Toca y pregunta"
        case .listening: "Escuchando… toca para terminar"
        case .thinking: "Nexus está pensando"
        case .speaking: "Toca para callar a Nexus"
        }
    }

    private var microphoneLabel: String {
        switch model.phase {
        case .idle: "Hablar con Nexus"
        case .listening: "Terminar de hablar"
        case .thinking: "Nexus está pensando"
        case .speaking: "Detener la respuesta"
        }
    }

    private func sendTyped() {
        let text = typed
        typed = ""
        typing = false
        model.ask(text)
    }
}
