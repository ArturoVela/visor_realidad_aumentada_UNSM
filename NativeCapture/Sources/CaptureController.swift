import ARKit
import AVFoundation
import Observation
import RoomPlan
import SwiftUI

@Observable
final class CaptureController {
    enum Phase: Equatable { case ready, restoring, permission, capturing, processing, saved, failed(String) }
    private(set) var phase: Phase = .ready
    private(set) var savedURL: URL?
    private(set) var summary = ""
    private(set) var room: RoomStructure?
    private(set) var layout: LabLayout?
    private(set) var arSession: ARSession?
    private(set) var hasSavedWorldMap = false
    private(set) var cameraStatusString: String?
    let isSupported = RoomCaptureSession.isSupported
    let supportsMesh = ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
    @ObservationIgnored private(set) var captureView: RoomCaptureView?
    @ObservationIgnored private var delegate: CaptureDelegate?
    @ObservationIgnored private var activeID: UUID?
    @ObservationIgnored private var processingTask: Task<Void, Never>?
    @ObservationIgnored private var diagnosticsTask: Task<Void, Never>?
    @ObservationIgnored private var liveSession: ARSession?
    @ObservationIgnored private var retainedCaptureView: RoomCaptureView?
    @ObservationIgnored private var didRestore = false
    @ObservationIgnored private var captureSite = "principal"

    var isBusy: Bool { phase == .restoring || phase == .permission || phase == .capturing || phase == .processing }

    func selectSite(_ site: String) async {
        if site != captureSite {
            cancel()
            arSession?.pause()
            arSession = nil
            retainedCaptureView = nil
            room = nil
            layout = nil
            savedURL = nil
            summary = ""
            hasSavedWorldMap = false
            didRestore = false
            phase = .ready
            captureSite = site
        }
        await restoreLatest()
    }

    func restoreLatest() async {
        guard !didRestore, !isBusy, room == nil else { return }
        didRestore = true
        let id = UUID()
        activeID = id
        phase = .restoring
        await Task.yield()
        do {
            let directory = try RoomStructure.captureDirectory(site: captureSite)
            guard FileManager.default.fileExists(atPath: directory.path) else {
                if activeID == id { activeID = nil; phase = .ready }
                return
            }
            let urls = try FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])
                .filter { $0.pathExtension.lowercased() == "json" && $0.lastPathComponent.hasPrefix("room-") }
                .sorted {
                    let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    return a > b
                }
            var lastError: (any Error)?
            for url in urls.prefix(20) {
                do {
                    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard size > 0, size <= 8 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .iso8601
                    let structure = try decoder.decode(RoomStructure.self, from: Data(contentsOf: url))
                    let plan = try LabLayoutPlanner.plan(room: structure)
                    guard activeID == id else { return }
                    room = structure
                    layout = plan
                    savedURL = url
                    hasSavedWorldMap = Self.worldMapURL(for: structure.roomID).map {
                        FileManager.default.fileExists(atPath: $0.path)
                    } ?? false
                    summary = Self.description(structure)
                    activeID = nil
                    phase = .saved
                    return
                } catch { lastError = error }
            }
            guard activeID == id else { return }
            activeID = nil
            if let lastError { phase = .failed("No se pudo abrir el escaneo guardado: \(lastError.localizedDescription). Puedes escanear de nuevo.") }
            else { phase = .ready }
        } catch {
            guard activeID == id else { return }
            fail(error.localizedDescription)
        }
    }

    func start() async {
        guard isSupported, !isBusy else { return }
        cameraStatusString = nil
        let id = UUID()
        activeID = id
        phase = .permission
        let authorized = await Self.requestCameraAccess()
        guard activeID == id, phase == .permission else { return }
        guard authorized else {
            fail("Cámara sin permiso. Autorízala en Ajustes para capturar el cuarto.")
            return
        }
        guard !Task.isCancelled else { cancel(); return }
        arSession?.pause()
        arSession = nil
        retainedCaptureView = nil
        let view = RoomCaptureView(frame: .zero)
        liveSession = view.captureSession.arSession
        let delegate = CaptureDelegate(controller: self, id: id)
        view.captureSession.delegate = delegate
        captureView = view
        self.delegate = delegate
        activeID = id
        phase = .capturing
    }

    static func requestCameraAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }

    func previewStarted() {
        guard phase == .capturing, let id = activeID else { return }
        diagnosticsTask?.cancel()
        writeCameraDiagnostic(event: "preview-started")
        diagnosticsTask = Task { [weak self] in
            for delay in [1, 3] {
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                guard let self, activeID == id, phase == .capturing else { return }
                writeCameraDiagnostic(event: delay == 1 ? "preview-after-1s" : "preview-after-4s")
                if delay == 3 {
                    if captureView?.captureSession.arSession.currentFrame == nil {
                        cameraStatusString = "La cámara no está enviando imágenes. El escaneo no puede continuar."
                    } else if captureView?.window == nil || (captureView?.bounds.width ?? 0) < 1
                                || (captureView?.bounds.height ?? 0) < 1 {
                        cameraStatusString = "La cámara está activa, pero la vista de captura no está visible."
                    }
                }
            }
            if self?.activeID == id { self?.diagnosticsTask = nil }
        }
    }

    func finish() {
        guard phase == .capturing else { return }
        guard let session = captureView?.captureSession.arSession, session.configuration != nil else {
            fail("RoomPlan no pudo iniciar la sesión AR. Vuelve a escanear el cuarto.")
            return
        }
        guard session.currentFrame != nil else {
            fail("El escaneo no recibió imágenes de cámara. Vuelve a iniciar la captura y espera a ver el cuarto antes de terminar.")
            return
        }
        diagnosticsTask?.cancel()
        diagnosticsTask = nil
        phase = .processing
        // Preserve tracking coordinates for the AR laboratory that follows the scan.
        captureView?.captureSession.stop(pauseARSession: false)
        writeCameraDiagnostic(event: "capture-stopped-for-processing")
    }

    func cancel() {
        guard isBusy else { return }
        if phase == .restoring { didRestore = false }
        let preview = captureView
        activeID = nil
        diagnosticsTask?.cancel()
        diagnosticsTask = nil
        processingTask?.cancel()
        processingTask = nil
        captureView?.captureSession.delegate = nil
        captureView?.captureSession.stop()
        captureView = nil
        delegate = nil
        liveSession?.pause()
        liveSession = nil
        phase = .ready
        writeCameraDiagnostic(event: "capture-cancelled", preview: preview)
    }

    func pauseAR() { arSession?.pause() }

    func resumeAR(realign: Bool = false) throws {
        guard !isBusy else { return }
        if !realign, let arSession, let configuration = arSession.configuration {
            arSession.run(configuration)
            return
        }
        guard let room, ARWorldTrackingConfiguration.isSupported, hasSavedWorldMap,
              let url = Self.worldMapURL(for: room.roomID) else {
            throw LabLayoutError.invalid("Este cuarto necesita un escaneo nuevo para alinearse con la cámara.")
        }
        do {
            let data = try Data(contentsOf: url)
            guard let map = try NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from: data) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let configuration = ARWorldTrackingConfiguration()
            configuration.initialWorldMap = map
            if supportsMesh { configuration.sceneReconstruction = .mesh }
            let session = ARSession()
            arSession?.pause()
            session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
            arSession = session
        } catch {
            hasSavedWorldMap = false
            throw LabLayoutError.invalid("No se pudo recuperar el mapa AR de este cuarto. Vuelve a escanearlo.")
        }
    }

    func saveWorldMapIfReady() async {
        guard !hasSavedWorldMap, let session = arSession, let frame = session.currentFrame,
              case .normal = frame.camera.trackingState,
              [.mapped, .extending].contains(frame.worldMappingStatus), let roomID = room?.roomID,
              let url = Self.worldMapURL(for: roomID) else { return }
        do {
            let map = try await session.currentWorldMap()
            try Task.checkCancellation()
            guard arSession === session, room?.roomID == roomID else { return }
            try Self.writeWorldMap(map, to: url)
            hasSavedWorldMap = true
        } catch {
            // A map may be temporarily unavailable. The 3D capture and live session stay usable.
        }
    }

    static let homePlacementName = "NexusAR.HomeLab.v1"

    static func placementMapURL(_ name: String) -> URL {
        let file = name == homePlacementName ? "HomeLab-v1" : name
        return URL.applicationSupportDirectory.appendingPathComponent("RoomWorldMaps", isDirectory: true)
            .appendingPathComponent(file).appendingPathExtension("arworldmap")
    }

    static func loadPlacementMap(_ name: String) throws -> ARWorldMap {
        let data = try Data(contentsOf: placementMapURL(name))
        guard let map = try NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from: data),
              map.anchors.contains(where: { $0.name == name }) else {
            throw LabLayoutError.invalid("El mapa guardado no contiene el punto de referencia.")
        }
        return map
    }

    static func writeWorldMap(_ map: ARWorldMap, to url: URL) throws {
        let data = try NSKeyedArchiver.archivedData(withRootObject: map, requiringSecureCoding: true)
        var directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try directory.setResourceValues(resourceValues)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
    }

    private static func worldMapURL(for roomID: UUID) -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("RoomWorldMaps", isDirectory: true)
            .appendingPathComponent(roomID.uuidString + ".arworldmap")
    }

    private static func description(_ room: RoomStructure) -> String {
        "\(room.surfaces.filter { $0.kind == .wall }.count) paredes · "
            + "\(room.surfaces.filter { $0.kind == .window }.count) ventanas"
    }

    fileprivate func ended(data: CapturedRoomData, error: (any Error)?, id: UUID) {
        guard id == activeID else { return }
        if let error { fail(error.localizedDescription); return }
        guard phase == .processing else {
            fail("Captura interrumpida. Inicia una captura nueva.")
            return
        }
        processingTask = Task {
            var capturedURL: URL?
            do {
                let room = try await RoomBuilder(options: []).capturedRoom(from: data)
                try Task.checkCancellation()
                guard activeID == id else { return }
                let structure = RoomStructure(room: room)
                let url = try structure.save(site: captureSite)
                capturedURL = url
                savedURL = url
                let plan = try LabLayoutPlanner.plan(room: structure)
                self.room = structure
                layout = plan
                summary = Self.description(structure)
                arSession = liveSession
                hasSavedWorldMap = false
                if supportsMesh, let configuration = liveSession?.configuration as? ARWorldTrackingConfiguration {
                    configuration.sceneReconstruction = .mesh
                    liveSession?.run(configuration)
                }
                retainedCaptureView = captureView
                captureView?.captureSession.delegate = nil
                captureView = nil
                delegate = nil
                liveSession = nil
                processingTask = nil
                activeID = nil
                phase = .saved
            } catch is CancellationError {
                // A cancelled capture never replaces an earlier saved file.
            } catch {
                guard activeID == id else { return }
                let message = capturedURL == nil ? error.localizedDescription
                    : "El escaneo quedó guardado y puedes compartirlo desde Más opciones. No se pudo generar el laboratorio: \(error.localizedDescription)"
                fail(message)
            }
            if activeID == id { processingTask = nil }
        }
    }

    private func fail(_ message: String) {
        let preview = captureView
        diagnosticsTask?.cancel()
        diagnosticsTask = nil
        captureView?.captureSession.delegate = nil
        captureView?.captureSession.stop()
        captureView = nil
        delegate = nil
        liveSession?.pause()
        liveSession = nil
        processingTask = nil
        activeID = nil
        phase = .failed(message)
        writeCameraDiagnostic(event: "capture-failed", preview: preview)
    }

    private func writeCameraDiagnostic(event: String, preview: RoomCaptureView? = nil) {
        let preview = preview ?? captureView
        let session = preview?.captureSession.arSession ?? liveSession ?? arSession
        let tracking: String
        if let frame = session?.currentFrame {
            switch frame.camera.trackingState {
            case .normal: tracking = "normal"
            case .notAvailable: tracking = "notAvailable"
            case .limited(let reason):
                switch reason {
                case .initializing: tracking = "limited.initializing"
                case .excessiveMotion: tracking = "limited.excessiveMotion"
                case .insufficientFeatures: tracking = "limited.insufficientFeatures"
                case .relocalizing: tracking = "limited.relocalizing"
                @unknown default: tracking = "limited.unknown"
                }
            }
        } else { tracking = "noFrame" }
        let authorization: String
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: authorization = "authorized"
        case .notDetermined: authorization = "notDetermined"
        case .denied: authorization = "denied"
        case .restricted: authorization = "restricted"
        @unknown default: authorization = "unknown"
        }
        let phaseName: String
        switch phase {
        case .ready: phaseName = "ready"
        case .restoring: phaseName = "restoring"
        case .permission: phaseName = "permission"
        case .capturing: phaseName = "capturing"
        case .processing: phaseName = "processing"
        case .saved: phaseName = "saved"
        case .failed: phaseName = "failed"
        }
        let snapshot = CameraDiagnostic(
            timestamp: .now, event: event, phase: phaseName, cameraAuthorization: authorization,
            isSupported: isSupported,
            configurationType: session?.configuration.map { String(describing: type(of: $0)) } ?? "none",
            hasCurrentFrame: session?.currentFrame != nil, trackingState: tracking,
            previewWidth: Double(preview?.bounds.width ?? 0), previewHeight: Double(preview?.bounds.height ?? 0),
            windowAttached: preview?.window != nil)
        do {
            let documents = try FileManager.default.url(
                for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let directory = documents.appendingPathComponent("Diagnostics", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(snapshot).write(to: directory.appendingPathComponent("capture-status.json"), options: .atomic)
        } catch {
            // Diagnostics are best effort; a storage error must not interrupt capture.
        }
    }
}

private nonisolated struct CameraDiagnostic: Encodable {
    let timestamp: Date
    let event: String
    let phase: String
    let cameraAuthorization: String
    let isSupported: Bool
    let configurationType: String
    let hasCurrentFrame: Bool
    let trackingState: String
    let previewWidth: Double
    let previewHeight: Double
    let windowAttached: Bool
}

private final class CaptureDelegate: RoomCaptureSessionDelegate {
    weak var controller: CaptureController?
    let id: UUID
    init(controller: CaptureController, id: UUID) { self.controller = controller; self.id = id }

    nonisolated func captureSession(_ session: RoomCaptureSession,
                                   didEndWith data: CapturedRoomData, error: (any Error)?) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            controller?.ended(data: data, error: error, id: id)
        }
    }
}

struct CapturePreview: UIViewRepresentable {
    let view: RoomCaptureView
    var onStarted: (@MainActor () -> Void)? = nil

    func makeUIView(context: Context) -> RoomCaptureView {
        var configuration = RoomCaptureSession.Configuration()
        configuration.isCoachingEnabled = true
        view.captureSession.run(configuration: configuration)
        onStarted?()
        return view
    }

    func updateUIView(_ uiView: RoomCaptureView, context: Context) {}
}
