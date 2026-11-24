import SwiftUI

// MARK: - Views

/// Stops of the moving packet, with the current one highlighted.
struct FairPacketCaption: View {
    let journey: LabPacketJourney
    let reached: Int
    var concealsFailure = false

    private struct Stop: Identifiable {
        let id: Int
        let name: String
        let failed: Bool
    }

    private var stops: [Stop] {
        var result = [Stop(id: 0, name: journey.sourceName, failed: false)]
        for (index, hop) in journey.hops.enumerated() where !hop.passive || hop.dies {
            result.append(.init(id: index + 1, name: hop.dies && concealsFailure ? "¿?" : hop.deviceName, failed: hop.dies))
        }
        return result
    }

    private var title: String {
        if reached > journey.hops.count { return "¡Llegó! Vuelve la respuesta" }
        if reached == journey.hops.count, journey.blocked { return "El paquete no pudo seguir" }
        if reached == journey.hops.count { return "¡Paquete entregado!" }
        return "Paquete en camino…"
    }

    private var symbol: String {
        if reached >= journey.hops.count { return journey.blocked ? "xmark.octagon.fill" : "checkmark.circle.fill" }
        return "paperplane.fill"
    }

    private var tint: Color {
        if reached >= journey.hops.count { return journey.blocked ? .red : .green }
        return .accentColor
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol)
                .font(.headline)
                .foregroundStyle(tint)
                .contentTransition(.symbolEffect(.replace))
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(stops) { stop in
                            if stop.id > 0 {
                                Image(systemName: "chevron.right").font(.caption2.weight(.bold)).foregroundStyle(.tertiary)
                            }
                            let current = stop.id <= reached && (stops.last(where: { $0.id <= reached })?.id == stop.id)
                            Text(stop.name)
                                .font(.caption.weight(current ? .bold : .regular))
                                .lineLimit(1)
                                .padding(.horizontal, 8).padding(.vertical, 5)
                                .background(chipColor(stop, current: current), in: Capsule())
                                .foregroundStyle(current ? Color.white : Color.primary)
                                .id(stop.id)
                        }
                    }
                }
                .onChange(of: reached) {
                    if let id = stops.last(where: { $0.id <= reached })?.id {
                        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) }
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func chipColor(_ stop: Stop, current: Bool) -> Color {
        if stop.failed && stop.id <= reached { return .red }
        if current { return .accentColor }
        return stop.id <= reached ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.12)
    }
}

/// Bottom panel of the fair mode: send a packet, play the 60-second challenge and see the ranking.
struct FairModePanel: View {
    let journey: LabPacketJourney?
    let reached: Int
    let challenge: LabFairChallenge?
    let outcome: LabFairOutcome?
    let scores: [LabFairScore]
    let message: String?
    let onSendPacket: () -> Void
    let onStartChallenge: () -> Void
    let onGiveUp: () -> Void
    let onTimeout: () -> Void
    let onSaveScore: (String) -> Void
    let onDismissOutcome: () -> Void
    let onClose: () -> Void
    var onAssistant: (() -> Void)? = nil

    @State private var playerName = ""
    @State private var showsRanking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Modo feria", systemImage: "sparkles").font(.headline)
                Spacer()
                if let onAssistant {
                    Button(action: onAssistant) {
                        Label("Hablar con Nexus", systemImage: "waveform").labelStyle(.iconOnly).frame(width: 36, height: 36)
                    }
                }
                Button { showsRanking.toggle() } label: {
                    Label("Ranking", systemImage: "trophy").labelStyle(.iconOnly).frame(width: 36, height: 36)
                }
                .accessibilityLabel(showsRanking ? "Ocultar ranking" : "Mostrar ranking")
                Button(action: onClose) {
                    Label("Salir del modo feria", systemImage: "xmark").labelStyle(.iconOnly).frame(width: 36, height: 36)
                }
            }

            if let challenge {
                challengeView(challenge)
            } else if let outcome {
                outcomeView(outcome)
            } else {
                if let journey { FairPacketCaption(journey: journey, reached: reached) }
                if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { actionButtons }
                    VStack(alignment: .leading, spacing: 8) { actionButtons }
                }
            }

            if showsRanking { ranking }
        }
        .padding(14)
        .frame(maxWidth: 460, alignment: .leading)
        .modifier(ViewerSurface(radius: 20, material: .thick))
        .animation(.snappy(duration: 0.22), value: challenge == nil)
        .animation(.snappy(duration: 0.22), value: outcome)
    }

    @ViewBuilder private var actionButtons: some View {
        Button(action: onSendPacket) {
            Label("Enviar un paquete", systemImage: "paperplane.fill").frame(minHeight: 34)
        }
        .buttonStyle(.borderedProminent)
        Button(action: onStartChallenge) {
            Label("Reto: encuentra la falla", systemImage: "stopwatch").frame(minHeight: 34)
        }
        .buttonStyle(.bordered)
    }

    private func challengeView(_ challenge: LabFairChallenge) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            TimelineView(.periodic(from: challenge.started, by: 0.1)) { context in
                let remaining = challenge.remaining(at: context.date)
                HStack(alignment: .firstTextBaseline) {
                    Text(remaining, format: .number.precision(.fractionLength(1)))
                        .font(.system(.largeTitle, design: .rounded).weight(.bold).monospacedDigit())
                        .foregroundStyle(remaining < 10 ? Color.red : Color.primary)
                    Text("s").font(.title3.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    if challenge.misses > 0 {
                        Label("\(challenge.misses)", systemImage: "xmark.circle").foregroundStyle(.orange)
                            .accessibilityLabel("\(challenge.misses) intentos fallidos")
                    }
                }
                ProgressView(value: remaining, total: LabFairChallenge.duration)
                    .tint(remaining < 10 ? Color.red : Color.accentColor)
            }
            Text("Un equipo de la red se averió. Sigue el paquete azul: donde se pone rojo, está la falla. **Toca el equipo dañado.**")
                .font(.callout)
            if let journey { FairPacketCaption(journey: journey, reached: reached, concealsFailure: true) }
            Button("Me rindo", role: .destructive, action: onGiveUp).buttonStyle(.bordered)
        }
        .task(id: challenge.started) {
            let remaining = challenge.remaining(at: .now)
            do { try await Task.sleep(for: .seconds(remaining)) } catch { return }
            onTimeout()
        }
    }

    @ViewBuilder private func outcomeView(_ outcome: LabFairOutcome) -> some View {
        switch outcome {
        case .found(let seconds, let name, let misses):
            VStack(alignment: .leading, spacing: 10) {
                Label("¡Encontraste la falla!", systemImage: "checkmark.seal.fill").font(.title3.bold()).foregroundStyle(.green)
                let time = seconds.formatted(.number.precision(.fractionLength(1)))
                let attempts = misses == 0 ? " al primer intento."
                    : " con \(misses) \(misses == 1 ? "intento fallido" : "intentos fallidos")."
                Text("**\(name)** estaba apagado. Lo hallaste en **\(time) s**\(attempts)")
                    .font(.callout)
                Text("Ya lo reparamos: mira cómo el paquete vuelve a llegar.").font(.footnote).foregroundStyle(.secondary)
                if LabFairLeaderboard.qualifies(seconds, in: scores) {
                    HStack {
                        TextField("Tu nombre para el ranking", text: $playerName)
                            .textFieldStyle(.roundedBorder)
                            .submitLabel(.done)
                            .onSubmit(save)
                        Button("Guardar", action: save).buttonStyle(.borderedProminent)
                            .disabled(playerName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                HStack {
                    Button("Jugar otra vez", systemImage: "arrow.clockwise", action: onStartChallenge).buttonStyle(.bordered)
                    Button("Listo", action: onDismissOutcome).buttonStyle(.bordered)
                }
            }
        case .timeout(let name):
            VStack(alignment: .leading, spacing: 10) {
                Label("¡Se acabó el tiempo!", systemImage: "timer").font(.title3.bold()).foregroundStyle(.orange)
                Text("La falla estaba en **\(name)**. Te la mostramos en la escena y ya la reparamos.").font(.callout)
                HStack {
                    Button("Intentar otra vez", systemImage: "arrow.clockwise", action: onStartChallenge).buttonStyle(.borderedProminent)
                    Button("Listo", action: onDismissOutcome).buttonStyle(.bordered)
                }
            }
        }
    }

    private func save() {
        let name = playerName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        onSaveScore(String(name.prefix(24)))
        playerName = ""
        showsRanking = true
    }

    private var ranking: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Mejores detectives").font(.subheadline.weight(.semibold))
            if scores.isEmpty {
                Text("Todavía no hay tiempos. ¡Sé el primero!").font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(Array(scores.enumerated()), id: \.element.id) { index, score in
                HStack {
                    Text(["🥇", "🥈", "🥉", "4.", "5."][min(index, 4)]).frame(width: 28, alignment: .leading)
                    Text(score.name).lineLimit(1)
                    Spacer()
                    Text("\(score.seconds.formatted(.number.precision(.fractionLength(1)))) s").monospacedDigit()
                }
                .font(.callout)
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
    }
}
