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
        var savedDates: [String: Date]? = nil
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
        if let id = base.editableProfileID { return "editable." + id.uuidString }
        return base.operationsProfile.map { siteStorageID == "principal" ? $0 : siteStorageID + "." + $0 }
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

    func lastSaved(for base: LabTopology) -> Date? {
        profile(base).flatMap { state.savedDates?[$0] ?? state.history[$0]?.first?.date }
    }

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
        guard base.editableProfileID == nil else {
            throw LabLayoutError.invalid("Guarda los cambios de esta copia desde Editar red en Montajes AR.")
        }
        guard let id = profile(base) else { return }
        try plan.validate()
        let previous = state.overrides[id] ?? .init()
        let changed = LabOperationsOverrides(plan, against: base)
        guard previous != changed else { return }
        let differences = changes(from: previous.apply(to: base), to: plan)
        var next = state
        next.overrides[id] = changed
        let checkpoint = Checkpoint(previous: previous, changes: differences)
        next.history[id] = Array(([checkpoint] + (next.history[id] ?? [])).prefix(20))
        next.savedDates = (next.savedDates ?? [:]).merging([id: checkpoint.date]) { _, updated in updated }
        try persist(next)
    }

    func undo(_ base: LabTopology) throws {
        guard let id = profile(base), let latest = state.history[id]?.first else { return }
        var next = state
        next.history[id]?.removeFirst()
        next.overrides[id] = latest.previous
        next.savedDates = (next.savedDates ?? [:]).merging([id: .now]) { _, updated in updated }
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
            if before.packetTracer != device.packetTracer { lines.append("\(device.name) · Configuración de interfaces") }
            let a = before.shutdownPorts ?? [], b = device.shutdownPorts ?? []
            for port in a.symmetricDifference(b).sorted() {
                lines.append("\(device.name) · \(port) → \(b.contains(port) ? "deshabilitado" : "habilitado")")
            }
        }
        let routes = old.siteRoutes
        for (host, target) in new.siteRoutes.sorted(by: { $0.key < $1.key }) where routes[host] != target {
            lines.append("\(host) → \(new.devices.first(where: { $0.id == target })?.name ?? target)")
        }
        let oldVLANs = Dictionary(uniqueKeysWithValues: old.links.map { ($0.id, $0.vlanIDs) })
        var recorded = Set<String>()
        for link in new.links where oldVLANs[link.id] != link.vlanIDs && recorded.insert(link.circuitID ?? link.id).inserted {
            lines.append("\(link.circuitID ?? link.id) · VLAN \(link.vlanIDs.map(String.init).joined(separator: ", "))")
        }
        return lines
    }
}

struct LabConsoleView: View {
    let base: LabTopology
    let poweredOff: Set<String>
    private let liveBase: (() -> LabTopology?)?
    private let save: ((LabTopology) throws -> Void)?
    private let close: (() -> Void)?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(LabOperationsStore.self) private var operations
    @State private var session: LabOperationsSession
    @State private var output: [Entry] = []
    @State private var command = ""
    @State private var recentCommands: [String: [String]] = [:]
    @State private var tab = Tab.terminal
    @State private var savedAt: Date?
    @FocusState private var typing: Bool

    private enum Tab: String, CaseIterable { case terminal = "Terminal", sites = "Sitios", history = "Historial" }
    private struct Entry: Identifiable {
        let id = UUID()
        let prompt: String
        let command: String
        let output: String
    }

    init(base: LabTopology, device: LabTopology.Device, poweredOff: Set<String>,
         liveBase: (() -> LabTopology?)? = nil, save: ((LabTopology) throws -> Void)? = nil,
         close: (() -> Void)? = nil) {
        self.base = base
        self.poweredOff = poweredOff
        self.liveBase = liveBase
        self.save = save
        self.close = close
        _session = State(initialValue: LabOperationsSession(stationID: device.id, targetID: device.id))
    }

    private let terminalBackground = Color(red: 0.06, green: 0.08, blue: 0.10)
    private let promptColor = Color(red: 0.42, green: 0.85, blue: 0.76)

    var body: some View {
        let plan = operations.configured(liveBase?() ?? base)
        let target = plan.devices.first { $0.id == session.targetID }
        let hasAdministration = plan.operationsProfile != nil && plan.editableProfileID == nil
        VStack(spacing: 0) {
            if hasAdministration {
                Picker("Vista de administración", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .padding(12)
            }
            switch tab {
            case .terminal:
                terminal(plan: plan, target: target)
            case .sites:
                List { LabSiteSections(plan: plan) }
            case .history:
                List { LabPlanSections(base: base) }
            }
        }
        .navigationTitle(target?.name ?? "Terminal")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(tab == .terminal ? .dark : nil, for: .navigationBar)
        .toolbarBackground(tab == .terminal ? terminalBackground : Color(uiColor: .systemBackground), for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            if let close { ToolbarItem(placement: .topBarTrailing) { Button("Listo", action: close) } }
        }
    }

    private func terminal(plan: LabTopology, target: LabTopology.Device?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack { targetPicker(plan); Spacer(minLength: 12); saveStatus(plan: plan, target: target) }
                VStack(alignment: .leading, spacing: 0) { targetPicker(plan); saveStatus(plan: plan, target: target) }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 4)
            Divider()
            ScrollViewReader { scroll in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(output) { entry in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(entry.prompt) \(entry.command)").foregroundStyle(promptColor)
                                if !entry.output.isEmpty {
                                    Text(entry.output)
                                        .accessibilityIdentifier(entry.id == output.last?.id ? "lab.console.output" : "")
                                }
                            }
                        }
                        Color.clear.frame(height: 1).id("terminal-end")
                    }
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .defaultScrollAnchor(.bottom)
                .onChange(of: output.last?.id) { _, _ in scroll.scrollTo("terminal-end", anchor: .bottom) }
            }
            Divider()
            if let target, let suggestion = session.prediction(for: command, device: target,
                                                                history: recentCommands[target.id] ?? []) {
                Button {
                    command = suggestion
                    typing = true
                } label: {
                    Label(suggestion, systemImage: "text.insert")
                        .font(.caption.monospaced()).lineLimit(1).frame(minHeight: 44)
                }
                .buttonStyle(.plain)
                .foregroundStyle(promptColor)
                .padding(.horizontal, 14)
                .accessibilityLabel("Completar \(suggestion)")
                .accessibilityIdentifier("lab.console.prediction")
            }
            commandBar(target: target)
        }
        .foregroundStyle(.white)
        .background(terminalBackground)
        .environment(\.colorScheme, .dark)
    }

    private func targetPicker(_ plan: LabTopology) -> some View {
        Picker("Equipo", selection: Binding(get: { session.targetID }, set: { session.selectTarget($0) })) {
            ForEach(plan.devices.filter { !$0.modelID.hasPrefix("patch-") || $0.id == session.targetID }) {
                Text($0.name).tag($0.id)
            }
        }
        .pickerStyle(.menu)
        .tint(promptColor)
        .frame(minHeight: 44)
    }

    @ViewBuilder private func saveStatus(plan: LabTopology, target: LabTopology.Device?) -> some View {
        Group {
            if target?.modelID.hasPrefix("patch-") == true || (save == nil && plan.operationsProfile == nil) {
                Text("Solo consulta")
            } else if let savedAt {
                Text("Guardado \(savedAt.formatted(date: .abbreviated, time: .shortened))")
                    .accessibilityIdentifier("lab.console.saved")
            } else if plan.operationsProfile == nil && plan.editableProfileID == nil {
                Text("El primer cambio crea una copia editable.")
            }
        }
        .font(.caption)
        .foregroundStyle(Color(white: 0.76))
    }

    private func commandBar(target: LabTopology.Device?) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 0)) : AnyLayout(HStackLayout(spacing: 8))
        return layout {
            promptLabel(target?.name).lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                .truncationMode(.head)
                .layoutPriority(1)
            HStack(spacing: 8) {
                commandInput.frame(minWidth: 100)
                runButton
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 3)
        .task {
            await Task.yield()
            typing = true
        }
    }

    private func prompt(_ name: String?) -> String { (name ?? "nexus") + session.mode.rawValue }

    private func promptLabel(_ name: String?) -> some View {
        Text(prompt(name)).font(.callout.monospaced().weight(.semibold))
            .foregroundStyle(promptColor)
            .accessibilityIdentifier("lab.console.prompt")
    }

    private var commandInput: some View {
        TextField("Comando", text: $command)
            .focused($typing)
            .font(.callout.monospaced())
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .submitLabel(.go)
            .accessibilityIdentifier("lab.console.command")
            .onSubmit {
                execute(command)
                Task {
                    await Task.yield()
                    typing = true
                }
            }
            .frame(minHeight: 44)
    }

    private var runButton: some View {
        Button { execute(command) } label: {
            Image(systemName: "return")
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Ejecutar")
        .tint(promptColor)
        .disabled(command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private func execute(_ input: String) {
        let line = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return }
        if ["clear", "cls"].contains(line.lowercased()) {
            output.removeAll()
            command = ""
            return
        }
        let base = liveBase?() ?? self.base
        let previousSession = session
        recentCommands[previousSession.targetID] = Array(((recentCommands[previousSession.targetID] ?? []) + [line]).suffix(24))
        let before = operations.configured(base)
        let currentPrompt = prompt(before.devices.first { $0.id == session.targetID }?.name)
        var plan = before
        let writable = save != nil || (base.operationsProfile != nil && base.editableProfileID == nil)
        var result = session.execute(line, on: &plan, poweredOff: poweredOff.union(operations.faults(in: base)), editingAllowed: writable)
        if plan != before {
            do {
                if let save { try save(plan) } else { try operations.save(plan, against: base) }
                savedAt = .now
            } catch {
                session = previousSession
                result = "Error al guardar · \(error.localizedDescription)"
            }
        }
        output = Array((output + [.init(prompt: currentPrompt, command: line, output: result)]).suffix(64))
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
    var opensTerminal = false
    var moveDevice: AnyView? = nil
    var catalystInspection: Catalyst2960Inspection? = nil
    var liveBase: (() -> LabTopology?)? = nil
    var save: ((LabTopology) throws -> Void)? = nil
    var powerCut: Binding<Bool>? = nil
    var pending: Set<String> = []
    @Environment(LabOperationsStore.self) private var operations
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicType
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    var body: some View {
        let plan = operations.configured(base)
        let current = plan.devices.first { $0.id == device.id } ?? device
        let terminal = opensTerminal || (base.operationsProfile != nil && current.isWorkstation)
        let scrollsActions = verticalSizeClass == .compact && dynamicType.isAccessibilitySize
            && current.visualModelID == Catalyst2960Asset.modelID && catalystInspection != nil
        NavigationStack {
            Group {
                if terminal {
                    LabConsoleView(base: base, device: current, poweredOff: poweredOff, liveBase: liveBase, save: save)
                } else if base.operationsProfile != nil && current.hasDashboard {
                    LabServerDashboard(device: current, topology: plan, poweredOff: poweredOff, base: base,
                                       locateTitle: locateTitle, onLocate: onLocate)
                } else {
                    DeviceInspector(device: current, topology: plan, locateTitle: locateTitle,
                                    onLocate: onLocate,
                                    poweredOff: poweredOff,
                                    console: scrollsActions ? LabConsoleView(base: base, device: current, poweredOff: poweredOff,
                                                                              liveBase: liveBase, save: save, close: { dismiss() }) : nil,
                                    showsConsole: scrollsActions, catalystInspection: catalystInspection,
                                    moveDevice: scrollsActions ? moveDevice : nil, powerCut: powerCut, pending: pending)
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if !terminal && !scrollsActions {
                    VStack(spacing: 0) {
                        if !current.modelID.hasPrefix("patch-") && !current.isFanTray {
                            NavigationLink {
                                LabConsoleView(base: base, device: current, poweredOff: poweredOff, liveBase: liveBase,
                                               save: save, close: { dismiss() })
                            } label: {
                                Label("Abrir CLI", systemImage: "terminal")
                                    .frame(maxWidth: .infinity, minHeight: 44)
                            }
                            .buttonStyle(.borderedProminent)
                            .padding(.horizontal, 16).padding(.vertical, 6)
                            .accessibilityIdentifier("lab.open-cli")
                        }
                        if let moveDevice { LabRackMoveLink(destination: moveDevice) }
                    }
                    .background(Color(uiColor: .systemBackground))
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { DismissButton() }
            }
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
                if settings.panel != .services {
                    Section("Simulación · \(settings.panel.rawValue)") {
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
                }

                Section {
                    Label {
                        Text(sample.state.rawValue)
                    } icon: {
                        Image(systemName: sample.state == .available ? "checkmark.circle"
                              : sample.state == .isolated ? "network.slash" : "power")
                            .foregroundStyle(sample.state == .available ? Color.green
                                : sample.state == .isolated ? Color.orange : Color.secondary)
                    }
                    LabeledContent("Actualización simulada") {
                        Text(sample.timestamp, format: .dateTime.hour().minute().second()).monospacedDigit()
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
    let onOpen: (LabImport.Entry) -> Void
    @Environment(LabOperationsStore.self) private var operations
    @Environment(SavedLaboratories.self) private var library
    @Environment(\.scenePhase) private var scenePhase
    @State private var received: [LabImport.Entry] = []
    @State private var imported: [LabImport.Entry] = []
    @State private var loading = true
    @State private var error: String?
    @State private var query = ""
    @State private var filter: Filter = .all
    @State private var order: Order = .recent
    @State private var editing: Edit?
    @State private var draft = ""

    private enum Filter: Hashable {
        case all, folder(UUID), archived, trash
    }

    private enum Order: String, CaseIterable {
        case recent = "Más recientes", old = "Más antiguos", name = "Nombre"
    }

    private enum Edit {
        case entry(LabImport.Entry), folder(SavedLaboratories.Folder?)

        var title: String {
            switch self {
            case .entry: "Renombrar laboratorio"
            case .folder(.some): "Renombrar carpeta"
            case .folder(.none): "Nueva carpeta"
            }
        }
    }

    private var entries: [LabImport.Entry] {
        (received + imported).filter { entry in
            let info = library.details(entry)
            let matches: Bool
            switch filter {
            case .all: matches = info.inLibrary
            case .folder(let id): matches = info.inLibrary && info.folderID == id
            case .archived: matches = info.archived && !info.deleted
            case .trash: matches = info.deleted
            }
            return matches && (query.isEmpty || library.name(entry).localizedStandardContains(query))
        }.sorted { a, b in
            switch order {
            case .recent: a.date > b.date
            case .old: a.date < b.date
            case .name: library.name(a).localizedStandardCompare(library.name(b)) == .orderedAscending
            }
        }
    }

    private var folderCounts: [UUID: Int] {
        (received + imported).reduce(into: [:]) { counts, entry in
            let info = library.details(entry)
            if info.inLibrary, let folder = info.folderID { counts[folder, default: 0] += 1 }
        }
    }

    var body: some View {
        let counts = folderCounts
        List {
            if let error { Label(error, systemImage: "exclamationmark.triangle") }
            if loading {
                ProgressView("Buscando laboratorios…")
            } else if filter == .all && query.isEmpty {
                if !library.folders.isEmpty {
                    Section("Carpetas") {
                        ForEach(library.folders) { folder in
                            let count = counts[folder.id, default: 0]
                            Button {
                                filter = .folder(folder.id)
                            } label: {
                                Label(folder.name, systemImage: "folder")
                            }
                            .badge(count.formatted())
                            .accessibilityValue(count == 1 ? "1 laboratorio" : "\(count) laboratorios")
                            .contextMenu {
                                Button("Renombrar", systemImage: "pencil") { beginEdit(.folder(folder), current: folder.name) }
                                Button("Quitar carpeta", systemImage: "folder.badge.minus", role: .destructive) {
                                    change { try library.removeFolder(folder) }
                                }
                            }
                        }
                    }
                }
                let unfiled = entries.filter { library.details($0).folderID == nil }
                let inbox = unfiled.filter(\.receivedFromMac)
                let local = unfiled.filter { !$0.receivedFromMac }
                Section("Recibidos del Mac · \(inbox.count)") {
                    if inbox.isEmpty {
                        Text("Los envíos desde Finder aparecen aquí.").foregroundStyle(.secondary)
                    }
                    rows(inbox)
                }
                Section("Importados en \(operations.activeSite) · \(local.count)") {
                    if local.isEmpty {
                        Text("Sin importaciones fuera de carpetas").foregroundStyle(.secondary)
                    }
                    rows(local)
                }
            } else {
                if entries.isEmpty { Text("Sin laboratorios").foregroundStyle(.secondary) }
                rows(entries)
            }
        }
        .navigationTitle(filterTitle)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(filter != .all)
        .searchable(text: $query, prompt: "Buscar laboratorios")
        .toolbar {
            if filter != .all {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Todos", systemImage: "chevron.left") { filter = .all }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Nueva carpeta", systemImage: "folder.badge.plus") { beginEdit(.folder(nil), current: "") }
                    Picker("Mostrar", selection: $filter) {
                        Text("Todos").tag(Filter.all)
                        ForEach(library.folders) { folder in
                            Text("\(folder.name) (\(counts[folder.id, default: 0]))").tag(Filter.folder(folder.id))
                        }
                        Text("Archivados").tag(Filter.archived)
                        Text("Papelera").tag(Filter.trash)
                    }
                    Picker("Ordenar por", selection: $order) {
                        ForEach(Order.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                } label: {
                    Label("Administrar biblioteca", systemImage: "ellipsis.circle")
                }
            }
        }
        .alert(editing?.title ?? "Nombre", isPresented: Binding(
            get: { editing != nil }, set: { if !$0 { editing = nil } })
        ) {
            TextField("Nombre", text: $draft)
            Button("Guardar", action: saveEdit)
            Button("Cancelar", role: .cancel) { editing = nil }
        }
        .task(id: operations.siteStorageID) { await reload() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await reload() } }
        }
        .refreshable { await reload() }
    }

    private var filterTitle: String {
        switch filter {
        case .all: "Laboratorios guardados"
        case .folder(let id): library.folders.first(where: { $0.id == id })?.name ?? "Carpeta"
        case .archived: "Archivados"
        case .trash: "Papelera"
        }
    }

    private func rows(_ entries: [LabImport.Entry]) -> some View {
        ForEach(entries) { entry in
            let info = library.details(entry)
            HStack {
                Button { onOpen(entry) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(library.name(entry))
                        HStack {
                            Text(entry.date, format: .dateTime.day().month().year().hour().minute())
                            if !info.enabled { Text("En pausa") }
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!info.inLibrary)
                Menu {
                    entryActions(entry, info: info)
                } label: {
                    Label("Acciones de \(library.name(entry))", systemImage: "ellipsis")
                        .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                }
            }
            .swipeActions {
                if info.inLibrary {
                    Button("Archivar", systemImage: "archivebox") { change { try library.change(entry) { $0.archived = true } } }
                        .tint(.indigo)
                } else {
                    Button("Recuperar", systemImage: "arrow.uturn.backward") { restore(entry) }.tint(.accentColor)
                }
            }
        }
    }

    @ViewBuilder
    private func entryActions(_ entry: LabImport.Entry, info: SavedLaboratories.Details) -> some View {
        if info.inLibrary {
            Button("Renombrar", systemImage: "pencil") { beginEdit(.entry(entry), current: library.name(entry)) }
            Menu("Mover a", systemImage: "folder") {
                Button("Sin carpeta") { change { try library.change(entry) { $0.folderID = nil } } }
                ForEach(library.folders) { folder in
                    Button(folder.name) { change { try library.change(entry) { $0.folderID = folder.id } } }
                }
            }
            Button(info.enabled ? "Pausar simulación" : "Activar simulación",
                   systemImage: info.enabled ? "pause.circle" : "play.circle") {
                change { try library.change(entry) { $0.enabled.toggle() } }
            }
            Button("Archivar", systemImage: "archivebox") { change { try library.change(entry) { $0.archived = true } } }
        } else {
            Button("Recuperar", systemImage: "arrow.uturn.backward") { restore(entry) }
        }
        if !info.deleted {
            Button("Mover a la papelera", systemImage: "trash", role: .destructive) {
                change { try library.change(entry) { $0.deleted = true } }
            }
        }
    }

    private func restore(_ entry: LabImport.Entry) {
        change {
            try library.change(entry) {
                if $0.deleted { $0.deleted = false }
                else { $0.archived = false }
            }
        }
    }

    private func beginEdit(_ edit: Edit, current: String) {
        draft = current
        editing = edit
    }

    private func saveEdit() {
        let edit = editing
        editing = nil
        change {
            switch edit {
            case .entry(let entry): try library.rename(entry, to: draft)
            case .folder(let existing): try library.saveFolder(draft, id: existing?.id)
            case nil: break
            }
        }
    }

    private func change(_ action: () throws -> Void) {
        do { try action(); error = nil }
        catch { self.error = error.localizedDescription }
    }

    private func reload() async {
        let site = operations.siteStorageID
        do {
            let latest = try await Self.load(site: site)
            guard !Task.isCancelled, site == operations.siteStorageID else { return }
            received = latest.received
            imported = latest.imported
            error = nil
        } catch {
            guard !Task.isCancelled, site == operations.siteStorageID else { return }
            self.error = error.localizedDescription
        }
        loading = false
    }

    @concurrent private static func load(site: String) async throws -> (received: [LabImport.Entry], imported: [LabImport.Entry]) {
        (try LabImport.received(), try LabImport.history(site: site))
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
    }
}
