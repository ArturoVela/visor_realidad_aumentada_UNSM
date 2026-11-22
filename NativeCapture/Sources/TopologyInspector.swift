import SwiftUI
import UniformTypeIdentifiers
import simd

private struct LabCableCSV: Transferable {
    let value: String
    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .commaSeparatedText) { Data($0.value.utf8) }
            .suggestedFileName("Nexus-Cableado")
    }
}

struct TopologyInspector: View {
    let topology: LabTopology
    var room: RoomStructure? = nil
    var layout: LabLayout? = nil
    @State private var cablePlan: LabCablePlan?
    @State private var exportError: String?
    var locateTitle = "Ver en 3D"
    var onLocate: ((LabInspectionDestination) -> Void)? = nil
    var console: ((LabTopology.Device) -> LabConsoleView?)? = nil
    var poweredOff: Set<String> = []
    var pending: Set<String> = []

    var body: some View {
        List {
            Section {
                Text(topology.name).font(.headline)
                Text("\(topology.devices.count) equipos · \(topology.links.count) conexiones")
                if let cablePlan {
                    ShareLink(item: LabCableCSV(value: cablePlan.csv(for: topology)), preview: SharePreview("Cableado simulado")) {
                        Label("Exportar tramos CSV", systemImage: "square.and.arrow.up")
                    }
                } else if let exportError {
                    Label(exportError, systemImage: "exclamationmark.triangle")
                } else if room != nil && layout != nil {
                    ProgressView("Calculando longitudes…")
                }
                Text("Inventario del diseño con puertos, servicios asignados y rutas de cableado.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("VLAN") {
                ForEach(topology.vlans) { vlan in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(vlan.id) · \(vlan.name)")
                        if !vlan.subnet.isEmpty { Text(vlan.subnet).font(.caption).monospaced() }
                    }
                }
            }
            Section("Equipos y servicios") {
                ForEach(topology.devices) { device in
                    NavigationLink {
                        DeviceInspector(device: device, topology: topology, locateTitle: locateTitle,
                                        onLocate: onLocate, poweredOff: poweredOff, console: console?(device), pending: pending)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(device.name)
                            Text(device.services.isEmpty ? (HardwareCatalog.reference(device.modelID)?.name ?? device.modelID)
                                 : device.services.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section("Conexiones") {
                ForEach(topology.links.filter { $0.circuitID == nil || $0.id == $0.circuitID }) { link in
                    let end = topology.circuit(for: link).last ?? link
                    NavigationLink { LinkInspector(link: link, topology: topology, locateTitle: locateTitle, onLocate: onLocate,
                                                       segments: cablePlan?.segments ?? [], poweredOff: poweredOff, pending: pending) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(name(link.fromDeviceID)) → \(name(end.toDeviceID))")
                            Text("\(link.fromPort) ↔ \(end.toPort)").font(.caption).monospaced()
                        }
                    }
                }
            }
            if !topology.notes.isEmpty {
                Section("Notas del diseño") {
                    ForEach(Array(topology.notes.enumerated()), id: \.offset) { _, note in Text(note).font(.footnote) }
                }
            }
        }
        .navigationTitle("Red y conexiones").navigationBarTitleDisplayMode(.inline)
        .task {
            guard let room, let layout else { return }
            do { cablePlan = try await Self.buildPlan(topology, room: room, layout: layout) }
            catch { exportError = error.localizedDescription }
        }
    }
    @concurrent private static func buildPlan(_ topology: LabTopology, room: RoomStructure,
                                              layout: LabLayout) async throws -> LabCablePlan {
        try LabCablePlan.make(topology, room: room, layout: layout)
    }

    private func name(_ id: String) -> String { topology.devices.first { $0.id == id }?.name ?? id }
}

struct PingDiagnosticView: View {
    let topology: LabTopology
    let layout: LabLayout?
    let poweredOff: Set<String>
    let onShowInScene: (String, String) -> Void
    @State private var sourceID = ""
    @State private var destinationID = ""
    @State private var diagnosis: LabTopology.PingDiagnosis?
    private let demoPairs = [("PC-A", "PC-B"), ("PC-A", "PC-C"), ("PC-B", "PC-C")]

    var body: some View {
        let devices = topology.devices.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        Form {
            if topology.operationsProfile == LabDemo.vlanProfile {
                Section {
                    ForEach(demoPairs.indices, id: \.self) { index in
                        let (source, destination) = demoPairs[index]
                        if let origin = devices.first(where: { $0.id == source }),
                           let target = devices.first(where: { $0.id == destination }) {
                            let title = "\(origin.name) → \(target.name)"
                            let result = sourceID == source && destinationID == destination ? diagnosis : nil
                            let reached = result?.issue == nil
                            let status = reached ? "Responde" : "Sin respuesta"
                            Button {
                                runPing(from: origin, to: target)
                            } label: {
                                HStack {
                                    Text(title)
                                    if result != nil {
                                        Spacer(minLength: 8)
                                        Label(status, systemImage: reached ? "checkmark.circle" : "exclamationmark.triangle")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .accessibilityLabel(title)
                            .accessibilityValue(result == nil ? "" : status)
                        }
                    }
                } header: {
                    Text("Pruebas de la demo")
                } footer: {
                    Text("En el diseño inicial, A → B usa la VLAN 10 y B → C pasa por el router. La ACL del router bloquea A → C.")
                }
            }
            Section {
                Picker("Origen", selection: clearingResult($sourceID)) { choices(devices, excluding: destinationID) }
                    .pickerStyle(.navigationLink)
                Picker("Destino", selection: clearingResult($destinationID)) { choices(devices, excluding: sourceID) }
                    .pickerStyle(.navigationLink)
                Button("Ejecutar ping simulado", systemImage: "point.3.connected.trianglepath.dotted") {
                    guard let origin = devices.first(where: { $0.id == sourceID }),
                          let destination = devices.first(where: { $0.id == destinationID }) else { return }
                    runPing(from: origin, to: destination)
                }
                .disabled(sourceID.isEmpty || destinationID.isEmpty)
            } footer: {
                Text("Calculado con la topología y el estado del laboratorio.")
            }
            if let diagnosis {
                Section("Resultado") {
                    Label(diagnosis.issue == nil ? "Destino alcanzable" : "Destino no alcanzable",
                          systemImage: diagnosis.issue == nil ? "checkmark.circle" : "exclamationmark.triangle")
                        .font(.headline)
                    if let issue = diagnosis.issue { Text(issue) }
                    PingSampleRows(sample: diagnosis.sample)
                    if let origin = devices.first(where: { $0.id == sourceID }),
                       let destination = devices.first(where: { $0.id == destinationID }) {
                        Button("Ver en escena", systemImage: "cube") { onShowInScene(sourceID, destinationID) }
                        PingRouteMap(topology: topology, layout: layout, diagnosis: diagnosis, origin: origin, destination: destination)
                    }
                }
                if let path = diagnosis.path {
                    Section(diagnosis.issue == nil ? "Saltos de la ruta" : "Saltos alcanzados") {
                        ForEach(Array(path.devices.enumerated()), id: \.offset) { index, device in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(index + 1). \(device.name)")
                                if index > 0 {
                                    let link = path.links[index - 1]
                                    Text(portDescription(link, toward: device.id))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        if let blocked = diagnosis.blockedLink, let device = diagnosis.blockedDevice,
                           let last = path.devices.last {
                            Label(portDescription(blocked, toward: blocked.fromDeviceID == last.id ? blocked.toDeviceID : blocked.fromDeviceID)
                                  + " · " + device.name, systemImage: "xmark.circle")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Diagnóstico de conectividad")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: topology) { diagnosis = nil }
        .onChange(of: poweredOff) { diagnosis = nil }
    }

    private func runPing(from origin: LabTopology.Device, to destination: LabTopology.Device) {
        sourceID = origin.id
        destinationID = destination.id
        diagnosis = topology.diagnosePing(from: origin, to: destination, poweredOff: poweredOff)
    }

    private func clearingResult(_ selection: Binding<String>) -> Binding<String> {
        Binding(get: { selection.wrappedValue }, set: { value in
            selection.wrappedValue = value
            diagnosis = nil
        })
    }

    private func choices(_ devices: [LabTopology.Device], excluding id: String) -> some View {
        Group {
            Text("Seleccionar equipo").tag("")
            ForEach(devices.filter { $0.id != id }) { device in
                Text("\(device.name) · \(device.ipv4 ?? "Sin IPv4")").tag(device.id)
            }
        }
    }

    private func portDescription(_ link: LabTopology.Link, toward device: String) -> String {
        let a = topology.devices.first { $0.id == link.fromDeviceID }?.sourcePortNames?[link.fromPort] ?? link.fromPort
        let b = topology.devices.first { $0.id == link.toDeviceID }?.sourcePortNames?[link.toPort] ?? link.toPort
        return device == link.toDeviceID ? "\(a) → \(b)" : "\(b) → \(a)"
    }
}

private struct PingSampleRows: View {
    let sample: LabTopology.PingSample

    var body: some View {
        LabeledContent("Respuestas", value: "\(sample.received) de \(sample.sent)")
        LabeledContent("Pérdida simulada", value: "\(sample.loss) %")
        if let latency = sample.mean {
            LabeledContent("Latencia media simulada", value: latency.formatted(.number.precision(.fractionLength(2))) + " ms")
        }
    }
}

private struct PingRouteMap: View {
    let topology: LabTopology
    let layout: LabLayout?
    let diagnosis: LabTopology.PingDiagnosis
    let origin: LabTopology.Device
    let destination: LabTopology.Device
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    var body: some View {
        let positions = devicePositions
        if let first = positions.values.first {
            let lower = positions.values.reduce(first, simd_min)
            let upper = positions.values.reduce(first, simd_max)
            let center = (lower + upper) / 2
            let span = simd_max(upper - lower, SIMD2(repeating: 1))
            let hops = diagnosis.path?.devices ?? []
            let routeIDs = Set(diagnosis.path?.links.map(\.id) ?? [])
            let mapLinks = topology.links.filter { $0.medium == .copper || $0.medium == .fiber || $0.medium == .serial }
            Canvas { context, size in
                let scale = min(max(1, size.width - 32) / CGFloat(span.x), max(1, size.height - 32) / CGFloat(span.y))
                func project(_ position: SIMD2<Float>) -> CGPoint {
                    CGPoint(x: size.width / 2 + CGFloat(position.x - center.x) * scale,
                            y: size.height / 2 + CGFloat(position.y - center.y) * scale)
                }
                func draw(_ link: LabTopology.Link, color: Color, style: StrokeStyle) {
                    guard let a = positions[link.fromDeviceID], let b = positions[link.toDeviceID] else { return }
                    var line = Path()
                    line.move(to: project(a))
                    line.addLine(to: project(b))
                    context.stroke(line, with: .color(color), style: style)
                }
                for link in mapLinks where !routeIDs.contains(link.id) && link.id != diagnosis.blockedLink?.id {
                    draw(link, color: .secondary.opacity(0.35), style: .init(lineWidth: 1))
                }
                for link in diagnosis.path?.links ?? [] {
                    draw(link, color: .accentColor, style: .init(lineWidth: 3, lineCap: .round))
                }
                if let blocked = diagnosis.blockedLink {
                    draw(blocked, color: .red, style: .init(lineWidth: 3, lineCap: .round, dash: [5, 4]))
                }
                for position in positions.values {
                    let dot = project(position)
                    context.fill(Path(ellipseIn: CGRect(x: dot.x - 2, y: dot.y - 2, width: 4, height: 4)), with: .color(.secondary))
                }
                func mark(_ device: LabTopology.Device, label: String, color: Color) {
                    guard let position = positions[device.id] else { return }
                    let dot = project(position)
                    context.fill(Path(ellipseIn: CGRect(x: dot.x - 9, y: dot.y - 9, width: 18, height: 18)), with: .color(color))
                    context.draw(Text(label).font(.caption2.bold()).foregroundStyle(.white), at: dot)
                }
                if !hops.contains(where: { $0.id == destination.id }) { mark(destination, label: "D", color: .secondary) }
                if hops.isEmpty { mark(origin, label: "O", color: .accentColor) }
                for (index, device) in hops.enumerated() { mark(device, label: "\(index + 1)", color: .accentColor) }
                if let blocked = diagnosis.blockedDevice { mark(blocked, label: "×", color: .red) }
            }
            .frame(height: verticalSizeClass == .compact ? 124 : 190)
            .accessibilityHidden(true)
            Text(topology.logicalPlan == nil ? "Plano del laboratorio" : "Plano lógico · O: origen · D: destino sin alcanzar")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var devicePositions: [String: SIMD2<Float>] {
        if let plan = topology.logicalPlan { return plan.devicePositions }
        guard let layout else { return [:] }
        let placements = Dictionary(uniqueKeysWithValues: layout.placements.map { ($0.id, $0) })
        return Dictionary(uniqueKeysWithValues: topology.devices.compactMap { device in
            guard let placement = placements[device.placementID] else { return nil }
            let location = placement.position + simd_quatf(angle: placement.yaw, axis: SIMD3(0, 1, 0)).act(device.offset)
            return (device.id, SIMD2(location.x, location.z))
        })
    }
}

struct DeviceInspector: View {
    let device: LabTopology.Device
    let topology: LabTopology
    var locateTitle = "Ver en 3D"
    var onLocate: ((LabInspectionDestination) -> Void)? = nil

    var consoleBase: LabTopology? = nil
    var poweredOff: Set<String> = []
    var console: LabConsoleView? = nil
    var showsConsole = true
    var catalystInspection: Catalyst2960Inspection? = nil
    var moveDevice: AnyView? = nil
    var powerCut: Binding<Bool>? = nil
    var pending: Set<String> = []

    private var defaultConsole: LabConsoleView? {
        (consoleBase ?? (device.sourceModel == nil ? nil : topology)).map {
            LabConsoleView(base: $0, device: device, poweredOff: poweredOff)
        }
    }

    var body: some View {
        Form {
            Section {
                Text(device.name).font(.title3.bold())
                if device.visualModelID == Catalyst2960Asset.modelID, let catalystInspection {
                    Catalyst2960Status(inspection: catalystInspection, deviceID: device.id)
                }
                if let sourceModel = device.sourceModel { LabeledContent("Modelo del archivo", value: sourceModel) }
                if let hardware = HardwareCatalog.reference(device.visualModelID) {
                    if device.visualModelID != device.modelID { LabeledContent("Referencia 3D", value: hardware.name) }
                    NavigationLink("Ficha de \(hardware.name)") { HardwareDetail(item: hardware) }
                }
                if showsConsole && !device.modelID.hasPrefix("patch-") && !device.isFanTray, let console = console ?? defaultConsole {
                    NavigationLink(destination: console) { Label("Abrir CLI", systemImage: "terminal") }
                        .accessibilityIdentifier("lab.open-cli")
                }
                if let moveDevice {
                    NavigationLink(destination: moveDevice) {
                        Label("Cambiar de unidad o rack", systemImage: "arrow.up.arrow.down")
                    }
                }
                if let address = device.ipv4 { LabeledContent("IPv4", value: address).monospaced() }
                if device.supportsWiFi {
                    LabeledContent("Conexión", value: (device.connectionMode ?? .ethernet).title)
                    if let access = topology.devices.first(where: { $0.id == device.wifiAccessPointID }) {
                        LabeledContent("Punto de acceso", value: access.name)
                    }
                }
                if let vlan = device.vlan { LabeledContent("VLAN", value: String(vlan)) }
                if let description = device.packetTracer?.description, !description.isEmpty { Text(description) }
                if let onLocate {
                    Button(locateTitle, systemImage: "mappin.circle") { onLocate(.init(deviceID: device.id)) }
                }
            }
            if let powerCut {
                Section("Alimentación simulada") {
                    let off = poweredOff.contains(device.id) || poweredOff.contains(device.placementID)
                    LabeledContent("Estado", value: off ? "Sin alimentación" : "Encendido")
                    Toggle("Simular corte de alimentación", systemImage: "powerplug", isOn: powerCut)
                }
            }
            if !device.services.isEmpty {
                Section("Servicios del diseño") {
                    ForEach(device.services, id: \.self) { Text($0) }
                }
            }
            if let details = device.packetTracer {
                if !details.dhcpPools.isEmpty {
                    Section("Servidor DHCP") {
                        ForEach(Array(details.dhcpPools.enumerated()), id: \.offset) { _, pool in
                            DisclosureGroup {
                                LabeledContent("Red", value: "\(pool.network) / \(pool.mask)")
                                LabeledContent("Rango", value: "\(pool.start) – \(pool.end)")
                                LabeledContent("Puerta de enlace", value: pool.gateway)
                                if !pool.dns.isEmpty, pool.dns != "0.0.0.0" { LabeledContent("DNS", value: pool.dns) }
                            } label: {
                                Label(pool.name.isEmpty ? "Pool DHCP" : pool.name,
                                      systemImage: pool.enabled ? "checkmark.circle" : "pause.circle")
                                    .accessibilityValue(pool.enabled ? "Activo" : "Desactivado")
                            }
                        }
                    }
                }
                if !details.interfaces.isEmpty {
                    Section("Configuración de interfaces") {
                        ForEach(details.interfaces, id: \.port) { port in
                            DisclosureGroup(device.sourcePortNames?[port.port] ?? port.port) {
                                if let ipv4 = port.ipv4, !ipv4.isEmpty { LabeledContent("IPv4", value: ipv4) }
                                if let mask = port.mask, !mask.isEmpty { LabeledContent("Máscara", value: mask) }
                                if let gateway = port.gateway, !gateway.isEmpty { LabeledContent("Puerta de enlace", value: gateway) }
                                if let server = port.dhcpServer, !server.isEmpty { LabeledContent("Servidor DHCP", value: server) }
                                if port.fromLease == true { Text("IPv4 recuperada de la concesión guardada en Packet Tracer.") }
                                if let area = port.ospfArea { LabeledContent("Área OSPF", value: area) }
                                if let description = port.description, !description.isEmpty { Text(description) }
                            }
                        }
                    }
                }
            }
            if let hosts = device.siteHosts, !hosts.isEmpty {
                Section("Sitios asignados") {
                    ForEach(hosts, id: \.self) { host in
                        Text(host)
                    }
                }
            }
            if !device.ports.isEmpty {
                Section("Puertos") {
                    ForEach(device.ports, id: \.self) { name in
                        let port = LabTopology.Port(deviceID: device.id, name: name)
                        NavigationLink {
                            PortInspector(port: port, topology: topology, poweredOff: poweredOff, pending: pending,
                                          locateTitle: locateTitle, onLocate: onLocate)
                        } label: {
                            Label(device.sourcePortNames?[name] ?? name, systemImage: "cable.connector").font(.callout.monospaced())
                        }
                    }
                }
            }
            if let configuration = device.configuration, !configuration.isEmpty {
                Section(device.sourceModel == nil ? "Configuración de referencia" : "Configuración del archivo") {
                    Text(configuration).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                }
            }
        }
        .navigationTitle("Equipo").navigationBarTitleDisplayMode(.inline)
    }
}

struct PortInspector: View {
    let port: LabTopology.Port
    let topology: LabTopology
    var poweredOff: Set<String> = []
    var pending: Set<String> = []
    var negotiatingLink: String? = nil
    var locateTitle = "Ver en 3D"
    var onLocate: ((LabInspectionDestination) -> Void)? = nil

    var body: some View {
        let device = topology.devices.first { $0.id == port.deviceID }
        let link = topology.link(at: port)
        let circuit = link.map(topology.circuit) ?? []
        let signal = topology.signal(at: port, poweredOff: poweredOff, pending: pending, negotiating: negotiatingLink)
        Form {
            Section("Puerto") {
                if let device { LabeledContent("Equipo", value: device.name) }
                SignalLabel(signal: signal)
                if let medium = link?.medium ?? topology.medium(at: port) { LabeledContent("Medio", value: medium.title) }
                if let speed = topology.speedLimit(for: circuit) {
                    LabeledContent("Velocidad nominal del modelo", value: speed.formatted() + " Mb/s")
                }
                if let onLocate {
                    Button("Localizar puerto", systemImage: "viewfinder") { onLocate(.init(deviceID: port.deviceID, port: port.name)) }
                        .accessibilityHint(locateTitle)
                }
            }
            if let link, let first = circuit.first, let last = circuit.last {
                let isOrigin = first.fromDeviceID == port.deviceID && first.fromPort == port.name
                let isDestination = last.toDeviceID == port.deviceID && last.toPort == port.name
                let otherID = isOrigin ? last.toDeviceID : isDestination ? first.fromDeviceID
                    : link.fromDeviceID == port.deviceID ? link.toDeviceID : link.fromDeviceID
                let otherPort = isOrigin ? last.toPort : isDestination ? first.fromPort
                    : link.fromDeviceID == port.deviceID ? link.toPort : link.fromPort
                Section("Conexión") {
                    if let other = topology.devices.first(where: { $0.id == otherID }) {
                        LabeledContent("Otro extremo", value: other.name)
                        LabeledContent("Puerto remoto", value: other.sourcePortNames?[otherPort] ?? otherPort).monospaced()
                    }
                    if let onLocate {
                        Button("Seguir cable", systemImage: "point.topleft.down.to.point.bottomright.curvepath") {
                            onLocate(.init(deviceID: port.deviceID, port: port.name, linkID: link.id))
                        }
                        .disabled(signal == .pending)
                    }
                    NavigationLink {
                        LinkInspector(link: link, topology: topology, locateTitle: locateTitle, onLocate: onLocate,
                                      poweredOff: poweredOff, pending: pending, negotiatingLink: negotiatingLink)
                    } label: { Label("Detalles y ping", systemImage: "waveform.path") }
                }
            }
        }
        .navigationTitle(device?.sourcePortNames?[port.name] ?? port.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct RackPDUInspector: View {
    let rack: LabARAssembly.Item
    let layout: LabLayout
    let topology: LabTopology
    let assembly: LabARAssembly?
    let poweredOff: Set<String>
    var selectedCircuit: Int? = nil
    var selectedOutlet: Int? = nil
    @State private var feed: LabARAssembly.PowerFeedPlan?

    var body: some View {
        let config = layout.pduConfiguration(for: rack.name)
        let devices = topology.devices.filter { $0.placementID == rack.name && assembly?.piece(.device($0.id)) == nil }
        let inventory = Dictionary(uniqueKeysWithValues: devices.map { ($0.id, $0) })
        let size = LabARAssembly.size(of: rack, in: layout, topology: topology)
        let strips = size.map { LabRackPower.strips(for: $0, configuration: config, devices: devices) } ?? []
        Form {
            ForEach(Array(strips.enumerated()).filter { selectedCircuit == nil || selectedCircuit == $0.offset }, id: \.offset) { index, strip in
                let outlets = Dictionary(uniqueKeysWithValues: strip.leads.compactMap { lead -> (Int, LabTopology.Device)? in
                    guard let start = lead.points.first, let socket = strip.sockets.firstIndex(of: start),
                          let device = inventory[lead.deviceID] else { return nil }
                    return (socket, device)
                })
                Section(config == .dual ? (index == 0 ? "PDU A" : "PDU B") : config.title) {
                    if let ups = strip.upsID.flatMap({ inventory[$0] }) {
                        LabeledContent("UPS", value: ups.name)
                    } else if assembly != nil && feed == nil {
                        ProgressView("Comprobando alimentación")
                    } else if feed?.externalUPSSources[rack] != nil {
                        LabeledContent("Origen", value: "UPS externo")
                    } else if assembly?.powerOutlets?[rack] != nil && index == 0 {
                        LabeledContent("Origen", value: "Toma de pared AR")
                    } else {
                        LabeledContent("Origen", value: "Alimentación virtual")
                    }
                    if feed?.reviewRacks.contains(rack) == true {
                        Label("Revisar recorrido de alimentación", systemImage: "exclamationmark.triangle")
                    }
                    LabeledContent("Tomas libres", value: "\(strip.sockets.count - outlets.count) de \(strip.sockets.count)")
                    if let socket = selectedOutlet {
                        LabeledContent("Toma \(socket + 1)", value: outlets[socket]?.name ?? "Libre")
                    }
                    ForEach(outlets.keys.sorted(), id: \.self) { socket in
                        if let device = outlets[socket] {
                            let off = poweredOff.contains(rack.name) || poweredOff.contains(strip.upsID ?? "")
                                || poweredOff.contains(device.id)
                            LabeledContent(device.name, value: "Toma \(socket + 1) · \(off ? "Sin alimentación" : "Activa")")
                        }
                    }
                }
            }
        }
        .navigationTitle("Distribución eléctrica")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if let assembly { feed = await Self.plan(assembly, layout: layout, topology: topology) }
        }
    }

    @concurrent private static func plan(_ assembly: LabARAssembly, layout: LabLayout, topology: LabTopology) async
        -> LabARAssembly.PowerFeedPlan {
        assembly.powerFeedPlan(in: layout, topology: topology)
    }
}

private struct SignalLabel: View {
    let signal: LabTopology.PortSignal

    var body: some View {
        let amber = signal == .blocked || signal == .negotiating
        Label {
            Text(signal.rawValue)
        } icon: {
            Image(systemName: signal == .active ? "checkmark.circle.fill" : amber ? "exclamationmark.circle.fill" : "circle")
                .foregroundStyle(signal == .active ? .green : amber ? .orange : .secondary)
        }
    }
}

struct LinkInspector: View {
    let link: LabTopology.Link
    let topology: LabTopology
    var locateTitle = "Ver en 3D"
    var onLocate: ((LabInspectionDestination) -> Void)? = nil
    var segments: [LabCablePlan.Segment] = []
    var poweredOff: Set<String> = []
    var pending: Set<String> = []
    var negotiatingLink: String? = nil
    @State private var ping: LabTopology.PingDiagnosis?

    var body: some View {
        let circuit = topology.circuit(for: link)
        let first = circuit.first ?? link, last = circuit.last ?? link
        let port = LabTopology.Port(deviceID: first.fromDeviceID, name: first.fromPort)
        let signal = topology.signal(at: port, poweredOff: poweredOff, pending: pending, negotiating: negotiatingLink)
        Form {
            Section("Extremo A") { endpoint(first.fromDeviceID, port: first.fromPort, accessibilityID: "connection-end-a") }
            Section("Extremo B") { endpoint(last.toDeviceID, port: last.toPort, accessibilityID: "connection-end-b") }
            Section("Cable") {
                SignalLabel(signal: signal)
                LabeledContent("Etiqueta del tramo", value: link.id)
                LabeledContent("Tipo", value: link.cableTitle)
                if let speed = topology.speedLimit(for: circuit) {
                    LabeledContent("Velocidad nominal del modelo", value: speed.formatted() + " Mb/s")
                }
                if let geometry = segments.first(where: { $0.link.id == link.id }) {
                    LabeledContent("Longitud simulada", value: geometry.length.formatted(.number.precision(.fractionLength(2))) + " m")
                    if geometry.bendRadius > 0 {
                        LabeledContent("Radio del modelo", value: (geometry.bendRadius * 1000).formatted() + " mm")
                    } else {
                        LabeledContent("Trazado", value: "Aproximado")
                    }
                }
                LabeledContent("VLAN indicadas", value: link.vlanIDs.isEmpty ? "No especificadas" : link.vlanIDs.map(String.init).joined(separator: ", "))
                if let onLocate {
                    Button("Seguir cable", systemImage: "point.topleft.down.to.point.bottomright.curvepath") {
                        onLocate(.init(deviceID: link.fromDeviceID, port: link.fromPort, linkID: link.id))
                    }.accessibilityHint(locateTitle).disabled(signal == .pending)
                }
                if link.medium == .copper {
                    Text("Conectores RJ45. La categoría y longitud física dependen de la instalación.")
                        .font(.footnote).foregroundStyle(.secondary)
                } else if link.medium == .fiber {
                    Text("Enlace óptico del plano. Confirma la compatibilidad de transceptores y conectores.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            if [.copper, .fiber, .serial].contains(link.medium),
               let source = topology.devices.first(where: { $0.id == first.fromDeviceID }),
               let target = topology.devices.first(where: { $0.id == last.toDeviceID }) {
                Section {
                    Button("Ejecutar ping simulado", systemImage: "waveform.path") {
                        ping = topology.diagnosePing(from: source, to: target, poweredOff: poweredOff.union(pending))
                    }
                    if let ping {
                        if let issue = ping.issue { Text(issue).font(.footnote).foregroundStyle(.secondary) }
                        PingSampleRows(sample: ping.sample)
                    }
                } header: {
                    Text("Ping entre extremos")
                } footer: {
                    Text("La prueba usa la topología del laboratorio y puede encontrar otra ruta disponible.")
                }
            }
            if circuit.count > 1 {
                Section {
                    ForEach(Array(circuit.enumerated()), id: \.element.id) { index, segment in
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Tramo \(index + 1)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            endpoint(segment.fromDeviceID, port: segment.fromPort, segmentID: segment.id, compact: true)
                            endpoint(segment.toDeviceID, port: segment.toPort, segmentID: segment.id, compact: true)
                        }.padding(.vertical, 3)
                    }
                } header: {
                    Text("Tramos físicos")
                } footer: {
                    Text("En el patch panel, los puertos F y R con el mismo número forman un paso pasivo.")
                }
            }
        }
        .navigationTitle("Conexión").navigationBarTitleDisplayMode(.inline)
        .onChange(of: topology) { ping = nil }
        .onChange(of: poweredOff) { ping = nil }
        .onChange(of: pending) { ping = nil }
    }

    @ViewBuilder private func endpoint(_ id: String, port: String, segmentID: String? = nil, compact: Bool = false,
                          accessibilityID: String? = nil) -> some View {
        if let device = topology.devices.first(where: { $0.id == id }) {
            let displayPort = device.sourcePortNames?[port] ?? port
            if let onLocate {
                Button {
                    onLocate(.init(deviceID: id, port: port, linkID: segmentID ?? link.id))
                } label: {
                    HStack(spacing: 10) {
                        endpointLabel(device.name, port: displayPort, compact: compact)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "viewfinder").foregroundStyle(Color.accentColor)
                            .accessibilityHidden(true)
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityHint(locateTitle)
                .accessibilityIdentifier(accessibilityID ?? "connection-port-\(id)-\(port)")
            } else {
                endpointLabel(device.name, port: displayPort, compact: compact)
            }
            if !compact, let address = device.ipv4 { LabeledContent("IPv4", value: address).monospaced() }
        }
    }

    private func endpointLabel(_ name: String, port: String, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(name).font(compact ? .subheadline.weight(.medium) : .headline)
            Text(port).font(.caption.monospaced()).foregroundStyle(.secondary)
        }
    }
}

struct DataCenterInfo: View {
    var topology: LabTopology? = nil
    @State private var testedPC: LabTopology.Device?

    var body: some View {
        Form {
            Section {
                Text("Plantilla de referencia Tier IV").font(.headline)
                Text("Sala virtual de 16 × 12 × 3,5 m. Para aplicarla a un escaneo, reserva una zona libre de 14,6 × 10,8 m, altura de 3,1 m y acceso por operación. Estas medidas corresponden a esta planta.")
            }
            Section("Alimentación A/B") {
                Label("A · rojo. B · violeta.", systemImage: "bolt")
                Text("Dos zonas técnicas con UPS y baterías de expansión. Las conducciones separadas llegan a PDU A y B en cada rack. Los servidores tienen dos fuentes. El ATS representa la alimentación alterna de equipos de una entrada.")
                Text("Aguas arriba se necesitan tableros y bypass, generación y combustible independientes. La autonomía, protección, puesta a tierra, selectividad y transferencia requieren cálculo y pruebas.")
            }
            Section("Refrigeración y montaje") {
                Text("InRow A/B en dos filas, con frentes hacia el pasillo frío y escape al caliente. Los puestos quedan en la zona de operación.")
                Text("La continuidad térmica requiere verificar condensadores externos, circuitos independientes, distribución de aire y capacidad después de una falla.")
                Text("La plantilla limita el radio del trazo a un mínimo de 32 mm para cobre y 40 mm para fibra. Usa el radio del cable y conector seleccionados para la instalación.")
            }
            if let topology, let server = topology.devices.first(where: { $0.id == LabDemo.labServerID }) {
                Section("Prueba de camino · VLAN 20") {
                    LabeledContent(server.name, value: server.ipv4 ?? "Sin dirección")
                    ForEach(topology.devices.filter { $0.id.hasPrefix("desk-") && $0.vlan == 20 }) { pc in
                        Button {
                            testedPC = pc
                        } label: {
                            Label("Probar \(pc.name)", systemImage: "desktopcomputer")
                        }
                    }
                    if let testedPC {
                        if let path = topology.switchedPath(from: testedPC.id, to: server.id, vlan: 20) {
                            Label("Camino encontrado para \(testedPC.name)", systemImage: "checkmark.circle")
                            Text(path.map(\.name).joined(separator: " → ")).font(.footnote)
                        } else {
                            Label("Camino interrumpido", systemImage: "exclamationmark.triangle")
                        }
                    }
                    Text("La comprobación sigue los enlaces habilitados de la VLAN. Selecciona la PC o laptop de operación para abrir su consola.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            if topology != nil {
                Section("Pruebas de infraestructura") {
                    NavigationLink("Abrir fichas de pruebas simuladas") { LabFacilityTrialsView() }
                }
            }
            Section("Validación del sitio") {
                Text("Verifica tolerancia a un fallo y mantenimiento sin interrupción. Revisa separación de rutas, compartimentación, detección y extinción, evacuación y capacidad bajo la carga del sitio. Uptime Institute certifica el diseño y la instalación.")
            }
            Section("Referencias") {
                Link("Uptime Institute · Tier Classification System", destination: URL(string: "https://uptimeinstitute.com/tiers")!)
                Link("Perú · Reglamento Nacional de Edificaciones", destination: URL(string: "https://www.gob.pe/institucion/vivienda/informes-publicaciones/2309793-reglamento-nacional-de-edificaciones-rne")!)
            }
        }
        .navigationTitle("Infraestructura y pruebas").navigationBarTitleDisplayMode(.inline)
    }
}


struct HomeLabGuide: View {
    let onFollowCable: (String) -> Void

    var body: some View {
        List {
            Section("1 · Reserva el espacio") {
                Text("Deja una zona libre de 4,32 × 3,4 m y al menos 2,1 m de altura para esta distribución. Instala el rack de 18 U en suelo firme, con acceso frontal y trasero. Mide fondo útil, holgura de cables y recorrido de los equipos antes de montar.")
                Text("En Montar HomeLab, elige un punto del piso o escanea el cuarto con LiDAR. En AR, camina alrededor y espera a que la ubicación quede guardada.")
            }
            Section("2 · Monta y etiqueta") {
                LabeledContent("U18", value: "PP-CAT6 · 24 pares RJ45")
                LabeledContent("U16", value: "SW-HOME · switch")
                LabeledContent("U12–13", value: "GW-HOME · router")
                LabeledContent("U14", value: "VELAARTURO-SERVICIOS · proxy, bóveda e IA")
                LabeledContent("U11", value: "PI-DOMÓTICA · Home Assistant y MQTT")
                LabeledContent("U10", value: "NVR-HOME · grabación RTSP")
                LabeledContent("U9", value: "PI-DNS · Pi-hole")
                LabeledContent("U8", value: "PVE-01 · hipervisor")
                LabeledContent("U6", value: "NAS-01 · espejo ZFS")
                LabeledContent("U4", value: "BACKUP-HOME · copias verificadas")
                LabeledContent("U1–2", value: "UPS-01 · respaldo eléctrico")
                Text("Etiqueta ambos extremos de cada Cat 6. Lleva los latiguillos por las guías laterales y el cableado hacia los puestos por la bandeja superior. Comprueba el mapa de hilos y el radio de curvatura del fabricante.")
                Button("Seguir cable de PC-SERVICIOS", systemImage: "cable.connector") { onFollowCable("home-pc-2") }
            }
            Section("3 · Configura la red") {
                LabeledContent("10 · Gestión", value: "192.168.60.0/24")
                LabeledContent("20 · Servicios", value: "192.168.61.0/24")
                LabeledContent("30 · Clientes", value: "192.168.62.0/24")
                LabeledContent("40 · Almacenamiento", value: "192.168.63.0/24")
                LabeledContent("50 · Domótica", value: "192.168.64.0/24")
                LabeledContent("60 · Vídeo", value: "192.168.65.0/24")
                Text("Asigna .1 a cada interfaz del gateway. En SW-HOME, deja VLAN 10 nativa hacia PVE-01 y etiqueta 20 y 40. AP-HOME anuncia Casa y Casa-IoT. CAM-ACCESO queda en la VLAN de vídeo. El switch requiere alimentación independiente para AP y cámara.")
            }
            Section("4 · Despliega los servicios") {
                Text("Instala Proxmox VE en PVE-01. Habilita VLAN-aware en vmbr0 y asigna la VLAN 20 a las VMs de publicación y proxy. Consulta la asignación de los dominios de velaarturo.com en la pestaña Sitios.")
                Text("En PI-DOMÓTICA instala Home Assistant OS con SSD y un coordinador Zigbee. Añade Mosquitto. Empareja sensores y actuadores. El YAML en Tools/Operations contiene reglas de luz, humedad y fuga de agua.")
                Text("Instala Pi-hole en PI-DNS. Monta NAS-01 y aplica permisos por grupo. Conecta CAM-ACCESO a NVR-HOME mediante RTSP. Apunta las copias de VM a BACKUP-HOME y a un destino fuera del rack.")
            }
            Section("5 · Comprueba desde el puesto") {
                Text("Toca PC-ADMIN o su laptop. En la consola ejecuta show interfaces para ver puertos y ping PVE-01 para seguir la VLAN de gestión.")
                Text("Herramientas locales en Tools/Operations. Verifica una copia con SHA-256, restaura a una carpeta nueva y reproduce un tramo del NVR.")
            }
            Section("Referencias") {
                Link("Guía de HomeLab de Chris Kirby", destination: URL(string: "https://chriskirby.net/setting-up-and-leveling-up-your-homelab-a-comprehensive-guide/")!)
                Link("Redes en Proxmox VE", destination: URL(string: "https://pve.proxmox.com/wiki/Network_Configuration")!)
                Link("Copias y restauración en Proxmox VE", destination: URL(string: "https://pve.proxmox.com/wiki/Backup_and_Restore")!)
                Link("Guardar y recuperar el mapa AR", destination: URL(string: "https://developer.apple.com/documentation/arkit/saving-and-loading-world-data")!)
            }
        }
        .navigationTitle("Montar HomeLab").navigationBarTitleDisplayMode(.inline)
    }
}

private struct LabFacilityTrialsView: View {
    @Environment(LabOperationsStore.self) private var operations
    @AppStorage("labFacilitySimulations.v1") private var archive = Data()
    @State private var scenario = LabFacilityTrial.Scenario.maintenance
    @State private var path = "A"
    @State private var load = 12.0
    @State private var available = 15.0
    @State private var battery = 8.0
    @State private var seconds = 20.0
    @State private var note = ""
    @State private var error: String?

    private var records: [String: [LabFacilityTrial]] {
        (try? JSONDecoder().decode([String: [LabFacilityTrial]].self, from: archive)) ?? [:]
    }

    var body: some View {
        Form {
            Section {
                Picker("Prueba", selection: $scenario) {
                    ForEach(LabFacilityTrial.Scenario.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                Picker("Ruta fuera de servicio", selection: $path) {
                    Text("A").tag("A")
                    Text("B").tag("B")
                }
                Stepper("Carga: \(load.formatted()) kW", value: $load, in: 1...200)
                Stepper("Capacidad de la ruta restante: \(available.formatted()) kW", value: $available, in: 0...250)
                if scenario == .transfer {
                    Stepper("Autonomía estimada de UPS: \(battery.formatted()) min", value: $battery, in: 0...120)
                    Stepper("Tiempo de transferencia: \(seconds.formatted()) s", value: $seconds, in: 0...600, step: 5)
                }
                TextField("Observación", text: $note, axis: .vertical).lineLimit(2...4)
                Button("Registrar prueba simulada", systemImage: "checkmark.seal", action: record)
                if let error { Label(error, systemImage: "exclamationmark.triangle") }
            } header: { Text(scenario.system) } footer: {
                Text("Escenario hipotético de \(operations.activeSite). Las capacidades son entradas del ejercicio. La sala física requiere mediciones y pruebas de campo.")
            }
            Section("Registro por subsistema") {
                let stored = records[operations.siteStorageID] ?? []
                if stored.isEmpty { Text("Sin pruebas registradas").foregroundStyle(.secondary) }
                ForEach(stored) { test in
                    DisclosureGroup {
                        LabeledContent("Ruta fuera de servicio", value: test.path)
                        LabeledContent("Carga y capacidad", value: "\(test.loadKW.formatted()) / \(test.availableKW.formatted()) kW")
                        if test.scenario == .transfer {
                            LabeledContent("Transferencia", value: "\(test.transferSeconds.formatted()) s")
                            LabeledContent("Autonomía", value: "\(test.batteryMinutes.formatted()) min")
                        }
                        if !test.note.isEmpty { Text(test.note) }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(test.scenario.rawValue)
                            Label(test.passed ? "Capacidad simulada suficiente" : "Prueba simulada fallida",
                                  systemImage: test.passed ? "checkmark.circle" : "exclamationmark.triangle")
                                .font(.caption)
                            Text(test.date, format: .dateTime.day().month().hour().minute()).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Pruebas simuladas")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func record() {
        let site = operations.siteStorageID
        let test = LabFacilityTrial(scenario: scenario, path: path, loadKW: load, availableKW: available,
                                    transferSeconds: seconds, batteryMinutes: battery, note: String(note.prefix(500)))
        var next = records
        next[site] = Array(([test] + (next[site] ?? [])).prefix(48))
        do { archive = try JSONEncoder().encode(next); note = ""; error = nil }
        catch { self.error = error.localizedDescription }
    }
}
