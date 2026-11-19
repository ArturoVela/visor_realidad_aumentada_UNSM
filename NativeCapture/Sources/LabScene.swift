import ARKit
import Observation
import OSLog
import RealityKit
import SwiftUI
import simd

enum LabViewMode: String, CaseIterable, Identifiable {
    case room = "3D", ar = "AR"
    var id: String { rawValue }
}

enum LabSceneTarget: Equatable {
    case link(String), device(String), hardware(String), placement(String)
}

@Observable
final class ARWalkthrough {
    enum Phase: Equatable {
        case preparing, starting, aligning, placing, ready, limited(String), interrupted, failed(String)
    }

    struct Pose: Equatable {
        let position: SIMD2<Float>
        let direction: SIMD2<Float>
    }

    var phase: Phase = .preparing
    var ready: Bool { phase == .ready }
    var pose: Pose?
    var target: LabSceneTarget?
    var focusOrigin: SIMD3<Float>?
    var focusDirection = SIMD3<Float>(0, 0, -1)
    var deviceInSight: String?
    var renderedLinks = Set<String>()
    var placementConfirmed = false
    var placementHint: String?
}

struct LabSceneView: UIViewRepresentable {
    let room: RoomStructure
    let layout: LabLayout
    let arSession: ARSession?
    let mode: LabViewMode
    var paintRoom: Bool
    var poweredOff: Set<String>
    @Binding var selection: LabPlacement?
    @Binding var trackingMessage: String?
    var onSelectHardware: (String) -> Void = { _ in }
    var topology: LabTopology? = nil
    var showCables: Bool = true
    var selectedLinkID: String? = nil
    var onSelectDevice: (String) -> Void = { _ in }
    var onSelectLink: (String) -> Void = { _ in }
    var sceneScale: Float = 1
    var arPlacementRequired: Bool = false
    var zoomStep: Int = 0
    var orbitReset: Int = 0
    var focusDeviceID: String? = nil
    var inspectionDestination: LabInspectionDestination? = nil
    var inspectionRevision: Int = 0
    var walkthrough: ARWalkthrough? = nil
    var isForeground = true
    var stereoEye: Float = 0
    var virtualPose: LabWalkPose? = nil
    var sceneReady: () -> Void = {}
    var worldPlacementName: String? = nil
    var restoresWorldPlacement = false
    var lockedDeviceID: String? = nil
    var showTraffic = true
    var topologyRevision = 0
    var physicalOcclusion = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> ARView {
        let view = LabRenderView(frame: .zero, cameraMode: mode == .ar ? .ar : .nonAR,
                                 automaticallyConfigureSession: false)
        context.coordinator.view = view
        view.didLayout = { [weak coordinator = context.coordinator] size in coordinator?.layoutCamera(to: size) }
        if mode == .ar {
            view.environment.background = .cameraFeed()
            if let arSession {
                view.session = arSession
                arSession.delegateQueue = .main
                arSession.delegate = context.coordinator
                if physicalOcclusion, ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
                    view.environment.sceneUnderstanding.options.insert(.occlusion)
                }
            } else {
                context.coordinator.report("Falta la sesión AR. Vuelve al cuarto o abre su escaneo.")
            }
        } else {
            context.coordinator.updateBackground()
        }
        if mode == .ar {
            view.didAttach = { [weak coordinator = context.coordinator] in coordinator?.prepareScene() }

        }
        if mode == .room && virtualPose == nil {
            let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pan(_:)))
            let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pinch(_:)))
            pan.maximumNumberOfTouches = 2
            pan.delegate = context.coordinator; pinch.delegate = context.coordinator
            view.addGestureRecognizer(pan); view.addGestureRecognizer(pinch)
        }
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tap(_:)))
        tap.cancelsTouchesInView = false
        view.addGestureRecognizer(tap)
        if mode == .room { context.coordinator.rebuildIfNeeded() }
        return view
    }

    func updateUIView(_ view: ARView, context: Context) {
        let topologyChanged = context.coordinator.parent.topologyRevision != topologyRevision
        context.coordinator.parent = self
        if mode == .room { context.coordinator.updateBackground() }
        if mode == .ar, ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            let enabled = view.environment.sceneUnderstanding.options.contains(.occlusion)
            if physicalOcclusion != enabled {
                if physicalOcclusion { view.environment.sceneUnderstanding.options.insert(.occlusion) }
                else { view.environment.sceneUnderstanding.options.remove(.occlusion) }
            }
        }
        guard mode == .room || context.coordinator.canBuildScene else { return }
        if virtualPose != nil {
            if topologyChanged { context.coordinator.rebuildIfNeeded() }
            context.coordinator.updateWalkCamera()
            context.coordinator.updateState()
            return
        }
        if mode == .ar && !isForeground { context.coordinator.hideTrackedContent(); return }
        context.coordinator.rebuildIfNeeded()
        context.coordinator.applyZoom()
        context.coordinator.updateState()
    }

    static func dismantleUIView(_ view: ARView, coordinator: Coordinator) {
        if view.session.delegate === coordinator { view.session.delegate = nil }
        view.scene.anchors.removeAll()
        coordinator.stopRendering()
        // CaptureController owns session lifetime. Changing view must not pause or reset it.
    }

    final class Coordinator: NSObject, ARSessionDelegate, UIGestureRecognizerDelegate {
        var parent: LabSceneView
        weak var view: ARView?
        private var lastRoomID: UUID?
        private var lastPlacements: [LabPlacement] = []
        private var lastTopology: LabTopology?
        private var lastFacility: TierFacility?
        private var roomEntity: Entity?
        private var rootAnchor: AnchorEntity?
        private var scaledContent: Entity?
        private var awaitingPlacement = false
        private var placedAnchorID: UUID?
        private var tracking = false
        private(set) var canBuildScene = false
        private var prepareTask: Task<Void, Never>?
        private var lastFrameTime = -Double.infinity
        private var cablesEntity: Entity?
        private var portLabelsEntity: Entity?
        private var lastSelectedLinkID: String?
        private var lastInspectedPort: LabInspectionDestination?
        private var lastInspectionRevision: Int?
        private var linkBodies: [String: ModelEntity] = [:]
        private var traceBodies: [String: ModelEntity] = [:]
        private var deviceHighlights: [String: Entity] = [:]
        private var highlightedDevice: Entity?
        private var lastLockedDeviceID: String?
        private var lastWalkPose: LabWalkPose?
        private var lastWalkLock: String?
        private var cameraTurn: AnimationPlaybackController?

        private struct TrafficCircuit {
            let id: String
            let devices: Set<String>
            let poweredEndpoints: Set<String>
            let portsEnabled: Bool
            let route: LabTrafficRoute
            let cableRadius: Float
            let greenLEDs: ModelEntity
            let amberLEDs: [(atStart: Bool, entity: ModelEntity)]
        }

        private struct TrafficSettings: Equatable {
            let enabled: Bool
            let reducedMotion: Bool
            let poweredOff: Set<String>
            let trace: String?
            let focus: String?
        }

        private var trafficCircuits: [TrafficCircuit] = []
        private var trafficSettings: TrafficSettings?
        private var activeTraffic: [Int] = []
        private var pulsePairs: [[ModelEntity]] = []
        private var trafficTask: Task<Void, Never>?
        private var portHits: [ObjectIdentifier: LabScenePort] = [:]
        private var devicePowerParents: [String: String] = [:]
        private var indicators: [String: [ModelEntity]] = [:]
        private var screens: [String: [ModelEntity]] = [:]
        private var consoleScreens: [String: [Entity]] = [:]
        private var dashboards: [(device: LabTopology.Device, led: ModelEntity, bars: [ModelEntity])] = []
        private var lastDashboardRefresh: TimeInterval = -.infinity
        private var highlights: [String: Entity] = [:]
        private var hardwareTemplates: [String: Entity] = [:]
        private var labelMaterials: [String: UnlitMaterial] = [:]
        private var renderError: String?
        private var lastPoweredOff: Set<String>?
        private weak var selectedHardwareHighlight: Entity?
        private var camera: PerspectiveCamera?
        private var cameraTarget = SIMD3<Float>.zero
        private var defaultCameraTarget = SIMD3<Float>.zero
        private var cameraRadius: Float = 6
        private var cameraYaw: Float = .pi / 4
        private var cameraPitch: Float = 0.75
        private var cameraBounds: [SIMD3<Float>] = []
        private var lastColorScheme: ColorScheme?
        private let orbitFieldOfView: Float = 55
        private var cameraMoved = false
        private var lastZoomStep = 0
        private var lastOrbitReset: Int
        private var lastFocusKey: String?
        private let materials = LabSceneMaterials()

        init(parent: LabSceneView) {
            self.parent = parent
            lastOrbitReset = parent.orbitReset
        }

        func updateBackground() {
            guard let view, lastColorScheme != parent.colorScheme else { return }
            lastColorScheme = parent.colorScheme
            let background: UIColor
            if parent.stereoEye != 0 { background = .black }
            else if parent.colorScheme == .dark { background = UIColor(red: 0.09, green: 0.12, blue: 0.16, alpha: 1) }
            else { background = UIColor(red: 0.91, green: 0.93, blue: 0.95, alpha: 1) }
            view.environment.background = .color(background)
        }

        func prepareScene() {
            guard prepareTask == nil, !canBuildScene, parent.mode == .room || parent.arSession != nil else { return }
            prepareTask = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .milliseconds(20)) } catch { return }
                guard let self, let view, view.window != nil else {
                    self?.prepareTask = nil
                    return
                }
                canBuildScene = true
                prepareTask = nil
                rebuildIfNeeded()
            }
        }

        func stopRendering() {
            prepareTask?.cancel()
            trafficTask?.cancel()
            cameraTurn?.stop()
            view = nil
        }

        func rebuildIfNeeded() {
            guard let view, lastRoomID != parent.room.roomID || lastPlacements != parent.layout.placements
                    || lastTopology != parent.topology || lastFacility != parent.layout.facility else { return }
            let reframe = lastRoomID != parent.room.roomID || lastPlacements != parent.layout.placements
            do {
                if let topology = parent.topology {
                    guard topology.devices.count <= 96, topology.links.count <= 192 else {
                        throw LabLayoutError.invalid("La vista admite hasta 96 dispositivos y 192 conexiones.")
                    }
                    try topology.validate()
                }
                let anchor = AnchorEntity(world: .zero)
                let content = Entity()
                anchor.addChild(content)
                let structure = try makeRoom()
                content.addChild(structure)
                indicators.removeAll(); screens.removeAll(); consoleScreens.removeAll(); dashboards.removeAll(); highlights.removeAll()
                deviceHighlights.removeAll()
                highlightedDevice = nil
                lastLockedDeviceID = nil
                lastWalkPose = nil
                trafficTask?.cancel(); trafficTask = nil
                trafficCircuits.removeAll(); pulsePairs.removeAll(); trafficSettings = nil
                portHits.removeAll(); devicePowerParents.removeAll(); linkBodies.removeAll(); traceBodies.removeAll()
                guard parent.layout.placements.filter({ $0.kind == .rack }).count <= 12,
                      parent.layout.placements.filter({ $0.kind == .workstation }).count <= 24 else {
                    throw LabLayoutError.invalid("La vista admite hasta 12 racks y 24 puestos.")
                }
                electricalLeads.removeAll()
                for placement in parent.layout.placements {
                    let object = try makePlacement(placement)
                    content.addChild(object)
                }
                electricalEntity = nil
                if let facility = parent.layout.facility { content.addChild(try makeFacility(facility)) }
                if let topology = parent.topology {
                    let cables = try makeCables(topology, lights: content)
                    content.addChild(cables)
                    cablesEntity = cables
                    let labels = Entity(); content.addChild(labels); portLabelsEntity = labels
                } else { cablesEntity = nil; portLabelsEntity = nil }
                let light = DirectionalLight()
                light.light.intensity = 1800
                light.look(at: SIMD3(0, -1, 0), from: SIMD3(2, 6, -3), relativeTo: nil)
                anchor.addChild(light)
                let fill = DirectionalLight()
                fill.light.intensity = 900
                fill.look(at: SIMD3(0, -1, 0), from: SIMD3(-3, 5, 4), relativeTo: nil)
                anchor.addChild(fill)
                if parent.mode == .room {
                    if reframe || camera == nil {
                        let polygon = parent.layout.floorPolygon
                        let lower = polygon.reduce(SIMD2<Float>(repeating: .infinity)) { simd_min($0, $1) }
                        let upper = polygon.reduce(SIMD2<Float>(repeating: -.infinity)) { simd_max($0, $1) }
                        let floor = parent.layout.floorHeight
                        let height = parent.layout.facility?.height ?? max(0.65, parent.layout.placements.map(\.size.y).max() ?? 0)
                        cameraTarget = SIMD3((lower.x + upper.x) / 2, floor + height * 0.38, (lower.y + upper.y) / 2)
                        defaultCameraTarget = cameraTarget
                        cameraBounds = polygon.flatMap { point in
                            [SIMD3(point.x, floor, point.y), SIMD3(point.x, floor + height, point.y)]
                        }
                        cameraMoved = false; cameraYaw = .pi / 4; cameraPitch = 0.75
                    }
                    let camera = PerspectiveCamera()
                    camera.camera.fieldOfViewInDegrees = parent.virtualPose == nil ? orbitFieldOfView : 60
                    if #available(iOS 18, *) { camera.camera.fieldOfViewOrientation = .vertical }
                    camera.camera.near = 0.03
                    camera.camera.far = 250
                    self.camera = camera
                    if parent.virtualPose != nil { updateWalkCamera() }
                    anchor.addChild(camera)
                }
                view.scene.anchors.removeAll()
                scaledContent = content
                awaitingPlacement = parent.mode == .ar && parent.arPlacementRequired
                anchor.isEnabled = parent.mode == .room
                view.scene.addAnchor(anchor)
                rootAnchor = anchor
                if parent.mode == .room && parent.virtualPose == nil {
                    updateCamera()
                    fitCamera(to: view.bounds.size)
                }
                roomEntity = structure
                #if DEBUG
                if let topology = parent.topology {
                    let missing = topology.links.filter { linkBodies[$0.id] == nil }.map(\.id)
                    Logger(subsystem: "org.unsm.NexusRoomCapture", category: "scene")
                        .info("Cableado de \(topology.name, privacy: .public): \(self.linkBodies.count)/\(topology.links.count). Omitidos: \(missing.joined(separator: ", "), privacy: .public)")
                }
                #endif
                lastRoomID = parent.room.roomID
                lastPlacements = parent.layout.placements
                lastTopology = parent.topology
                lastFacility = parent.layout.facility
                lastSelectedLinkID = nil
                lastInspectedPort = nil
                lastInspectionRevision = nil
                lastPoweredOff = nil
                renderError = nil
                updateState()
                if parent.virtualPose != nil {
                    Task { @MainActor [weak self] in self?.parent.sceneReady() }
                }
                if parent.mode == .ar {
                    parent.walkthrough?.renderedLinks = Set(linkBodies.keys)
                    let state = view.session.currentFrame?.camera.trackingState
                    if state == nil { suspend(.starting) }
                }
            } catch { renderError = error.localizedDescription; report(error.localizedDescription) }
        }

        private func makeRoom() throws -> Entity {
            var batch = LabSceneMesh(), floor = LabSceneMesh()
            let surfaces = parent.room.surfaces
            for surface in surfaces {
                guard surface.curve == nil else { throw LabLayoutError.invalid("La vista todavía no admite superficies curvas. Corrige esa captura.") }
                let matrix = try LabGeometry.matrix(surface)
                if surface.kind == .floor {
                    let points = try surface.polygonCorners.map { corner -> SIMD3<Float> in
                        guard corner.count == 3 else { throw LabLayoutError.invalid("Esquina de suelo incompleta.") }
                        return try LabGeometry.worldPoint(surface, SIMD3(corner[0], corner[1], corner[2]))
                    }
                    var indices = try LabGeometry.triangulate(points.map { SIMD2($0.x, $0.z) })
                    for i in stride(from: 0, to: indices.count, by: 3) {
                        let a = points[Int(indices[i])], b = points[Int(indices[i + 1])], c = points[Int(indices[i + 2])]
                        if simd_cross(b - a, c - a).y < 0 { indices.swapAt(i + 1, i + 2) }
                    }
                    floor.append(positions: points, normals: Array(repeating: SIMD3(0, 1, 0), count: points.count), indices: indices.map(UInt32.init))
                } else if surface.kind == .wall {
                    guard surface.polygonCorners.isEmpty, surface.dimensions[2] <= 0.005 else {
                        throw LabLayoutError.invalid("Muro no rectangular o no plano: la vista no cerrará ese contorno por aproximación.")
                    }
                    let holes = try surfaces.filter { [.window, .door, .opening].contains($0.kind) && $0.parentID == surface.id }
                        .map { try holeRect($0, wall: surface) }
                    guard holes.count <= 32 else { throw LabLayoutError.invalid("Demasiadas aberturas en una pared.") }
                    let halfW = surface.dimensions[0] / 2, halfH = surface.dimensions[1] / 2
                    let cutHeight = parent.layout.floorHeight + 0.65
                    let localCut = matrix.columns.1.y > 0
                        ? (cutHeight - matrix.columns.3.y) / matrix.columns.1.y : halfH
                    let visibleTop = parent.mode == .room && parent.virtualPose == nil
                        ? min(halfH, max(-halfH, localCut)) : halfH
                    if visibleTop <= -halfH { continue }
                    let xs = Array(Set([-halfW, halfW] + holes.flatMap { [Float($0.minX), Float($0.maxX)] })).sorted()
                    let ys = Array(Set([-halfH, visibleTop] + holes.flatMap { [Float($0.minY), Float($0.maxY)] }
                        .filter { $0 > -halfH && $0 < visibleTop })).sorted()
                    for x in 0..<(xs.count - 1) {
                        for y in 0..<(ys.count - 1) {
                            let width = xs[x + 1] - xs[x], height = ys[y + 1] - ys[y]
                            let center = SIMD3((xs[x] + xs[x + 1]) / 2, (ys[y] + ys[y + 1]) / 2, 0)
                            if width > 0.00001, height > 0.00001,
                               !holes.contains(where: { $0.contains(CGPoint(x: CGFloat(center.x), y: CGFloat(center.y))) }) {
                                // ponytail: 8 cm is visual thickness, never a measured building property.
                                batch.box(size: SIMD3(width, height, 0.08), center: center, matrix: matrix)
                            }
                        }
                    }
                }
            }
            for opening in surfaces where [.window, .door, .opening].contains(opening.kind) {
                guard surfaces.contains(where: { $0.kind == .wall && $0.id == opening.parentID }) else {
                    throw LabLayoutError.invalid("Hay una abertura sin pared padre. No se representará como muro cerrado.")
                }
            }
            let entity = Entity()
            entity.name = "Paredes y suelo del cuarto"
            let tier = parent.layout.facility != nil
            if !batch.indices.isEmpty { entity.addChild(try batch.model(material: tier ? materials.facilityWall : materials.white)) }
            if !floor.indices.isEmpty { entity.addChild(try floor.model(material: tier ? materials.facilityFloor : materials.white)) }
            return entity
        }

        private func makeFacility(_ facility: TierFacility) throws -> Entity {
            let root = Entity()
            root.position = facility.origin
            root.orientation = simd_quatf(angle: facility.yaw, axis: SIMD3(0, 1, 0))
            var partitions = LabSceneMesh(), coldAisle = LabSceneMesh(), hotAisle = LabSceneMesh()
            let cutaway = parent.mode == .room && parent.virtualPose == nil
            let wallHeight = cutaway ? 0.47 : facility.height - 0.23
            func panel(_ x: Float, _ z: Float, _ width: Float, _ depth: Float) {
                partitions.box(size: SIMD3(width, wallHeight, depth), center: SIMD3(x, wallHeight / 2, z))
            }
            // Leave the 1.5 m operator opening and technical access at the ends of the two bay walls.
            panel(-0.55, 2.67, 9.6, 0.12)
            panel(6.18, 2.67, 0.86, 0.12)
            panel(5.17, -2.91, 0.12, 3.28)
            if cutaway {
                panel(-5.17, -2.91, 0.12, 3.28)
            } else {
                let penetration = TierFacility.conduitAZ
                let zLimits: [Float] = [-4.55, penetration - 0.065, penetration + 0.065, -1.27]
                for (start, end) in [(zLimits[0], zLimits[1]), (zLimits[2], zLimits[3])] {
                    panel(-5.17, (start + end) / 2, 0.12, end - start)
                }
                let lower = facility.conduitHeight - 0.065, upper = facility.conduitHeight + 0.065
                partitions.box(size: SIMD3(0.12, lower, 0.13), center: SIMD3(-5.17, lower / 2, penetration))
                if upper < wallHeight {
                    partitions.box(size: SIMD3(0.12, wallHeight - upper, 0.13),
                                   center: SIMD3(-5.17, (wallHeight + upper) / 2, penetration))
                }
            }
            root.addChild(try partitions.model(material: materials.facilityWall))
            coldAisle.box(size: SIMD3(9, 0.002, 1.52), center: SIMD3(0, 0.002, -0.57))
            for z: Float in [-3.46, 2.12] {
                hotAisle.box(size: SIMD3(9, 0.002, 0.82), center: SIMD3(0, 0.002, z))
            }
            root.addChild(try coldAisle.model(material: materials.coldAisle))
            root.addChild(try hotAisle.model(material: materials.hotAisle))
            var grilles = LabSceneMesh()
            var louvers = LabSceneMesh()
            for column in -2...2 {
                let x = Float(column) * 1.6
                grilles.box(size: SIMD3(0.51, 0.008, 0.44), center: SIMD3(x, 0.005, -0.57))
                for row in 0..<10 {
                    louvers.box(size: SIMD3(0.465, 0.003, 0.011), center: SIMD3(x, 0.011, -0.75 + Float(row) * 0.04))
                }
            }
            root.addChild(try grilles.model(material: materials.metal))
            root.addChild(try louvers.model(material: materials.dark))


            for (name, x, z) in [("PASILLO FRÍO", Float(0), Float(-0.59)), ("PASILLO CALIENTE", 0, -3.47),
                                 ("OPERACIÓN · VLAN 20", 0, 5.03)] {
                let sign = try label(name, width: 1.75, height: 0.17)
                sign.position = SIMD3(x, 0.006, z)
                sign.orientation = simd_quatf(angle: -.pi / 2, axis: SIMD3(1, 0, 0))
                root.addChild(sign)
            }
            let rackSize = HardwareCatalog.renderSize("rack-r42612")
            let partsMaterials: [any RealityKit.Material] = [materials.graphite, materials.panel, materials.metal,
                                                            materials.dark, materials.power, materials.screen]
            for side: Float in [-1, 1] {
                let circuit = side < 0 ? "A" : "B"
                let cabinet = Entity()
                cabinet.position = SIMD3(side * 6.15, 0, -3.55)
                cabinet.orientation = simd_quatf(angle: .pi, axis: SIMD3(0, 1, 0))
                for (index, mesh) in rackMeshes(rackSize).enumerated() where !mesh.indices.isEmpty {
                    cabinet.addChild(try mesh.model(material: partsMaterials[index]))
                }
                let title = try label("UPS + BATERÍAS \(circuit)", width: 0.51, height: 0.027)
                title.position = SIMD3(0, rackSize.y - 0.026, -rackSize.z / 2 - 0.003)
                cabinet.addChild(title)
                for (id, slot) in [("battery-9px", 2), ("battery-9px", 5), ("battery-9px", 8), ("ups-9px", 13), ("ups-9px", 17)] {
                    let unit = try makeFacilityEquipment(id, circuit: circuit)
                    let size = HardwareCatalog.reference(id)!.size!
                    let y = RackMount.base + Float(slot) * RackMount.unit + size.y / 2
                    unit.position = SIMD3(0, y, -rackSize.z / 2 + RackMount.frontInset + size.z / 2)
                    cabinet.addChild(unit)
                }
                root.addChild(cabinet)
                var switchboard = LabSceneMesh(), breakers = LabSceneMesh()
                let board = SIMD3<Float>(side * 6.62, 0.98, -1.86)
                switchboard.box(size: SIMD3(0.51, 1.30, 0.24), center: board)
                for row in 0..<3 {
                    for column in 0..<4 {
                        breakers.box(size: SIMD3(0.032, 0.044, 0.012),
                            center: board + SIMD3((Float(column) - 1.5) * 0.047, 0.24 - Float(row) * 0.19, 0.122))
                    }
                }
                root.addChild(try switchboard.model(material: materials.panel))
                root.addChild(try breakers.model(material: materials.dark))
                let incoming = try label("TABLERO \(circuit) · ENTRADA EXTERIOR", width: 0.45, height: 0.028)
                incoming.position = board + SIMD3(0, 0.58, 0.124)
                incoming.orientation = simd_quatf(angle: 0, axis: SIMD3(0, 1, 0))
                root.addChild(incoming)

                for (row, z) in [(0, Float(-2.1)), (1, Float(0.95))] {
                    let cooling = try makeFacilityEquipment("cooling-inrow", circuit: circuit)
                    cooling.position = SIMD3(side * 1.84, 1.991 / 2, z)
                    cooling.orientation = simd_quatf(angle: row == 0 ? .pi : 0, axis: SIMD3(0, 1, 0))
                    root.addChild(cooling)
                }
            }
            let power = try makeElectricalRoutes(facility)
            root.addChild(power)
            electricalEntity = power
            if parent.mode == .room, parent.room.source.contains("sintética") {
                for side: Float in [-1, 1] {
                    let generator = try makeExteriorGenerator(side < 0 ? "A" : "B")
                    generator.position = SIMD3(side * 8.78, 0, -3.78)
                    root.addChild(generator)
                }
            }
            return root
        }

        private func makeExteriorGenerator(_ path: String) throws -> Entity {
            let entity = Entity()
            var pad = LabSceneMesh()
            pad.box(size: SIMD3(1.63, 0.06, 2.71), center: SIMD3(0, 0.03, 0))
            entity.addChild(try pad.model(material: materials.facilityFloor))
            var enclosure = LabSceneMesh(), details = LabSceneMesh(), ventilation = LabSceneMesh()
            enclosure.box(size: SIMD3(1.22, 1.36, 2.28), center: SIMD3(0, 0.85, 0))
            details.box(size: SIMD3(1.33, 0.14, 2.42), center: SIMD3(0, 0.09, 0))
            details.box(size: SIMD3(0.48, 0.89, 0.025), center: SIMD3(-0.24, 0.84, -1.153))
            details.box(size: SIMD3(0.065, 0.08, 0.018), center: SIMD3(-0.06, 0.84, -1.169))
            ventilation.tube(from: SIMD3(0.32, 1.50, 0.72), to: SIMD3(0.32, 1.81, 0.72), radius: 0.05)
            for fin in 0..<19 {
                ventilation.box(size: SIMD3(0.36, 0.018, 0.024),
                                center: SIMD3(0.32, 0.50 + Float(fin) * 0.037, -1.153))
            }
            entity.addChild(try enclosure.model(material: materials.graphite))
            entity.addChild(try details.model(material: materials.metal))
            entity.addChild(try ventilation.model(material: materials.dark))
            let plate = try label("GENERACIÓN " + path + " · EXTERIOR", width: 1.03, height: 0.11)
            plate.position = SIMD3(0, 1.37, -1.17)
            entity.addChild(plate)
            return entity
        }

        private func makeFacilityEquipment(_ id: String, circuit: String) throws -> Entity {
            let size = HardwareCatalog.reference(id)!.size!
            let entity = Entity()
            entity.name = "hardware:" + id
            entity.components.set(CollisionComponent(shapes: [ShapeResource.generateBox(size: size)]))
            var chassis = LabSceneMesh(), grate = LabSceneMesh(), status = LabSceneMesh()
            chassis.box(size: size, center: .zero)
            let cooling = id == "cooling-inrow", front = -size.z / 2 - 0.002
            let rows = cooling ? 43 : 4
            for row in 0..<rows {
                let y = (Float(row) / Float(rows - 1) - 0.5) * size.y * 0.77
                for face: Float in [-1, 1] {
                    grate.box(size: SIMD3(size.x * (cooling ? 0.77 : 0.57), cooling ? 0.012 : 0.004, 0.004),
                              center: SIMD3(cooling ? 0 : 0.045, y, face * (size.z / 2 + 0.002)))
                }
            }
            let screenY = cooling ? size.y * 0.43 : 0
            status.box(size: SIMD3(cooling ? 0.065 : 0.024, cooling ? 0.029 : 0.013, 0.004),
                       center: SIMD3(cooling ? 0 : -0.126, screenY, front - 0.002))
            entity.addChild(try chassis.model(material: materials.graphite))
            entity.addChild(try grate.model(material: materials.dark))
            entity.addChild(try status.model(material: circuit == "A" ? materials.powerA : materials.powerB))
            let name = cooling ? "INROW \(circuit)" : id == "ups-9px" ? "9PX · UPS \(circuit)" : "72 V · BATERÍA \(circuit)"
            let sign = try label(name, width: cooling ? 0.22 : 0.16, height: cooling ? 0.028 : 0.012)
            sign.position = SIMD3(cooling ? 0 : -0.10, cooling ? size.y * 0.47 : 0.027, front - 0.003)
            entity.addChild(sign)
            return entity
        }

        private var electricalEntity: Entity?
        private var electricalLeads: [Entity] = []

        private func makeElectricalRoutes(_ facility: TierFacility) throws -> Entity {
            let container = Entity()
            var supports = LabSceneMesh()
            let rackDepth = HardwareCatalog.renderSize("rack-r42612").z
            let rackHeight = HardwareCatalog.renderSize("rack-r42612").y
            let overhead = facility.conduitHeight
            for side: Float in [-1, 1] {
                var runs = LabSceneMesh()
                func conduit(_ points: [SIMD3<Float>]) {
                    guard let bends = LabGeometry.cableBends(points, radius: 0.090) else { return }
                    for (a, b) in zip(bends, bends.dropFirst()) where simd_distance(a, b) > 0.0001 {
                        runs.tube(from: a, to: b, radius: 0.013)
                    }
                    for (a, b) in zip(points, points.dropFirst()) {
                        let length = simd_distance(a, b)
                        guard abs(a.y - b.y) < 0.01, length >= 0.8 else { continue }
                        let clamps = max(1, Int(ceil(length / 1.25)))
                        for index in 0..<clamps {
                            let point = a + (b - a) * ((Float(index) + 0.5) / Float(clamps))
                            supports.box(size: SIMD3(0.044, 0.035, 0.044), center: point)
                            let drop = facility.height - point.y
                            supports.box(size: SIMD3(0.012, drop, 0.012), center: point + SIMD3(0, drop / 2, 0))
                        }
                    }
                }
                let origin = side * 6.15
                let trunkZ: Float = side < 0 ? TierFacility.conduitAZ : 2.36
                conduit([SIMD3(origin, rackHeight, -3.03), SIMD3(origin, overhead, -3.03),
                         SIMD3(origin, overhead, trunkZ), SIMD3(-side * 4.1, overhead, trunkZ)])
                conduit([SIMD3(side * 6.62, 1.63, -1.86), SIMD3(side * 6.62, overhead + 0.19, -1.86),
                         SIMD3(side * 6.62, overhead + 0.19, -3.03),
                         SIMD3(origin, overhead + 0.19, -3.03), SIMD3(origin, rackHeight, -3.03)])
                for x: Float in [-3.7, 0, 3.7] {
                    let riserX = x + side * 0.251
                    for (index, z) in [(0, Float(-2.1)), (1, Float(0.95))] {
                        let rear = z + (index == 0 ? -1 : 1) * (rackDepth / 2 - 0.105)
                        conduit([SIMD3(riserX, overhead, trunkZ), SIMD3(riserX, overhead, rear),
                                 SIMD3(riserX, 0.30, rear)])
                    }
                }
                if !runs.indices.isEmpty { container.addChild(try runs.model(material: side < 0 ? materials.powerA : materials.powerB)) }
            }
            if !supports.indices.isEmpty { container.addChild(try supports.model(material: materials.metal)) }
            return container
        }

        private func holeRect(_ hole: RoomStructure.Surface, wall: RoomStructure.Surface) throws -> CGRect {
            let relative = try simd_inverse(LabGeometry.matrix(wall)) * LabGeometry.matrix(hole)
            guard abs(abs(relative.columns.0.x) - 1) < 0.01, abs(abs(relative.columns.1.y) - 1) < 0.01,
                  abs(relative.columns.3.z) <= 0.03 else {
                throw LabLayoutError.invalid("Abertura inclinada o no alineada con la pared. Revisa la captura.")
            }
            let a = relative * SIMD4(-hole.dimensions[0] / 2, -hole.dimensions[1] / 2, 0, 1)
            let b = relative * SIMD4(hole.dimensions[0] / 2, hole.dimensions[1] / 2, 0, 1)
            let minX = min(a.x, b.x), maxX = max(a.x, b.x), minY = min(a.y, b.y), maxY = max(a.y, b.y)
            let halfW = wall.dimensions[0] / 2, halfH = wall.dimensions[1] / 2
            guard minX >= -halfW - 0.03, maxX <= halfW + 0.03, minY >= -halfH - 0.03, maxY <= halfH + 0.03 else {
                throw LabLayoutError.invalid("Una abertura sobrepasa su pared. Revisa las medidas del escaneo.")
            }
            return CGRect(x: CGFloat(max(minX, -halfW)), y: CGFloat(max(minY, -halfH)),
                          width: CGFloat(min(maxX, halfW) - max(minX, -halfW)),
                          height: CGFloat(min(maxY, halfH) - max(minY, -halfH)))
        }

        private func makePlacement(_ placement: LabPlacement) throws -> Entity {
            guard placement.size.x > 0, placement.size.y > 0, placement.size.z > 0,
                  [placement.size.x, placement.size.y, placement.size.z, placement.position.x,
                   placement.position.y, placement.position.z, placement.yaw].allSatisfy(\.isFinite) else {
                throw LabLayoutError.invalid("Equipo con tamaño o posición inválidos.")
            }
            let entity = Entity()
            entity.name = "placement:" + placement.id
            entity.position = placement.position
            entity.orientation = simd_quatf(angle: placement.yaw, axis: SIMD3(0, 1, 0))
            let parts = placement.kind == .rack ? rackMeshes(placement.size) : workstationMeshes(placement.size)
            let surfaceMaterials: [any RealityKit.Material] = [materials.graphite, materials.panel, materials.metal, materials.dark, materials.power, materials.screen]
            for (index, mesh) in parts.enumerated() where !mesh.indices.isEmpty {
                let model = try mesh.model(material: surfaceMaterials[index])
                entity.addChild(model)
                if index == 4 { indicators[placement.id, default: []].append(model) }
                if index == 5 { screens[placement.id, default: []].append(model) }
            }
            let s = placement.size
            let shapes: [ShapeResource]
            if placement.kind == .rack {
                shapes = [-s.x / 2 + 0.007, s.x / 2 - 0.007].map {
                    ShapeResource.generateBox(size: SIMD3(0.014, s.y, s.z)).offsetBy(translation: SIMD3($0, s.y / 2, 0))
                } + [Float(0.045), s.y - 0.025].map {
                    ShapeResource.generateBox(size: SIMD3(s.x, 0.05, s.z)).offsetBy(translation: SIMD3(0, $0, 0))
                }
            } else {
                shapes = [ShapeResource.generateBox(size: SIMD3(s.x, 0.04, s.z)).offsetBy(translation: SIMD3(0, 0.73, 0))]
            }
            entity.components.set(CollisionComponent(shapes: shapes))
            try addHardware(to: entity, placement: placement)
            if placement.kind == .rack && parent.layout.facility != nil {
                try addRackElectrical(to: entity, placement: placement)
            }
            var outline = LabSceneMesh()
            let w = placement.size.x / 2 + 0.006, h = placement.size.y, d = placement.size.z / 2 + 0.006
            for x in [-w, w] { for z in [-d, d] { outline.box(size: SIMD3(0.004, h, 0.004), center: SIMD3(x, h / 2, z)) } }
            for y in [Float(0.004), h] {
                for z in [-d, d] { outline.box(size: SIMD3(w * 2, 0.004, 0.004), center: SIMD3(0, y, z)) }
                for x in [-w, w] { outline.box(size: SIMD3(0.004, 0.004, d * 2), center: SIMD3(x, y, 0)) }
            }
            let highlight = try outline.model(material: materials.accent)
            highlight.isEnabled = false
            entity.addChild(highlight)
            highlights[placement.id] = highlight
            return entity
        }

        private func addRackElectrical(to rack: Entity, placement: LabPlacement) throws {
            let devices = parent.topology?.devices.filter { $0.placementID == placement.id } ?? []
            let z = placement.size.z / 2 - 0.105
            var strips = LabSceneMesh(), outlets = LabSceneMesh(), transfer = LabSceneMesh()
            transfer.box(size: SIMD3(0.439, 0.044, 0.203), center: SIMD3(0, 1.91, z - 0.112))
            for (supply, side) in [-1 as Float, 1].enumerated() {
                let x = side * 0.251
                strips.box(size: SIMD3(0.039, 1.54, 0.034), center: SIMD3(x, 1.07, z))
                var leads = LabSceneMesh()
                for outlet in 0..<14 {
                    outlets.box(size: SIMD3(0.021, 0.027, 0.003),
                                center: SIMD3(x, 0.45 + Float(outlet) * 0.097, z + 0.018))
                }
                for device in devices where device.hasDashboard {
                    let size = HardwareCatalog.renderSize(device.modelID)
                    let socket = device.offset + SIMD3(size.x / 2 - 0.037 - Float(supply) * 0.075, 0, size.z / 2 + 0.006)
                    let leadZ = socket.z + 0.075
                    let points = [SIMD3(x, socket.y, z - 0.018), SIMD3(x, socket.y, leadZ),
                                  SIMD3(socket.x, socket.y, leadZ), socket]
                    if let path = LabGeometry.cableBends(points, radius: 0.027) {
                        for (a, b) in zip(path, path.dropFirst()) where simd_distance(a, b) > 0.0001 {
                            leads.tube(from: a, to: b, radius: 0.005)
                        }
                    }
                }
                if !leads.indices.isEmpty {
                    let wires = try leads.model(material: side < 0 ? materials.powerA : materials.powerB)
                    wires.isEnabled = parent.showCables
                    rack.addChild(wires)
                    electricalLeads.append(wires)
                }
                let tag = try label(side < 0 ? "PDU A" : "PDU B", width: 0.055, height: 0.015)
                tag.position = SIMD3(x, 1.855, z + 0.020)
                tag.orientation = simd_quatf(angle: 0, axis: SIMD3(0, 1, 0))
                rack.addChild(tag)
            }
            rack.addChild(try strips.model(material: materials.graphite))
            rack.addChild(try outlets.model(material: materials.dark))
            rack.addChild(try transfer.model(material: materials.metal))
            let ats = try label("ATS · ENTRADAS A/B", width: 0.22, height: 0.016)
            ats.position = SIMD3(0, 1.91, z - 0.009)
            ats.orientation = simd_quatf(angle: 0, axis: SIMD3(0, 1, 0))
            rack.addChild(ats)
        }

        private func rackMeshes(_ size: SIMD3<Float>) -> [LabSceneMesh] {
            var parts = Array(repeating: LabSceneMesh(), count: 6)
            let w = size.x, h = size.y, d = size.z, front = -d / 2
            func box(_ part: Int, _ dimensions: SIMD3<Float>, _ center: SIMD3<Float>) { parts[part].box(size: dimensions, center: center) }
            let capacity = RackMount.capacity(height: h)
            let railZ = front + RackMount.frontInset + 0.015
            for sign: Float in [-1, 1] {
                let side = sign * (w / 2 - 0.007)
                box(0, SIMD3(0.014, h - 0.09, d - 0.06), SIMD3(side, h / 2, 0))
                for z in [front + 0.018, d / 2 - 0.018] {
                    box(0, SIMD3(0.024, h - 0.055, 0.036), SIMD3(sign * (w / 2 - 0.013), h / 2, z))
                    box(3, SIMD3(0.064, 0.04, 0.074), SIMD3(sign * (w / 2 - 0.047), 0.02, z))
                }
                let railX = sign * 0.248
                box(2, SIMD3(0.014, RackMount.unit * Float(capacity), 0.022),
                    SIMD3(railX, RackMount.base + RackMount.unit * Float(capacity) / 2, railZ))
                for unit in 0..<capacity {
                    for offset: Float in [0.00635, 0.02222, 0.03810] {
                        let y = RackMount.base + Float(unit) * RackMount.unit + offset
                        box(3, SIMD3(0.008, 0.008, 0.002), SIMD3(railX, y, railZ - 0.012))
                    }
                    let y = RackMount.base + (Float(unit) + 0.5) * RackMount.unit
                    box(2, SIMD3(0.02, 0.006, 0.024), SIMD3(sign * 0.28, y, d / 2 - 0.083))
                }
                box(3, SIMD3(0.009, h - 0.2, 0.08), SIMD3(sign * 0.287, h / 2, d / 2 - 0.105))
            }
            box(0, SIMD3(w, 0.055, d), SIMD3(0, 0.069, 0))
            box(0, SIMD3(w, 0.042, d - 0.17), SIMD3(0, h - 0.021, -0.085))
            for vent in 0..<18 {
                box(3, SIMD3(0.013, 0.003, d * 0.20), SIMD3(-0.21 + Float(vent) * 0.024, h, 0.1))
            }
            return parts
        }

        private func workstationMeshes(_ size: SIMD3<Float>) -> [LabSceneMesh] {
            var parts = Array(repeating: LabSceneMesh(), count: 6)
            func box(_ part: Int, _ dimensions: SIMD3<Float>, _ center: SIMD3<Float>) { parts[part].box(size: dimensions, center: center) }
            let w = size.x, d = size.z, top: Float = 0.75
            box(1, SIMD3(w, 0.04, d), SIMD3(0, top - 0.02, 0))
            for x in [-w / 2 + 0.07, w / 2 - 0.07] { for z in [-d / 2 + 0.07, d / 2 - 0.07] {
                box(2, SIMD3(0.035, top - 0.04, 0.035), SIMD3(x, (top - 0.04) / 2, z))
            } }
            box(0, SIMD3(0.2, 0.018, 0.15), SIMD3(-0.1, top + 0.009, 0.1))
            box(2, SIMD3(0.035, 0.15, 0.025), SIMD3(-0.1, top + 0.09, 0.14))
            box(0, SIMD3(0.52, 0.32, 0.035), SIMD3(-0.1, top + 0.29, 0.14))
            box(5, SIMD3(0.477, 0.277, 0.003), SIMD3(-0.1, top + 0.29, 0.12))
            box(0, SIMD3(0.4, 0.012, 0.14), SIMD3(-0.1, top + 0.008, -0.19))
            for row in 0..<4 { for key in 0..<12 {
                box(2, SIMD3(0.023, 0.003, 0.018), SIMD3(-0.27 + Float(key) * 0.031, top + 0.016, -0.233 + Float(row) * 0.028))
            } }
            return parts
        }

        private func addHardware(to entity: Entity, placement: LabPlacement) throws {
            if let topology = parent.topology {
                for device in topology.devices where device.placementID == placement.id && device.modelID != "rack-r42612" {
                    let model = try hardware(device.modelID)
                    model.name = "device:" + device.id
                    model.position = device.offset
                    entity.addChild(model)
                    try addRackMount(to: entity, modelID: device.modelID, at: device.offset, placement: placement)
                    devicePowerParents[device.id] = placement.id
                    registerPower(model, placementID: device.id)
                    deviceHighlights[device.id] = model.findEntity(named: "hardware-selection")
                    try addPorts(device: device, to: model)
                    let size = hardwareSize(device.modelID)
                    let badge = try label(String(device.name.prefix(38)), width: min(0.19, size.x - 0.012), height: 0.016)
                    badge.position = SIMD3(0, size.y / 2 - 0.010, -size.z / 2 - 0.013)
                    model.addChild(badge)
                }
                if placement.kind == .rack {
                    if topology.operationsProfile != nil {
                        try addRackPanels(to: entity, placement: placement, topology: topology)
                        let monitored = topology.devices.filter { $0.placementID == placement.id && $0.hasDashboard }
                        try addDashboardMonitors(to: entity, placement: placement, devices: monitored)
                    }
                    try addRackTitle(to: entity, placement: placement)
                } else if topology.operationsProfile != nil,
                          let station = topology.devices.first(where: { $0.placementID == placement.id && $0.modelID == "pc-optiplex7010" }) {
                    try addConsoleScreen(to: entity, station: station)
                }
                return
            }
            if placement.kind == .rack {
                let devices: [(String, Float)] = [("switch-2960", 1.79), ("switch-3560", 1.67),
                    ("router-1941", 1.46), ("router-2911", 1.23), ("firewall-asa5505", 1.02),
                    ("server-c220m5", 0.77), ("server-c220m5", 0.59), ("server-c220m5", 0.41)]
                for (id, height) in devices {
                    let model = try hardware(id)
                    model.position = RackMount.center(id, rackDepth: placement.size.z, slot: RackMount.slot(id, near: height))
                    entity.addChild(model)
                    try addRackMount(to: entity, modelID: id, at: model.position, placement: placement)
                    registerPower(model, placementID: placement.id)
                }
                try addRackTitle(to: entity, placement: placement)
            } else {
                let desktop = try hardware("pc-optiplex7010")
                let desktopSize = hardwareSize("pc-optiplex7010")
                desktop.position = SIMD3(placement.size.x / 2 - 0.16, desktopSize.y / 2 + 0.015, 0)
                entity.addChild(desktop); registerPower(desktop, placementID: placement.id)
                let laptop = try hardware("laptop-latitude5420")
                laptop.position = SIMD3(0.37, 0.77, -0.13)
                entity.addChild(laptop); registerPower(laptop, placementID: placement.id)
                let phone = try hardware("phone-7960")
                phone.position = SIMD3(-0.47, 0.79, 0.13)
                entity.addChild(phone); registerPower(phone, placementID: placement.id)
            }
        }

        private func addConsoleScreen(to workstation: Entity, station: LabTopology.Device) throws {
            let monitor = Entity()
            monitor.name = "device:" + station.id
            monitor.position = SIMD3(-0.1, 1.04, 0.119)
            monitor.components.set(CollisionComponent(shapes: [
                ShapeResource.generateBox(size: SIMD3(0.51, 0.31, 0.035))
            ]))
            let terminal = try label("NEXUS · CONSOLA DE OPERACIÓN", width: 0.40, height: 0.042)
            terminal.position = SIMD3(0, 0.065, -0.004)
            terminal.name = "screen"
            monitor.addChild(terminal)
            consoleScreens[station.id, default: []].append(terminal)
            workstation.addChild(monitor)
        }

        private func addDashboardMonitors(to rack: Entity, placement: LabPlacement,
                                         devices: [LabTopology.Device]) throws {
            let width = LabMonitorMount.displayWidth, height = LabMonitorMount.displayHeight
            let frameSize = SIMD3(width + LabMonitorMount.bezel, height + LabMonitorMount.bezel, 0.022)
            let template = MeshResource.generateBox(size: frameSize, cornerRadius: 0.007)
            let front = -placement.size.z / 2 + LabMonitorMount.inset
            var steel = LabSceneMesh(), brackets = LabSceneMesh(), screws = LabSceneMesh(), harness = LabSceneMesh()
            for (index, device) in devices.enumerated() {
                let side: Float = index.isMultiple(of: 2) ? 1 : -1
                let x = LabMonitorMount.centerX(for: placement.size.x, side: side)
                let columnX = side * (placement.size.x / 2 + 0.041)
                let highest: Float = placement.size.y > 1.5 ? 1.78 : 1.58
                let row = index / 2
                let y = highest - Float(row) * 0.247
                let postZ = front + 0.050
                if row == 0 {
                    steel.box(size: SIMD3(0.048, highest + 0.057, 0.047),
                              center: SIMD3(columnX, 0.021 + (highest + 0.057) / 2, postZ))
                    brackets.box(size: SIMD3(0.113, 0.023, 0.220), center: SIMD3(columnX + side * 0.032, 0.0115, postZ + 0.041))
                    for dx: Float in [-0.032, 0.032] {
                        for dz: Float in [-0.066, 0.066] {
                            let bolt = SIMD3(columnX + side * 0.032 + dx, 0.023, postZ + 0.041 + dz)
                            screws.tube(from: bolt, to: bolt + SIMD3(0, 0.007, 0), radius: 0.007)
                        }
                    }
                    harness.tube(from: SIMD3(columnX + side * 0.031, 0.029, postZ + 0.033),
                                 to: SIMD3(columnX + side * 0.031, highest + 0.006, postZ + 0.033), radius: 0.0055)
                }

                // Clamp, two pinned links and a rear VESA plate. Each screen has its own load path to the post.
                brackets.box(size: SIMD3(0.070, 0.056, 0.056), center: SIMD3(columnX, y, postZ))
                let base = SIMD3(columnX + side * 0.033, y, postZ)
                let elbow = SIMD3(columnX + side * 0.112, y, front + 0.090)
                let head = SIMD3(x, y, front + 0.027)
                for (a, b) in [(base, elbow), (elbow, head)] {
                    let delta = b - a
                    var transform = simd_float4x4(simd_quatf(from: SIMD3(1, 0, 0), to: simd_normalize(delta)))
                    transform.columns.3 = SIMD4((a + b) / 2, 1)
                    steel.box(size: SIMD3(simd_length(delta), 0.029, 0.026), center: .zero, matrix: transform)
                }
                for joint in [base, elbow, head] {
                    brackets.tube(from: joint - SIMD3(0, 0.021, 0), to: joint + SIMD3(0, 0.021, 0), radius: 0.020)
                    screws.tube(from: joint + SIMD3(0, 0.020, 0), to: joint + SIMD3(0, 0.025, 0), radius: 0.008)
                }
                brackets.box(size: SIMD3(0.093, 0.088, 0.010), center: SIMD3(x, y, front + 0.016))
                for dx: Float in [-0.0375, 0.0375] {
                    for dy: Float in [-0.0375, 0.0375] {
                        let bolt = SIMD3(x + dx, y + dy, front + 0.021)
                        screws.tube(from: bolt, to: bolt + SIMD3(0, 0, 0.003), radius: 0.004)
                    }
                }
                let outlet = SIMD3(x + side * 0.044, y - 0.057, front + 0.014)
                let loop = SIMD3(x + side * 0.044, y - 0.110, front + 0.041)
                let bend = SIMD3(x - side * 0.031, y - 0.088, front + 0.098)
                let clip = SIMD3(columnX + side * 0.031, y - 0.044, postZ + 0.033)
                let cable = [outlet, loop, bend, clip]
                for (a, b) in zip(cable, cable.dropFirst()) { harness.tube(from: a, to: b, radius: 0.0038) }

                let monitor = Entity()
                monitor.name = "device:" + device.id
                monitor.position = SIMD3(x, y, front)
                monitor.components.set(CollisionComponent(shapes: [ShapeResource.generateBox(size: frameSize)]))
                monitor.addChild(ModelEntity(mesh: template, materials: [materials.graphite]))
                let face = try dashboardFace(for: device, width: width, height: height)
                face.position.z = -0.012
                monitor.addChild(face)
                let led = ModelEntity(mesh: .generateBox(size: SIMD3(0.007, 0.007, 0.002)), materials: [materials.power])
                led.position = SIMD3(-0.129, 0.013, -0.014)
                monitor.addChild(led)
                let bars = [SIMD3<Float>(-0.13, -0.022, -0.014), SIMD3<Float>(-0.13, -0.053, -0.014)].enumerated().map { index, point in
                    let bar = ModelEntity(mesh: .generateBox(size: SIMD3(0.131, 0.005, 0.0015)),
                                          materials: [index == 0 ? materials.power : materials.activity])
                    bar.position = point
                    monitor.addChild(bar)
                    return bar
                }
                dashboards.append((device, led, bars))
                rack.addChild(monitor)
            }
            if !steel.indices.isEmpty {
                rack.addChild(try steel.model(material: materials.metal))
                rack.addChild(try brackets.model(material: materials.graphite))
                rack.addChild(try screws.model(material: materials.metal))
                rack.addChild(try harness.model(material: materials.dark))
            }
        }

        private func dashboardFace(for device: LabTopology.Device, width: Float, height: Float) throws -> ModelEntity {
            let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
            let image = UIGraphicsImageRenderer(size: CGSize(width: 320, height: 180), format: format).image { context in
                UIColor(red: 0.025, green: 0.043, blue: 0.070, alpha: 1).setFill()
                context.fill(CGRect(x: 0, y: 0, width: 320, height: 180))
                func draw(_ value: String, size: CGFloat, x: CGFloat, y: CGFloat, color: UIColor) {
                    let font = UIFont.monospacedSystemFont(ofSize: size, weight: .semibold)
                    (value as NSString).draw(in: CGRect(x: x, y: y, width: 309 - x, height: 27),
                                             withAttributes: [.foregroundColor: color, .font: font])
                }
                let secondary = UIColor(red: 0.65, green: 0.75, blue: 0.87, alpha: 1)
                draw("SIMULACIÓN", size: 13, x: 18, y: 12, color: secondary)
                draw(String(device.name.prefix(25)), size: 17, x: 18, y: 34, color: .white)
                draw(String(device.services.joined(separator: " · ").prefix(34)), size: 13, x: 18, y: 55, color: secondary)
                draw("ESTADO", size: 12, x: 38, y: 69, color: secondary)
                draw("RX · Mb/s", size: 13, x: 169, y: 103, color: .white)
                draw("TX · Mb/s", size: 13, x: 169, y: 135, color: .white)
            }
            guard let cg = image.cgImage else { throw LabLayoutError.invalid("No se pudo preparar la pantalla.") }
            let texture = try TextureResource.generate(from: cg, options: .init(semantic: .color))
            var material = UnlitMaterial(); material.color = .init(tint: .white, texture: .init(texture))
            let view = ModelEntity(mesh: .generatePlane(width: width, height: height), materials: [material])
            view.orientation = simd_quatf(angle: .pi, axis: SIMD3(0, 1, 0))
            return view
        }

        private func updateDashboards(force: Bool = false) {
            let clock = ProcessInfo.processInfo.systemUptime
            guard parent.isForeground, let topology = parent.topology, force || clock - lastDashboardRefresh > 2 else { return }
            lastDashboardRefresh = clock
            let now = Date()
            for (device, led, bars) in dashboards {
                let sample = LabServerSample(device: device, topology: topology, poweredOff: parent.poweredOff, timestamp: now)
                led.model?.materials = [sample.state == .available ? materials.power
                    : sample.state == .isolated ? materials.activity : materials.powerA]
                for (bar, rate) in zip(bars, [sample.receiveMbps, sample.transmitMbps]) {
                    let fraction = Float(min(1, rate / 65))
                    bar.isEnabled = fraction > 0
                    bar.scale.x = max(0.01, fraction)
                    bar.position.x = -0.13 + 0.0655 * fraction
                }
            }
        }

        private func addRackPanels(to rack: Entity, placement: LabPlacement, topology: LabTopology) throws {
            let capacity = RackMount.capacity(height: placement.size.y)
            let used = Set(topology.devices.filter { $0.placementID == placement.id }.flatMap { device in
                let start = RackMount.slot(device.modelID, near: device.offset.y)
                return start..<(start + RackMount.units(device.modelID))
            })
            let front = -placement.size.z / 2 + RackMount.frontInset + 0.004
            var blanks = LabSceneMesh(), hardware = LabSceneMesh()
            for slot in 0..<capacity where !used.contains(slot) {
                let y = RackMount.base + (Float(slot) + 0.5) * RackMount.unit
                blanks.box(size: SIMD3(0.488, RackMount.unit - 0.003, 0.013), center: SIMD3(0, y, front))
                for side: Float in [-1, 1] {
                    hardware.box(size: SIMD3(0.008, 0.006, 0.002), center: SIMD3(side * 0.232, y, front - 0.007))
                }
                if slot.isMultiple(of: 3) {
                    hardware.box(size: SIMD3(0.070, 0.003, 0.003), center: SIMD3(0, y, front - 0.007))
                }
            }
            if !blanks.indices.isEmpty {
                rack.addChild(try blanks.model(material: materials.graphite))
                rack.addChild(try hardware.model(material: materials.panel))
            }
        }

        private func addRackMount(to rack: Entity, modelID: String, at center: SIMD3<Float>, placement: LabPlacement) throws {
            guard placement.kind == .rack else { return }
            let size = hardwareSize(modelID)
            let front = center.z - size.z / 2
            if modelID == "raspberry-pi5" {
                var shelf = LabSceneMesh()
                shelf.box(size: SIMD3(0.487, 0.005, 0.20),
                          center: SIMD3(0, center.y - size.y / 2 - 0.003, front + 0.083))
                for side: Float in [-1, 1] {
                    shelf.box(size: SIMD3(0.027, 0.043, 0.005),
                              center: SIMD3(side * 0.239, center.y + 0.006, front))
                }
                rack.addChild(try shelf.model(material: materials.metal))
                return
            }
            var brackets = LabSceneMesh(), fasteners = LabSceneMesh()
            if modelID == "firewall-asa5505" {
                let y = center.y - size.y / 2 - 0.004
                brackets.box(size: SIMD3(0.49, 0.008, 0.23), center: SIMD3(0, y, front + 0.107))
            }
            for sign: Float in [-1, 1] {
                let width = 0.253 - size.x / 2
                let x = sign * (0.253 - width / 2)
                let y = modelID == "firewall-asa5505" ? center.y - size.y / 2 : center.y
                let height = modelID == "firewall-asa5505" ? 0.018 : size.y - 0.004
                let earWidth = modelID == "firewall-asa5505" ? 0.024 : width
                brackets.box(size: SIMD3(earWidth, height, 0.006),
                             center: SIMD3(modelID == "firewall-asa5505" ? sign * 0.244 : x, y, front - 0.001))
                fasteners.tube(from: SIMD3(sign * 0.247, y, front - 0.003),
                               to: SIMD3(sign * 0.247, y, front - 0.007), radius: 0.003)
            }
            rack.addChild(try brackets.model(material: materials.graphite))
            rack.addChild(try fasteners.model(material: materials.metal))
        }

        private func addRackTitle(to entity: Entity, placement: LabPlacement) throws {
            let capacity = RackMount.capacity(height: placement.size.y)
            let title = try label("\(placement.title) · \(capacity) U", width: placement.size.x - 0.12, height: 0.035)
            if capacity == 42 { title.name = "hardware:rack-r42612" }
            title.position = SIMD3(0, placement.size.y - 0.026, -placement.size.z / 2 - 0.002)
            title.components.set(CollisionComponent(shapes: [ShapeResource.generateBox(size: SIMD3(placement.size.x - 0.1, 0.04, 0.01))]))
            entity.addChild(title)
        }

        private func worldPort(_ device: LabTopology.Device, _ name: String) throws -> LabScenePort {
            try LabScenePort.world(device, name, in: parent.layout)
        }

        private func addPorts(device: LabTopology.Device, to entity: Entity) throws {
            var sockets = LabSceneMesh()
            for name in device.ports where !name.lowercased().contains("power") && !name.lowercased().contains("psu") {
                let port = try LabScenePort.local(device, name)
                let hit = Entity(); hit.name = "port:" + name
                hit.position = port.point + port.normal * 0.004
                hit.orientation = simd_quatf(from: SIMD3(0, 0, 1), to: port.normal)
                let hitWidth: Float = device.modelID == "patch-copper" ? 0.015 : 0.019
                hit.components.set(CollisionComponent(shapes: [ShapeResource.generateBox(size: SIMD3(hitWidth, 0.016, 0.012))]))
                entity.addChild(hit)
                portHits[ObjectIdentifier(hit)] = try worldPort(device, name)
                var matrix = simd_float4x4(hit.orientation)
                matrix.columns.3 = SIMD4(port.point + port.normal * 0.002, 1)
                sockets.box(size: SIMD3(0.015, 0.012, 0.002), center: .zero, matrix: matrix)
            }
            if !sockets.indices.isEmpty { entity.addChild(try sockets.model(material: materials.dark)) }
        }

        private func makeCables(_ topology: LabTopology, lights: Entity) throws -> Entity {
            let container = Entity(); container.name = "Cableado del diseño"
            var trays = LabSceneMesh()
            var trafficPaths: [String: [SIMD3<Float>]] = [:]
            let plan = try LabCablePlan.make(topology, room: parent.room, layout: parent.layout)
            for tray in plan.trays { addTray(from: tray.start, to: tray.end, mesh: &trays) }
            for upright in plan.uprights {
                var transform = simd_float4x4(simd_quatf(angle: upright.yaw, axis: SIMD3(0, 1, 0)))
                transform.columns.3 = SIMD4(upright.center, 1)
                trays.box(size: upright.size, center: .zero, matrix: transform)
            }
            for segment in plan.segments {
                let link = segment.link, rounded = segment.points, pickingPath = segment.pickingPath
                var wire = LabSceneMesh(), plugs = LabSceneMesh(), boots = LabSceneMesh()
                let radius = link.medium.cableRadius
                var highlight = LabSceneMesh()
                for (start, end) in zip(rounded, rounded.dropFirst()) {
                    guard simd_distance(start, end) > 0.0001 else { continue }
                    wire.tube(from: start, to: end, radius: radius)
                    highlight.tube(from: start, to: end, radius: radius * 1.55)
                }
                let shapes = zip(pickingPath, pickingPath.dropFirst()).compactMap { start, end -> ShapeResource? in
                    let delta = end - start, length = simd_length(delta)
                    guard length > 0.0001 else { return nil }
                    let radius: Float = 0.009
                    return ShapeResource.generateCapsule(height: length + radius * 2, radius: radius)
                        .offsetBy(rotation: simd_quatf(from: SIMD3(0, 1, 0), to: delta / length), translation: (start + end) / 2)
                }
                for endpoint in segment.endpoints {
                    var matrix = simd_float4x4(simd_quatf(from: SIMD3(0, 0, 1), to: endpoint.normal))
                    matrix.columns.3 = SIMD4(endpoint.point, 1)
                    let connectorSize = link.medium == .fiber ? SIMD3<Float>(0.009, 0.008, 0.019) : SIMD3<Float>(0.012, 0.009, 0.023)
                    plugs.box(size: connectorSize, center: SIMD3(0, 0, 0.009), matrix: matrix)
                    let isCopper = link.medium == .copper
                    wire.box(size: SIMD3(0.011, 0.009, 0.012), center: SIMD3(0, 0, 0.024), matrix: matrix)
                    if isCopper {
                        boots.box(size: SIMD3(0.009, 0.0028, 0.017), center: SIMD3(0, -0.0052, 0.013), matrix: matrix)
                        for rib in 0..<3 {
                            boots.box(size: SIMD3(0.009 - Float(rib) * 0.001, 0.008 - Float(rib) * 0.001, 0.0014),
                                      center: SIMD3(0, 0, 0.030 + Float(rib) * 0.003), matrix: matrix)
                        }
                    }
                }
                let material = wireMaterial(link.medium)
                let body = try wire.model(material: material)
                let trace = try highlight.model(material: materials.trace)
                trace.isEnabled = false
                let cable = Entity(); cable.name = "cable:" + link.id
                cable.addChild(body); cable.addChild(trace); cable.addChild(try plugs.model(material: materials.connector))
                if !boots.indices.isEmpty { cable.addChild(try boots.model(material: materials.graphite)) }
                cable.components.set(CollisionComponent(shapes: shapes))
                container.addChild(cable)
                linkBodies[link.id] = body
                traceBodies[link.id] = trace
                trafficPaths[link.id] = rounded
            }
            if !trays.indices.isEmpty { container.addChild(try trays.model(material: materials.metal)) }
            try makeTraffic(topology, paths: trafficPaths, lights: lights, cables: container)
            return container
        }

        private func makeTraffic(_ topology: LabTopology, paths: [String: [SIMD3<Float>]],
                                 lights: Entity, cables: Entity) throws {
            let devices = Dictionary(uniqueKeysWithValues: topology.devices.map { ($0.id, $0) })
            for link in topology.links where link.circuitID == nil || link.id == link.circuitID {
                let circuit = topology.circuit(for: link)
                let segments = circuit.compactMap { paths[$0.id] }
                guard let end = circuit.last, segments.count == circuit.count,
                      let route = LabTrafficRoute(segments),
                      let from = devices[link.fromDeviceID], let to = devices[end.toDeviceID] else { continue }
                var green = LabSceneMesh()
                var amberLEDs: [(atStart: Bool, entity: ModelEntity)] = []
                for (index, endpoint) in [(from, link.fromPort), (to, end.toPort)].enumerated()
                where !endpoint.0.modelID.hasPrefix("patch-") {
                    let port = try worldPort(endpoint.0, endpoint.1)
                    var amber = LabSceneMesh()
                    var matrix = simd_float4x4(simd_quatf(angle: atan2(port.normal.x, port.normal.z), axis: SIMD3(0, 1, 0)))
                    matrix.columns.3 = SIMD4(port.point + port.normal * 0.003 + SIMD3(0, 0.007, 0), 1)
                    let lens = SIMD3<Float>(0.0033, 0.0023, 0.0025)
                    green.box(size: lens, center: SIMD3(-0.0045, 0, 0), matrix: matrix)
                    amber.box(size: lens, center: SIMD3(0.0045, 0, 0), matrix: matrix)
                    let lamp = try amber.model(material: materials.activity)
                    lamp.isEnabled = false
                    lights.addChild(lamp)
                    amberLEDs.append((atStart: index == 0, entity: lamp))
                }
                guard !green.indices.isEmpty else { continue }
                let linkLED = try green.model(material: materials.power)
                linkLED.isEnabled = false
                lights.addChild(linkLED)
                let participants = Set(circuit.flatMap { [$0.fromDeviceID, $0.toDeviceID] })
                let poweredEndpoints = Set([from, to].filter { !$0.modelID.hasPrefix("patch-") }.map(\.id))
                let portsEnabled = circuit.allSatisfy { segment in
                    devices[segment.fromDeviceID]?.shutdownPorts?.contains(segment.fromPort) != true
                    && devices[segment.toDeviceID]?.shutdownPorts?.contains(segment.toPort) != true
                }
                trafficCircuits.append(.init(id: link.id, devices: participants, poweredEndpoints: poweredEndpoints,
                                             portsEnabled: portsEnabled, route: route, cableRadius: link.medium.cableRadius,
                                             greenLEDs: linkLED, amberLEDs: amberLEDs))
            }
            guard !trafficCircuits.isEmpty else { return }
            let dot = MeshResource.generateSphere(radius: 0.005)
            for _ in 0..<min(5, trafficCircuits.count) {
                let lights = [ModelEntity(mesh: dot, materials: [materials.power]),
                              ModelEntity(mesh: dot, materials: [materials.activity]),
                              ModelEntity(mesh: dot, materials: [materials.power]),
                              ModelEntity(mesh: dot, materials: [materials.activity])]
                for marker in lights {
                    marker.isEnabled = false
                    cables.addChild(marker)
                }
                pulsePairs.append(lights)
            }
        }

        private func isPoweredOff(_ id: String) -> Bool {
            parent.poweredOff.contains(id) || devicePowerParents[id].map { parent.poweredOff.contains($0) } == true
        }

        private func configureTraffic() {
            let enabled = parent.showTraffic && parent.showCables && parent.isForeground &&
                (parent.mode != .ar || tracking && !awaitingPlacement)
            let settings = TrafficSettings(enabled: enabled, reducedMotion: parent.reduceMotion,
                                           poweredOff: parent.poweredOff, trace: parent.selectedLinkID,
                                           focus: parent.lockedDeviceID)
            guard trafficSettings != settings else { return }
            trafficSettings = settings
            let traced = parent.topology?.links.first { $0.id == settings.trace }
            let circuitID = traced.map { $0.circuitID ?? $0.id }
            var focused: [Int] = [], ordinary: [Int] = []
            for (index, circuit) in trafficCircuits.enumerated() {
                let connected = circuit.portsEnabled && !circuit.poweredEndpoints.contains(where: { isPoweredOff($0) })
                circuit.greenLEDs.isEnabled = connected
                for lamp in circuit.amberLEDs { lamp.entity.isEnabled = false }
                guard connected, enabled else { continue }
                if let circuitID {
                    if circuit.id == circuitID { focused.append(index) }
                } else if let focus = settings.focus {
                    if circuit.devices.contains(focus) { focused.append(index) }
                } else { ordinary.append(index) }
            }
            if ordinary.count > pulsePairs.count {
                // Spread the overview across the topology. A trace or a pin keeps its own circuits.
                activeTraffic = pulsePairs.indices.map { ordinary[$0 * ordinary.count / pulsePairs.count] }
            } else {
                activeTraffic = Array((focused + ordinary).prefix(pulsePairs.count))
            }
            for (index, lights) in pulsePairs.enumerated() {
                for marker in lights {
                    marker.isEnabled = index < activeTraffic.count
                }
            }
            trafficTask?.cancel()
            trafficTask = nil
            paintTraffic(at: ProcessInfo.processInfo.systemUptime, staticFrame: settings.reducedMotion)
            updateDashboards(force: true)
            let sampleDashboards = !dashboards.isEmpty && parent.isForeground && (parent.mode != .ar || tracking && !awaitingPlacement)
            guard !settings.reducedMotion, !activeTraffic.isEmpty || sampleDashboards else { return }
            trafficTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    guard let delay = self.map({ $0.activeTraffic.isEmpty ? 1000 : 33 }) else { break }
                    do { try await Task.sleep(for: .milliseconds(delay)) } catch { break }
                    guard let self else { break }
                    if !self.activeTraffic.isEmpty { self.paintTraffic(at: ProcessInfo.processInfo.systemUptime, staticFrame: false) }
                    self.updateDashboards()
                }
            }
        }

        private func trafficCamera() -> (eye: SIMD3<Float>, forward: SIMD3<Float>, focal: Float)? {
            guard let view, view.bounds.height > 0 else { return nil }
            let height = Float(view.bounds.height)
            if let camera {
                let focal = height / (2 * tan(camera.camera.fieldOfViewInDegrees * .pi / 360))
                return (camera.position, camera.orientation.act(SIMD3(0, 0, -1)), focal)
            }
            guard let arCamera = view.session.currentFrame?.camera, let rootAnchor else { return nil }
            let windowScene = view.window?.windowScene
            let interfaceOrientation: UIInterfaceOrientation?
            if #available(iOS 26, *) { interfaceOrientation = windowScene?.effectiveGeometry.interfaceOrientation }
            else { interfaceOrientation = windowScene?.interfaceOrientation }
            let orientation = interfaceOrientation.flatMap { $0 == .unknown ? nil : $0 } ?? .portrait
            let projection = arCamera.projectionMatrix(for: orientation, viewportSize: view.bounds.size, zNear: 0.01, zFar: 100)
            let transform = simd_inverse(rootAnchor.transform.matrix) * arCamera.transform
            let eye = SIMD3(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
            let forward = simd_normalize(-SIMD3(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z))
            return (eye, forward, height * abs(projection.columns.1.y) / 2)
        }

        private func paintTraffic(at time: TimeInterval, staticFrame: Bool) {
            guard !activeTraffic.isEmpty, let viewGeometry = trafficCamera() else { return }
            for (slot, index) in activeTraffic.enumerated() {
                let circuit = trafficCircuits[index]
                let period = max(1.1, circuit.route.length / 1.3)
                let phase = Float((time / Double(period) + Double(index) * 0.173).truncatingRemainder(dividingBy: 1))
                let outbound: Float = staticFrame ? 0.23 : phase
                let inbound: Float = staticFrame ? 0.73 : 1 - (phase + 0.42).truncatingRemainder(dividingBy: 1)
                let tailLength = min(0.05, 0.033 / circuit.route.length)
                let fractions = [outbound, inbound, outbound - tailLength, inbound + tailLength]
                let surface = circuit.cableRadius * (parent.selectedLinkID == nil ? 1 : 1.55)
                for (index, marker) in pulsePairs[slot].enumerated() {
                    let fraction = fractions[index]
                    let point = circuit.route.point(at: fraction)
                    let delta = point - viewGeometry.eye
                    let depth = simd_dot(delta, viewGeometry.forward)
                    let shown = depth > 0.02 && (0...1).contains(fraction)
                    marker.isEnabled = shown
                    guard shown else { continue }
                    let radius = LabTrafficRoute.markerRadius(cableRadius: circuit.cableRadius, depth: depth,
                                                             projectedPointsAtOneMeter: viewGeometry.focal)
                    marker.scale = SIMD3(repeating: radius / 0.005 * (index < 2 ? 1 : 0.62))
                    // Bias toward the viewer by one wire radius so a tiny packet isn't buried inside the wire.
                    marker.position = point - simd_normalize(delta) * surface * 0.96
                }
                for lamp in circuit.amberLEDs {
                    let pulseAtJack = lamp.atStart ? min(outbound, inbound) < 0.16 : max(outbound, inbound) > 0.84
                    lamp.entity.isEnabled = staticFrame || pulseAtJack
                }
            }
        }

        private func repaintStaticTraffic() {
            if parent.reduceMotion { paintTraffic(at: 0, staticFrame: true) }
        }

        private func wireMaterial(_ medium: LabTopology.Medium) -> SimpleMaterial {
            switch medium {
            case .fiber: return materials.fiberWire
            case .console: return materials.consoleWire
            default: return materials.copperWire
            }
        }

        private func addTray(from start: SIMD3<Float>, to end: SIMD3<Float>, mesh: inout LabSceneMesh) {
            let delta = end - start, length = simd_length(delta)
            guard length > 0.015 else { return }
            var transform = simd_float4x4(simd_quatf(angle: atan2(delta.x, delta.z), axis: SIMD3(0, 1, 0)))
            transform.columns.3 = SIMD4((start + end) / 2, 1)
            for x: Float in [-0.054, 0.054] {
                mesh.box(size: SIMD3(0.008, 0.033, length), center: SIMD3(x, -0.008, 0), matrix: transform)
            }
            for rung in 0..<max(1, Int(length / 0.16)) {
                mesh.box(size: SIMD3(0.112, 0.006, 0.014),
                         center: SIMD3(0, -0.015, min(length / 2 - 0.007, -length / 2 + 0.012 + Float(rung) * 0.16)), matrix: transform)
            }
        }

        private func showPortLabels(_ ports: [LabScenePort]) {
            guard let container = portLabelsEntity else { return }
            container.children.removeAll()
            do {
                for port in ports {
                    let tag = try label(port.name, width: 0.12, height: 0.018)
                    tag.position = port.point + port.normal * 0.035 + SIMD3(0, 0.025, 0)
                    tag.orientation = simd_quatf(angle: atan2(port.normal.x, port.normal.z), axis: SIMD3(0, 1, 0))
                    container.addChild(tag)
                }
            } catch { report(error.localizedDescription) }
        }

        private func registerPower(_ entity: Entity, placementID: String) {
            if let model = entity as? ModelEntity {
                if model.name == "power" { indicators[placementID, default: []].append(model) }
                if model.name == "screen" { screens[placementID, default: []].append(model) }
            }
            for child in entity.children { registerPower(child, placementID: placementID) }
        }

        private func hardwareSize(_ id: String) -> SIMD3<Float> { HardwareCatalog.renderSize(id) }

        private func hardware(_ id: String) throws -> Entity {
            if let template = hardwareTemplates[id] { return template.clone(recursive: true) }
            var parts = Array(repeating: LabSceneMesh(), count: 6)
            func box(_ part: Int, _ size: SIMD3<Float>, _ center: SIMD3<Float>) { parts[part].box(size: size, center: center) }
            let size = hardwareSize(id), w = size.x, h = size.y, d = size.z
            let rackDevice = RackMount.units(id) == 2 || id.hasPrefix("switch-") || id.hasPrefix("patch-") || id.hasPrefix("server-")
            if id != "raspberry-pi5" {
                box(rackDevice || id == "pc-optiplex7010" || id == "phone-7960" ? 0 : 1, size, .zero)
            }
            let front = -d / 2 - 0.002
            if id.hasPrefix("patch-") {
                let count = LabDemo.ports(id).count / 2
                for side: Float in [-1, 1] {
                    let z = side * (d / 2 + 0.002)
                    box(1, SIMD3(w - 0.004, h - 0.003, 0.004), SIMD3(0, 0, z))
                    for port in 0..<count {
                        let x = (Float(port) - Float(count - 1) / 2) * (w - 0.045) / Float(count)
                        box(2, SIMD3(0.014, 0.014, 0.003), SIMD3(x, -0.004, z + side * 0.002))
                        box(3, SIMD3(0.011, 0.010, 0.002), SIMD3(x, -0.004, z + side * 0.004))
                    }
                }
            } else if id == "ups-9px" {
                box(1, SIMD3(w - 0.012, h - 0.012, 0.006), SIMD3(0, 0, front))
                box(5, SIMD3(0.094, 0.026, 0.003), SIMD3(0.115, -0.005, front - 0.004))
                box(4, SIMD3(0.009, 0.006, 0.003), SIMD3(0.17, -0.009, front - 0.004))
                for slot in 0..<17 {
                    box(3, SIMD3(0.005, 0.039, 0.002), SIMD3(-0.19 + Float(slot) * 0.013, -0.005, front - 0.004))
                }
                for socket in 0..<8 {
                    box(3, SIMD3(0.026, 0.021, 0.004), SIMD3(-0.17 + Float(socket) * 0.044, 0, d / 2 + 0.003))
                }
            } else if id == "switch-2960" || id == "switch-3560" {
                box(1, SIMD3(w - 0.006, h - 0.003, 0.003), SIMD3(0, 0, front + 0.001))
                for row in 0..<2 { for port in 0..<12 {
                    let x = -w / 2 + 0.045 + Float(port) * 0.023
                    let y = -0.009 + Float(row) * 0.018
                    box(2, SIMD3(0.018, 0.015, 0.004), SIMD3(x, y, front - 0.001))
                    box(3, SIMD3(0.015, 0.011, 0.002), SIMD3(x, y, front - 0.004))
                    box(4, SIMD3(0.003, 0.002, 0.002), SIMD3(x + 0.009, y + 0.006, front - 0.002))
                } }
                for port in 0..<2 {
                    box(3, SIMD3(id == "switch-3560" ? 0.014 : 0.015, 0.013, 0.004), SIMD3(w / 2 - 0.055 + Float(port) * 0.024, 0, front))
                }
                box(4, SIMD3(0.006, 0.006, 0.004), SIMD3(-w / 2 + 0.016, 0, front))
                box(2, SIMD3(0.036, 0.023, 0.003), SIMD3(w / 2 - 0.042, 0, d / 2 + 0.001))
                box(3, SIMD3(0.017, 0.012, 0.002), SIMD3(w / 2 - 0.042, 0, d / 2 + 0.003))
            } else if id == "router-1941" || id == "router-2911" || id == "firewall-asa5505" {
                let count = id == "router-1941" ? 2 : id == "router-2911" ? 3 : 8
                for port in 0..<count {
                    box(3, SIMD3(0.016, 0.014, 0.005), SIMD3(-w / 2 + 0.027 + Float(port) * 0.021, 0, d / 2 + 0.002))
                }
                box(1, SIMD3(w * 0.95, h * 0.84, 0.002), SIMD3(0, 0, front + 0.001))
                for row in 0..<3 { for vent in 0..<20 {
                    box(3, SIMD3(0.004, h * 0.09, 0.002),
                        SIMD3(-w * 0.40 + Float(vent) * w * 0.027, (Float(row) - 1) * h * 0.19, front - 0.001))
                } }
                for led in 0..<4 {
                    box(4, SIMD3(0.003, 0.003, 0.002), SIMD3(w / 2 - 0.019 - Float(led) * 0.012, 0, front - 0.001))
                }
                if id != "firewall-asa5505" {
                    for x in [-w / 4, w / 4] {
                        box(2, SIMD3(w * 0.42, 0.021, 0.003), SIMD3(x, 0.021, d / 2 + 0.002))
                        box(3, SIMD3(w * 0.35, 0.012, 0.002), SIMD3(x, 0.021, d / 2 + 0.004))
                    }
                }
            } else if id.hasPrefix("server-") {
                // Catalogued SFF example: ten 2.5-inch bays; occupancy is illustrative, not detected hardware.
                box(0, SIMD3(w - 0.035, h - 0.006, 0.005), SIMD3(0, 0, front))
                let bayWidth = (w - 0.07) / 5, bayHeight = (h - 0.008) / 2
                for row in 0..<2 { for bay in 0..<5 {
                    let x = -w / 2 + 0.035 + bayWidth * (Float(bay) + 0.5)
                    let y = (Float(row) - 0.5) * bayHeight
                    box(2, SIMD3(bayWidth - 0.002, bayHeight - 0.002, 0.006), SIMD3(x, y, front - 0.004))
                    box(3, SIMD3(bayWidth - 0.01, bayHeight * 0.35, 0.004), SIMD3(x, y, front - 0.009))
                    box(4, SIMD3(0.003, 0.003, 0.004), SIMD3(x + bayWidth * 0.37, y, front - 0.009))
                } }
                for port in LabDemo.ports(id).indices {
                    box(3, SIMD3(0.016, 0.014, 0.004), SIMD3(-0.04 + Float(port) * 0.024, 0, d / 2 + 0.003))
                }
                if id == "server-firewall" {
                    box(2, SIMD3(0.075, 0.021, 0.003), SIMD3(-0.16, 0, front - 0.009))
                }
                for supply in 0..<2 {
                    let x = w / 2 - 0.055 - Float(supply) * 0.075
                    box(2, SIMD3(0.068, 0.035, 0.003), SIMD3(x, 0, d / 2 + 0.002))
                    box(3, SIMD3(0.014, 0.010, 0.004), SIMD3(x + 0.018, 0, d / 2 + 0.004))
                    for vent in 0..<7 {
                        box(3, SIMD3(0.003, 0.022, 0.002), SIMD3(x - 0.025 + Float(vent) * 0.0045, 0, d / 2 + 0.004))
                    }
                }
                for x in [-w / 2 + 0.01, w / 2 - 0.01] { box(2, SIMD3(0.014, h * 0.7, 0.024), SIMD3(x, 0, front - 0.008)) }
                box(4, SIMD3(0.006, 0.006, 0.005), SIMD3(-w / 2 + 0.025, 0, front - 0.005))
            } else if id == "raspberry-pi5" {
                box(0, SIMD3(w * 0.91, 0.004, d * 0.89), SIMD3(0, -0.010, 0))
                box(2, SIMD3(0.045, 0.005, 0.041), SIMD3(-0.010, 0.002, -0.005))
                for fin in 0..<9 {
                    box(2, SIMD3(0.002, 0.010, 0.041),
                        SIMD3(-0.030 + Float(fin) * 0.005, 0.008, -0.005))
                }
                for x: Float in [-0.022, 0.002, 0.026] {
                    box(2, SIMD3(0.016, 0.013, 0.017), SIMD3(x, 0, d / 2 - 0.007))
                    box(3, SIMD3(0.013, 0.008, 0.005), SIMD3(x, 0.002, d / 2 + 0.001))
                }
                for pin in 0..<12 {
                    box(2, SIMD3(0.0018, 0.007, 0.0018),
                        SIMD3(-0.038 + Float(pin) * 0.0042, -0.002, -0.027))
                }
                box(4, SIMD3(0.004, 0.002, 0.004), SIMD3(w / 2 - 0.008, -0.005, -d / 2 + 0.006))
            } else if id == "access-point" {
                box(2, SIMD3(w * 0.72, 0.006, d * 0.72), SIMD3(0, -h / 2, 0))
                box(4, SIMD3(0.030, 0.002, 0.002), SIMD3(0, h / 2 + 0.001, -d / 2 + 0.02))
                for slot in 0..<8 {
                    box(3, SIMD3(0.002, 0.009, 0.001), SIMD3(-0.052 + Float(slot) * 0.014, -0.007, front + 0.001))
                }
            } else if id == "camera-ip" {
                parts[2].tube(from: SIMD3(0, -h / 2 - 0.032, 0.038), to: SIMD3(0, 0.006, 0.038), radius: 0.017)
                box(2, SIMD3(w, 0.006, 0.083), SIMD3(0, -h / 2 - 0.033, 0.028))
                parts[3].tube(from: SIMD3(0, 0, front + 0.001), to: SIMD3(0, 0, front - 0.006), radius: 0.033)
                parts[5].tube(from: SIMD3(0, 0, front - 0.006), to: SIMD3(0, 0, front - 0.008), radius: 0.018)
                for n in 0..<8 {
                    let angle = Float(n) * .pi / 4
                    parts[2].tube(from: SIMD3(cos(angle) * 0.026, sin(angle) * 0.026, front - 0.007),
                                  to: SIMD3(cos(angle) * 0.026, sin(angle) * 0.026, front - 0.009), radius: 0.003)
                }
            } else if id == "pc-optiplex7010" {
                box(1, SIMD3(w - 0.012, h - 0.015, 0.007), SIMD3(0, 0, front))
                for vent in 0..<12 { box(3, SIMD3(w * 0.6, 0.005, 0.004), SIMD3(0, -h * 0.35 + Float(vent) * h * 0.04, front - 0.005)) }
                box(3, SIMD3(w * 0.7, 0.015, 0.004), SIMD3(0, h * 0.29, front - 0.005))
                box(4, SIMD3(0.01, 0.01, 0.005), SIMD3(0, h * 0.4, front - 0.005))
            } else if id == "laptop-latitude5420" {
                for row in 0..<4 { for key in 0..<10 {
                    box(3, SIMD3(0.019, 0.002, 0.016), SIMD3(-0.115 + Float(key) * 0.025, h / 2 + 0.002, -0.025 + Float(row) * 0.021))
                } }
                box(0, SIMD3(0.09, 0.001, 0.045), SIMD3(0, h / 2 + 0.002, -0.073))
                box(0, SIMD3(w, 0.19, 0.012), SIMD3(0, 0.10, d / 2))
                box(5, SIMD3(w - 0.022, 0.165, 0.003), SIMD3(0, 0.10, d / 2 - 0.008))
            } else if id == "phone-7960" {
                box(0, SIMD3(w * 0.25, 0.035, d * 0.9), SIMD3(-w * 0.32, h / 2 + 0.015, 0))
                box(5, SIMD3(w * 0.44, 0.003, d * 0.25), SIMD3(w * 0.1, h / 2 + 0.003, d * 0.18))
                for row in 0..<4 { for key in 0..<3 {
                    box(2, SIMD3(0.02, 0.006, 0.017), SIMD3(-0.01 + Float(key) * 0.027, h / 2 + 0.005, -0.075 + Float(row) * 0.025))
                } }
                for key in 0..<6 { box(2, SIMD3(0.017, 0.005, 0.01), SIMD3(w * 0.39, h / 2 + 0.005, -0.005 + Float(key) * 0.017)) }
                for key in 0..<4 { box(2, SIMD3(0.014, 0.005, 0.009), SIMD3(-0.01 + Float(key) * 0.022, h / 2 + 0.005, d * 0.015)) }
            }
            let group = Entity(); group.name = "hardware:" + id
            let surfaceMaterials: [any RealityKit.Material] = [materials.graphite, materials.panel, materials.metal, materials.dark, materials.power, materials.screen]
            for (index, mesh) in parts.enumerated() where !mesh.indices.isEmpty {
                let model = try mesh.model(material: surfaceMaterials[index])
                if index == 4 { model.name = "power" }; if index == 5 { model.name = "screen" }
                group.addChild(model)
            }
            var shape = ShapeResource.generateBox(size: size)
            if id == "laptop-latitude5420" { shape = .generateBox(size: SIMD3(w, 0.23, d)).offsetBy(translation: SIMD3(0, 0.10, 0)) }
            group.components.set(CollisionComponent(shapes: [shape]))
            var rim = LabSceneMesh()
            let visualSize = id == "laptop-latitude5420" ? SIMD3(w, Float(0.23), d) : size
            let centerY: Float = id == "laptop-latitude5420" ? 0.10 : 0
            let half = visualSize / 2 + SIMD3<Float>(repeating: 0.002)
            for x in [-half.x, half.x] { for z in [-half.z, half.z] { rim.box(size: SIMD3(0.0015, half.y * 2, 0.0015), center: SIMD3(x, centerY, z)) } }
            for y in [-half.y + centerY, half.y + centerY] {
                for z in [-half.z, half.z] { rim.box(size: SIMD3(half.x * 2, 0.0015, 0.0015), center: SIMD3(0, y, z)) }
                for x in [-half.x, half.x] { rim.box(size: SIMD3(0.0015, 0.0015, half.z * 2), center: SIMD3(x, y, 0)) }
            }
            let highlight = try rim.model(material: materials.accent)
            highlight.name = "hardware-selection"; highlight.isEnabled = false
            group.addChild(highlight)
            if rackDevice, parent.topology == nil, let item = HardwareCatalog.item(id) {
                let plate = try label(item.name, width: min(w * 0.25, 0.09), height: 0.009)
                plate.position = SIMD3(id.hasPrefix("switch-") ? w * 0.20 : w * 0.27, h * 0.31, front - 0.007)
                group.addChild(plate)
            }
            hardwareTemplates[id] = group
            return group.clone(recursive: true)
        }

        private func label(_ text: String, width: Float, height: Float) throws -> ModelEntity {
            let material: UnlitMaterial
            if let cached = labelMaterials[text] { material = cached }
            else {
                let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
                let image = UIGraphicsImageRenderer(size: CGSize(width: 768, height: 96), format: format).image { context in
                    UIColor(white: 0.06, alpha: 1).setFill(); context.fill(CGRect(x: 0, y: 0, width: 768, height: 96))
                    let fontSize = min(CGFloat(58), CGFloat(700) / CGFloat(max(text.count, 1)) / 0.62)
                    let font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .semibold)
                    let style = NSMutableParagraphStyle(); style.alignment = .center
                    (text as NSString).draw(in: CGRect(x: 18, y: (96 - font.lineHeight) / 2, width: 732, height: font.lineHeight + 2),
                                           withAttributes: [.font: font, .foregroundColor: UIColor.white, .paragraphStyle: style])
                }
                guard let cgImage = image.cgImage else { throw LabLayoutError.invalid("No se pudo generar una etiqueta de equipo.") }
                let texture = try TextureResource.generate(from: cgImage, options: .init(semantic: .color))
                var value = UnlitMaterial(); value.color = .init(tint: .white, texture: .init(texture))
                labelMaterials[text] = value; material = value
            }
            let entity = ModelEntity(mesh: .generatePlane(width: width, height: height), materials: [material])
            entity.orientation = simd_quatf(angle: .pi, axis: SIMD3(0, 1, 0))
            return entity
        }

        func updateState() {
            let scale = SIMD3(repeating: parent.sceneScale)
            if let scaledContent, scaledContent.scale != scale { scaledContent.scale = scale }
            roomEntity?.isEnabled = parent.paintRoom
            cablesEntity?.isEnabled = parent.showCables
            electricalEntity?.isEnabled = parent.showCables
            for lead in electricalLeads { lead.isEnabled = parent.showCables }
            portLabelsEntity?.isEnabled = parent.showCables || parent.inspectionDestination?.port != nil
            if lastPoweredOff != parent.poweredOff {
                lastPoweredOff = parent.poweredOff
                for (id, models) in indicators { for model in models { model.model?.materials = [isPoweredOff(id) ? materials.off : materials.power] } }
                for (id, models) in screens { for model in models { model.model?.materials = [isPoweredOff(id) ? materials.dark : materials.screen] } }
                for (id, overlays) in consoleScreens {
                    for overlay in overlays { overlay.isEnabled = !isPoweredOff(id) }
                }
            }
            if lastLockedDeviceID != parent.lockedDeviceID {
                lastLockedDeviceID = parent.lockedDeviceID
                highlightedDevice?.isEnabled = false
                highlightedDevice = parent.lockedDeviceID.flatMap { deviceHighlights[$0] }
                highlightedDevice?.isEnabled = true
            }
            configureTraffic()
            for (id, entity) in highlights { entity.isEnabled = parent.selection?.id == id }
            if lastSelectedLinkID != parent.selectedLinkID || lastInspectedPort != parent.inspectionDestination {
                lastSelectedLinkID = parent.selectedLinkID
                lastInspectedPort = parent.inspectionDestination
                updateTraceAndPortLabels()
            }
            if parent.selection != nil && selectedHardwareHighlight !== highlightedDevice { selectedHardwareHighlight?.isEnabled = false }
            if parent.mode == .room && parent.virtualPose == nil {
                let key = parent.focusDeviceID.map { "device:" + $0 } ?? parent.selection.map { "placement:" + $0.id }
                if let destination = parent.inspectionDestination, let topology = parent.topology,
                   parent.inspectionRevision != lastInspectionRevision {
                    lastInspectionRevision = parent.inspectionRevision
                    focusOrbit(on: destination, in: topology)
                } else if key != lastFocusKey {
                    lastFocusKey = key
                    if let id = parent.focusDeviceID,
                       let device = parent.topology?.devices.first(where: { $0.id == id }),
                       let placement = parent.layout.placements.first(where: { $0.id == device.placementID }) {
                        let rotation = simd_quatf(angle: placement.yaw, axis: SIMD3(0, 1, 0))
                        cameraTarget = placement.position + rotation.act(device.offset)
                        cameraRadius = max(0.8, simd_length(hardwareSize(device.modelID)) * 2)
                        cameraYaw = placement.yaw + .pi / 10; cameraPitch = 0.22
                        cameraMoved = true
                        updateCamera()
                    } else if let placement = parent.selection {
                        cameraTarget = placement.position + SIMD3(0, placement.size.y / 2, 0)
                        cameraRadius = max(2.5, simd_length(placement.size) * 1.5)
                        cameraYaw = placement.yaw + .pi / 10; cameraPitch = 0.3
                        cameraMoved = true
                        updateCamera()
                    }
                }
            }
        }

        private func updateTraceAndPortLabels() {
            guard let topology = parent.topology else { return }
            let picked = topology.links.first { $0.id == parent.selectedLinkID }
            let circuit = picked.map(topology.circuit(for:)) ?? []
            let ids = Set(circuit.map(\.id))
            for (id, body) in linkBodies { body.isEnabled = !ids.contains(id) }
            for (id, trace) in traceBodies { trace.isEnabled = ids.contains(id) }

            var endpoints: [(String, String)] = []
            if let first = circuit.first, let last = circuit.last {
                endpoints = [(first.fromDeviceID, first.fromPort), (last.toDeviceID, last.toPort)]
            }
            if let focus = parent.inspectionDestination, let port = focus.port,
               !endpoints.contains(where: { $0 == (focus.deviceID, port) }) {
                endpoints.append((focus.deviceID, port))
            }
            let labels = endpoints.compactMap { id, name in
                topology.devices.first(where: { $0.id == id }).flatMap { try? worldPort($0, name) }
            }
            showPortLabels(labels)
        }

        private func focusOrbit(on destination: LabInspectionDestination, in topology: LabTopology) {
            let observer = camera?.position ?? LabWalkPose.start(in: parent.layout).position
            guard let spot = destination.spot(in: topology, layout: parent.layout, observer: observer) else { return }
            let initial = LabWalkPose(position: observer, yaw: 0)
            let rackTarget = destination.port == nil ? LabFocusTarget.inventory(topology, in: parent.layout)
                .first(where: { $0.id == destination.deviceID }) : nil
            let framing = rackTarget.map { initial.framing($0, in: parent.layout) }
                ?? initial.inspecting(spot.point, fromSide: spot.normal, in: parent.layout)
            let distance = simd_distance(spot.point, framing.position)
            cameraTarget = framing.position + framing.rotation.act(SIMD3(0, 0, -distance))
            let offset = framing.position - cameraTarget
            cameraRadius = max(0.35, simd_length(offset))
            cameraYaw = atan2(offset.x, -offset.z)
            cameraPitch = atan2(offset.y, simd_length(SIMD2(offset.x, offset.z)))
            cameraMoved = true
            updateCamera()
        }

        @objc func tap(_ recognizer: UITapGestureRecognizer) {
            guard let view else { return }
            guard parent.mode == .room || tracking else { return }
            if awaitingPlacement {
                let point = recognizer.location(in: view)
                if let name = parent.worldPlacementName {
                    guard !parent.restoresWorldPlacement,
                          let result = view.raycast(from: point, allowing: .existingPlaneGeometry, alignment: .horizontal)
                            .first(where: {
                                guard let plane = $0.anchor as? ARPlaneAnchor else { return false }
                                switch plane.classification {
                                case .ceiling, .table, .seat, .wall, .window, .door: return false
                                default: return true
                                }
                            }), let frame = view.session.currentFrame else {
                        if !parent.restoresWorldPlacement {
                            parent.walkthrough?.placementHint = "Mueve el iPhone hacia el piso hasta detectarlo y vuelve a tocar."
                        }
                        return
                    }
                    let position = result.worldTransform.columns.3
                    let camera = frame.camera.transform.columns.3
                    let yaw = atan2(position.x - camera.x, position.z - camera.z)
                    var matrix = simd_float4x4(simd_quatf(angle: yaw, axis: SIMD3<Float>(0, 1, 0)))
                    matrix.columns.3 = position
                    let anchor = ARAnchor(name: name, transform: matrix)
                    view.session.add(anchor: anchor)
                    applyWorldPlacement(anchor)
                } else {
                    guard let result = view.raycast(from: point, allowing: .estimatedPlane, alignment: .horizontal).first else {
                        parent.walkthrough?.placementHint = "Mueve el iPhone para detectar una superficie y vuelve a tocar."
                        return
                    }
                    rootAnchor?.transform = Transform(matrix: result.worldTransform)
                    confirmPlacement()
                }
                rootAnchor?.isEnabled = true
                transition(.ready)
                return
            }
            let target = target(at: recognizer.location(in: view))
            parent.selection = nil
            if selectedHardwareHighlight !== highlightedDevice { selectedHardwareHighlight?.isEnabled = false }
            if let highlight = target?.highlight {
                selectedHardwareHighlight = highlight
                highlight.isEnabled = true
            }
            switch target?.item {
            case .link(let id): parent.onSelectLink(id)
            case .device(let id): parent.onSelectDevice(id)
            case .hardware(let id): parent.onSelectHardware(id)
            case .placement(let id): parent.selection = parent.layout.placements.first { $0.id == id }
            case nil: break
            }
            updateState()
        }

        private func target(at point: CGPoint) -> (item: LabSceneTarget, highlight: Entity?, deviceID: String?)? {
            var entity = view?.entity(at: point)
            while let current = entity {
                if let port = portHits[ObjectIdentifier(current)] {
                    if parent.showCables, let link = parent.topology?.links.first(where: {
                        ($0.fromDeviceID == port.deviceID && $0.fromPort == port.name)
                            || ($0.toDeviceID == port.deviceID && $0.toPort == port.name)
                    }) { return (.link(link.id), nil, port.deviceID) }
                    return (.device(port.deviceID), nil, port.deviceID)
                }
                if current.name.hasPrefix("cable:") {
                    return (.link(String(current.name.dropFirst("cable:".count))), nil, nil)
                }
                if current.name.hasPrefix("device:") {
                    let id = String(current.name.dropFirst("device:".count))
                    return (.device(id), current.findEntity(named: "hardware-selection"), id)
                }
                if current.name.hasPrefix("hardware:") {
                    return (.hardware(String(current.name.dropFirst("hardware:".count))), current.findEntity(named: "hardware-selection"), nil)
                }
                if current.name.hasPrefix("placement:") {
                    return (.placement(String(current.name.dropFirst("placement:".count))), nil, nil)
                }
                entity = current.parent
            }
            return nil
        }

        @objc func pan(_ recognizer: UIPanGestureRecognizer) {
            guard let view, parent.mode == .room else { return }
            cameraMoved = true
            let delta = recognizer.translation(in: view)
            if recognizer.numberOfTouches >= 2 {
                let right = SIMD3(cos(cameraYaw), 0, -sin(cameraYaw))
                let forward = SIMD3(sin(cameraYaw), 0, cos(cameraYaw))
                cameraTarget += (-right * Float(delta.x) + forward * Float(delta.y)) * cameraRadius / 700
            } else {
                cameraYaw -= Float(delta.x) * 0.006
                cameraPitch = min(1.35, max(0.12, cameraPitch + Float(delta.y) * 0.006))
            }
            recognizer.setTranslation(.zero, in: view)
            updateCamera()
        }

        @objc func pinch(_ recognizer: UIPinchGestureRecognizer) {
            guard parent.mode == .room else { return }
            cameraMoved = true
            cameraRadius = min(40, max(0.8, cameraRadius / Float(recognizer.scale)))
            recognizer.scale = 1
            updateCamera()
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            !(gestureRecognizer is UITapGestureRecognizer) && !(otherGestureRecognizer is UITapGestureRecognizer)
        }

        private var orbitRotation: simd_quatf {
            let backward = SIMD3(sin(cameraYaw) * cos(cameraPitch), sin(cameraPitch), -cos(cameraYaw) * cos(cameraPitch))
            let right = simd_normalize(simd_cross(SIMD3<Float>(0, 1, 0), backward))
            let up = simd_cross(backward, right)
            return simd_quatf(simd_float3x3(columns: (right, up, backward)))
        }

        private func updateCamera() {
            let rotation = orbitRotation
            camera?.position = cameraTarget + rotation.act(SIMD3(0, 0, cameraRadius))
            camera?.orientation = rotation
            repaintStaticTraffic()
        }

        func updateWalkCamera() {
            guard let pose = parent.virtualPose, let camera else { return }
            let lockChanged = lastWalkLock != parent.lockedDeviceID
            let viewport = view?.bounds.size ?? .zero
            if viewport.width > 0, viewport.height > 0 {
                let aspect = Float(viewport.width / viewport.height)
                let minVerticalField = 2 * atan(1.52 / (3 * aspect)) * 180 / .pi
                let field = parent.lockedDeviceID != nil && parent.inspectionDestination?.port == nil
                    ? max(60, min(94, minVerticalField)) : 60
                if camera.camera.fieldOfViewInDegrees != field { camera.camera.fieldOfViewInDegrees = field }
            }
            guard lastWalkPose != pose || lockChanged else { return }
            let rotate = lockChanged && parent.lockedDeviceID != nil && !parent.reduceMotion && parent.stereoEye == 0
                && (lastWalkPose.map { LabWalkPose.canTravel(from: $0.position, to: pose.position, in: parent.layout) } ?? false)
            lastWalkPose = pose
            lastWalkLock = parent.lockedDeviceID
            let transform = Transform(rotation: pose.rotation,
                                      translation: pose.position + pose.rotation.act(SIMD3(parent.stereoEye * 0.032, 0, 0)))
            cameraTurn?.stop()
            if rotate {
                cameraTurn = camera.move(to: transform, relativeTo: camera.parent, duration: 0.24, timingFunction: .easeInOut)
            } else {
                cameraTurn = nil
                camera.transform = transform
            }
            repaintStaticTraffic()
        }

        func applyZoom() {
            guard parent.mode == .room else { return }
            if lastOrbitReset != parent.orbitReset {
                lastOrbitReset = parent.orbitReset
                lastZoomStep = parent.zoomStep
                cameraTarget = defaultCameraTarget
                cameraYaw = .pi / 4
                cameraPitch = 0.75
                cameraMoved = false
                if let view { fitCamera(to: view.bounds.size) }
                return
            }
            guard lastZoomStep != parent.zoomStep else { return }
            cameraRadius = min(100, max(0.8, cameraRadius * pow(0.75, Float(parent.zoomStep - lastZoomStep))))
            lastZoomStep = parent.zoomStep
            cameraMoved = true
            updateCamera()
        }

        func layoutCamera(to size: CGSize) {
            if parent.virtualPose != nil { updateWalkCamera() }
            else { fitCamera(to: size) }
        }

        func fitCamera(to size: CGSize) {
            guard parent.mode == .room, parent.virtualPose == nil, !cameraMoved, size.width > 0, size.height > 0 else { return }
            cameraRadius = LabGeometry.orbitDistance(for: cameraBounds, target: cameraTarget, rotation: orbitRotation,
                                                     aspect: Float(size.width / size.height), verticalField: orbitFieldOfView)
            updateCamera()
        }

        func report(_ message: String?) {
            Task { @MainActor [weak self] in
                guard let self, view != nil else { return }
                let text = renderError ?? message
                if let text, parent.mode == .ar { suspend(.failed(text)) }
                else { parent.trackingMessage = text }
            }
        }

        private func transition(_ phase: ARWalkthrough.Phase) {
            guard let walkthrough = parent.walkthrough, walkthrough.phase != phase else { return }
            walkthrough.phase = phase
            if phase != .ready {
                walkthrough.pose = nil
                walkthrough.target = nil
                walkthrough.focusOrigin = nil
                walkthrough.deviceInSight = nil
            }
        }

        func hideTrackedContent() {
            tracking = false
            if rootAnchor?.isEnabled == true { rootAnchor?.isEnabled = false }
            configureTraffic()
        }

        private func suspend(_ phase: ARWalkthrough.Phase) {
            hideTrackedContent()
            transition(phase)
        }

        nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
            // The delegate queue is explicitly set to the main queue in makeUIView.
            MainActor.assumeIsolated { updateTracking(frame) }
        }

        private func applyWorldPlacement(_ anchor: ARAnchor) {
            placedAnchorID = anchor.identifier
            rootAnchor?.transform = Transform(matrix: anchor.transform)
            confirmPlacement()
        }

        private func confirmPlacement() {
            awaitingPlacement = false
            parent.walkthrough?.placementHint = nil
            parent.walkthrough?.placementConfirmed = true
        }

        private func updateTracking(_ frame: ARFrame) {
            guard parent.isForeground, let view, rootAnchor != nil, renderError == nil,
                  frame.timestamp - lastFrameTime >= 0.15 else { return }
            lastFrameTime = frame.timestamp
            if let phase = unavailablePhase(frame.camera.trackingState) { suspend(phase); return }
            tracking = true
            if let name = parent.worldPlacementName, (parent.restoresWorldPlacement || placedAnchorID != nil),
               let anchor = frame.anchors.first(where: { $0.name == name }) {
                if anchor.identifier != placedAnchorID { applyWorldPlacement(anchor) }
                else { rootAnchor?.transform = Transform(matrix: anchor.transform) }
            }
            if awaitingPlacement {
                transition(parent.restoresWorldPlacement ? .aligning : .placing)
                return
            }
            if rootAnchor?.isEnabled == false { rootAnchor?.isEnabled = true }
            configureTraffic()
            repaintStaticTraffic()
            if let walkthrough = parent.walkthrough {
                transition(.ready)
                let center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
                let hit = target(at: center)
                if walkthrough.target != hit?.item { walkthrough.target = hit?.item }
                if walkthrough.deviceInSight != hit?.deviceID { walkthrough.deviceInSight = hit?.deviceID }
                let t = rootAnchor.map { simd_inverse($0.transform.matrix) * frame.camera.transform } ?? frame.camera.transform
                let camera = SIMD3(t.columns.3.x, t.columns.3.y, t.columns.3.z)
                let forward = -SIMD3(t.columns.2.x, t.columns.2.y, t.columns.2.z)
                let modelCamera = camera / parent.sceneScale
                if walkthrough.focusOrigin != modelCamera { walkthrough.focusOrigin = modelCamera }
                if walkthrough.focusDirection != forward { walkthrough.focusDirection = forward }
                if !parent.arPlacementRequired || placedAnchorID != nil {
                    let pose = ARWalkthrough.Pose(position: SIMD2(modelCamera.x, modelCamera.z),
                                                  direction: SIMD2(-t.columns.2.x, -t.columns.2.z))
                    if walkthrough.pose != pose { walkthrough.pose = pose }
                    #if DEBUG
                    if parent.layout.facility != nil, let rootAnchor {
                        sampleDeviceWalk(cameraPosition: SIMD3(t.columns.3.x, t.columns.3.y, t.columns.3.z),
                                         anchorPosition: rootAnchor.position(relativeTo: nil), time: frame.timestamp)
                    }
                    #endif
                }
            }
        }

        #if DEBUG
        private var initialWalk: (camera: SIMD3<Float>, anchor: SIMD3<Float>)?
        private var walkSampleTime = -Double.infinity
        private var cameraTravel: Float = 0
        private var anchorTravel: Float = 0

        private func sampleDeviceWalk(cameraPosition: SIMD3<Float>, anchorPosition: SIMD3<Float>, time: TimeInterval) {
            guard time - walkSampleTime >= 2 else { return }
            walkSampleTime = time
            if initialWalk == nil { initialWalk = (cameraPosition, anchorPosition) }
            guard let initialWalk else { return }
            cameraTravel = max(cameraTravel, simd_distance(cameraPosition, initialWalk.camera))
            anchorTravel = max(anchorTravel, simd_distance(anchorPosition, initialWalk.anchor))
            let values: [String: Double] = [
                "sampledAt": Date().timeIntervalSince1970,
                "cameraTravelMeters": Double(cameraTravel),
                "anchorTravelMeters": Double(anchorTravel)
            ]
            let url = URL.cachesDirectory.appendingPathComponent("NexusWalkthrough.json")
            if let data = try? JSONEncoder().encode(values) { try? data.write(to: url, options: .atomic) }
        }
        #endif

        private func unavailablePhase(_ state: ARCamera.TrackingState) -> ARWalkthrough.Phase? {
            switch state {
            case .normal: return nil
            case .notAvailable: return .limited("La cámara aún no puede ubicar el iPhone.")
            case .limited(.initializing): return .starting
            case .limited(.relocalizing): return .aligning
            case .limited(.excessiveMotion): return .limited("Baja la velocidad y mantén el iPhone estable.")
            case .limited(.insufficientFeatures): return .limited("Apunta a una pared iluminada con detalles.")
            case .limited: return .limited("Mueve el iPhone despacio para recuperar la posición.")
            }
        }

        nonisolated func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
            MainActor.assumeIsolated {
                guard view != nil, rootAnchor != nil, renderError == nil,
                      let phase = unavailablePhase(camera.trackingState) else { return }
                suspend(phase)
            }
        }

        nonisolated func sessionWasInterrupted(_ session: ARSession) {
            MainActor.assumeIsolated { suspend(.interrupted) }
        }

        nonisolated func sessionInterruptionEnded(_ session: ARSession) {
            MainActor.assumeIsolated { suspend(parent.arPlacementRequired ? .starting : .aligning) }
        }

        nonisolated func sessionShouldAttemptRelocalization(_ session: ARSession) -> Bool { true }

        nonisolated func session(_ session: ARSession, didFailWithError error: any Error) {
            let message = "AR: " + error.localizedDescription
            MainActor.assumeIsolated { suspend(.failed(message)) }
        }
    }
}

extension LabTopology.Medium {
    var sceneColor: UIColor {
        switch self {
        case .copper: UIColor(red: 0.12, green: 0.42, blue: 0.93, alpha: 1)
        case .fiber: UIColor(red: 1, green: 0.53, blue: 0.07, alpha: 1)
        case .console: UIColor(red: 0.12, green: 0.73, blue: 0.74, alpha: 1)
        case .powerA: UIColor(red: 0.78, green: 0.21, blue: 0.22, alpha: 1)
        case .powerB: UIColor(red: 0.57, green: 0.35, blue: 0.90, alpha: 1)
        }
    }
}

enum LabSignalColor {
    static let outgoing = UIColor(red: 0.2, green: 0.95, blue: 0.58, alpha: 1)
    static let incoming = UIColor(red: 1, green: 0.48, blue: 0.13, alpha: 1)
    static let trace = UIColor(red: 1, green: 0.79, blue: 0.28, alpha: 1)
}

private struct LabSceneMaterials {
    let white: PhysicallyBasedMaterial
    let facilityFloor = SimpleMaterial(color: UIColor(red: 0.52, green: 0.59, blue: 0.62, alpha: 1), roughness: 0.8, isMetallic: false)
    let facilityWall = SimpleMaterial(color: UIColor(red: 0.34, green: 0.42, blue: 0.48, alpha: 1), roughness: 0.82, isMetallic: false)
    let coldAisle = SimpleMaterial(color: UIColor(red: 0.35, green: 0.63, blue: 0.72, alpha: 1), roughness: 0.84, isMetallic: false)
    let hotAisle = SimpleMaterial(color: UIColor(red: 0.72, green: 0.49, blue: 0.37, alpha: 1), roughness: 0.84, isMetallic: false)
    let graphite = SimpleMaterial(color: UIColor(red: 0.14, green: 0.16, blue: 0.18, alpha: 1), roughness: 0.57, isMetallic: false)
    let panel = SimpleMaterial(color: UIColor(red: 0.29, green: 0.34, blue: 0.37, alpha: 1), roughness: 0.49, isMetallic: false)
    let metal = SimpleMaterial(color: UIColor(red: 0.63, green: 0.67, blue: 0.69, alpha: 1), roughness: 0.36, isMetallic: true)
    let connector = SimpleMaterial(color: UIColor(red: 0.52, green: 0.61, blue: 0.63, alpha: 1), roughness: 0.36, isMetallic: false)
    let dark = SimpleMaterial(color: UIColor(white: 0.025, alpha: 1), roughness: 0.8, isMetallic: false)
    let power: UnlitMaterial
    let activity: UnlitMaterial
    let screen: UnlitMaterial
    let accent: UnlitMaterial
    let trace: UnlitMaterial
    let powerA: UnlitMaterial
    let powerB: UnlitMaterial
    let off = SimpleMaterial(color: UIColor(white: 0.12, alpha: 1), roughness: 0.8, isMetallic: false)
    let copperWire = SimpleMaterial(color: LabTopology.Medium.copper.sceneColor, roughness: 0.55, isMetallic: false)
    let fiberWire = SimpleMaterial(color: LabTopology.Medium.fiber.sceneColor, roughness: 0.55, isMetallic: false)
    let consoleWire = SimpleMaterial(color: LabTopology.Medium.console.sceneColor, roughness: 0.55, isMetallic: false)

    init() {
        var white = PhysicallyBasedMaterial()
        white.baseColor = .init(tint: .white)
        white.roughness = 0.92
        white.metallic = 0.0
        self.white = white
        var power = UnlitMaterial(); power.color = .init(tint: LabSignalColor.outgoing); self.power = power
        var activity = UnlitMaterial(); activity.color = .init(tint: LabSignalColor.incoming); self.activity = activity
        var screen = UnlitMaterial(); screen.color = .init(tint: UIColor(red: 0.03, green: 0.25, blue: 0.44, alpha: 1)); self.screen = screen
        var accent = UnlitMaterial(); accent.color = .init(tint: UIColor(red: 0.1, green: 0.58, blue: 1, alpha: 1)); self.accent = accent
        var trace = UnlitMaterial(); trace.color = .init(tint: LabSignalColor.trace); self.trace = trace
        var powerA = UnlitMaterial(); powerA.color = .init(tint: LabTopology.Medium.powerA.sceneColor); self.powerA = powerA
        var powerB = UnlitMaterial(); powerB.color = .init(tint: LabTopology.Medium.powerB.sceneColor); self.powerB = powerB
    }
}

private final class LabRenderView: ARView {
    var didLayout: ((CGSize) -> Void)?
    var didAttach: (() -> Void)?
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { didAttach?() }
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        didLayout?(bounds.size)
    }
}

private struct LabSceneMesh {
    var positions: [SIMD3<Float>] = []
    var normals: [SIMD3<Float>] = []
    var indices: [UInt32] = []

    mutating func append(positions newPositions: [SIMD3<Float>], normals newNormals: [SIMD3<Float>], indices newIndices: [UInt32]) {
        let offset = UInt32(positions.count)
        positions += newPositions; normals += newNormals; indices += newIndices.map { $0 + offset }
    }

    mutating func box(size: SIMD3<Float>, center: SIMD3<Float>, matrix: simd_float4x4 = matrix_identity_float4x4) {
        let half = size / 2
        let corners: [SIMD3<Float>] = [SIMD3(-1, -1, -1), SIMD3(1, -1, -1), SIMD3(1, 1, -1), SIMD3(-1, 1, -1),
                                      SIMD3(-1, -1, 1), SIMD3(1, -1, 1), SIMD3(1, 1, 1), SIMD3(-1, 1, 1)]
        let faces = [[0, 3, 2, 1], [4, 5, 6, 7], [0, 4, 7, 3], [1, 2, 6, 5], [0, 1, 5, 4], [3, 7, 6, 2]]
        let faceNormals: [SIMD3<Float>] = [SIMD3(0, 0, -1), SIMD3(0, 0, 1), SIMD3(-1, 0, 0), SIMD3(1, 0, 0), SIMD3(0, -1, 0), SIMD3(0, 1, 0)]
        for (index, face) in faces.enumerated() {
            let points = face.map { matrix * SIMD4(corners[$0] * half + center, 1) }.map { SIMD3($0.x, $0.y, $0.z) }
            let normal4 = matrix * SIMD4(faceNormals[index], 0)
            let normal = simd_normalize(SIMD3(normal4.x, normal4.y, normal4.z))
            append(positions: points, normals: Array(repeating: normal, count: 4), indices: [0, 1, 2, 0, 2, 3])
        }
    }

    mutating func tube(from a: SIMD3<Float>, to b: SIMD3<Float>, radius: Float) {
        let axis = simd_normalize(b - a)
        let reference = abs(axis.y) < 0.9 ? SIMD3<Float>(0, 1, 0) : SIMD3<Float>(1, 0, 0)
        let u = simd_normalize(simd_cross(axis, reference)), v = simd_cross(axis, u)
        // ponytail: eight-sided batched tubes are enough for 1:1 patch cords; no entity per segment.
        for side in 0..<8 {
            let angleA = Float(side) * .pi / 4, angleB = Float(side + 1) * .pi / 4
            let normalA = u * cos(angleA) + v * sin(angleA), normalB = u * cos(angleB) + v * sin(angleB)
            let base = positions.count
            append(positions: [a + normalA * radius, a + normalB * radius, b + normalB * radius, b + normalA * radius],
                   normals: [normalA, normalB, normalB, normalA], indices: [0, 1, 2, 0, 2, 3])
            assert(simd_dot(simd_cross(positions[base + 1] - positions[base], positions[base + 2] - positions[base]), normalA + normalB) > 0,
                   "Cable triangle must face outward.")
        }
    }

    func model(material: any RealityKit.Material) throws -> ModelEntity {
        var descriptor = MeshDescriptor(name: "Nexus — geometría original")
        descriptor.positions = MeshBuffer(positions)
        descriptor.normals = MeshBuffer(normals)
        descriptor.primitives = .triangles(indices)
        return ModelEntity(mesh: try MeshResource.generate(from: [descriptor]), materials: [material])
    }
}
