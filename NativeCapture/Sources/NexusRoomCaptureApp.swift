import ARKit
import RoomPlan
import SwiftUI
import UniformTypeIdentifiers
import simd

@main
struct NexusRoomCaptureApp: App {
    var body: some Scene { WindowGroup { LaboratoryScreen() } }
}

private struct LaboratoryScreen: View {
    @State private var capture = CaptureController()
    @State private var operations = LabOperationsStore()
    @State private var mode: LabViewMode = .room
    @State private var paintRoom = true
    @State private var poweredOff = Set<String>()
    @State private var selection: LabPlacement?
    @State private var hardwareSelection: HardwareItem?
    @State private var trackingMessage: String?
    @State private var walkthrough = ARWalkthrough()
    @State private var tracedLinkID: String?
    @State private var inspectionDestination: LabInspectionDestination?
    @State private var inspectionRevision = 0
    @State private var lockedDeviceID: String?
    @AppStorage("labShowTraffic") private var showTraffic = true
    @AppStorage("labPhysicalOcclusion") private var physicalOcclusion = true
    private enum EquipmentBrowser: String, Identifiable {
        case catalog, scene
        var id: Self { self }
    }
    @State private var equipmentBrowser: EquipmentBrowser?
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var retryImport = false
    @State private var projectProgress: LocalizedStringKey?
    @State private var cameraRevision = 0
    @State private var orbitReset = 0
    @State private var previewProject: LabProject?
    @State private var appliedTemplate: LabProject?
    private enum ScanTemplate { case tier, home }
    @State private var templateOnNextScan: ScanTemplate?
    @State private var roomTopology: LabTopology?
    @State private var deviceSelection: LabTopology.Device?
    @State private var linkSelection: LabTopology.Link?
    @State private var showTopology = false
    @State private var showMonitors = false
    @State private var showTierInfo = false
    @State private var showImporter = false
    @State private var showSiteLibrary = false
    @State private var travelMode: LabTravelMode?
    @State private var showHomeGuide = false
    @State private var placementSavedInSession = false
    @State private var restoringPlacement = false
    @State private var requestingPreviewCamera = false
    @State private var showCables = true
    @State private var previewSession: ARSession?
    @State private var sceneZoom = 0
    @State private var homeARScale: LabARScale = .fullSize
    @State private var tierARScale: LabARScale = .tenth
    @State private var showARScales = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NavigationStack {
            Group {
                if let view = capture.captureView { scanner(view: view) }
                else if capture.phase == .restoring || capture.phase == .permission || requestingPreviewCamera {
                    ProgressView(capture.phase == .restoring ? "Abriendo laboratorio…" : "Preparando cámara…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let project = previewProject {
                    workspace(room: project.room, layout: project.layout, topology: operations.configured(project.topology))
                } else if let project = appliedTemplate {
                    workspace(room: project.room, layout: project.layout, topology: operations.configured(project.topology))
                } else if let room = capture.room, let layout = capture.layout {
                    workspace(room: room, layout: layout, topology: roomTopology)
                } else { startScreen }
            }
            .disabled(projectProgress != nil)
            .allowsHitTesting(projectProgress == nil)
            .overlay {
                Group {
                    if let projectProgress {
                        ProgressView(projectProgress)
                            .padding(16)
                            .modifier(ViewerSurface(radius: 16, material: .thick))
                            .padding(16)
                            .transition(.opacity)
                    }
                }
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: projectProgress != nil)
            }
            .navigationTitle("Nexus AR")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !capture.isBusy {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { beginCapture() } label: { Label("Escanear", systemImage: "viewfinder") }
                            .disabled(!capture.isSupported || projectProgress != nil)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            templateMenu
                            equipmentMenu
                            if currentTopology != nil { networkMenu }
                            if currentLayout != nil { viewerMenu }
                            roomAndFilesMenu
                        } label: { Label("Más opciones", systemImage: "ellipsis.circle") }
                            .menuOrder(.fixed)
                            .disabled(projectProgress != nil)
                    }
                }
            }
        }
        .tint(.blue)
        .task {
            let previous = UserDefaults.standard.string(forKey: "activeLaboratory")
            await capture.selectSite(operations.siteStorageID)
            switch previous {
            case "demo": openDataCenter()
            case "home": openHomeLab()
            case "imported":
                let site = operations.siteStorageID
                loadProject("Abriendo importación…", retryImport: true, build: { try LabImport.loadLatest(site: site) }) { project in
                    showPreview(project, key: "imported")
                }
            default: break
            }
        }
        .onChange(of: capture.phase) { _, phase in
            switch phase {
            case .saved:
                let freshCapture = capture.arSession != nil
                if freshCapture {
                    walkthrough = ARWalkthrough()
                    previewSession?.pause()
                    previewSession = nil
                    previewProject = nil
                    appliedTemplate = nil
                    sceneZoom = 0
                }
                if let room = capture.room, let layout = capture.layout {
                    roomTopology = try? LabDemo.roomLab(room: room, layout: layout)
                }
                mode = previewProject == nil && freshCapture ? .ar : .room
                paintRoom = false
                tracedLinkID = nil
                poweredOff.removeAll()
                selection = nil
                trackingMessage = nil
                if freshCapture {
                    UserDefaults.standard.set("scan", forKey: "activeLaboratory")
                    if let templateOnNextScan { applyTemplate(openAR: true, home: templateOnNextScan == .home) }
                    templateOnNextScan = nil
                } else {
                    let active = UserDefaults.standard.string(forKey: "activeLaboratory")
                    if active == "scan-tier" || active == "scan-home" { applyTemplate(openAR: false, home: active == "scan-home") }
                }
            case .ready:
                if capture.arSession == nil { mode = .room }
            case .failed(let message):
                errorMessage = message
                showError = true
                if capture.arSession == nil { mode = .room }
            default: break
            }
        }
        .onChange(of: operations.siteStorageID) { _, site in
            previewSession?.pause()
            previewSession = nil
            appliedTemplate = nil
            roomTopology = nil
            mode = .room
            cameraRevision += 1
            walkthrough = ARWalkthrough()
            Task {
                await capture.selectSite(site)
                guard operations.siteStorageID == site else { return }
                let active = UserDefaults.standard.string(forKey: "activeLaboratory")
                if active == "imported" {
                    if let entry = try? LabImport.history(site: site).first { openInventory(entry) }
                    else { openDataCenter() }
                } else if capture.room == nil && active == "scan-home" {
                    openHomeLab()
                } else if capture.room == nil && active == "scan-tier" {
                    openDataCenter()
                }
            }
        }
        .onChange(of: currentLayout?.placements) { _, _ in
            lockedDeviceID = nil
            inspectionDestination = nil
        }
        .onChange(of: lockedDeviceID) { _, id in
            if inspectionDestination?.deviceID != id { inspectionDestination = nil }
        }
        .onChange(of: cameraRevision) { _, _ in
            lockedDeviceID = nil
            inspectionDestination = nil
        }
        .onChange(of: mode) { _, value in
            lockedDeviceID = nil
            inspectionDestination = nil
            guard value != .ar || canUseAR else {
                mode = .room
                return
            }
            trackingMessage = nil
            if value == .room { capture.pauseAR(); previewSession?.pause() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                if mode == .ar {
                    walkthrough.pose = nil
                    walkthrough.target = nil
                    walkthrough.phase = .interrupted
                }
                capture.cancel()
                capture.pauseAR()
                previewSession?.pause()
            } else if phase == .active {
                if capture.room == nil { Task { await capture.restoreLatest() } }
                if mode == .ar {
                    if previewProject == nil { resumeRoomAR() }
                    else if let configuration = previewSession?.configuration { previewSession?.run(configuration) }
                }
            }
        }
        .sheet(item: $selection) { item in
            NavigationStack {
                PlacementInspector(placement: item, topology: currentTopology, locateTitle: locateTitle,
                                   onLocate: locateInScene, poweredOff: $poweredOff)
                    .toolbar { DismissButton() }
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(item: $hardwareSelection) { item in
            NavigationStack { HardwareDetail(item: item).toolbar { DismissButton() } }
        }
        .sheet(item: $equipmentBrowser) { browser in
            NavigationStack {
                switch browser {
                case .catalog:
                    catalogList
                case .scene:
                    sceneEquipmentList
                }
            }
        }
        .sheet(isPresented: $showMonitors) {
            if let baseTopology {
                LabMonitorInventory(base: baseTopology, poweredOff: poweredOff, locateTitle: locateTitle) {
                    showMonitors = false
                    locateInScene($0)
                }
            }
        }
        .sheet(isPresented: $showTopology) {
            if let topology = currentTopology {
                TopologyInspector(topology: topology, room: previewProject?.room ?? capture.room, layout: currentLayout,
                                  locateTitle: locateTitle, onLocate: locateInScene)
            }
        }
        .sheet(isPresented: $showARScales) {
            if let previewSpace {
                ARScalePicker(selection: arScale, space: previewSpace, onSelect: selectARScale)
            }
        }
        .sheet(item: $deviceSelection) { device in
            if let baseTopology {
                LabDeviceSheet(device: device, base: baseTopology, poweredOff: poweredOff,
                               locateTitle: locateTitle, onLocate: locateInScene)
            }
        }
        .sheet(item: $linkSelection) { link in
            if let topology = currentTopology {
                NavigationStack {
                    LinkInspector(link: link, topology: topology, locateTitle: locateTitle, onLocate: locateInScene)
                        .toolbar { DismissButton() }
                }
            }
        }
        .sheet(isPresented: $showTierInfo) {
            DataCenterInfo(topology: currentLayout?.facility == nil ? nil : currentTopology)
        }
        .sheet(isPresented: $showHomeGuide) {
            HomeLabGuide { id in
                showCables = true
                tracedLinkID = id
                showHomeGuide = false
            }
        }
        .fullScreenCover(item: $travelMode) { travel in
            if let room = previewProject?.room ?? capture.room, let layout = currentLayout {
                LabTravelView(mode: travel, room: room, layout: layout, topology: baseTopology,
                              showCables: $showCables, poweredOff: poweredOff, showTraffic: $showTraffic)
            }
        }
        .sheet(isPresented: $showSiteLibrary) {
            LabInventoryLibrary(base: baseTopology, onOpen: openInventory)
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, urls.isEmpty { return }
            let site = operations.siteStorageID
            loadProject("Importando topología…", retryImport: true, build: {
                guard let url = try result.get().first else { throw CocoaError(.fileNoSuchFile) }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size > 0, size <= 8 * 1024 * 1024 else { throw LabLayoutError.invalid("Archivo vacío o mayor de 8 MB.") }
                let project = try LabImport.project(from: Data(contentsOf: url, options: .mappedIfSafe))
                _ = try LabImport.save(project.topology, site: site)
                return project
            }) { project in
                showPreview(project, key: "imported")
            }
        }
        .alert("No se pudo completar la acción", isPresented: $showError) {
            if retryImport {
                Button("Elegir otro archivo") { showImporter = true }
            } else if capture.isSupported {
                Button("Volver a escanear") { beginCapture() }
            }
            Button("Cerrar", role: .cancel) {}
        } message: { Text(errorMessage) }
        .onChange(of: showError) { _, presented in
            if !presented { retryImport = false }
        }
        .environment(operations)
    }

    private var templateMenu: some View {
        Menu("Plantillas", systemImage: "square.on.square") {
            Button("HomeLab Proxmox", systemImage: "server.rack") { openHomeLab() }
            Button("Plantilla Tier IV", systemImage: "building.2") { openDataCenter() }
            Section {
                if isHomeLab {
                    Button("Guía de montaje", systemImage: "list.number") { showHomeGuide = true }
                }
                Button(currentLayout?.facility == nil ? "Criterios Tier IV" : "Infraestructura y pruebas", systemImage: "info.circle") {
                    showTierInfo = true
                }
            }
        }
    }

    private var equipmentMenu: some View {
        Menu("Equipos", systemImage: "server.rack") {
            Button("Equipos disponibles", systemImage: "list.bullet.rectangle") { equipmentBrowser = .catalog }
            if let currentLayout, !currentLayout.placements.isEmpty {
                Button("Elementos de la escena", systemImage: "cube") { equipmentBrowser = .scene }
            }
        }
    }

    private var networkMenu: some View {
        Menu("Red y conexiones", systemImage: "point.3.connected.trianglepath.dotted") {
            Button("Ver equipos y conexiones", systemImage: "list.bullet") { showTopology = true }
            if currentTopology?.operationsProfile != nil {
                Button("Monitores de servidores", systemImage: "display") { showMonitors = true }
            }
            Toggle("Mostrar cables", systemImage: "cable.connector", isOn: $showCables)
            Toggle("Flujo simulado", systemImage: "waveform.path", isOn: $showTraffic)
        }
    }

    private var viewerMenu: some View {
        Menu("Vista y recorrido", systemImage: "cube") {
            Button("Recorrido 3D", systemImage: "figure.walk") { openTravel(.walk) }
            Button("Modo VR", systemImage: "eyeglasses") { openTravel(.vr) }
            Button("Restablecer vista 3D", systemImage: "arrow.counterclockwise") { resetOrbit() }
            if previewProject == nil, appliedTemplate != nil {
                Button("Configurar maqueta AR", systemImage: "ruler") {
                    if isHomeLab { openHomeLab() } else { openDataCenter() }
                }
            }
            if mode == .ar {
                Section("Realidad aumentada") {
                    if let _ = placementAnchorName {
                        Button("Recalibrar punto de referencia", systemImage: "move.3d") { openPreviewAR(reposition: true) }
                    }
                    if capture.supportsMesh {
                        Toggle("Oclusión con espacio real", systemImage: "square.on.square.intersection.dashed", isOn: $physicalOcclusion)
                    }
                    Toggle("Reconstruir paredes y suelo", systemImage: "square.3.layers.3d", isOn: $paintRoom)
                    if previewProject == nil && capture.hasSavedWorldMap {
                        Button("Volver a alinear el cuarto", systemImage: "viewfinder") { resumeRoomAR(realign: true) }
                    }
                }
            }
        }
    }

    private var roomAndFilesMenu: some View {
        Menu("Cuarto y archivos", systemImage: "folder") {
            if capture.room != nil {
                Section {
                    Button(isHomeLab ? "Ajustar HomeLab al escaneo" : "Aplicar plantilla al cuarto", systemImage: "square.dashed.inset.filled") {
                        applyTemplate(openAR: mode == .ar, home: isHomeLab)
                    }
                    if previewProject != nil || appliedTemplate != nil {
                        Button("Volver a mi cuarto", systemImage: "house") {
                            previewProject = nil
                            appliedTemplate = nil
                            mode = .room
                            UserDefaults.standard.set("scan", forKey: "activeLaboratory")
                        }
                    }
                }
            }
            Button("Importar topología exportada", systemImage: "square.and.arrow.down") { showImporter = true }
            Button("Sitios e inventarios", systemImage: "archivebox") { showSiteLibrary = true }
            if let url = capture.savedURL { ShareLink("Compartir escaneo", item: url) }
        }
    }

    private var catalogList: some View {
        List {
            ForEach(HardwareItem.Family.allCases, id: \.self) { family in
                if let items = HardwareCatalog.byFamily[family] {
                    Section(family.rawValue) {
                        ForEach(items) { item in
                            NavigationLink { HardwareDetail(item: item) } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.name)
                                    Text(item.category).font(.caption).foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 4)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Equipos disponibles")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { DismissButton() }
    }

    private var sceneEquipmentList: some View {
        let placements = currentLayout?.placements ?? []
        let topology = currentTopology
        return List {
            ForEach([LabPlacement.Kind.rack, .workstation], id: \.self) { kind in
                let group = placements.filter { $0.kind == kind }
                if !group.isEmpty {
                    Section(kind == .rack ? "Racks" : "Puestos de trabajo") {
                        ForEach(group) { placement in
                            NavigationLink {
                                PlacementInspector(placement: placement, topology: topology, locateTitle: locateTitle,
                                                   onLocate: locateInScene, poweredOff: $poweredOff)
                            } label: {
                                Label(placement.title, systemImage: kind == .rack ? "server.rack" : "desktopcomputer")
                            }
                        }
                    }
                }
            }
            if currentLayout?.facility != nil {
                Section("Infraestructura Tier IV") {
                    ForEach(HardwareCatalog.infrastructure) { item in
                        NavigationLink(item.name) { HardwareDetail(item: item) }
                    }
                }
            }
        }
        .navigationTitle("Elementos de la escena")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { DismissButton() }
    }

    private func beginCapture() {
        templateOnNextScan = isHomeLab ? .home : currentLayout?.facility != nil ? .tier : nil
        selection = nil
        hardwareSelection = nil
        previewSession?.pause()
        Task { await capture.start() }
    }

    private var isHomeLab: Bool { (previewProject ?? appliedTemplate)?.isHomeLab == true }
    private var isManualHome: Bool { isHomeLab && previewProject != nil }
    private var hasScalablePreview: Bool { isManualHome || previewProject?.layout.facility != nil }
    private var arScale: LabARScale {
        if isManualHome { return homeARScale }
        if previewProject?.layout.facility != nil { return tierARScale }
        return previewProject == nil ? .fullSize : .tenth
    }
    private var isHomeFloorPlacement: Bool { isManualHome && arScale == .fullSize }
    private var previewSpace: LabARSpace? {
        guard hasScalablePreview, let previewProject else { return nil }
        return LabARSpace(virtualRoom: previewProject.room, layout: previewProject.layout)
    }
    private var placementAnchorName: String? {
        guard let profile = previewProject?.topology.operationsProfile else { return nil }
        if profile == "home", arScale == .fullSize, operations.activeSite == "Principal" {
            return CaptureController.homePlacementName
        }
        return "NexusAR.\(operations.siteStorageID).\(profile).\(arScale.rawValue).v1"
    }
    private var previewMapExists: Bool {
        placementAnchorName.map { FileManager.default.fileExists(atPath: CaptureController.placementMapURL($0).path) } ?? false
    }
    private var canSelectARScale: Bool {
        hasScalablePreview && (mode == .room || (!restoringPlacement && !walkthrough.placementConfirmed))
    }
    private var baseTopology: LabTopology? { previewProject?.topology ?? appliedTemplate?.topology ?? roomTopology }
    private var currentTopology: LabTopology? { baseTopology.map(operations.configured) }
    private var currentLayout: LabLayout? { previewProject?.layout ?? appliedTemplate?.layout ?? capture.layout }
    private var canUseAR: Bool {
        ARWorldTrackingConfiguration.isSupported &&
            (previewProject != nil || capture.arSession != nil || capture.hasSavedWorldMap)
    }

    private func resumeRoomAR(realign: Bool = false) {
        do {
            try capture.resumeAR(realign: realign)
            if mode != .ar || realign {
                walkthrough = ARWalkthrough()
                cameraRevision += 1
            } else {
                walkthrough.phase = .aligning
            }
            mode = .ar
        } catch {
            mode = .room
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    private func openTravel(_ travel: LabTravelMode) {
        mode = .room
        travelMode = travel
    }

    private func openInventory(_ entry: LabImport.Entry) {
        showSiteLibrary = false
        loadProject("Abriendo inventario…", build: { try LabImport.load(entry) }) { project in
            showPreview(project, key: "imported")
        }
    }

    private func openDataCenter() {
        loadProject("Abriendo Tier IV…", build: { try LabDemo.dataCenter() }) { project in
            showPreview(project, key: "demo")
        }
    }

    private func openHomeLab() {
        loadProject("Abriendo HomeLab…", build: { try LabDemo.homeLab() }) { project in
            showPreview(project, key: "home")
        }
    }

    private func selectARScale(_ scale: LabARScale) {
        guard canSelectARScale, scale != arScale else { return }
        if mode == .room {
            previewSession?.pause()
            previewSession = nil
        }
        walkthrough.placementHint = nil
        if isManualHome { homeARScale = scale } else { tierARScale = scale }
    }

    private func loadProject(
        _ progress: LocalizedStringKey, retryImport: Bool = false,
        build: @escaping @Sendable () throws -> LabProject, open: @escaping (LabProject) -> Void
    ) {
        guard projectProgress == nil else { return }
        projectProgress = progress
        Task {
            defer { projectProgress = nil }
            do {
                open(try await Self.prepareProject(build))
            } catch {
                self.retryImport = retryImport
                errorMessage = retryImport
                    ? "Usa el archivo .nexus.json generado por el exportador de Packet Tracer en el Mac. \(error.localizedDescription)"
                    : error.localizedDescription
                showError = true
            }
        }
    }

    @concurrent private static func prepareProject(_ build: @Sendable () throws -> LabProject) async rethrows -> LabProject {
        try build()
    }

    private func showPreview(_ project: LabProject, key: String) {
        previewProject = project
        sceneZoom = 0
        previewSession?.pause()
        previewSession = nil
        mode = .room
        capture.pauseAR()
        poweredOff.removeAll()
        trackingMessage = nil
        tracedLinkID = nil
        selection = nil
        walkthrough = ARWalkthrough()
        UserDefaults.standard.set(key, forKey: "activeLaboratory")
    }

    private func openPreviewAR(reposition: Bool = false) {
        guard canUseAR, !requestingPreviewCamera else { return }
        requestingPreviewCamera = true
        Task {
            defer { requestingPreviewCamera = false }
            guard await CaptureController.requestCameraAccess() else {
                errorMessage = "Autoriza la cámara para Nexus AR en Ajustes y vuelve a abrir AR."
                showError = true
                return
            }
            startPreviewSession(reposition: reposition)
        }
    }

    private func startPreviewSession(reposition: Bool) {
        guard canUseAR, previewProject != nil else { return }
        let anchorName = placementAnchorName
        let configuration = ARWorldTrackingConfiguration()
        configuration.planeDetection = [.horizontal]
        if capture.supportsMesh { configuration.sceneReconstruction = .mesh }
        restoringPlacement = false
        placementSavedInSession = false
        if reposition, let anchorName, let session = previewSession, let tracked = session.configuration {
            for anchor in session.currentFrame?.anchors ?? [] where anchor.name == anchorName {
                session.remove(anchor: anchor)
            }
            walkthrough = ARWalkthrough()
            cameraRevision += 1
            tracedLinkID = nil
            session.run(tracked)
            mode = .ar
            return
        }
        if let anchorName, previewMapExists, !reposition {
            do {
                configuration.initialWorldMap = try CaptureController.loadPlacementMap(anchorName)
                restoringPlacement = true
                placementSavedInSession = true
            } catch {
                errorMessage = "El mapa guardado no pudo abrirse. Marca un nuevo punto en el piso."
                showError = true
            }
        }
        walkthrough = ARWalkthrough()
        tracedLinkID = nil
        paintRoom = false
        capture.pauseAR()
        previewSession?.pause()
        let session = ARSession()
        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        previewSession = session
        cameraRevision += 1
        mode = .ar
    }

    private func savePlacement(session: ARSession, name: String) async {
        guard let frame = session.currentFrame, case .normal = frame.camera.trackingState,
              [.mapped, .extending].contains(frame.worldMappingStatus),
              frame.anchors.contains(where: { $0.name == name }) else { return }
        do {
            let map = try await session.currentWorldMap()
            try Task.checkCancellation()
            guard session === previewSession, placementAnchorName == name, !placementSavedInSession,
                  map.anchors.contains(where: { $0.name == name }) else { return }
            try CaptureController.writeWorldMap(map, to: CaptureController.placementMapURL(name))
            placementSavedInSession = true
        } catch {
            // The mapping task retries once tracking has more views of the room.
        }
    }

    private func applyTemplate(openAR: Bool, home: Bool = false) {
        guard let room = capture.room, let measured = capture.layout else { return }
        loadProject("Ajustando plantilla al cuarto…", build: {
            try home ? LabDemo.homeLab(in: (room, measured)) : LabDemo.dataCenter(in: (room, measured))
        }) { project in
            previewSession?.pause()
            previewSession = nil
            previewProject = nil
            appliedTemplate = project
            mode = .room
            paintRoom = false
            tracedLinkID = nil
            selection = nil
            sceneZoom = 0
            poweredOff.removeAll()
            cameraRevision += 1
            UserDefaults.standard.set(home ? "scan-home" : "scan-tier", forKey: "activeLaboratory")
            if openAR && canUseAR { resumeRoomAR() }
        }
    }

    private var startScreen: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Image(systemName: "viewfinder").font(.largeTitle.weight(.light)).foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text("Explora un laboratorio").font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
                Text("Escanea tu cuarto para recorrerlo en realidad aumentada, o explora las plantillas HomeLab y Tier IV.")
                    .font(.body).foregroundStyle(.secondary)
                VStack(spacing: 10) {
                    Button(action: openHomeLab) {
                        Label("Abrir HomeLab Proxmox", systemImage: "server.rack")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }.buttonStyle(.bordered)
                    if capture.isSupported {
                        Button { beginCapture() } label: {
                            Label("Escanear cuarto", systemImage: "camera")
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(capture.isBusy)
                        Button(action: openDataCenter) {
                            Label("Abrir plantilla Tier IV", systemImage: "building.2")
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }.buttonStyle(.bordered)
                    } else {
                        Button(action: openDataCenter) {
                            Label("Abrir plantilla Tier IV", systemImage: "building.2")
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }.buttonStyle(.borderedProminent)
                    }
                }
                if !capture.isSupported {
                    Text("El escaneo del cuarto requiere LiDAR.").font(.footnote).foregroundStyle(.secondary)
                } else {
                    Text("El escaneo se guarda en este dispositivo.").font(.footnote).foregroundStyle(.secondary)
                }
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
        VStack(spacing: 0) {
            workspaceHeader(layout: layout, topology: topology)
            LabSceneView(
                room: room, layout: layout, arSession: previewProject == nil ? capture.arSession : previewSession, mode: mode,
                paintRoom: mode == .room || paintRoom,
                poweredOff: baseTopology.map { poweredOff.union(operations.faults(in: $0)) } ?? poweredOff,
                selection: $selection, trackingMessage: $trackingMessage,
                onSelectHardware: { hardwareSelection = HardwareCatalog.reference($0) },
                topology: topology, showCables: showCables, selectedLinkID: linkSelection?.id ?? tracedLinkID,
                onSelectDevice: { id in deviceSelection = topology?.devices.first { $0.id == id } },
                onSelectLink: { id in inspect(.link(id), topology: topology, layout: layout) },
                sceneScale: mode == .ar ? arScale.factor : 1,
                arPlacementRequired: previewProject != nil && mode == .ar, zoomStep: sceneZoom,
                orbitReset: orbitReset,
                focusDeviceID: deviceSelection?.id,
                inspectionDestination: inspectionDestination, inspectionRevision: inspectionRevision,
                walkthrough: mode == .ar ? walkthrough : nil,
                isForeground: scenePhase == .active && travelMode == nil,
                worldPlacementName: mode == .ar ? placementAnchorName : nil,
                restoresWorldPlacement: restoringPlacement,
                lockedDeviceID: lockedDeviceID, showTraffic: showTraffic, physicalOcclusion: physicalOcclusion)
                .id("\(room.roomID)-\(mode.rawValue)-\(cameraRevision)")
                .frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
                .overlay(alignment: .top) {
                    if mode == .room {
                        HStack(alignment: .top, spacing: 8) {
                            if showTraffic && showCables && topology?.links.isEmpty == false {
                                LabTrafficLegend().allowsHitTesting(false)
                            }
                            Spacer(minLength: 0)
                            if canSelectARScale {
                                ARScaleButton(scale: arScale) { showARScales = true }
                                    .layoutPriority(1)
                            }
                        }
                        .padding(12)
                    }
                }
                .overlay(alignment: .bottom) {
                    if mode == .room {
                        HStack {
                            if topology != nil { cableControl }
                            Button { openTravel(.walk) } label: {
                                Label("Recorrido 3D", systemImage: "figure.walk")
                                    .labelStyle(.iconOnly).frame(width: 44, height: 44)
                            }.buttonStyle(ViewerPressStyle()).modifier(ViewerSurface(radius: 24))
                            Spacer(minLength: 8)
                            orbitControls
                        }
                        .padding(16)
                    }
                }
                .overlay {
                    if mode == .ar {
                        AimingReticle(walkthrough: walkthrough).allowsHitTesting(false).accessibilityHidden(true)
                    }
                }
                .overlay {
                    if mode == .ar {
                        WalkthroughHUD(
                            walkthrough: walkthrough, layout: layout, topology: topology,
                            worldMapped: previewProject == nil || isHomeFloorPlacement,
                            manualHome: isHomeFloorPlacement,
                            mapSaved: previewProject != nil ? placementSavedInSession : capture.hasSavedWorldMap,
                            scale: arScale, space: previewSpace,
                            onSelectScale: canSelectARScale ? { showARScales = true } : nil,
                            traceID: showCables ? tracedLinkID : nil, showVirtualWalls: paintRoom,
                            focusTargets: LabFocusTarget.inventory(topology, in: layout),
                            lockedDeviceID: $lockedDeviceID, showTraffic: $showTraffic, showCables: showCables,
                            onInspect: { inspect($0, topology: topology, layout: layout) },
                            onDismissTrace: { tracedLinkID = nil }, onDetails: { linkSelection = $0 },
                            onRealign: {
                                if previewProject != nil { openPreviewAR() }
                                else { resumeRoomAR(realign: true) }
                            })
                    }
                }
                .task(id: mode == .ar && previewProject == nil && scenePhase == .active ? room.roomID : nil) {
                    guard mode == .ar, previewProject == nil, scenePhase == .active else { return }
                    while !Task.isCancelled && !capture.hasSavedWorldMap {
                        await capture.saveWorldMapIfReady()
                        if capture.hasSavedWorldMap { break }
                        do { try await Task.sleep(for: .seconds(2)) } catch { break }
                    }
                }
                .task(id: placementAnchorName != nil && walkthrough.placementConfirmed && mode == .ar && scenePhase == .active ? cameraRevision : nil) {
                    guard let name = placementAnchorName, walkthrough.placementConfirmed, mode == .ar,
                          scenePhase == .active, let session = previewSession else { return }
                    while !Task.isCancelled && !placementSavedInSession {
                        await savePlacement(session: session, name: name)
                        if placementSavedInSession { break }
                        do { try await Task.sleep(for: .seconds(2)) } catch { break }
                    }
                }
            if mode == .room && (verticalSizeClass != .compact || layout.placements.isEmpty) {
                workspaceFooter(layout: layout)
            }
        }
    }

    private func workspaceHeader(layout: LabLayout, topology: LabTopology?) -> some View {
        let racks = layout.placements.filter { $0.kind == .rack }.count
        let desks = layout.placements.filter { $0.kind == .workstation }.count
        let rackLabel = "\(racks) \(racks == 1 ? "rack" : "racks")"
        let deskLabel = "\(desks) \(desks == 1 ? "puesto" : "puestos")"
        let title = isHomeLab ? LabDemo.homeName : layout.facility != nil ? "Plantilla Tier IV" : previewProject == nil ? "Cuarto escaneado" : topology?.name ?? "Laboratorio virtual"
        let area = "\(layout.area.formatted(.number.precision(.fractionLength(0...1)))) m²"
        return Group {
            if verticalSizeClass == .compact {
                HStack(spacing: 12) {
                    Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Spacer(minLength: 0)
                    if mode == .room && layout.facility != nil && previewProject != nil && capture.isSupported {
                        Button(action: openTemplateWalk) {
                            Label("Recorrer mi cuarto en AR", systemImage: "viewfinder")
                                .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                        }.buttonStyle(.bordered)
                    }
                    if isHomeLab { homeActions }
                    workspacePicker
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 16) {
                        workspaceContext(title, summary: "\(area) · \(rackLabel) · \(deskLabel)").fixedSize()
                        Spacer(minLength: 0)
                        workspacePicker
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        workspaceContext(title, summary: "\(area) · \(rackLabel) · \(deskLabel)")
                        workspacePicker
                    }
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, verticalSizeClass == .compact ? 4 : 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .systemBackground))
    }

    private func workspaceContext(_ title: String, summary: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.headline).accessibilityAddTraits(.isHeader)
            Text(summary).font(.caption).monospacedDigit().foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var workspacePicker: some View {
        if !canUseAR {
            if !dynamicTypeSize.isAccessibilitySize {
                Label("3D", systemImage: "cube").font(.subheadline.weight(.medium))
            }
        } else if verticalSizeClass == .compact || dynamicTypeSize.isAccessibilitySize {
            viewPicker.pickerStyle(.menu)
        } else {
            viewPicker.pickerStyle(.segmented).frame(minWidth: 134, idealWidth: 165, maxWidth: 220)
        }
    }

    private var orbitControls: some View {
        HStack(spacing: 0) {
            Button { sceneZoom = max(-8, sceneZoom - 1) } label: {
                Label("Alejar equipos", systemImage: "minus").labelStyle(.iconOnly).frame(width: 44, height: 44)
            }.disabled(sceneZoom <= -8)
            Divider().frame(height: 18)
            Button { sceneZoom = min(12, sceneZoom + 1) } label: {
                Label("Acercar equipos", systemImage: "plus").labelStyle(.iconOnly).frame(width: 44, height: 44)
            }.disabled(sceneZoom >= 12)
            Divider().frame(height: 18)
            Button(action: resetOrbit) {
                Label("Restablecer encuadre", systemImage: "arrow.counterclockwise")
                    .labelStyle(.iconOnly).frame(width: 44, height: 44)
            }
        }
        .font(.system(size: 18, weight: .semibold))
        .buttonStyle(ViewerPressStyle())
        .modifier(ViewerSurface(radius: 24))
    }

    private var cableControl: some View {
        Button { showCables.toggle(); if !showCables { tracedLinkID = nil } } label: {
            Label(showCables ? "Ocultar cableado" : "Mostrar cableado",
                  systemImage: showCables ? "point.3.connected.trianglepath.dotted" : "eye.slash")
                .labelStyle(.iconOnly)
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 44, height: 44)
        }
        .buttonStyle(ViewerPressStyle())
        .modifier(ViewerSurface(radius: 24))
    }

    private func resetOrbit() {
        inspectionDestination = nil
        lockedDeviceID = nil
        tracedLinkID = nil
        mode = .room
        sceneZoom = 0
        orbitReset += 1
    }

    private func openTemplateWalk() {
        if capture.room == nil || (capture.arSession == nil && !capture.hasSavedWorldMap) { beginCapture() }
        else { applyTemplate(openAR: true) }
    }

    private var homeActions: some View {
        Menu {
            if canUseAR && previewProject != nil {
                Button(isHomeFloorPlacement ? (previewMapExists ? "Volver a la ubicación guardada" : "Elegir punto en el piso")
                       : "Colocar maqueta AR",
                       systemImage: "location.viewfinder") { openPreviewAR() }
            }
            if capture.isSupported {
                Button("Escanear un cuarto", systemImage: "camera") { beginCapture() }
                if capture.room != nil {
                    Button("Usar el cuarto escaneado", systemImage: "square.dashed.inset.filled") { applyTemplate(openAR: canUseAR, home: true) }
                }
            }
            Button("Guía de montaje", systemImage: "list.number") { showHomeGuide = true }
        } label: {
            Group {
                if verticalSizeClass == .compact {
                    Label("Montar HomeLab", systemImage: "wrench.and.screwdriver").labelStyle(.iconOnly)
                } else {
                    Label("Montar HomeLab", systemImage: "wrench.and.screwdriver").labelStyle(.titleAndIcon)
                }
            }.frame(minWidth: 44, minHeight: 36)
        }.buttonStyle(.bordered)
    }

    private func workspaceFooter(layout: LabLayout) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let trackingMessage {
                Label(trackingMessage, systemImage: "viewfinder").font(.callout)
            }
            if isHomeLab {
                HStack { homeActions; Spacer(minLength: 0) }
            } else if layout.facility != nil && previewProject != nil && capture.isSupported {
                Button(action: openTemplateWalk) {
                    HStack(spacing: 8) {
                        Image(systemName: "viewfinder").accessibilityHidden(true)
                        Text("Recorrer mi cuarto en AR").lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
            } else if layout.facility != nil && previewProject != nil {
                Label("Para recorrer la plantilla se requiere un iPhone con LiDAR.", systemImage: "viewfinder")
                    .font(.footnote).foregroundStyle(.secondary)
            } else if !canUseAR && previewProject == nil && capture.isSupported {
                Text("Escanea el cuarto para recorrerlo en AR.").font(.footnote).foregroundStyle(.secondary)
            }
            if (!dynamicTypeSize.isAccessibilitySize || layout.placements.isEmpty), let warning = layout.warnings.first {
                Label(warning, systemImage: "info.circle").font(.footnote).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
            .padding(16).background(Color(uiColor: .systemBackground))
    }

    private var locateTitle: String { mode == .ar ? "Marcar en AR" : "Ver en 3D" }

    private func locateInScene(_ destination: LabInspectionDestination) {
        inspectionDestination = destination
        inspectionRevision += 1
        lockedDeviceID = destination.deviceID
        selection = nil
        if let linkID = destination.linkID {
            showCables = true
            tracedLinkID = linkID
        }
        deviceSelection = nil
        linkSelection = nil
        equipmentBrowser = nil
        showTopology = false
    }

    private func inspect(_ target: LabSceneTarget, topology: LabTopology?, layout: LabLayout) {
        switch target {
        case .link(let id):
            if mode == .ar { tracedLinkID = id }
            else { tracedLinkID = nil; linkSelection = topology?.links.first { $0.id == id } }
        case .device(let id):
            deviceSelection = topology?.devices.first { $0.id == id }
        case .hardware(let id): hardwareSelection = HardwareCatalog.reference(id)
        case .placement(let id): selection = layout.placements.first { $0.id == id }
        }
    }

    private var viewPicker: some View {
        Picker("Vista", selection: Binding(
            get: { mode },
            set: { value in
                guard value != .ar || canUseAR else { return }
                if value == .ar {
                    paintRoom = false
                    tracedLinkID = nil
                    if previewProject == nil { resumeRoomAR(); return }
                    openPreviewAR()
                    return
                }
                mode = value
            })) {
            Text("3D").accessibilityLabel("Cuarto 3D").tag(LabViewMode.room)
            Text("AR \(arScale.title)")
                .accessibilityLabel("Realidad aumentada, escala \(arScale.title)")
                .tag(LabViewMode.ar).disabled(!canUseAR)
        }
    }
}

private struct ARScaleButton: View {
    let scale: LabARScale
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("Escala \(scale.title)", systemImage: "ruler")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(ViewerPressStyle())
        .modifier(ViewerSurface(radius: 12))
        .accessibilityLabel("Escala AR")
        .accessibilityValue(scale.title)
    }
}

private struct ARScalePicker: View {
    let selection: LabARScale
    let space: LabARSpace
    let onSelect: (LabARScale) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(LabARScale.allCases, id: \.self) { scale in
                        Button {
                            onSelect(scale)
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                let ratio = Text(scale.title).font(.headline).foregroundStyle(.primary)
                                let dimensions = Text(space.scaled(to: scale).summary)
                                    .font(.subheadline).foregroundStyle(.secondary)
                                ViewThatFits(in: .horizontal) {
                                    if verticalSizeClass == .compact {
                                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                                            ratio.fixedSize()
                                            dimensions.fixedSize()
                                        }
                                    }
                                    VStack(alignment: .leading, spacing: 4) {
                                        ratio
                                        dimensions
                                    }
                                }
                                Spacer(minLength: 0)
                                if scale == selection {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Color.accentColor)
                                        .accessibilityHidden(true)
                                }
                            }
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                        .accessibilityElement(children: .combine)
                        .accessibilityAddTraits(scale == selection ? .isSelected : [])
                    }
                } header: {
                    Text("Espacio de referencia")
                } footer: {
                    Text("Ancho × fondo × alto y superficie de la sala virtual. Comprueba que el espacio esté libre antes de colocar el modelo.")
                }
            }
            .navigationTitle("Escala AR")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { DismissButton() }
        }
    }
}

private extension LabARSpace {
    var summary: String {
        let length = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0...3))
        let area = floorArea.formatted(.number.precision(.fractionLength(0...4)))
        return "\(size.x.formatted(length)) × \(size.z.formatted(length)) × \(size.y.formatted(length)) m · \(area) m²"
    }
}

struct ViewerSurface: ViewModifier {
    let radius: CGFloat
    var material: Material = .regular
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius)
        content
            .background {
                if reduceTransparency || contrast == .increased {
                    shape.fill(Color(uiColor: .secondarySystemBackground))
                } else {
                    shape.fill(material)
                }
            }
            .overlay {
                if contrast == .increased {
                    shape.strokeBorder(.primary.opacity(0.36)).allowsHitTesting(false)
                }
            }
    }
}

struct ViewerPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color.accentColor)
            .opacity(enabled ? (configuration.isPressed ? 0.62 : 1) : 0.35)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.94 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct WalkthroughHUD: View {
    let walkthrough: ARWalkthrough
    let layout: LabLayout
    let topology: LabTopology?
    let worldMapped: Bool
    let manualHome: Bool
    let mapSaved: Bool
    let scale: LabARScale
    let space: LabARSpace?
    let onSelectScale: (() -> Void)?
    let traceID: String?
    let showVirtualWalls: Bool
    let focusTargets: [LabFocusTarget]
    @Binding var lockedDeviceID: String?
    @Binding var showTraffic: Bool
    let showCables: Bool
    let onInspect: (LabSceneTarget) -> Void
    let onDismissTrace: () -> Void
    let onDetails: (LabTopology.Link) -> Void
    let onRealign: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicType

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                if let onSelectScale, dynamicType.isAccessibilitySize && geometry.size.height >= 360 {
                    VStack(alignment: .leading, spacing: 8) {
                        ARScaleButton(scale: scale, action: onSelectScale)
                        status
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    HStack(alignment: .top, spacing: 8) {
                        status
                            .frame(maxWidth: dynamicType.isAccessibilitySize ? .none : 320, alignment: .leading)
                        Spacer(minLength: 0)
                        if let onSelectScale {
                            ARScaleButton(scale: scale, action: onSelectScale)
                        } else if worldMapped && walkthrough.ready && !dynamicType.isAccessibilitySize && geometry.size.width >= 320 {
                            let device = topology.flatMap { network in
                                network.links.first { $0.id == traceID }.flatMap { network.circuit(for: $0).last?.toDeviceID }
                            }
                            let placement = topology?.devices.first { $0.id == (device ?? lockedDeviceID) }?.placementID
                            WalkthroughMap(layout: layout, walkthrough: walkthrough, destinationID: placement)
                        }
                    }
                }
                Spacer(minLength: 0)
                if walkthrough.ready {
                    HStack(alignment: .bottom) {
                        if showTraffic && showCables && topology?.links.isEmpty == false &&
                            !dynamicType.isAccessibilitySize && geometry.size.width >= (lockedDeviceID == nil ? 330 : 430) {
                            LabTrafficLegend()
                        }
                        Spacer(minLength: 4)
                        if !focusTargets.isEmpty {
                            LabFocusControls(targets: focusTargets, choose: chooseTarget, lockedID: lockedDeviceID,
                                             onLock: { lockedDeviceID = $0; tracedFocus($0) }, showTraffic: $showTraffic,
                                             onOpenDevice: { onInspect(.device($0)) })
                        }
                    }.padding(.bottom, 6)
                    let cap = max(56, geometry.size.height * (geometry.size.height < 360 ? 0.44 : 0.38))
                    ViewThatFits(in: .vertical) {
                        inspection.fixedSize(horizontal: false, vertical: true)
                        ScrollView { inspection }
                    }
                    .frame(maxWidth: 460, maxHeight: cap)
                    .modifier(ViewerSurface(radius: 18, material: .thick))
                    .transition(.opacity)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: walkthrough.ready)
        }
        .sensoryFeedback(.selection, trigger: traceID) { _, current in current != nil }
    }

    private func tracedFocus(_ id: String?) {
        if id != nil { onDismissTrace() }
    }

    private func chooseTarget(_ method: LabFocusMode) -> LabFocusTarget? {
        if method == .aim, let id = walkthrough.deviceInSight,
           let target = focusTargets.first(where: { $0.id == id }) { return target }
        guard let origin = walkthrough.focusOrigin else { return nil }
        let range: Float = method == .aim ? max(8, 0.8 / scale.factor) : max(3, 0.35 / scale.factor)
        return LabFocusTarget.pick(method, from: origin, direction: walkthrough.focusDirection,
                                   in: focusTargets, maximumDistance: range)
    }

    private var inspection: some View {
        ARInspectionControls(
            walkthrough: walkthrough, layout: layout, topology: topology,
            traceID: traceID, showVirtualWalls: showVirtualWalls, lockedDeviceID: lockedDeviceID,
            onInspect: onInspect, onDismissTrace: onDismissTrace, onDetails: onDetails)
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private var status: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch walkthrough.phase {
            case .preparing:
                message("Preparando la sala", detail: nil, loading: true)
            case .starting:
                message("Iniciando cámara", detail: "Mueve el iPhone despacio.", loading: true)
            case .aligning:
                message("Recuperando el anclaje", detail: manualHome ? "Apunta hacia el piso y las paredes de la ubicación guardada."
                        : "Apunta a las mismas paredes y esquinas del escaneo.", loading: true)
            case .placing:
                if manualHome {
                    message("Elige el lugar del rack", detail: walkthrough.placementHint ?? "Despeja el espacio. Apunta al piso y toca donde quedará el centro del rack.", icon: "hand.tap")
                } else {
                    message("Coloca la maqueta", detail: walkthrough.placementHint ?? "Apunta a una superficie horizontal y tócala.", icon: "hand.tap")
                }
                if let space {
                    Text(space.scaled(to: scale).summary).font(.caption).foregroundStyle(.secondary)
                }
            case .ready:
                let title = manualHome ? (mapSaved ? "Ubicación guardada" : "HomeLab anclado")
                                       : worldMapped ? "Anclado al cuarto" : "Maqueta colocada"
                message("\(title) · \(scale.title)",
                        detail: worldMapped && !mapSaved ? "Muévete despacio y apunta alrededor para guardar la ubicación." : nil,
                        icon: "viewfinder")
            case .limited(let detail):
                message("Buscando posición", detail: detail, icon: "viewfinder", recovery: true)
            case .interrupted:
                message("Cámara interrumpida", detail: "Apunta de nuevo al cuarto.", icon: "video.slash", recovery: true)
            case .failed(let detail):
                message("AR interrumpida", detail: detail, icon: "exclamationmark.triangle", recovery: true)
            }
        }
        .padding(10)
        .modifier(ViewerSurface(radius: 12))
        .accessibilityElement(children: .contain)
    }

    private func message(_ title: String, detail: String?, icon: String = "viewfinder",
                         loading: Bool = false, recovery: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                if loading { ProgressView().controlSize(.small).accessibilityHidden(true) }
                else { Image(systemName: icon).foregroundStyle(Color.accentColor).accessibilityHidden(true) }
                Text(title).font(.subheadline.weight(.semibold))
            }
            if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
            if recovery && worldMapped && mapSaved {
                Button("Volver a alinear", action: onRealign)
                    .font(.subheadline.weight(.semibold)).frame(minHeight: 44)
            }
        }
    }
}

private struct AimingReticle: View {
    let walkthrough: ARWalkthrough

    var body: some View {
        if walkthrough.ready {
            Image(systemName: "scope")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(walkthrough.target == nil ? Color.white : Color.yellow)
                .shadow(color: .black, radius: 3)
        }
    }
}

private struct WalkthroughMap: View {
    let layout: LabLayout
    let walkthrough: ARWalkthrough
    let destinationID: String?

    var body: some View {
        let pose = walkthrough.pose
        let inside = pose.map { LabGeometry.contains($0.position, polygon: layout.floorPolygon) } ?? false
        if let pose {
            VStack(alignment: .leading, spacing: 2) {
                Canvas { context, size in
                    let polygon = layout.floorPolygon
                    let lower = polygon.reduce(SIMD2<Float>(repeating: .infinity)) { simd_min($0, $1) }
                    let upper = polygon.reduce(SIMD2<Float>(repeating: -.infinity)) { simd_max($0, $1) }
                    let extent = upper - lower
                    let scale = min(Float(size.width - 10) / extent.x, Float(size.height - 10) / extent.y)
                    let center = (lower + upper) / 2
                    func point(_ p: SIMD2<Float>) -> CGPoint {
                        CGPoint(x: size.width / 2 + CGFloat((p.x - center.x) * scale),
                                y: size.height / 2 + CGFloat((p.y - center.y) * scale))
                    }
                    func shape(_ vertices: [SIMD2<Float>]) -> Path {
                        Path { path in
                            guard let first = vertices.first else { return }
                            path.move(to: point(first))
                            for vertex in vertices.dropFirst() { path.addLine(to: point(vertex)) }
                            path.closeSubpath()
                        }
                    }
                    let floor = shape(polygon)
                    context.fill(floor, with: .color(.secondary.opacity(0.14)))
                    context.stroke(floor, with: .color(.secondary), lineWidth: 1)
                    for placement in layout.placements {
                        let c = SIMD2(placement.position.x, placement.position.z)
                        let right = SIMD2(cos(placement.yaw), -sin(placement.yaw)) * placement.size.x / 2
                        let back = SIMD2(sin(placement.yaw), cos(placement.yaw)) * placement.size.z / 2
                        let footprint = shape([c - right - back, c + right - back, c + right + back, c - right + back])
                        context.fill(footprint, with: .color(.secondary))
                        if destinationID == placement.id {
                            context.stroke(footprint, with: .color(.orange), lineWidth: 2)
                        }
                    }
                    if inside {
                        let p = point(pose.position)
                        let direction = pose.direction / max(simd_length(pose.direction), 0.001)
                        let dot = CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)
                        let heading = Path { path in
                            path.move(to: p)
                            path.addLine(to: CGPoint(x: p.x + CGFloat(direction.x * 11), y: p.y + CGFloat(direction.y * 11)))
                        }
                        context.stroke(heading, with: .color(.cyan), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        context.fill(Path(ellipseIn: dot), with: .color(.cyan))
                    }
                }.frame(height: 72).accessibilityHidden(true)
                Label(inside ? "Tu posición" : "Fuera del cuarto", systemImage: "location.fill")
                    .font(.caption2.weight(.semibold))
            }
            .padding(8).frame(width: 116)
            .modifier(ViewerSurface(radius: 12))
            .allowsHitTesting(false)
        }
    }
}

private struct ARInspectionControls: View {
    let walkthrough: ARWalkthrough
    let layout: LabLayout
    let topology: LabTopology?
    let traceID: String?
    let showVirtualWalls: Bool
    let lockedDeviceID: String?
    let onInspect: (LabSceneTarget) -> Void
    let onDismissTrace: () -> Void
    let onDetails: (LabTopology.Link) -> Void

    var body: some View {
        let target: LabSceneTarget? = if case .link = walkthrough.target {
            walkthrough.target
        } else { lockedDeviceID.map { .device($0) } ?? walkthrough.target }
        VStack(alignment: .leading, spacing: 8) {
            if let topology, let link = topology.links.first(where: { $0.id == traceID }) {
                let circuit = topology.circuit(for: link)
                let first = circuit.first ?? link
                let last = circuit.last ?? link
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label("Ruta del cable", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                            .font(.subheadline.bold())
                        Spacer()
                        Button(action: onDismissTrace) {
                            Image(systemName: "xmark.circle.fill").frame(minWidth: 44, minHeight: 44)
                        }.buttonStyle(.plain).accessibilityLabel("Quitar resaltado")
                    }
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 12) {
                            endpoint("Origen", deviceID: first.fromDeviceID, port: first.fromPort).fixedSize()
                            endpoint("Destino", deviceID: last.toDeviceID, port: last.toPort).fixedSize()
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            endpoint("Origen", deviceID: first.fromDeviceID, port: first.fromPort)
                            endpoint("Destino", deviceID: last.toDeviceID, port: last.toPort)
                        }
                    }
                    HStack {
                        Text(circuit.allSatisfy { walkthrough.renderedLinks.contains($0.id) }
                             ? "Sigue el cable resaltado en amarillo."
                             : "Consulta los extremos en la ficha. Este tramo no tiene una ruta 3D válida.")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        Button("Ficha") { onDetails(link) }.font(.subheadline.weight(.semibold)).frame(minHeight: 44)
                    }
                }
                Divider()
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { aimAction(target) }
                VStack(alignment: .leading, spacing: 6) { aimAction(target) }
            }
            if showVirtualWalls {
                Label("Paredes virtuales activas. Los objetos físicos siguen en el cuarto.", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private func aimAction(_ target: LabSceneTarget?) -> some View {
        Text(target.map { name($0) } ?? "Apunta a un cable, puerto o equipo.")
            .font(.subheadline)
            .frame(maxWidth: .infinity, alignment: .leading)
        if let target {
            Button { onInspect(target) } label: {
                Text(actionName(target)).fontWeight(.semibold)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    private func actionName(_ target: LabSceneTarget) -> String {
        if case .link = target { return "¿Adónde va?" }
        return "Inspeccionar"
    }

    private func name(_ target: LabSceneTarget) -> String {
        switch target {
        case .link: return "Cable en la mira"
        case .device(let id): return topology?.devices.first { $0.id == id }?.name ?? id
        case .hardware(let id): return HardwareCatalog.reference(id)?.name ?? id
        case .placement(let id): return layout.placements.first { $0.id == id }?.title ?? id
        }
    }

    private func endpoint(_ title: String, deviceID: String, port: String) -> some View {
        let device = topology?.devices.first { $0.id == deviceID }
        let place = layout.placements.first { $0.id == device?.placementID }?.title
        return VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            Text("\(device?.name ?? deviceID) · \(device?.sourcePortNames?[port] ?? port)")
                .font(.subheadline.weight(.medium))
            if let place { Text(place).font(.caption).foregroundStyle(.secondary) }
        }.accessibilityElement(children: .combine)
    }
}

private struct PlacementInspector: View {
    let placement: LabPlacement
    let topology: LabTopology?
    var locateTitle = "Ver en 3D"
    var onLocate: ((LabInspectionDestination) -> Void)? = nil
    @Binding var poweredOff: Set<String>
    private var referenceItems: [HardwareItem] {
        let ids = placement.kind == .rack
            ? ["rack-r42612", "switch-2960", "switch-3560", "router-1941", "router-2911", "firewall-asa5505", "server-c220m5"]
            : ["pc-optiplex7010", "laptop-latitude5420", "phone-7960"]
        return ids.compactMap(HardwareCatalog.item)
    }
    var body: some View {
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
            if let topology {
                let devices = topology.devices.filter { $0.placementID == placement.id }
                if !devices.isEmpty {
                    Section("Dispositivos instalados") {
                        ForEach(devices) { device in
                            NavigationLink(device.name) {
                                DeviceInspector(device: device, topology: topology,
                                                locateTitle: locateTitle, onLocate: onLocate)
                            }
                        }
                    }
                }
            } else {
                Section("Modelos de referencia") {
                    ForEach(referenceItems) { item in
                        NavigationLink(item.name) { HardwareDetail(item: item) }
                    }
                }
            }
        }
        .navigationTitle(placement.title)
        .navigationBarTitleDisplayMode(.inline)
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
