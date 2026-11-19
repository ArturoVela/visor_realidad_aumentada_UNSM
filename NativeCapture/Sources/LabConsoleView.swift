import SwiftUI

@Observable final class LabOperationsStore {
    struct Checkpoint: Identifiable, Codable {
        var id = UUID()
        var date = Date()
        var previous: LabOperationsOverrides
        var changes: [String]
    }

    private struct State: Codable {
        var sites: [String: String] = ["Principal": "principal"]
        var active = "Principal"
        var overrides: [String: LabOperationsOverrides] = [:]
        var history: [String: [Checkpoint]] = [:]
        var faults: [String: Set<String>]? = nil
        var monitors: [String: [String: LabMonitorConfiguration]]? = nil
    }

    private let key = "labPlanOperations.v2"
    private var state: State
    private(set) var revision = 0

    init() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: key), let saved = try? JSONDecoder().decode(State.self, from: data) {
            state = saved
        } else {
            let old = defaults.data(forKey: "labPlanOperations.v1")
            state = State(overrides: old.flatMap { try? JSONDecoder().decode([String: LabOperationsOverrides].self, from: $0) } ?? [:])
        }
    }

    var activeSite: String { state.active }
    var siteStorageID: String { state.sites[state.active] ?? "principal" }
    var siteNames: [String] { state.sites.keys.sorted() }

    private func profile(_ base: LabTopology) -> String? {
        base.operationsProfile.map { siteStorageID == "principal" ? $0 : siteStorageID + "." + $0 }
    }

    func configured(_ base: LabTopology) -> LabTopology {
        guard let id = profile(base), let settings = state.overrides[id] else { return base }
        return settings.apply(to: base)
    }

    func faults(in base: LabTopology) -> Set<String> {
        profile(base).flatMap { state.faults?[$0] } ?? []
    }

    func setFault(_ active: Bool, for device: String, in base: LabTopology) throws {
        guard let id = profile(base) else { return }
        var next = state
        var entries = next.faults ?? [:]
        var failed = faults(in: base)
        if active { failed.insert(device) } else { failed.remove(device) }
        entries[id] = failed
        next.faults = entries
        try persist(next)
    }

    func monitors(in base: LabTopology) -> [String: LabMonitorConfiguration] {
        profile(base).flatMap { state.monitors?[$0] } ?? [:]
    }

    func setMonitor(_ configuration: LabMonitorConfiguration, for device: String, in base: LabTopology) throws {
        guard let id = profile(base) else { return }
        var next = state
        var profiles = next.monitors ?? [:]
        profiles[id, default: [:]][device] = configuration
        next.monitors = profiles
        try persist(next)
    }

    func history(for base: LabTopology) -> [Checkpoint] { profile(base).flatMap { state.history[$0] } ?? [] }

    func selectSite(_ name: String) throws {
        guard state.sites[name] != nil, activeSite != name else { return }
        var next = state
        next.active = name
        try persist(next)
    }

    func createSite(_ text: String) throws {
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 45, !name.contains(where: { $0.isNewline }),
              !state.sites.keys.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }),
              state.sites.count < 24 else { throw LabLayoutError.invalid("Usa un sitio nuevo de hasta 45 caracteres. Límite de 24 sitios.") }
        var next = state
        next.sites[name] = UUID().uuidString
        next.active = name
        try persist(next)
    }

    func save(_ plan: LabTopology, against base: LabTopology) throws {
        guard let id = profile(base) else { return }
        try plan.validate()
        let previous = state.overrides[id] ?? .init()
        let changed = LabOperationsOverrides(plan, against: base)
        guard previous != changed else { return }
        let differences = changes(from: previous.apply(to: base), to: plan)
        var next = state
        next.overrides[id] = changed
        next.history[id] = Array(([Checkpoint(previous: previous, changes: differences)] + (next.history[id] ?? [])).prefix(20))
        try persist(next)
    }

    func undo(_ base: LabTopology) throws {
        guard let id = profile(base), let latest = state.history[id]?.first else { return }
        var next = state
        next.history[id]?.removeFirst()
        next.overrides[id] = latest.previous
        try persist(next)
    }

    private func persist(_ next: State) throws {
        UserDefaults.standard.set(try JSONEncoder().encode(next), forKey: key)
        state = next
        revision &+= 1
    }

    private func changes(from old: LabTopology, to new: LabTopology) -> [String] {
        let oldDevices = Dictionary(uniqueKeysWithValues: old.devices.map { ($0.id, $0) })
        var lines: [String] = []
        for device in new.devices {
            guard let before = oldDevices[device.id] else { continue }
            if before.name != device.name { lines.append("\(before.name) → \(device.name)") }
            if before.ipv4 != device.ipv4 { lines.append("\(device.name) · \(before.ipv4 ?? "—") → \(device.ipv4 ?? "—")") }
            let a = before.shutdownPorts ?? [], b = device.shutdownPorts ?? []
            for port in a.symmetricDifference(b).sorted() {
                lines.append("\(device.name) · \(port) → \(b.contains(port) ? "deshabilitado" : "habilitado")")
            }
        }
        let routes = old.siteRoutes
        for (host, target) in new.siteRoutes.sorted(by: { $0.key < $1.key }) where routes[host] != target {
            lines.append("\(host) → \(new.devices.first(where: { $0.id == target })?.name ?? target)")
        }
        return lines
    }
}

struct LabConsoleView: View {
    let base: LabTopology
    let poweredOff: Set<String>
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(LabOperationsStore.self) private var operations
    @State private var session: LabOperationsSession
    @State private var output: [Entry] = []
    @State private var command = ""
    @State private var tab = Tab.terminal

    private enum Tab: String, CaseIterable { case terminal = "Terminal", sites = "Sitios", history = "Historial" }
    private struct Entry: Identifiable {
        let id = UUID()
        let command: String
        let output: String
    }

    init(base: LabTopology, device: LabTopology.Device, poweredOff: Set<String>) {
        self.base = base
        self.poweredOff = poweredOff
        _session = State(initialValue: LabOperationsSession(stationID: device.id, targetID: device.id))
    }

    var body: some View {
        let plan = operations.configured(base)
        let target = plan.devices.first { $0.id == session.targetID }
        let station = plan.devices.first { $0.id == session.stationID }
        List {
            Section {
                Picker("Vista de administración", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(.init(top: 4, leading: 0, bottom: 4, trailing: 0))
            }
            switch tab {
            case .terminal:
                Section {
                    Picker("Equipo", selection: Binding(get: { session.targetID }, set: {
                        session.targetID = $0
                        session.port = nil
                    })) {
                        ForEach(plan.devices.filter { !$0.modelID.hasPrefix("patch-") || $0.id == session.targetID }) {
                            Text($0.name).tag($0.id)
                        }
                    }
                    if let port = session.port { LabeledContent("Interfaz", value: port).monospaced() }
                    if dynamicTypeSize.isAccessibilitySize {
                        VStack(alignment: .leading, spacing: 4) { commandInput; runButton }
                    } else {
                        HStack(spacing: 8) {
                            commandInput.frame(maxWidth: .infinity)
                            runButton.fixedSize()
                        }
                    }
                    Menu("Comandos", systemImage: "list.bullet.rectangle") {
                        ForEach(["help", "show services", "show interfaces", "show running-config", "show vlans", "show devices"], id: \.self) { suggestion in
                            Button(suggestion) { execute(suggestion) }
                        }
                    }
                    .frame(minHeight: 44)
                } footer: {
                    Text("Consola del plano. Los cambios se guardan en este dispositivo.")
                }
                if let entry = output.last {
                    transcript(entry)
                    if output.count > 1 {
                        Section("Historial") {
                            ForEach(output.dropLast().reversed()) { item in
                                DisclosureGroup(item.command) {
                                    Text(item.output).font(.footnote.monospaced()).textSelection(.enabled)
                                }
                            }
                        }
                    }
                } else {
                    Section("Consola de \(target?.name ?? "equipo")") {
                        Text("Ejecuta help para ver comandos. Puedes inspeccionar puertos, comprobar caminos de red y cambiar la asignación de un sitio.")
                            .foregroundStyle(.secondary)
                    }
                }
            case .sites:
                LabSiteSections(plan: plan)
            case .history:
                LabPlanSections(base: base)
            }
        }
        .navigationTitle(station?.name ?? "Administración")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var commandInput: some View {
        TextField("Escribe un comando", text: $command)
            .font(.callout.monospaced())
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .submitLabel(.go)
            .accessibilityIdentifier("lab.console.command")
            .onSubmit { execute(command) }
            .frame(minHeight: 44)
    }

    private var runButton: some View {
        Button("Ejecutar") { execute(command) }
            .buttonStyle(.borderedProminent)
            .disabled(command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .frame(minHeight: 44)
    }

    private func transcript(_ entry: Entry) -> some View {
        Section("Última salida") {
            VStack(alignment: .leading, spacing: 8) {
                Text(entry.command).font(.callout.monospaced().weight(.semibold)).foregroundStyle(.tint)
                Text(entry.output).font(.footnote.monospaced()).textSelection(.enabled)
                    .accessibilityIdentifier("lab.console.output")
            }
        }
    }

    private func execute(_ input: String) {
        let line = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return }
        let before = operations.configured(base)
        var plan = before
        var result = session.execute(line, on: &plan, poweredOff: poweredOff.union(operations.faults(in: base)))
        if plan != before {
            do { try operations.save(plan, against: base) }
            catch { result = error.localizedDescription }
        }
        output = Array((output + [.init(command: line, output: result)]).suffix(16))
        command = ""
    }
}

struct LabSiteSections: View {
    let plan: LabTopology

    var body: some View {
        let routes = plan.siteRoutes
        let names = Dictionary(uniqueKeysWithValues: plan.devices.map { ($0.id, $0.name) })
        ForEach(LabSite.Group.allCases, id: \.self) { group in
            Section(group.rawValue) {
                ForEach(LabSite.all.filter { $0.group == group }) { site in
                    if let owner = routes[site.host], let name = names[owner] {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(site.host)
                            Text(name).font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(minHeight: 36)
                    }
                }
            }
        }
    }
}

extension LabTopology.Device {
    var isWorkstation: Bool { modelID == "pc-optiplex7010" || modelID == "laptop-latitude5420" }
}

struct LabDeviceSheet: View {
    let device: LabTopology.Device
    let base: LabTopology
    let poweredOff: Set<String>
    var locateTitle = "Ver en 3D"
    var onLocate: ((LabInspectionDestination) -> Void)? = nil
    @Environment(LabOperationsStore.self) private var operations

    var body: some View {
        let plan = operations.configured(base)
        let current = plan.devices.first { $0.id == device.id } ?? device
        NavigationStack {
            Group {
                if base.operationsProfile != nil && current.isWorkstation {
                    LabConsoleView(base: base, device: current, poweredOff: poweredOff)
                } else if base.operationsProfile != nil && current.hasDashboard {
                    LabServerDashboard(device: current, topology: plan, poweredOff: poweredOff, base: base,
                                       locateTitle: locateTitle, onLocate: onLocate)
                } else {
                    DeviceInspector(device: current, topology: plan, locateTitle: locateTitle,
                                    onLocate: onLocate,
                                    consoleBase: base.operationsProfile == nil || current.modelID.hasPrefix("patch-") ? nil : base,
                                    poweredOff: poweredOff)
                }
            }
            .toolbar { DismissButton() }
        }
    }
}

private struct LabServerDashboard: View {
    let device: LabTopology.Device
    let topology: LabTopology
    let poweredOff: Set<String>
    let base: LabTopology
    let locateTitle: String
    let onLocate: ((LabInspectionDestination) -> Void)?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(LabOperationsStore.self) private var operations
    @State private var error: String?

    var body: some View {
        let simulatedFaults = operations.faults(in: base)
        let effectivePower = poweredOff.union(simulatedFaults)
        let settings = operations.monitors(in: base)[device.id] ?? .init()
        TimelineView(.periodic(from: .now, by: LabServerSample.interval)) { context in
            let sample = LabServerSample(device: device, topology: topology,
                                         poweredOff: effectivePower, timestamp: context.date)
            List {
                Section {
                    Label(sample.state.rawValue, systemImage: sample.state == .available ? "checkmark.circle"
                          : sample.state == .isolated ? "network.slash" : "power")
                        .foregroundStyle(sample.state == .available ? Color.green
                            : sample.state == .isolated ? Color.orange : Color.secondary)
                    LabeledContent("Actualización simulada") {
                        Text(sample.timestamp, style: .time).monospacedDigit()
                    }
                    let failed = simulatedFaults.contains(device.id)
                    Button {
                        attempt { try operations.setFault(!failed, for: device.id, in: base) }
                    } label: {
                        Label(failed ? "Encender en simulación" : "Apagar en simulación",
                              systemImage: failed ? "power.circle" : "power")
                            .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .accessibilityIdentifier("lab.dashboard.power")
                } header: {
                    Text("Simulación · Monitor de 14″")
                }

                Section("Ajustes del monitor") {
                    Picker("Vista", selection: setting(\.panel)) {
                        ForEach(LabMonitorConfiguration.Panel.allCases, id: \.self) { Text($0.rawValue) }
                    }
                    .accessibilityIdentifier("lab.dashboard.page")
                    if settings.panel != .services {
                        Picker("Gráfico", selection: setting(\.chart)) {
                            ForEach(LabMonitorConfiguration.Chart.allCases, id: \.self) { Text($0.rawValue) }
                        }
                        .accessibilityIdentifier("lab.dashboard.chart")
                    }
                    if let error { Text(error).foregroundStyle(.secondary) }
                }
                .pickerStyle(.navigationLink)

                if settings.panel == .services {
                    Section("Servicios asignados") {
                        if device.services.isEmpty && (device.siteHosts ?? []).isEmpty {
                            Text("Sin servicios asignados").foregroundStyle(.secondary)
                        }
                        ForEach(Array(device.services.enumerated()), id: \.offset) { _, service in
                            LabeledContent(service, value: sample.state.rawValue)
                        }
                        ForEach(device.siteHosts ?? [], id: \.self) { Text($0).font(.callout.monospaced()) }
                    }
                } else {
                    Section(settings.panel.rawValue) {
                        let layout = dynamicTypeSize.isAccessibilitySize
                            ? AnyLayout(VStackLayout(spacing: 16))
                            : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
                        layout {
                            ForEach(settings.panel.metrics, id: \.self) { metric in
                                metricCard(metric, value: metric.value(in: sample), rings: settings.usesRings)
                            }
                        }
                        .padding(.vertical, 8)
                        if settings.panel == .network {
                            LabeledContent("IPv4", value: device.ipv4 ?? "Sin dirección")
                            if let vlan = device.vlan { LabeledContent("VLAN", value: String(vlan)) }
                        } else {
                            LabeledContent("Entrada", value: LabMonitorConfiguration.Metric.receive.formatted(sample.receiveMbps))
                            LabeledContent("Salida", value: LabMonitorConfiguration.Metric.transmit.formatted(sample.transmitMbps))
                        }
                    }
                }
                Section {
                    NavigationLink {
                        DeviceInspector(device: device, topology: topology, locateTitle: locateTitle, onLocate: onLocate,
                                        consoleBase: base, poweredOff: poweredOff)
                    } label: { Label("Ver equipo y cableado", systemImage: "cable.connector") }
                    ShareLink(item: report(sample)) { Label("Exportar ficha del servidor", systemImage: "square.and.arrow.up") }
                }
            }
        }
        .navigationTitle(device.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func setting<Value>(_ keyPath: WritableKeyPath<LabMonitorConfiguration, Value>) -> Binding<Value> {
        Binding {
            (operations.monitors(in: base)[device.id] ?? .init())[keyPath: keyPath]
        } set: { value in
            var settings = operations.monitors(in: base)[device.id] ?? .init()
            settings[keyPath: keyPath] = value
            attempt { try operations.setMonitor(settings, for: device.id, in: base) }
        }
    }

    private func attempt(_ action: () throws -> Void) {
        do { try action(); error = nil }
        catch { self.error = error.localizedDescription }
    }

    private func metricCard(_ metric: LabMonitorConfiguration.Metric, value: Double, rings: Bool) -> some View {
        VStack(spacing: 6) {
            ZStack {
                LabMonitorChart(rings: rings, fraction: 1).fill(.secondary.opacity(0.22))
                LabMonitorChart(rings: rings, fraction: value / metric.maximum).fill(.tint)
            }
            .frame(width: 64, height: 64)
            .accessibilityHidden(true)
            Text(metric.rawValue)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(metric.formatted(value))
                .font(.title3.weight(.semibold).monospacedDigit())
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("lab.dashboard.metric." + metric.rawValue)
    }

    private func report(_ sample: LabServerSample) -> String {
        let receive = LabMonitorConfiguration.Metric.receive.formatted(sample.receiveMbps)
        let transmit = LabMonitorConfiguration.Metric.transmit.formatted(sample.transmitMbps)
        return ([device.name, "Nexus AR · Ficha simulada", sample.state.rawValue, sample.timestamp.ISO8601Format(),
          "IPv4 \(device.ipv4 ?? "—")", "VLAN \(device.vlan.map(String.init) ?? "—")",
          "RX \(receive) · TX \(transmit)", device.services.joined(separator: ", ")]
         + (device.siteHosts ?? []) + [device.configuration ?? ""]).joined(separator: "\n")
    }
}

nonisolated struct LabMonitorChart: Shape {
    let rings: Bool
    let fraction: Double

    func path(in rect: CGRect) -> Path {
        let fraction = min(1, max(0, fraction))
        guard fraction > 0 else { return Path() }
        let size = min(rect.width, rect.height)
        if rings {
            let lineWidth = size * 0.15
            var path = Path()
            path.addRelativeArc(center: CGPoint(x: rect.midX, y: rect.midY), radius: (size - lineWidth) / 2,
                                startAngle: .degrees(-90), delta: .degrees(360 * fraction))
            return path.strokedPath(StrokeStyle(lineWidth: lineWidth, lineCap: .round))
        }
        let width = size * 0.44
        let height = rect.height * fraction
        return Path(roundedRect: CGRect(x: rect.midX - width / 2, y: rect.maxY - height, width: width, height: height),
                    cornerRadius: min(size * 0.10, height / 2))
    }
}

struct LabPlanSections: View {
    let base: LabTopology?
    @Environment(LabOperationsStore.self) private var operations
    @State private var editingSite = false
    @State private var name = ""
    @State private var error: String?

    var body: some View {
        let history = base.map(operations.history) ?? []
        Section("Plan por sitio") {
            Picker("Sitio activo", selection: Binding(get: { operations.activeSite },
                                                       set: { site in attempt { try operations.selectSite(site) } })) {
                ForEach(operations.siteNames, id: \.self) { Text($0).tag($0) }
            }
            Button("Nuevo sitio", systemImage: "plus") { name = ""; editingSite = true }
                .alert("Nuevo sitio", isPresented: $editingSite) {
                    TextField("Nombre", text: $name)
                    Button("Crear") { attempt { try operations.createSite(name) } }
                    Button("Cancelar", role: .cancel) {}
                } message: {
                    Text("Cada sitio guarda sus escaneos, cambios y puntos AR por separado.")
                }
        }
        Section("Cambios de configuración") {
            if history.isEmpty { Text("Sin cambios guardados").foregroundStyle(.secondary) }
            else if let base {
                Button("Deshacer último cambio", systemImage: "arrow.uturn.backward") { attempt { try operations.undo(base) } }
                ForEach(history) { checkpoint in
                    DisclosureGroup {
                        ForEach(Array(checkpoint.changes.enumerated()), id: \.offset) { _, change in Text(change) }
                    } label: { Text(checkpoint.date, format: .dateTime.day().month().hour().minute().second()) }
                }
            }
            if let error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary) }
        }
    }

    private func attempt(_ action: () throws -> Void) {
        do { try action(); error = nil }
        catch { self.error = error.localizedDescription }
    }
}

struct LabInventoryLibrary: View {
    let base: LabTopology?
    let onOpen: (LabImport.Entry) -> Void
    @Environment(LabOperationsStore.self) private var operations
    @State private var loading = true
    @State private var entries: [LabImport.Entry] = []
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                LabPlanSections(base: base)
                Section("Inventarios importados") {
                    if loading { ProgressView("Abriendo historial…") }
                    else if let error { Label(error, systemImage: "exclamationmark.triangle") }
                    else if entries.isEmpty { Text("Sin inventarios en este sitio").foregroundStyle(.secondary) }
                    ForEach(entries) { entry in
                        Button { onOpen(entry) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(entry.name)
                                Text(entry.date, format: .dateTime.day().month().year().hour().minute())
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            .frame(minHeight: 44)
                        }
                    }
                }
            }
            .navigationTitle("Sitios e inventarios")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { DismissButton() }
        }
        .task(id: operations.siteStorageID) {
            let site = operations.siteStorageID
            entries = []
            loading = true
            error = nil
            do {
                let stored = try await Self.load(site: site)
                guard !Task.isCancelled else { return }
                entries = stored
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
            loading = false
        }
    }

    @concurrent private static func load(site: String) async throws -> [LabImport.Entry] {
        try LabImport.history(site: site)
    }
}

struct LabMonitorInventory: View {
    let base: LabTopology
    let poweredOff: Set<String>
    var locateTitle = "Ver en 3D"
    var onLocate: ((LabInspectionDestination) -> Void)? = nil
    @Environment(LabOperationsStore.self) private var operations

    var body: some View {
        let topology = operations.configured(base)
        NavigationStack {
            List(topology.devices.filter { $0.hasDashboard }) { device in
                NavigationLink {
                    LabServerDashboard(device: device, topology: topology, poweredOff: poweredOff,
                                       base: base, locateTitle: locateTitle, onLocate: onLocate)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(device.name)
                        if let service = device.services.first { Text(service).font(.caption).foregroundStyle(.secondary) }
                    }
                    .frame(minHeight: 44)
                    .accessibilityElement(children: .combine)
                }
            }
            .navigationTitle("Monitores de servidores")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { DismissButton() }
        }
    }
}
