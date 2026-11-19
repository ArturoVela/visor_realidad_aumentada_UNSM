import CoreMotion
import SwiftUI
import simd

enum LabTravelMode: String, Identifiable {
    case walk = "Recorrido 3D"
    case vr = "Modo VR"
    var id: Self { self }
}

struct LabTravelView: View {
    let mode: LabTravelMode
    let room: RoomStructure
    let layout: LabLayout
    let baseTopology: LabTopology?
    @State private var topology: LabTopology?
    @State private var topologyRevision = 0
    @Environment(LabOperationsStore.self) private var operations
    @Binding var showCables: Bool
    let poweredOff: Set<String>
    @State private var focusTargets: [LabFocusTarget]
    @Binding var showTraffic: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pose: LabWalkPose
    @State private var lockedID: String?
    @State private var inspectedPort: LabScenePort?
    @State private var inspectionDestination: LabInspectionDestination?
    @State private var traceID: String?
    @State private var legendExpanded = true
    @State private var stereo = false
    @State private var motionEnabled = false
    @State private var showsScene = false
    @State private var readyEyes = Set<Int>()
    @State private var showingMonitors = false
    @State private var selectedDevice: LabTopology.Device?
    @State private var selectedLink: LabTopology.Link?
    @State private var error: String?
    @GestureState private var lookDrag = CGSize.zero
    @GestureState private var joystick = SIMD2<Float>.zero

    init(mode: LabTravelMode, room: RoomStructure, layout: LabLayout, topology: LabTopology?,
         showCables: Binding<Bool>, poweredOff: Set<String>, showTraffic: Binding<Bool>) {
        self.mode = mode
        self.room = room
        self.layout = layout
        baseTopology = topology
        _topology = State(initialValue: topology)
        _showCables = showCables
        self.poweredOff = poweredOff
        _focusTargets = State(initialValue: LabFocusTarget.inventory(topology, in: layout))
        _showTraffic = showTraffic
        _pose = State(initialValue: LabWalkPose.start(in: layout))
    }

    var body: some View {
        GeometryReader { geometry in
            let landscape = geometry.size.width > geometry.size.height
            let split = mode == .vr && landscape && stereo
            let ready = split ? readyEyes.contains(-1) && readyEyes.contains(1) : readyEyes.contains(0)
            ZStack {
                Color.black.ignoresSafeArea()
                Group {
                    if showsScene {
                        if split { HStack(spacing: 2) { eye(-1); eye(1) } }
                        else { eye(0) }
                    }
                }
                .ignoresSafeArea()
                .simultaneousGesture(DragGesture(minimumDistance: 10)
                    .updating($lookDrag) { value, offset, _ in offset = value.translation }
                    .onEnded {
                        let turned = looking(from: aimedPose, translation: $0.translation)
                        lockedID = nil
                        inspectedPort = nil
                        inspectionDestination = nil
                        pose = turned
                    })
                VStack {
                    HStack {
                        Text(mode.rawValue).font(.headline)
                            .padding(.horizontal, 12).padding(.vertical, 9)
                            .modifier(ViewerSurface(radius: 24))
                        Spacer(minLength: 4)
                        if mode == .vr {
                            icon(motionEnabled ? "Mirar con el dedo" : "Mirar moviendo el iPhone",
                                 motionEnabled ? "hand.draw" : "gyroscope") { motionEnabled.toggle() }
                                .disabled(!CMMotionManager().isDeviceMotionAvailable)
                            if landscape {
                                icon(split ? "Vista de una pantalla" : "Vista para gafas", "eyeglasses") {
                                    readyEyes.removeAll()
                                    stereo.toggle()
                                }
                            }
                        }
                        if ready, !split, topology?.operationsProfile != nil,
                           let admin = topology?.devices.first(where: \.isWorkstation) {
                            icon("Consola de administración", "terminal") { selectedDevice = admin }
                        }
                        if split || focusTargets.isEmpty {
                            icon("Restablecer recorrido", "arrow.counterclockwise", action: resetPose)
                        }
                        icon("Cerrar recorrido", "xmark") { dismiss() }
                    }
                    legendPanel(width: geometry.size.width)
                    Spacer(minLength: 4)
                    VStack(alignment: .trailing, spacing: 6) {
                        if !split, let link = topology?.links.first(where: { $0.id == traceID }) {
                            traceControl(link)
                        }
                        if !split && !focusTargets.isEmpty {
                            LabFocusControls(targets: focusTargets, choose: chooseTarget,
                                             lockedID: lockedID, onLock: setFocus,
                                             showTraffic: $showTraffic, lockedPort: inspectedPort?.name,
                                             onOpenDevice: { id in selectedDevice = topology?.devices.first { $0.id == id } },
                                             onReset: resetPose,
                                             onOpenMonitors: topology?.operationsProfile == nil ? nil : { showingMonitors = true })
                        }
                        HStack(alignment: .bottom) {
                            walkingControl
                            Spacer(minLength: 0)
                            if !split {
                                if mode == .vr && showTraffic && showCables, topology?.links.isEmpty == false {
                                    LabTrafficLegend()
                                } else if lockedID == nil {
                                    Text("Arrastra para mirar").font(.caption)
                                        .padding(10).modifier(ViewerSurface(radius: 16))
                                }
                            }
                        }
                    }
                    .opacity(ready ? 1 : 0)
                    .allowsHitTesting(ready)
                    .accessibilityHidden(!ready)
                }
                .padding(12)
                if ready && !split && !focusTargets.isEmpty {
                    Image(systemName: lockedID == nil ? "plus" : "scope")
                        .font(.system(size: lockedID == nil ? 13 : 20, weight: .semibold))
                        .foregroundStyle(lockedID == nil ? Color.white.opacity(0.84) : Color.accentColor)
                        .shadow(color: .black, radius: 2)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .ignoresSafeArea()
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
                if (!ready && !introducingLegend) || error != nil {
                    Group {
                        if let error { Label(error, systemImage: "exclamationmark.triangle") }
                        else { ProgressView("Cargando recorrido…") }
                    }
                    .padding(16).modifier(ViewerSurface(radius: 16))
                    .allowsHitTesting(false)
                }
            }
            .task {
                guard mode != .walk || topology?.links.isEmpty != false else { return }
                do { try await Task.sleep(for: .milliseconds(20)) } catch { return }
                showsScene = true
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: ready)
            .onChange(of: landscape) { _, horizontal in
                if stereo && !horizontal {
                    readyEyes.removeAll()
                    stereo = false
                }
            }
            .task(id: joystick != .zero && ready && scenePhase == .active) {
                guard joystick != .zero, ready, scenePhase == .active else { return }
                let clock = ContinuousClock()
                var last = clock.now
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(16)) } catch { break }
                    let now = clock.now
                    let elapsed = last.duration(to: now).components
                    move(joystick, seconds: Float(elapsed.seconds) + Float(elapsed.attoseconds) / 1e18)
                    last = now
                }
            }
            .task(id: ready && motionEnabled && lockedID == nil && scenePhase == .active ? (landscape ? 2 : 1) : 0) {
                guard ready, motionEnabled, lockedID == nil, scenePhase == .active else { return }
                await trackHeadRotation(landscape: landscape)
            }
        }
        .preferredColorScheme(.dark)
        .onChange(of: operations.revision, initial: true) {
            topology = baseTopology.map(operations.configured)
            topologyRevision &+= 1
            focusTargets = LabFocusTarget.inventory(topology, in: layout)
        }
        .sheet(isPresented: $showingMonitors) {
            if let baseTopology {
                LabMonitorInventory(base: baseTopology, poweredOff: poweredOff) {
                    showingMonitors = false
                    locate($0)
                }
            }
        }
        .sheet(item: $selectedDevice) { device in
            if let baseTopology {
                LabDeviceSheet(device: device, base: baseTopology, poweredOff: poweredOff, onLocate: locate)
            }
        }
        .sheet(item: $selectedLink) { link in
            if let topology {
                NavigationStack {
                    LinkInspector(link: link, topology: topology, onLocate: locate)
                        .toolbar { DismissButton() }
                }
            }
        }
    }

    private var introducingLegend: Bool {
        mode == .walk && topology?.links.isEmpty == false && !showsScene
    }

    @ViewBuilder private func legendPanel(width: CGFloat) -> some View {
        if mode == .walk, let topology, !topology.links.isEmpty {
            let panelWidth: CGFloat = max(0, min(width - 24, 336))
            let onEnter: (() -> Void)? = introducingLegend ? { enterWalk() } : nil
            HStack(alignment: .top) {
                LabCableLegend(topology: topology, hasPower: layout.facility != nil,
                               expanded: $legendExpanded, onEnter: onEnter)
                    .frame(maxWidth: panelWidth, alignment: .leading)
                Spacer(minLength: 0)
            }
        }
    }

    private func enterWalk() {
        legendExpanded = false
        showsScene = true
    }

    private var walkingControl: some View {
        ZStack {
            Circle().fill(.regularMaterial)
            Image(systemName: "arrow.up.and.down.and.arrow.left.and.right").font(.system(size: 43, weight: .ultraLight))
                .foregroundStyle(.secondary)
            Circle().fill(.tint).frame(width: 27, height: 27)
                .offset(x: CGFloat(joystick.x * 26), y: CGFloat(-joystick.y * 26))
        }
        .frame(width: 98, height: 98)
        .contentShape(.circle)
        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .local).updating($joystick) { value, vector, _ in
            let axes = SIMD2(Float(value.location.x - 49), Float(49 - value.location.y)) / 35
            vector = axes / max(1, simd_length(axes))
        })
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Moverse por la sala")
        .accessibilityAction(named: Text("Avanzar")) { accessibilityMove(SIMD2(0, 1)) }
        .accessibilityAction(named: Text("Retroceder")) { accessibilityMove(SIMD2(0, -1)) }
        .accessibilityAction(named: Text("Ir a la izquierda")) { accessibilityMove(SIMD2(-1, 0)) }
        .accessibilityAction(named: Text("Ir a la derecha")) { accessibilityMove(SIMD2(1, 0)) }
        .accessibilityAction(named: Text("Girar a la izquierda")) { turn(.pi / 8) }
        .accessibilityAction(named: Text("Girar a la derecha")) { turn(-.pi / 8) }
    }

    private func accessibilityMove(_ direction: SIMD2<Float>) {
        for _ in 0..<6 { move(direction, seconds: 0.05) }
    }

    private func icon(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol).labelStyle(.iconOnly).frame(width: 44, height: 44)
        }
        .buttonStyle(ViewerPressStyle()).modifier(ViewerSurface(radius: 24))
    }

    private func traceControl(_ link: LabTopology.Link) -> some View {
        HStack(spacing: 0) {
            Button { selectedLink = link } label: {
                Label("Cable resaltado", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                    .font(.caption.weight(.semibold)).padding(.leading, 10).frame(minHeight: 44)
            }.buttonStyle(ViewerPressStyle()).accessibilityHint("Abrir ficha de conexión")
            Button { traceID = nil } label: {
                Label("Quitar resaltado", systemImage: "xmark").labelStyle(.iconOnly).frame(width: 44, height: 44)
            }.buttonStyle(ViewerPressStyle())
        }.modifier(ViewerSurface(radius: 24))
    }

    private func locate(_ destination: LabInspectionDestination) {
        guard let topology, let spot = destination.spot(in: topology, layout: layout, observer: pose.position) else { return }
        let device = topology.devices.first { $0.id == destination.deviceID }
        inspectedPort = device.flatMap { device in
            destination.port.flatMap { try? LabScenePort.world(device, $0, in: layout) }
        }
        inspectionDestination = destination
        pose = pose.inspecting(spot.point, fromSide: spot.normal, in: layout)
        lockedID = destination.deviceID
        if let link = destination.linkID {
            showCables = true
            traceID = link
        }
        selectedLink = nil
        selectedDevice = nil
    }

    private func eye(_ side: Int) -> some View {
        LabSceneView(room: room, layout: layout, arSession: nil, mode: .room, paintRoom: true,
                     poweredOff: baseTopology.map { poweredOff.union(operations.faults(in: $0)) } ?? poweredOff,
                     selection: .constant(nil), trackingMessage: $error,
                     topology: topology, showCables: showCables, selectedLinkID: selectedLink?.id ?? traceID,
                     onSelectDevice: { id in selectedDevice = topology?.devices.first { $0.id == id } },
                     onSelectLink: { id in selectedLink = topology?.links.first { $0.id == id } },
                     inspectionDestination: inspectionDestination,
                     isForeground: scenePhase == .active && selectedDevice == nil && selectedLink == nil && !showingMonitors,
                     stereoEye: Float(side), virtualPose: looking(from: aimedPose, translation: lookDrag),
                     sceneReady: { _ = readyEyes.insert(side) },
                     lockedDeviceID: lockedID, showTraffic: showTraffic, topologyRevision: topologyRevision)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityHidden(true)
    }

    private var aimedPose: LabWalkPose {
        if let port = inspectedPort, port.deviceID == lockedID { return pose.aimed(at: port.point) }
        if let target = focusTargets.first(where: { $0.id == lockedID }) {
            return pose.aimed(at: target.framingPoint(in: layout))
        }
        return pose
    }

    private func chooseTarget(_ method: LabFocusMode) -> LabFocusTarget? {
        let camera = aimedPose
        return LabFocusTarget.pick(method, from: camera.position,
                                   direction: camera.rotation.act(SIMD3(0, 0, -1)), in: focusTargets)
    }

    private func setFocus(_ id: String?) {
        inspectedPort = nil
        inspectionDestination = nil
        lockedID = id
        if let target = focusTargets.first(where: { $0.id == id }) { pose = pose.framing(target, in: layout) }
    }

    private func resetPose() {
        setFocus(nil)
        traceID = nil
        pose = .start(in: layout)
    }

    private func move(_ axes: SIMD2<Float>, seconds: Float) {
        var next = aimedPose
        next.walk(axes, seconds: seconds, in: layout)
        pose = next
    }

    private func turn(_ angle: Float) {
        setFocus(nil)
        pose.look(horizontal: angle, vertical: 0)
    }

    private func looking(from pose: LabWalkPose, translation: CGSize) -> LabWalkPose {
        var result = pose
        result.look(horizontal: -Float(translation.width) * 0.005, vertical: Float(translation.height) * 0.005)
        return result
    }

    private func trackHeadRotation(landscape: Bool) async {
        let sensor = CMMotionManager()
        guard sensor.isDeviceMotionAvailable else { return }
        sensor.deviceMotionUpdateInterval = 1.0 / 45
        sensor.startDeviceMotionUpdates()
        defer { sensor.stopDeviceMotionUpdates() }
        var last: TimeInterval?
        while !Task.isCancelled {
            if let motion = sensor.deviceMotion, motion.timestamp != last {
                let delta = Float(min(0.05, motion.timestamp - (last ?? motion.timestamp)))
                last = motion.timestamp
                let rate = motion.rotationRate
                let sign = rotationSign
                let yaw = -Float(landscape ? rate.x : rate.y) * sign
                let pitch = Float(landscape ? -rate.y : rate.x) * sign
                if abs(yaw) + abs(pitch) > 0.045 { pose.look(horizontal: yaw * delta, vertical: pitch * delta) }
            }
            do { try await Task.sleep(for: .milliseconds(22)) } catch { break }
        }
    }

    private var rotationSign: Float {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        let orientation: UIInterfaceOrientation?
        if #available(iOS 26, *) { orientation = scene?.effectiveGeometry.interfaceOrientation }
        else { orientation = scene?.interfaceOrientation }
        return orientation == .landscapeLeft || orientation == .portraitUpsideDown ? -1 : 1
    }
}

struct LabFocusControls: View {
    let targets: [LabFocusTarget]
    let choose: (LabFocusMode) -> LabFocusTarget?
    let lockedID: String?
    let onLock: (String?) -> Void
    @Binding var showTraffic: Bool
    var lockedPort: String? = nil
    var onOpenDevice: ((String) -> Void)? = nil
    var onReset: (() -> Void)? = nil
    var onOpenMonitors: (() -> Void)? = nil

    @AppStorage("labFocusMode") private var method: LabFocusMode = .aim
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var missed = false

    var body: some View {
        let locked = targets.first { $0.id == lockedID }
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 0) {
                if let locked {
                    action("Equipo anterior", "chevron.left") {
                        onLock(LabFocusTarget.step(-1, after: locked.id, in: targets)?.id)
                    }.disabled(targets.count < 2)
                    if let onOpenDevice {
                        Button { onOpenDevice(locked.id) } label: {
                            lockedLabel(locked).frame(minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).accessibilityHint("Abrir ficha del equipo")
                    } else {
                        lockedLabel(locked)
                    }
                    action("Equipo siguiente", "chevron.right") {
                        onLock(LabFocusTarget.step(1, after: locked.id, in: targets)?.id)
                    }.disabled(targets.count < 2)
                    action("Soltar equipo", "lock.open") { onLock(nil) }
                } else {
                    Button {
                        let choice = choose(method)
                        missed = choice == nil
                        if let choice { onLock(choice.id) }
                    } label: {
                        Label("Fijar equipo", systemImage: "scope")
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                            .padding(.leading, 10).frame(minHeight: 44)
                    }.buttonStyle(ViewerPressStyle())
                }
                Menu {
                    Picker("Método de fijación", selection: $method) {
                        ForEach(LabFocusMode.allCases) { option in Text(option.rawValue).tag(option) }
                    }
                    Toggle("Flujo simulado", isOn: $showTraffic)
                    if let onOpenMonitors {
                        Button("Monitores de servidores", systemImage: "display", action: onOpenMonitors)
                    }
                    if let onReset {
                        Button("Restablecer recorrido", systemImage: "arrow.counterclockwise", action: onReset)
                    }
                } label: {
                    Label("Ajustes de fijación", systemImage: "ellipsis").labelStyle(.iconOnly)
                        .frame(width: 44, height: 44)
                }
                .accessibilityValue(method.rawValue)
            }
            .padding(.horizontal, 2)
            .modifier(ViewerSurface(radius: 24))
            if missed && locked == nil {
                Text(method == .aim ? "Apunta a la cara de un equipo." : "Acércate a un equipo.")
                    .font(.caption).padding(.horizontal, 10).padding(.vertical, 6)
                    .modifier(ViewerSurface(radius: 12))
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .accessibilityElement(children: .contain)
        .sensoryFeedback(.selection, trigger: lockedID) { _, next in next != nil }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: missed)
        .onChange(of: method) { _, _ in missed = false }
        .onChange(of: lockedID) { _, _ in missed = false }
    }

    private func lockedLabel(_ target: LabFocusTarget) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(target.name).font(.subheadline.weight(.semibold)).lineLimit(1)
            if let lockedPort {
                Text(lockedPort).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(lockedPort.map { "Equipo fijado: \(target.name), puerto \($0)" }
                            ?? "Equipo fijado: \(target.name)")
    }

    private func action(_ title: String, _ symbol: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Label(title, systemImage: symbol).labelStyle(.iconOnly).frame(width: 44, height: 44)
        }.buttonStyle(ViewerPressStyle())
    }
}

private struct LabCableLegend: View {
    let topology: LabTopology
    let hasPower: Bool
    @Binding var expanded: Bool
    var onEnter: (() -> Void)? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicType

    private var media: [LabTopology.Medium] {
        let used = Set(topology.links.map(\.medium))
        return [.copper, .fiber, .console, .powerA, .powerB].filter { kind in
            used.contains(kind) || (hasPower && (kind == .powerA || kind == .powerB))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { expanded.toggle() }
            } label: {
                HStack(spacing: 9) {
                    Label("Leyenda de cables", systemImage: "cable.connector").font(.subheadline.weight(.semibold))
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold)).accessibilityHidden(true)
                }
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
            }
            .buttonStyle(ViewerPressStyle())
            .accessibilityValue(expanded ? "Expandida" : "Contraída")
            .accessibilitySortPriority(1)
            if expanded {
                if dynamicType.isAccessibilitySize {
                    ScrollView { key }.frame(height: 112)
                } else {
                    key
                }
            }
            if let onEnter {
                Button("Entrar al recorrido", systemImage: "figure.walk", action: onEnter)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .padding(.horizontal, 12).padding(.bottom, 12)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .modifier(ViewerSurface(radius: 18, material: .thick))
    }

    private var key: some View {
        VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), alignment: .leading)], alignment: .leading, spacing: 7) {
                ForEach(media, id: \.self) { medium in
                    legendItem(medium == .copper ? "Cobre · RJ45" : medium.title, color: medium.sceneColor, dot: false)
                }
                legendItem("Cable resaltado", color: LabSignalColor.trace, dot: false)
            }
            Divider()
            Text("Paquetes simulados").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            HStack(spacing: 14) {
                legendItem("Ida", color: LabSignalColor.outgoing, dot: true)
                legendItem("Vuelta", color: LabSignalColor.incoming, dot: true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }

    private func legendItem(_ title: String, color: UIColor, dot: Bool) -> some View {
        HStack(spacing: 7) {
            Capsule().fill(Color(uiColor: color)).frame(width: dot ? 6 : 15, height: dot ? 6 : 3)
                .accessibilityHidden(true)
            Text(title).font(.caption)
        }
    }
}

struct LabTrafficLegend: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Flujo simulado").font(.caption.weight(.semibold))
            HStack(spacing: 9) {
                direction("Ida", Color(uiColor: LabSignalColor.outgoing), "arrow.right")
                direction("Vuelta", Color(uiColor: LabSignalColor.incoming), "arrow.left")
            }.font(.caption2)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .modifier(ViewerSurface(radius: 12))
        .accessibilityElement(children: .combine)
    }

    private func direction(_ title: String, _ color: Color, _ arrow: String) -> some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: arrow).fontWeight(.bold).foregroundStyle(color)
        }
    }
}
