//
//  CollaborativeSessionView.swift
//  NexusRoomCapture
//
//  Created for CISCO NEXUS AR — UNSM.
//  Interfaz de usuario para iniciar o unirse a sesiones AR multi-iPhone.
//

import SwiftUI
import MultipeerConnectivity

struct CollaborativeSessionView: View {
    @Bindable var session: NexusPeerSession
    var onSyncMarkerTriggered: (() -> Void)?
    @Environment(\.dismiss) private var dismiss

    @State private var selectedTab: Int = 0 // 0: Anfitrión, 1: Unirse

    init(session: NexusPeerSession, onSyncMarkerTriggered: (() -> Void)? = nil) {
        self.session = session
        self.onSyncMarkerTriggered = onSyncMarkerTriggered
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Selector de modo si está desconectado
                if !session.status.isConnected && !isCurrentlyBusy {
                    Picker("Rol de sesión", selection: $selectedTab) {
                        Text("Iniciar como Anfitrión").tag(0)
                        Text("Unirse a una sesión").tag(1)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, 8)
                }

                ScrollView {
                    VStack(spacing: 20) {
                        statusCard

                        if session.status.isConnected {
                            connectedSessionControls
                        } else if isHostingState {
                            hostingActiveControls
                        } else if isBrowsingState {
                            browsingResultsList
                        } else {
                            if selectedTab == 0 {
                                hostStartCard
                            } else {
                                guestStartCard
                            }
                        }

                        spatialAlignmentInfoCard
                    }
                    .padding(16)
                }
            }
            .navigationTitle("Sesión Colaborativa AR")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    DismissButton()
                }
            }
        }
    }

    // MARK: - Estado Lógico

    private var isHostingState: Bool {
        if case .hosting = session.status { return true }
        return false
    }

    private var isBrowsingState: Bool {
        if case .browsing = session.status { return true }
        if case .connecting = session.status { return true }
        return false
    }

    private var isCurrentlyBusy: Bool {
        isHostingState || isBrowsingState
    }

    // MARK: - Componentes de la Interfaz

    private var statusCard: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(statusColor)
                .frame(width: 14, height: 14)
                .overlay {
                    if isCurrentlyBusy || session.status.isConnected {
                        Circle()
                            .stroke(statusColor.opacity(0.4), lineWidth: 4)
                            .scaleEffect(1.3)
                    }
                }

            VStack(alignment: .leading, spacing: 2) {
                Text(session.status.title)
                    .font(.headline)
                if let peer = session.connectedPeerName {
                    Text("Dispositivo vinculado: \(peer)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if isCurrentlyBusy {
                    Text("Usando red local Wi-Fi y Bluetooth (sin internet)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(14)
        .background(Color(uiColor: .secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var statusColor: Color {
        switch session.status {
        case .idle: return .secondary
        case .hosting, .browsing, .connecting: return .orange
        case .connected: return .green
        case .error: return .red
        }
    }

    // MARK: - Tarjetas Iniciales

    private var hostStartCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Modo Anfitrión (Host)", systemImage: "antenna.radiowaves.left.and.right")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.tint)

            Text("Recomendado para el iPhone con LiDAR (ej. iPhone 16 Pro). Compartirás el laboratorio 1:1, los racks y la sala en tiempo real con otro iPhone cercano.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Button {
                session.startHosting()
            } label: {
                HStack {
                    Image(systemName: "bolt.horizontal.fill")
                    Text("Iniciar transmisión de sesión")
                }
                .font(.body.weight(.medium))
                .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(16)
        .background(Color(uiColor: .secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var guestStartCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Modo Invitado / Colaborador", systemImage: "magnifyingglass")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.tint)

            Text("Ideal para cualquier modelo (ej. iPhone 17 normal). Buscará y se conectará automáticamente al iPhone que tenga la sesión activa.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Button {
                session.startBrowsing()
            } label: {
                HStack {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                    Text("Buscar iPhones cercanos")
                }
                .font(.body.weight(.medium))
                .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(16)
        .background(Color(uiColor: .secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - Controles de Transmisión (Host Activo)

    private var hostingActiveControls: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                ProgressView()
                    .padding(.trailing, 6)
                Text("Esperando que el otro iPhone se conecte...")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Toggle("Modo presentación (solo lectura para invitados)", isOn: $session.isPresentationOnly)
                .font(.subheadline)
                .onChange(of: session.isPresentationOnly) { _, newValue in
                    session.sendReliable(.setPresentationMode(enabled: newValue))
                }

            Button(role: .destructive) {
                session.disconnect()
            } label: {
                Text("Detener transmisión")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
        }
        .padding(16)
        .background(Color(uiColor: .secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - Lista de Anfitriones Descubiertos (Búsqueda)

    private var browsingResultsList: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Dispositivos encontrados:")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                ProgressView()
            }

            if session.discoveredHosts.isEmpty {
                Text("Asegúrate de que el otro iPhone haya presionado 'Iniciar transmisión' y esté cerca.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                ForEach(session.discoveredHosts, id: \.self) { peer in
                    HStack {
                        Image(systemName: "iphone.gen3")
                            .font(.title3)
                            .foregroundStyle(.tint)
                        VStack(alignment: .leading) {
                            Text(peer.displayName)
                                .font(.body.weight(.medium))
                            Text("Laboratorio AR disponible")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Conectar") {
                            session.connect(to: peer)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                    .padding(10)
                    .background(Color(uiColor: .tertiarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }

            Button("Cancelar búsqueda") {
                session.disconnect()
            }
            .buttonStyle(.bordered)
            .frame(maxWidth: .infinity)
        }
        .padding(16)
        .background(Color(uiColor: .secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - Sesión Conectada

    private var connectedSessionControls: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Sesión en Vivo Activa", systemImage: "checkmark.seal.fill")
                .font(.headline)
                .foregroundStyle(.green)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Alineación espacial:")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(session.isSpatialAligned ? "🟢 Sincronizado" : "🟡 Calibrando...")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(session.isSpatialAligned ? .green : .orange)
                }

                Text("Método: \(session.spatialAlignmentMethod)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .background(Color(uiColor: .tertiarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            if session.isHost {
                Toggle("Modo presentación (invitados solo ven)", isOn: $session.isPresentationOnly)
                    .font(.subheadline)
                    .onChange(of: session.isPresentationOnly) { _, newValue in
                        session.sendReliable(.setPresentationMode(enabled: newValue))
                    }
            }

            // Opción B: Marcador QR de calibración rápida
            Button {
                onSyncMarkerTriggered?()
                dismiss()
            } label: {
                Label("Calibrar con marcador / piso (Opción B)", systemImage: "qrcode.viewfinder")
                    .frame(maxWidth: .infinity, minHeight: 40)
            }
            .buttonStyle(.bordered)

            Button(role: .destructive) {
                session.disconnect()
            } label: {
                Text("Desconectar sesión colaborativa")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(16)
        .background(Color(uiColor: .secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - Tarjeta Informativa de Alineación

    private var spatialAlignmentInfoCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("¿Cómo funciona la alineación 1:1?")
                .font(.subheadline.weight(.semibold))

            Text("• **Opción A (Automática ARKit):** Apunten ambos teléfonos hacia la misma zona del cuarto durante unos segundos. ARKit iguala las coordenadas espaciales automáticamente.\n• **Opción B (Marcador / QR):** Toquen el mismo punto físico de referencia o escaneen un código común para anclaje inmediato.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemBackground).opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
