import ARKit
import RealityKit
import SwiftUI
import simd

enum LabViewMode: String, CaseIterable, Identifiable {
    case room = "3D", ar = "AR"
    var id: String { rawValue }
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
    var focusDeviceID: String? = nil

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> ARView {
        let view = LabRenderView(frame: .zero, cameraMode: mode == .ar ? .ar : .nonAR,
                                 automaticallyConfigureSession: false)
        context.coordinator.view = view
        view.didLayout = { [weak coordinator = context.coordinator] size in coordinator?.fitCamera(to: size) }
        if mode == .ar {
            view.environment.background = .cameraFeed()
            if let arSession {
                view.session = arSession
                arSession.delegate = context.coordinator
                // Preserve RoomPlan's session-local origin and existing anchors.
                if let configuration = arSession.configuration { arSession.run(configuration, options: []) }
            } else {
                context.coordinator.report("Escanea el cuarto antes de entrar en AR; falta la sesión de captura.")
            }
        } else {
            view.environment.background = .color(UIColor(red: 0.91, green: 0.93, blue: 0.95, alpha: 1))
            let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pan(_:)))
            let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pinch(_:)))
            pan.maximumNumberOfTouches = 2
            pan.delegate = context.coordinator; pinch.delegate = context.coordinator
            view.addGestureRecognizer(pan); view.addGestureRecognizer(pinch)
        }
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tap(_:)))
        tap.cancelsTouchesInView = false
        view.addGestureRecognizer(tap)
        context.coordinator.rebuildIfNeeded()
        return view
    }

    func updateUIView(_ view: ARView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.rebuildIfNeeded()
        context.coordinator.applyZoom()
        context.coordinator.updateState()
    }

    static func dismantleUIView(_ view: ARView, coordinator: Coordinator) {
        if view.session.delegate === coordinator { view.session.delegate = nil }
        view.scene.anchors.removeAll()
        // CaptureController owns session lifetime. Changing view must not pause or reset it.
    }

    final class Coordinator: NSObject, ARSessionDelegate, UIGestureRecognizerDelegate {
        var parent: LabSceneView
        weak var view: ARView?
        private var lastRoomID: UUID?
        private var lastPlacements: [LabPlacement] = []
        private var lastTopology: LabTopology?
        private var roomEntity: Entity?
        private var rootAnchor: AnchorEntity?
        private var awaitingPlacement = false
        private var cablesEntity: Entity?
        private var portLabelsEntity: Entity?
        private var lastSelectedLinkID: String?
        private var linkBodies: [String: ModelEntity] = [:]
        private var linkMaterials: [String: SimpleMaterial] = [:]
        private var portHits: [ObjectIdentifier: LabScenePort] = [:]
        private var devicePowerParents: [String: String] = [:]
        private var indicators: [String: [ModelEntity]] = [:]
        private var screens: [String: [ModelEntity]] = [:]
        private var highlights: [String: Entity] = [:]
        private var hardwareTemplates: [String: Entity] = [:]
        private var labelMaterials: [String: UnlitMaterial] = [:]
        private var renderError: String?
        private weak var selectedHardwareHighlight: Entity?
        private var camera: PerspectiveCamera?
        private var cameraTarget = SIMD3<Float>.zero
        private var cameraRadius: Float = 6
        private var cameraYaw: Float = .pi / 4
        private var cameraPitch: Float = 0.75
        private var cameraFitRadius: Float = 3
        private var cameraMoved = false
        private var lastZoomStep = 0
        private var lastFocusKey: String?
        private let materials = LabSceneMaterials()

        init(parent: LabSceneView) { self.parent = parent }

        func rebuildIfNeeded() {
            guard let view, lastRoomID != parent.room.roomID || lastPlacements != parent.layout.placements
                    || lastTopology != parent.topology else { return }
            let reframe = lastRoomID != parent.room.roomID || lastPlacements != parent.layout.placements
            do {
                if let topology = parent.topology {
                    guard topology.devices.count <= 96, topology.links.count <= 192 else {
                        throw LabLayoutError.invalid("La vista admite hasta 96 dispositivos y 192 conexiones.")
                    }
                    try topology.validate()
                }
                let anchor = AnchorEntity(world: .zero)
                let structure = try makeRoom()
                anchor.addChild(structure)
                indicators.removeAll(); screens.removeAll(); highlights.removeAll()
                portHits.removeAll(); devicePowerParents.removeAll(); linkBodies.removeAll(); linkMaterials.removeAll()
                guard parent.layout.placements.filter({ $0.kind == .rack }).count <= 12,
                      parent.layout.placements.filter({ $0.kind == .workstation }).count <= 24 else {
                    throw LabLayoutError.invalid("La vista admite hasta 12 racks y 24 puestos.")
                }
                for placement in parent.layout.placements {
                    let object = try makePlacement(placement)
                    anchor.addChild(object)
                }
                if let topology = parent.topology {
                    let cables = try makeCables(topology)
                    anchor.addChild(cables)
                    cablesEntity = cables
                    let labels = Entity(); anchor.addChild(labels); portLabelsEntity = labels
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
                        cameraTarget = SIMD3((lower.x + upper.x) / 2, parent.layout.floorHeight + 0.9, (lower.y + upper.y) / 2)
                        cameraFitRadius = simd_length(SIMD3((upper.x - lower.x) / 2, Float(1.1), (upper.y - lower.y) / 2))
                        cameraRadius = max(4, cameraFitRadius * 3)
                        cameraMoved = false; cameraYaw = .pi / 4; cameraPitch = 0.75
                    }
                    let camera = PerspectiveCamera()
                    camera.camera.fieldOfViewInDegrees = 55
                    camera.camera.near = 0.03
                    camera.camera.far = 250
                    anchor.addChild(camera)
                    self.camera = camera
                }
                view.scene.anchors.removeAll()
                anchor.scale = SIMD3(repeating: parent.sceneScale)
                awaitingPlacement = parent.mode == .ar && parent.arPlacementRequired
                anchor.isEnabled = !awaitingPlacement
                view.scene.addAnchor(anchor)
                rootAnchor = anchor
                if parent.mode == .room { updateCamera(); fitCamera(to: view.bounds.size) }
                roomEntity = structure
                lastRoomID = parent.room.roomID
                lastPlacements = parent.layout.placements
                lastTopology = parent.topology
                lastSelectedLinkID = nil
                renderError = nil
                updateState()
                if awaitingPlacement { report("Apunta a una superficie y toca para colocar la maqueta 1:10.") }
            } catch { renderError = error.localizedDescription; report(error.localizedDescription) }
        }

        private func makeRoom() throws -> Entity {
            var batch = LabSceneMesh()
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
                    batch.append(positions: points, normals: Array(repeating: SIMD3(0, 1, 0), count: points.count), indices: indices.map(UInt32.init))
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
                    let visibleTop = parent.mode == .room ? min(halfH, max(-halfH, localCut)) : halfH
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
            entity.name = "Cuarto blanco — estructura capturada"
            entity.addChild(try batch.model(material: materials.white))
            return entity
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
                shapes = [-s.x / 2 + 0.018, s.x / 2 - 0.018].map {
                    ShapeResource.generateBox(size: SIMD3(0.035, s.y, s.z)).offsetBy(translation: SIMD3($0, s.y / 2, 0))
                } + [Float(0.045), s.y - 0.025].map {
                    ShapeResource.generateBox(size: SIMD3(s.x, 0.05, s.z)).offsetBy(translation: SIMD3(0, $0, 0))
                }
            } else {
                shapes = [ShapeResource.generateBox(size: SIMD3(s.x, 0.04, s.z)).offsetBy(translation: SIMD3(0, 0.73, 0))]
            }
            entity.components.set(CollisionComponent(shapes: shapes))
            try addHardware(to: entity, placement: placement)
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

        private func rackMeshes(_ size: SIMD3<Float>) -> [LabSceneMesh] {
            var parts = Array(repeating: LabSceneMesh(), count: 6)
            let w = size.x, h = size.y, d = size.z, front = -d / 2
            func box(_ part: Int, _ dimensions: SIMD3<Float>, _ center: SIMD3<Float>) { parts[part].box(size: dimensions, center: center) }
            for x in [-w / 2 + 0.018, w / 2 - 0.018] { box(0, SIMD3(0.035, h, d), SIMD3(x, h / 2, 0)) }
            for y in [Float(0.045), h - 0.025] { box(0, SIMD3(w, 0.05, d), SIMD3(0, y, 0)) }
            for x in [-w / 2 + 0.05, w / 2 - 0.05] { box(0, SIMD3(0.035, h - 0.1, 0.035), SIMD3(x, h / 2, d / 2 - 0.025)) }
            for x in [-w / 2 + 0.055, w / 2 - 0.055] {
                box(2, SIMD3(0.026, h - 0.14, 0.035), SIMD3(x, h / 2, front + 0.035))
                for index in 0..<22 { box(3, SIMD3(0.009, 0.009, 0.003), SIMD3(x, 0.15 + Float(index) * (h - 0.3) / 22, front + 0.015)) }
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
                    devicePowerParents[device.id] = placement.id
                    registerPower(model, placementID: device.id)
                    try addPorts(device: device, to: model)
                }
                if placement.kind == .rack { try addRackTitle(to: entity, placement: placement) }
                return
            }
            if placement.kind == .rack {
                let front = -placement.size.z / 2 + 0.07
                let devices: [(String, Float)] = [("switch-2960", 1.79), ("switch-3560", 1.67),
                    ("router-1941", 1.46), ("router-2911", 1.23), ("firewall-asa5505", 1.02),
                    ("server-c220m5", 0.77), ("server-c220m5", 0.59), ("server-c220m5", 0.41)]
                for (id, height) in devices {
                    let model = try hardware(id)
                    let size = hardwareSize(id)
                    model.position = SIMD3(0, height, front + size.z / 2)
                    entity.addChild(model)
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

        private func addRackTitle(to entity: Entity, placement: LabPlacement) throws {
            let title = try label("Cisco R42612 · 42 U", width: placement.size.x - 0.12, height: 0.035)
            title.name = "hardware:rack-r42612"
            title.position = SIMD3(0, placement.size.y - 0.026, -placement.size.z / 2 - 0.002)
            title.components.set(CollisionComponent(shapes: [ShapeResource.generateBox(size: SIMD3(placement.size.x - 0.1, 0.04, 0.01))]))
            entity.addChild(title)
        }

        private func localPort(_ device: LabTopology.Device, _ name: String) throws -> LabScenePort {
            guard device.ports.contains(name), let index = LabDemo.ports(device.modelID).firstIndex(of: name) else {
                throw LabLayoutError.invalid("Puerto \(name) ausente en \(device.name).")
            }
            let size = hardwareSize(device.modelID), w = size.x, h = size.y, d = size.z
            var point = SIMD3<Float>(0, 0, d / 2 + 0.004), normal = SIMD3<Float>(0, 0, 1)
            if name.lowercased().contains("console") {
                point.x = w / 2 - 0.025
            } else {
                switch device.modelID {
                case "switch-2960", "switch-3560":
                    normal = SIMD3(0, 0, -1)
                    point.z = -d / 2 - 0.004
                    if index < 24 { point.x = -w / 2 + 0.045 + Float(index % 12) * 0.023; point.y = -0.009 + Float(index / 12) * 0.018 }
                    else { point.x = w / 2 - 0.055 + Float(index - 24) * 0.024 }
                case "router-1941", "router-2911", "firewall-asa5505": point.x = -w / 2 + 0.027 + Float(index) * 0.021
                case "server-c220m5": point.x = -0.04 + Float(index) * 0.024
                case "pc-optiplex7010": point.y = h * 0.2
                case "laptop-latitude5420": point = SIMD3(w / 2 + 0.004, 0, d * 0.2); normal = SIMD3(1, 0, 0)
                case "phone-7960": point.x = -0.017 + Float(index) * 0.034; point.y = -h * 0.15
                default: throw LabLayoutError.invalid("Modelo sin anclaje de puerto visual: \(device.modelID).")
                }
            }
            return LabScenePort(deviceID: device.id, name: name, point: point, normal: normal)
        }

        private func worldPort(_ device: LabTopology.Device, _ name: String) throws -> LabScenePort {
            guard let placement = parent.layout.placements.first(where: { $0.id == device.placementID }) else {
                throw LabLayoutError.invalid("Equipo sin rack o puesto: \(device.name).")
            }
            let local = try localPort(device, name), rotation = simd_quatf(angle: placement.yaw, axis: SIMD3(0, 1, 0))
            return LabScenePort(deviceID: device.id, name: name,
                point: placement.position + rotation.act(device.offset + local.point), normal: rotation.act(local.normal))
        }

        private func addPorts(device: LabTopology.Device, to entity: Entity) throws {
            var sockets = LabSceneMesh()
            for name in device.ports where !name.lowercased().contains("power") && !name.lowercased().contains("psu") {
                let port = try localPort(device, name)
                let hit = Entity(); hit.name = "port:" + name
                hit.position = port.point + port.normal * 0.004
                hit.orientation = simd_quatf(from: SIMD3(0, 0, 1), to: port.normal)
                hit.components.set(CollisionComponent(shapes: [ShapeResource.generateBox(size: SIMD3(0.019, 0.016, 0.012))]))
                entity.addChild(hit)
                portHits[ObjectIdentifier(hit)] = try worldPort(device, name)
                var matrix = simd_float4x4(hit.orientation)
                matrix.columns.3 = SIMD4(port.point + port.normal * 0.002, 1)
                sockets.box(size: SIMD3(0.015, 0.012, 0.002), center: .zero, matrix: matrix)
            }
            if !sockets.indices.isEmpty { entity.addChild(try sockets.model(material: materials.dark)) }
        }

        private func makeCables(_ topology: LabTopology) throws -> Entity {
            let container = Entity(); container.name = "Conexiones — rutas ilustrativas, sin tráfico simulado"
            for (index, link) in topology.links.enumerated() {
                // Electrical A/B remains metadata until actual PDUs and PSU inputs are catalogued.
                if link.medium == .powerA || link.medium == .powerB { continue }
                guard let from = topology.devices.first(where: { $0.id == link.fromDeviceID }),
                      let to = topology.devices.first(where: { $0.id == link.toDeviceID }) else {
                    throw LabLayoutError.invalid("Conexión \(link.id) con equipo inexistente.")
                }
                let a = try worldPort(from, link.fromPort), b = try worldPort(to, link.toPort)
                let points = try cableRoute(a, b, from: from, to: to, lane: index % 6, medium: link.medium)
                var wire = LabSceneMesh(), plugs = LabSceneMesh()
                let radius: Float = link.medium == .fiber ? 0.0025 : 0.0035
                let rounded = roundedPath(points)
                var shapes: [ShapeResource] = []
                for i in 0..<(rounded.count - 1) {
                    let start = rounded[i], end = rounded[i + 1], delta = end - start, length = simd_length(delta)
                    guard length > 0.0001 else { continue }
                    wire.tube(from: start, to: end, radius: radius)
                }
                // Picking follows coarse orthogonal spans; curved visual subdivisions need no extra shapes.
                for i in 0..<(points.count - 1) {
                    let start = points[i], end = points[i + 1], delta = end - start, length = simd_length(delta)
                    guard length > 0.0001 else { continue }
                    shapes.append(ShapeResource.generateCapsule(height: max(0.02, length), radius: 0.009)
                        .offsetBy(rotation: simd_quatf(from: SIMD3(0, 1, 0), to: delta / length), translation: (start + end) / 2))
                }
                for endpoint in [a, b] {
                    var matrix = simd_float4x4(simd_quatf(from: SIMD3(0, 0, 1), to: endpoint.normal))
                    matrix.columns.3 = SIMD4(endpoint.point, 1)
                    let connectorSize = link.medium == .fiber ? SIMD3<Float>(0.009, 0.008, 0.019) : SIMD3<Float>(0.012, 0.009, 0.023)
                    plugs.box(size: connectorSize, center: SIMD3(0, 0, 0.009), matrix: matrix)
                    wire.box(size: SIMD3(0.011, 0.009, 0.012), center: SIMD3(0, 0, 0.025), matrix: matrix)
                }
                let material = wireMaterial(link.medium)
                let body = try wire.model(material: material)
                let cable = Entity(); cable.name = "cable:" + link.id
                cable.addChild(body); cable.addChild(try plugs.model(material: materials.metal))
                cable.components.set(CollisionComponent(shapes: shapes))
                container.addChild(cable)
                linkBodies[link.id] = body; linkMaterials[link.id] = material
            }
            return container
        }

        private func wireMaterial(_ medium: LabTopology.Medium) -> SimpleMaterial {
            switch medium {
            case .fiber: return materials.fiberWire
            case .console: return materials.consoleWire
            default: return materials.copperWire
            }
        }

        private func cableRoute(_ a: LabScenePort, _ b: LabScenePort, from: LabTopology.Device,
                                to: LabTopology.Device, lane: Int, medium: LabTopology.Medium) throws -> [SIMD3<Float>] {
            guard let pa = parent.layout.placements.first(where: { $0.id == from.placementID }),
                  let pb = parent.layout.placements.first(where: { $0.id == to.placementID }) else {
                throw LabLayoutError.invalid("No se encontró soporte físico para cablear.")
            }
            let stubA = a.point + a.normal * 0.045, stubB = b.point + b.normal * 0.045
            let side: Float = medium == .fiber ? -1 : 1
            func sidePoint(_ stub: SIMD3<Float>, _ placement: LabPlacement) -> SIMD3<Float> {
                let rotation = simd_quatf(angle: placement.yaw, axis: SIMD3(0, 1, 0))
                var local = rotation.inverse.act(stub - placement.position)
                local.x = side * (placement.size.x / 2 + 0.025 + Float(lane) * 0.008)
                return placement.position + rotation.act(local)
            }
            let sideA = sidePoint(stubA, pa), sideB = sidePoint(stubB, pb)
            if pa.id == pb.id {
                let rotation = simd_quatf(angle: pa.yaw, axis: SIMD3(0, 1, 0))
                let localA = rotation.inverse.act(sideA - pa.position), localB = rotation.inverse.act(sideB - pa.position)
                let bend = pa.position + rotation.act(SIMD3(localA.x, localB.y, localA.z))
                return [a.point, stubA, sideA, bend, sideB, stubB, b.point]
            }
            let height = max(pa.position.y + pa.size.y, pb.position.y + pb.size.y, a.point.y, b.point.y) + 0.08 + Float(lane) * 0.012
            let overheadA = SIMD3(sideA.x, height, sideA.z), overheadB = SIMD3(sideB.x, height, sideB.z)
            let cornerA = SIMD3(overheadB.x, height, overheadA.z), cornerB = SIMD3(overheadA.x, height, overheadB.z)
            let corner = LabGeometry.contains(SIMD2(cornerA.x, cornerA.z), polygon: parent.layout.floorPolygon) ? cornerA : cornerB
            return [a.point, stubA, sideA, overheadA, corner, overheadB, sideB, stubB, b.point]
        }

        private func roundedPath(_ input: [SIMD3<Float>]) -> [SIMD3<Float>] {
            var clean: [SIMD3<Float>] = []
            for point in input where clean.last.map({ simd_distance($0, point) > 0.0001 }) ?? true { clean.append(point) }
            guard clean.count > 2 else { return clean }
            var result = [clean[0]]
            for i in 1..<(clean.count - 1) {
                let before = clean[i] - clean[i - 1], after = clean[i + 1] - clean[i]
                let radius = min(Float(0.025), simd_length(before) * 0.3, simd_length(after) * 0.3)
                let a = clean[i] - simd_normalize(before) * radius, b = clean[i] + simd_normalize(after) * radius
                result.append(a)
                for step in 1...3 { let t = Float(step) / 3; result.append(a * (1 - t) * (1 - t) + clean[i] * 2 * t * (1 - t) + b * t * t) }
            }
            result.append(clean[clean.count - 1])
            return result
        }

        private func showPortLabels(_ ports: [LabScenePort]) {
            guard let container = portLabelsEntity else { return }
            container.children.removeAll()
            do {
                for port in ports {
                    let tag = try label(port.name, width: 0.12, height: 0.018)
                    tag.position = port.point + port.normal * 0.035 + SIMD3(0, 0.025, 0)
                    tag.orientation = simd_quatf(from: SIMD3(0, 0, 1), to: port.normal)
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

        private func hardwareSize(_ id: String) -> SIMD3<Float> {
            if let measured = HardwareCatalog.item(id)?.size { return measured }
            // ponytail: uncatalogued dimensions are exterior approximations, labelled in the inspector.
            switch id {
            case "switch-2960", "switch-3560": return SIMD3(0.445, 0.044, 0.30)
            case "router-1941": return SIMD3(0.343, 0.089, 0.292)
            case "router-2911": return SIMD3(0.438, 0.089, 0.305)
            case "firewall-asa5505": return SIMD3(0.20, 0.045, 0.175)
            case "server-c220m5": return SIMD3(0.482, 0.043, 0.787)
            case "pc-optiplex7010": return SIMD3(0.175, 0.36, 0.417)
            case "laptop-latitude5420": return SIMD3(0.321, 0.02, 0.212)
            default: return SIMD3(0.19, 0.08, 0.23)
            }
        }

        private func hardware(_ id: String) throws -> Entity {
            if let template = hardwareTemplates[id] { return template.clone(recursive: true) }
            var parts = Array(repeating: LabSceneMesh(), count: 6)
            func box(_ part: Int, _ size: SIMD3<Float>, _ center: SIMD3<Float>) { parts[part].box(size: size, center: center) }
            let size = hardwareSize(id), w = size.x, h = size.y, d = size.z
            box(id == "firewall-asa5505" || id == "pc-optiplex7010" || id == "phone-7960" ? 0 : 1, size, .zero)
            let front = -d / 2 - 0.002
            if id == "switch-2960" || id == "switch-3560" {
                for row in 0..<2 { for port in 0..<12 {
                    box(3, SIMD3(0.015, 0.013, 0.004), SIMD3(-w / 2 + 0.045 + Float(port) * 0.023, -0.009 + Float(row) * 0.018, front))
                } }
                for port in 0..<2 {
                    box(3, SIMD3(id == "switch-3560" ? 0.014 : 0.015, 0.013, 0.004), SIMD3(w / 2 - 0.055 + Float(port) * 0.024, 0, front))
                }
                box(4, SIMD3(0.006, 0.006, 0.004), SIMD3(-w / 2 + 0.016, 0, front))
            } else if id == "router-1941" || id == "router-2911" || id == "firewall-asa5505" {
                let count = id == "router-1941" ? 2 : id == "router-2911" ? 3 : 8
                for port in 0..<count {
                    box(3, SIMD3(0.016, 0.014, 0.005), SIMD3(-w / 2 + 0.027 + Float(port) * 0.021, 0, d / 2 + 0.002))
                }
                for vent in 0..<10 { box(3, SIMD3(0.003, h * 0.4, 0.003), SIMD3(-w * 0.22 + Float(vent) * w * 0.04, 0, front)) }
                box(4, SIMD3(0.006, 0.006, 0.004), SIMD3(w / 2 - 0.023, 0, front))
            } else if id == "server-c220m5" {
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
                for port in 0..<2 { box(3, SIMD3(0.016, 0.014, 0.004), SIMD3(-0.04 + Float(port) * 0.024, 0, d / 2 + 0.003)) }
                for x in [-w / 2 + 0.01, w / 2 - 0.01] { box(2, SIMD3(0.014, h * 0.7, 0.024), SIMD3(x, 0, front - 0.008)) }
                box(4, SIMD3(0.006, 0.006, 0.005), SIMD3(-w / 2 + 0.025, 0, front - 0.005))
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
            if let item = HardwareCatalog.item(id) {
                // Educational label above the chassis: does not cover ports or impersonate a manufacturer marking.
                let plate = try label(item.name, width: min(w * 0.85, 0.40), height: 0.024)
                plate.position = SIMD3(0, h / 2 + 0.022, front - 0.004)
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
                    let fontSize = min(CGFloat(32), CGFloat(700) / CGFloat(max(text.count, 1)) / 0.62)
                    (text as NSString).draw(in: CGRect(x: 20, y: 25, width: 728, height: 58), withAttributes: [
                        .font: UIFont.monospacedSystemFont(ofSize: fontSize, weight: .semibold), .foregroundColor: UIColor.white])
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
            roomEntity?.isEnabled = parent.paintRoom
            cablesEntity?.isEnabled = parent.showCables
            func isOff(_ id: String) -> Bool {
                parent.poweredOff.contains(id) || devicePowerParents[id].map { parent.poweredOff.contains($0) } == true
            }
            for (id, models) in indicators { for model in models { model.model?.materials = [isOff(id) ? materials.off : materials.power] } }
            for (id, models) in screens { for model in models { model.model?.materials = [isOff(id) ? materials.dark : materials.screen] } }
            for (id, entity) in highlights { entity.isEnabled = parent.selection?.id == id }
            for (id, body) in linkBodies {
                if id == parent.selectedLinkID { body.model?.materials = [materials.accent] }
                else if let normal = linkMaterials[id] { body.model?.materials = [normal] }
            }
            if lastSelectedLinkID != parent.selectedLinkID {
                lastSelectedLinkID = parent.selectedLinkID
                if let topology = parent.topology, let link = topology.links.first(where: { $0.id == parent.selectedLinkID }),
                   let from = topology.devices.first(where: { $0.id == link.fromDeviceID }),
                   let to = topology.devices.first(where: { $0.id == link.toDeviceID }) {
                    do { showPortLabels([try worldPort(from, link.fromPort), try worldPort(to, link.toPort)]) }
                    catch { report(error.localizedDescription) }
                } else { showPortLabels([]) }
            }
            if parent.selection != nil { selectedHardwareHighlight?.isEnabled = false }
            if parent.mode == .room {
                let key = parent.focusDeviceID.map { "device:" + $0 } ?? parent.selection.map { "placement:" + $0.id }
                if key != lastFocusKey {
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

        @objc func tap(_ recognizer: UITapGestureRecognizer) {
            guard let view else { return }
            if awaitingPlacement {
                guard let result = view.raycast(from: recognizer.location(in: view), allowing: .estimatedPlane, alignment: .horizontal).first else {
                    report("Mueve el iPhone lentamente y toca una superficie horizontal visible.")
                    return
                }
                rootAnchor?.transform = Transform(matrix: result.worldTransform)
                rootAnchor?.scale = SIMD3(repeating: parent.sceneScale)
                rootAnchor?.isEnabled = true
                awaitingPlacement = false
                report(nil)
                return
            }
            var entity = view.entity(at: recognizer.location(in: view))
            while let current = entity {
                if let port = portHits[ObjectIdentifier(current)] {
                    selectedHardwareHighlight?.isEnabled = false
                    parent.selection = nil
                    showPortLabels([port])
                    if let link = parent.topology?.links.first(where: {
                        ($0.fromDeviceID == port.deviceID && $0.fromPort == port.name)
                            || ($0.toDeviceID == port.deviceID && $0.toPort == port.name)
                    }) { parent.onSelectLink(link.id) }
                    else { parent.onSelectDevice(port.deviceID) }
                    return
                }
                if current.name.hasPrefix("cable:") {
                    parent.selection = nil; selectedHardwareHighlight?.isEnabled = false
                    parent.onSelectLink(String(current.name.dropFirst("cable:".count)))
                    return
                }
                if current.name.hasPrefix("device:") {
                    selectedHardwareHighlight?.isEnabled = false
                    selectedHardwareHighlight = current.findEntity(named: "hardware-selection")
                    selectedHardwareHighlight?.isEnabled = true
                    parent.selection = nil
                    parent.onSelectDevice(String(current.name.dropFirst("device:".count)))
                    return
                }
                if current.name.hasPrefix("hardware:") {
                    selectedHardwareHighlight?.isEnabled = false
                    selectedHardwareHighlight = current.findEntity(named: "hardware-selection")
                    selectedHardwareHighlight?.isEnabled = true
                    parent.selection = nil
                    updateState()
                    parent.onSelectHardware(String(current.name.dropFirst("hardware:".count)))
                    return
                }
                if current.name.hasPrefix("placement:") {
                    selectedHardwareHighlight?.isEnabled = false
                    let id = String(current.name.dropFirst("placement:".count))
                    parent.selection = parent.layout.placements.first { $0.id == id }
                    updateState()
                    return
                }
                entity = current.parent
            }
            parent.selection = nil
            selectedHardwareHighlight?.isEnabled = false
            updateState()
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

        private func updateCamera() {
            let offset = SIMD3(sin(cameraYaw) * cos(cameraPitch), sin(cameraPitch), -cos(cameraYaw) * cos(cameraPitch)) * cameraRadius
            let backward = simd_normalize(offset)
            let right = simd_normalize(simd_cross(SIMD3<Float>(0, 1, 0), backward))
            let up = simd_cross(backward, right)
            camera?.position = cameraTarget + offset
            camera?.orientation = simd_quatf(simd_float3x3(columns: (right, up, backward)))
        }

        func applyZoom() {
            guard parent.mode == .room, lastZoomStep != parent.zoomStep else { return }
            cameraRadius = min(100, max(0.8, cameraRadius * pow(0.75, Float(parent.zoomStep - lastZoomStep))))
            lastZoomStep = parent.zoomStep
            cameraMoved = true
            updateCamera()
        }

        func fitCamera(to size: CGSize) {
            guard parent.mode == .room, !cameraMoved, size.width > 0, size.height > 0 else { return }
            let verticalHalf = Float(55) * .pi / 360
            let horizontalHalf = atan(tan(verticalHalf) * Float(size.width / size.height))
            cameraRadius = max(3, cameraFitRadius / sin(min(verticalHalf, horizontalHalf)) * 1.12)
            updateCamera()
        }

        func report(_ message: String?) {
            Task { @MainActor [weak self] in
                guard let self else { return }
                parent.trackingMessage = renderError ?? (awaitingPlacement ? "Apunta a una superficie y toca para colocar la maqueta 1:10." : message)
            }
        }

        nonisolated func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
            let message: String?
            switch camera.trackingState {
            case .normal: message = nil
            case .notAvailable: message = "Seguimiento no disponible. Comprueba cámara y vuelve al espacio escaneado."
            case .limited(let reason):
                switch reason {
                case .initializing: message = "Iniciando AR. Mueve el iPhone lentamente."
                case .excessiveMotion: message = "Movimiento rápido. Mantén el iPhone estable."
                case .insufficientFeatures: message = "Faltan referencias. Apunta a una zona iluminada con detalles."
                case .relocalizing: message = "Recuperando posición. Apunta al mismo cuarto escaneado."
                @unknown default: message = "Seguimiento limitado. Mueve el iPhone lentamente."
                }
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                parent.trackingMessage = renderError ?? (awaitingPlacement ? "Apunta a una superficie y toca para colocar la maqueta 1:10." : message)
            }
        }

        nonisolated func session(_ session: ARSession, didFailWithError error: any Error) {
            let message = "AR: " + error.localizedDescription
            Task { @MainActor [weak self] in self?.parent.trackingMessage = message }
        }
    }
}

private struct LabSceneMaterials {
    let white: PhysicallyBasedMaterial
    let graphite = SimpleMaterial(color: UIColor(white: 0.23, alpha: 1), roughness: 0.65, isMetallic: false)
    let panel = SimpleMaterial(color: UIColor(white: 0.64, alpha: 1), roughness: 0.6, isMetallic: false)
    let metal = SimpleMaterial(color: UIColor(white: 0.76, alpha: 1), roughness: 0.45, isMetallic: false)
    let dark = SimpleMaterial(color: UIColor(white: 0.025, alpha: 1), roughness: 0.8, isMetallic: false)
    let power: UnlitMaterial
    let screen: UnlitMaterial
    let accent: UnlitMaterial
    let off = SimpleMaterial(color: UIColor(white: 0.12, alpha: 1), roughness: 0.8, isMetallic: false)
    let copperWire = SimpleMaterial(color: UIColor(red: 0.12, green: 0.42, blue: 0.93, alpha: 1), roughness: 0.55, isMetallic: false)
    let fiberWire = SimpleMaterial(color: UIColor(red: 1, green: 0.53, blue: 0.07, alpha: 1), roughness: 0.55, isMetallic: false)
    let consoleWire = SimpleMaterial(color: UIColor(red: 0.12, green: 0.73, blue: 0.74, alpha: 1), roughness: 0.55, isMetallic: false)

    init() {
        var white = PhysicallyBasedMaterial()
        white.baseColor = .init(tint: .white)
        white.roughness = 0.92
        white.metallic = 0.0
        self.white = white
        var power = UnlitMaterial(); power.color = .init(tint: UIColor(red: 0.2, green: 0.95, blue: 0.58, alpha: 1)); self.power = power
        var screen = UnlitMaterial(); screen.color = .init(tint: UIColor(red: 0.03, green: 0.25, blue: 0.44, alpha: 1)); self.screen = screen
        var accent = UnlitMaterial(); accent.color = .init(tint: UIColor(red: 0.1, green: 0.58, blue: 1, alpha: 1)); self.accent = accent
    }
}

private struct LabScenePort {
    let deviceID: String
    let name: String
    let point: SIMD3<Float>
    let normal: SIMD3<Float>
}

private final class LabRenderView: ARView {
    var didLayout: ((CGSize) -> Void)?
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
