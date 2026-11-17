import ARKit
import RoomPlan
import SwiftUI
import UniformTypeIdentifiers

@main
struct NexusRoomCaptureApp: App {
    var body: some Scene { WindowGroup { LaboratoryScreen() } }
}

private struct LaboratoryScreen: View {
    @State private var capture = CaptureController()
    @State private var mode: LabViewMode = .room
    @State private var paintRoom = true
    @State private var poweredOff = Set<String>()
    @State private var selection: LabPlacement?
    @State private var hardwareSelection: HardwareItem?
    @State private var trackingMessage: String?
    @State private var showCatalog = false
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var cameraRevision = 0
    @State private var previewProject: LabProject?
    @State private var roomTopology: LabTopology?
    @State private var deviceSelection: LabTopology.Device?
    @State private var linkSelection: LabTopology.Link?
    @State private var showTopology = false
    @State private var showTierInfo = false
    @State private var showImporter = false
    @State private var showCables = true
    @State private var previewSession: ARSession?
    @State private var sceneZoom = 0
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    var body: some View {
        NavigationStack {
            Group {
                if let view = capture.captureView { scanner(view: view) }
                else if capture.phase == .restoring || capture.phase == .permission {
                    ProgressView(capture.phase == .restoring ? "Abriendo laboratorio…" : "Preparando cámara…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let project = previewProject {
                    workspace(room: project.room, layout: project.layout, topology: project.topology)
                } else if let room = capture.room, let layout = capture.layout {
                    workspace(room: room, layout: layout, topology: roomTopology)
                } else { startScreen }
            }
            .navigationTitle("Nexus AR")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !capture.isBusy {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { beginCapture() } label: { Label("Escanear", systemImage: "viewfinder") }
                            .disabled(!capture.isSupported)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button("Equipos del laboratorio", systemImage: "server.rack") { showCatalog = true }
                            Button("Sala de servidores de prueba", systemImage: "building.2") { openDataCenter() }
                            Button("Importar topología exportada", systemImage: "square.and.arrow.down") { showImporter = true }
                            if previewProject != nil, capture.room != nil {
                                Button("Volver a mi cuarto", systemImage: "house") {
                                    previewProject = nil
                                    mode = .room
                                    UserDefaults.standard.set("scan", forKey: "activeLaboratory")
                                }
                            }
                            if currentTopology != nil {
                                Button("Red y conexiones", systemImage: "point.3.connected.trianglepath.dotted") { showTopology = true }
                                Toggle("Mostrar cables", isOn: $showCables)
                            }
                            Button("Criterios Tier IV", systemImage: "info.circle") { showTierInfo = true }
                            if let layout = currentLayout {
                                Section("Elementos colocados") {
                                    ForEach(layout.placements) { placement in
                                        Button(placement.title, systemImage: placement.kind == .rack ? "server.rack" : "desktopcomputer") {
                                            selection = placement
                                        }
                                    }
                                }
                            }
                            if let url = capture.savedURL { ShareLink("Compartir escaneo", item: url) }
                            if currentLayout != nil {
                                Button("Restablecer vista 3D", systemImage: "arrow.counterclockwise") {
                                    mode = .room
                                    cameraRevision += 1
                                    sceneZoom = 0
                                }
                            }
                        } label: { Label("Más opciones", systemImage: "ellipsis.circle") }
                    }
                }
            }
        }
        .tint(.blue)
        .task {
            let previous = UserDefaults.standard.string(forKey: "activeLaboratory")
            await capture.restoreLatest()
            switch previous {
            case "demo": openDataCenter()
            case "imported":
                if let project = try? LabImport.loadLatest() { previewProject = project; mode = .room }
            default: break
            }
        }
        .onChange(of: capture.phase) { _, phase in
            switch phase {
            case .saved:
                if capture.arSession != nil {
                    previewSession?.pause()
                    previewSession = nil
                    previewProject = nil
                    sceneZoom = 0
                }
                if let room = capture.room, let layout = capture.layout {
                    roomTopology = try? LabDemo.roomLab(room: room, layout: layout)
                }
                mode = previewProject == nil && capture.arSession != nil ? .ar : .room
                if capture.arSession != nil { UserDefaults.standard.set("scan", forKey: "activeLaboratory") }
                paintRoom = true
                poweredOff.removeAll()
                selection = nil
                trackingMessage = nil
            case .ready:
                if capture.arSession == nil { mode = .room }
            case .failed(let message):
                errorMessage = message
                showError = true
                if capture.arSession == nil { mode = .room }
            default: break
            }
        }
        .onChange(of: mode) { _, value in
            guard value != .ar || canUseAR else {
                mode = .room
                return
            }
            trackingMessage = nil
            if value == .room { capture.pauseAR(); previewSession?.pause() }
            else if previewProject != nil {
                if let configuration = previewSession?.configuration { previewSession?.run(configuration) }
            } else { capture.resumeAR() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                capture.cancel()
                capture.pauseAR()
                previewSession?.pause()
            } else if phase == .active {
                if capture.room == nil { Task { await capture.restoreLatest() } }
                if mode == .ar {
                    if previewProject != nil, let configuration = previewSession?.configuration { previewSession?.run(configuration) }
                    else { capture.resumeAR() }
                }
            }
        }
        .sheet(item: $selection) { item in
            PlacementInspector(placement: item, poweredOff: $poweredOff)
        }
        .sheet(item: $hardwareSelection) { item in
            NavigationStack { HardwareDetail(item: item).toolbar { DismissButton() } }
        }
        .sheet(isPresented: $showCatalog) {
            NavigationStack {
                List(HardwareCatalog.items) { item in
                    NavigationLink { HardwareDetail(item: item) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.name)
                            Text(item.category).font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 4)
                    }
                }
                .navigationTitle("10 equipos")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { DismissButton() }
            }
        }
        .sheet(isPresented: $showTopology) {
            if let topology = currentTopology { TopologyInspector(topology: topology) }
        }
        .sheet(item: $deviceSelection) { device in
            if let topology = currentTopology {
                NavigationStack { DeviceInspector(device: device, topology: topology).toolbar { DismissButton() } }
            }
        }
        .sheet(item: $linkSelection) { link in
            if let topology = currentTopology {
                NavigationStack { LinkInspector(link: link, topology: topology).toolbar { DismissButton() } }
            }
        }
        .sheet(isPresented: $showTierInfo) { DataCenterInfo() }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json], allowsMultipleSelection: false) { result in
            do {
                guard let url = try result.get().first else { return }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size > 0, size <= 8 * 1024 * 1024 else { throw LabLayoutError.invalid("Archivo vacío o mayor de 8 MB.") }
                let project = try LabImport.project(from: Data(contentsOf: url))
                _ = try LabImport.save(project.topology)
                previewProject = project
                sceneZoom = 0
                mode = .room
                capture.pauseAR()
                poweredOff.removeAll()
                UserDefaults.standard.set("imported", forKey: "activeLaboratory")
            } catch {
                errorMessage = "Usa el archivo .nexus.json generado por el exportador de Packet Tracer en el Mac. \(error.localizedDescription)"
                showError = true
            }
        }
        .alert("No se pudo completar la acción", isPresented: $showError) {
            Button("Volver a escanear") { beginCapture() }
            Button("Cerrar", role: .cancel) {}
        } message: { Text(errorMessage) }
    }

    private func beginCapture() {
        selection = nil
        hardwareSelection = nil
        previewSession?.pause()
        Task { await capture.start() }
    }

    private var currentTopology: LabTopology? { previewProject?.topology ?? roomTopology }
    private var currentLayout: LabLayout? { previewProject?.layout ?? capture.layout }
    private var canUseAR: Bool {
        previewProject == nil ? capture.arSession != nil : ARWorldTrackingConfiguration.isSupported
    }

    private func openDataCenter() {
        do {
            previewProject = try LabDemo.dataCenter()
            sceneZoom = 0
            previewSession?.pause()
            previewSession = nil
            mode = .room
            capture.pauseAR()
            poweredOff.removeAll()
            trackingMessage = nil
            UserDefaults.standard.set("demo", forKey: "activeLaboratory")
        } catch { errorMessage = error.localizedDescription; showError = true }
    }

    private var startScreen: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Image(systemName: "viewfinder").font(.system(size: 56, weight: .light)).foregroundStyle(.blue)
                    .accessibilityHidden(true)
                Text("Tu cuarto, un laboratorio.").font(.largeTitle.bold())
                Text("Escanea paredes, suelo y accesos. Al terminar verás el cuarto blanco con racks, servidores y un puesto de trabajo distribuidos automáticamente.")
                    .font(.body).foregroundStyle(.secondary)
                Button { beginCapture() } label: {
                    Label("Escanear cuarto", systemImage: "camera")
                        .frame(maxWidth: .infinity).padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!capture.isSupported || capture.isBusy)
                if !capture.isSupported {
                    Text("La captura necesita un iPhone o iPad con LiDAR. Puedes abrir un laboratorio guardado en este dispositivo.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Text("Todo se genera y guarda en este dispositivo. Las medidas del escaneo son estimadas.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(maxWidth: 600, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private func scanner(view: RoomCaptureView) -> some View {
        VStack(spacing: 0) {
            CapturePreview(view: view, onStarted: { capture.previewStarted() })
                .overlay {
                    if capture.phase == .processing {
                        ProgressView("Creando tu laboratorio…")
                            .padding(24).background(.regularMaterial, in: .rect(cornerRadius: 16))
                    }
                }
            VStack(spacing: 12) {
                if let status = capture.cameraStatusString {
                    Text(status).font(.footnote).foregroundStyle(.secondary)
                }
                Text("Recorre paredes, puertas y suelo lentamente.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button("Cancelar", role: .cancel) { capture.cancel() }
                        .frame(minHeight: 44)
                    Spacer(minLength: 12)
                    Button("Terminar y generar") { capture.finish() }
                        .buttonStyle(.borderedProminent).frame(minHeight: 44)
                        .disabled(capture.phase != .capturing)
                }
            }.padding().background(.bar)
        }
    }

    private func workspace(room: RoomStructure, layout: LabLayout, topology: LabTopology?) -> some View {
        LabSceneView(
            room: room, layout: layout, arSession: previewProject == nil ? capture.arSession : previewSession, mode: mode,
            paintRoom: mode == .room || paintRoom, poweredOff: poweredOff,
            selection: $selection, trackingMessage: $trackingMessage,
            onSelectHardware: { hardwareSelection = HardwareCatalog.item($0) },
            topology: topology, showCables: showCables, selectedLinkID: linkSelection?.id,
            onSelectDevice: { id in deviceSelection = topology?.devices.first { $0.id == id } },
            onSelectLink: { id in linkSelection = topology?.links.first { $0.id == id } },
            sceneScale: previewProject != nil && mode == .ar ? 0.1 : 1,
            arPlacementRequired: previewProject != nil && mode == .ar, zoomStep: sceneZoom,
            focusDeviceID: deviceSelection?.id)
            .id("\(room.roomID)-\(mode.rawValue)-\(cameraRevision)")
            .ignoresSafeArea(edges: .bottom)
            .overlay(alignment: .trailing) {
                if mode == .room {
                    VStack(spacing: 8) {
                        Button { sceneZoom = min(12, sceneZoom + 1) } label: {
                            Image(systemName: "plus.magnifyingglass").frame(width: 44, height: 44)
                        }.accessibilityLabel("Acercar equipos")
                        Button { sceneZoom = max(-8, sceneZoom - 1) } label: {
                            Image(systemName: "minus.magnifyingglass").frame(width: 44, height: 44)
                        }.accessibilityLabel("Alejar equipos")
                    }.background(.regularMaterial, in: .capsule).padding(12)
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 10) {
                  if previewProject != nil && verticalSizeClass != .compact {
                    Text(topology?.name ?? "Laboratorio virtual").font(.caption).foregroundStyle(.secondary)
                  }
                  if verticalSizeClass == .compact {
                    HStack {
                        Text("\(layout.area.formatted(.number.precision(.fractionLength(1)))) m²").monospacedDigit()
                        Spacer(minLength: 12)
                        viewPicker.pickerStyle(.menu)
                        if mode == .ar {
                            Toggle("Blanco", isOn: $paintRoom)
                                .accessibilityLabel("Paredes y suelo blancos")
                                .fixedSize()
                        }
                    }.font(.subheadline)
                  } else {
                    ViewThatFits(in: .horizontal) {
                      HStack {
                        Label("\(layout.area.formatted(.number.precision(.fractionLength(1)))) m²", systemImage: "square.dashed")
                        Spacer()
                        Label("\(layout.placements.filter { $0.kind == .rack }.count) rack", systemImage: "server.rack")
                        Label("\(layout.placements.filter { $0.kind == .workstation }.count) puesto", systemImage: "desktopcomputer")
                      }.fixedSize(horizontal: true, vertical: false)
                      VStack(alignment: .leading, spacing: 4) {
                        Text("\(layout.area.formatted(.number.precision(.fractionLength(1)))) m²")
                        Text("\(layout.placements.filter { $0.kind == .rack }.count) rack · \(layout.placements.filter { $0.kind == .workstation }.count) puesto")
                      }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.subheadline).monospacedDigit()
                    if dynamicTypeSize.isAccessibilitySize {
                        viewPicker.pickerStyle(.menu)
                    } else {
                        viewPicker.pickerStyle(.segmented)
                    }
                    if mode == .ar {
                        Toggle("Paredes y suelo blancos", isOn: $paintRoom).font(.subheadline)
                    }
                  }
                }.padding(12).frame(maxWidth: .infinity).background(.regularMaterial)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    if let trackingMessage {
                        Label(trackingMessage, systemImage: "viewfinder").font(.callout)
                    }
                    if mode == .ar {
                        Text(previewProject != nil ? "Maqueta AR 1:10. Toca una superficie para colocarla; muévete alrededor para verla."
                             : paintRoom
                             ? "Reconstrucción virtual: los muebles físicos siguen presentes. Desactiva el blanco para ver tu entorno."
                             : "Racks virtuales a escala real. Respeta los objetos físicos.")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        Text(verticalSizeClass == .compact
                             ? "Muros recortados en 3D. Gira, acerca y toca un equipo."
                             : "Muros recortados para ver el interior. Gira con un dedo, acerca con dos y toca un equipo para inspeccionarlo.")
                            .font(.footnote).foregroundStyle(.secondary)
                        if !canUseAR && verticalSizeClass != .compact {
                            Text(previewProject == nil
                                 ? "Escanea de nuevo para alinear AR con tu posición actual."
                                 : "Sala virtual de demostración. La red y los servicios describen el diseño.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    if let warning = layout.warnings.first {
                        Label(warning, systemImage: "info.circle").font(.footnote).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12).background(.regularMaterial)
            }
    }

    private var viewPicker: some View {
        Picker("Vista", selection: Binding(
            get: { mode },
            set: { value in
                guard value != .ar || canUseAR else { return }
                if value == .ar, previewProject != nil {
                    capture.pauseAR()
                    if previewSession == nil {
                        let session = ARSession()
                        let configuration = ARWorldTrackingConfiguration()
                        configuration.planeDetection = [.horizontal]
                        session.run(configuration)
                        previewSession = session
                    }
                }
                mode = value
            })) {
            Text("Cuarto 3D").tag(LabViewMode.room)
            Text(previewProject == nil ? "Realidad aumentada" : "Maqueta AR 1:10").tag(LabViewMode.ar).disabled(!canUseAR)
        }
    }
}

private struct PlacementInspector: View {
    let placement: LabPlacement
    @Binding var poweredOff: Set<String>
    private var items: [HardwareItem] {
        let ids = placement.kind == .rack
            ? ["rack-r42612", "switch-2960", "switch-3560", "router-1941", "router-2911", "firewall-asa5505", "server-c220m5"]
            : ["pc-optiplex7010", "laptop-latitude5420", "phone-7960"]
        return ids.compactMap(HardwareCatalog.item)
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Encendido", isOn: Binding(
                        get: { !poweredOff.contains(placement.id) },
                        set: { value in
                            if value { poweredOff.remove(placement.id) }
                            else { poweredOff.insert(placement.id) }
                        }))
                    Text("Controla indicadores y pantallas del equipo virtual.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Equipos") {
                    ForEach(items) { item in
                        NavigationLink(item.name) { HardwareDetail(item: item) }
                    }
                }
            }
            .navigationTitle(placement.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { DismissButton() }
        }.presentationDetents([.medium, .large])
    }
}

struct HardwareDetail: View {
    let item: HardwareItem
    var body: some View {
        Form {
            Section {
                Text(item.name).font(.title3.bold())
                Text(item.summary)
            }
            Section("Conexiones") { Text(item.ports) }
            if let size = item.size {
                Section("Dimensiones exteriores") {
                    LabeledContent("Ancho", value: meters(size.x))
                    LabeledContent("Alto", value: meters(size.y))
                    LabeledContent("Fondo", value: meters(size.z))
                }
            }
            Section("Referencia") {
                Link(destination: item.sourceURL) {
                    Label(item.sourceTitle, systemImage: "arrow.up.right.square")
                }
                if let url = item.dimensionsSourceURL {
                    Link("Dimensiones del fabricante", destination: url)
                }
                Text("Representación 3D educativa del exterior; consulta la ficha del fabricante para especificaciones y configuración.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle(item.category)
        .navigationBarTitleDisplayMode(.inline)
    }
    private func meters(_ value: Float) -> String {
        value.formatted(.number.precision(.fractionLength(3))) + " m"
    }
}

struct DismissButton: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View { Button("Listo") { dismiss() } }
}
