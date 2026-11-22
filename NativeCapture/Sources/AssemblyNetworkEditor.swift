import SwiftUI

struct AssemblyPortRoute {
    let origin: LabTopology.Port
    var vlan: Int
    var level: LabCableLevel = .floor

    func vlanIDs(in topology: LabTopology) -> [Int] {
        if vlan == 0 { return topology.vlans.map(\.id) }
        return vlan > 0 ? [vlan] : []
    }
}

struct AssemblyPortRouteForm: View {
    let topology: LabTopology
    @Binding var route: AssemblyPortRoute

    var body: some View {
        Form {
            AssemblyVLANPicker(vlans: topology.vlans, selection: $route.vlan)
            AssemblyCableLevelPicker(level: $route.level)
        }
        .navigationTitle("Canaleta y VLAN")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct AssemblyPhysicalPortPicker: View {
    let topology: LabTopology
    let options: [LabTopology.Port]
    let origin: LabTopology.Port?
    let preferredDevice: String?
    let select: (LabTopology.Port) throws -> Void
    @State private var deviceID = ""
    @State private var errorMessage: String?

    var body: some View {
        let ports = Dictionary(grouping: options, by: \.deviceID)
        let devices = topology.devices.filter { ports[$0.id]?.isEmpty == false }
        Form {
            if let origin {
                Section("Origen seleccionado") {
                    let name = topology.devices.first { $0.id == origin.deviceID }?.name ?? origin.deviceID
                    Label("\(name) · \(origin.name)", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Color.accentColor)
                }
            }
            if devices.isEmpty {
                Text(origin == nil ? "Coloca un equipo con puertos libres."
                     : "Coloca otro equipo con un puerto libre y compatible.")
                    .foregroundStyle(.secondary)
            } else {
                AssemblyDevicePicker(devices: devices, selection: $deviceID)
                if let devicePorts = ports[deviceID] {
                    Section(origin == nil ? "Puertos libres" : "Puertos compatibles") {
                        ForEach(devicePorts, id: \.self) { port in
                            Button {
                                do { try select(port) }
                                catch { errorMessage = error.localizedDescription }
                            } label: {
                                Label(port.name, systemImage: "cable.connector")
                                    .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                        }
                    }
                }
            }
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.circle").foregroundStyle(.secondary)
            }
        }
        .navigationTitle(origin == nil ? "Puerto de origen" : "Puerto de destino")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: devices.map(\.id), initial: true) { _, ids in
            guard !ids.contains(deviceID) else { return }
            if let preferredDevice, ids.contains(preferredDevice) { deviceID = preferredDevice }
            else { deviceID = ids.count == 1 ? ids[0] : "" }
        }
        .onChange(of: deviceID) { errorMessage = nil }
    }
}

enum AssemblyNetworkAction {
    case rack(RackMount.Height, String)
    case mount(RackMount.Equipment, String, rack: String, slot: Int)
    case configure(String, name: String, address: String?, vlan: Int?, LabServerServices)
    case disconnect(String)
    case cableLevel(String, LabCableLevel)
    case trace(String)
    case placeWaypoint(String, Int)
    case removeWaypoint(String, Int)
    case monitor(String, LabMonitorConfiguration.Panel)
    case dhcp(String, Int)
    case dns(String, String)
    case http(String, String)
}

struct AssemblyNetworkEditor: View {
    let project: LabProject
    let assembly: LabARAssembly
    let selected: LabARAssembly.Item?
    let connect: () -> Void
    let edit: (AssemblyNetworkAction) throws -> String?

    private var topology: LabTopology { project.topology }
    private var servers: [LabTopology.Device] { topology.devices.filter { $0.visualModelID.hasPrefix("server-") } }

    var body: some View {
        List {
            Section("Montaje") {
                NavigationLink {
                    AssemblyRackForm(edit: edit)
                } label: { Label("Añadir rack", systemImage: "server.rack") }
                NavigationLink {
                    LabRackEquipmentForm(project: project, assembly: assembly, equipment: .server, popOnCommit: true) { name, rack, slot in
                        try edit(.mount(.server, name, rack: rack, slot: slot))
                    }
                } label: { Label("Montar servidor", systemImage: "server") }
                if !servers.isEmpty {
                    NavigationLink {
                        AssemblyMonitorForm(servers: servers, edit: edit)
                    } label: { Label("Añadir pantalla", systemImage: "display") }
                }
            }
            Section("Conexiones") {
                Button("Conectar puertos", systemImage: "cable.connector", action: connect)
                NavigationLink {
                    AssemblyCableList(topology: topology, assembly: assembly, selected: selected, edit: edit)
                } label: { Label("Editar cables", systemImage: "point.topleft.down.to.point.bottomright.curvepath") }
            }
            Section("Simulación") {
                NavigationLink {
                    AssemblyServerList(servers: servers, vlans: topology.vlans, selected: selected, edit: edit)
                } label: { Label("Configurar servidores", systemImage: "slider.horizontal.3") }
                NavigationLink {
                    AssemblyNetworkTest(topology: topology, selected: selected, edit: edit)
                } label: { Label("Probar DHCP, DNS y HTTP", systemImage: "terminal") }
            }
        }
        .navigationTitle("Editar red")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct AssemblyRackForm: View {
    let edit: (AssemblyNetworkAction) throws -> String?
    @State private var title = ""
    @State private var height: RackMount.Height
    let popOnCommit: Bool

    init(height: RackMount.Height = .medium, popOnCommit: Bool = false, edit: @escaping (AssemblyNetworkAction) throws -> String?) {
        _height = State(initialValue: height)
        self.popOnCommit = popOnCommit
        self.edit = edit
    }

    var body: some View {
        Form {
            TextField("Nombre del rack", text: $title)
            Picker("Altura", selection: $height) {
                ForEach(RackMount.Height.allCases) { size in Text("\(size.rawValue) U").tag(size) }
            }
            Section {
                AssemblyCommitButton("Añadir y colocar", disabled: title.trimmedForNetwork.isEmpty, pop: popOnCommit) {
                    try edit(.rack(height, title))
                }
            } footer: {
                Text("Montaje de 19 pulgadas con el mismo ancho y fondo exterior en las tres alturas.")
            }
        }
        .navigationTitle("Añadir rack")
    }
}

struct LabRackEquipmentForm: View {
    let project: LabProject
    let assembly: LabARAssembly?
    let equipment: RackMount.Equipment
    var preferredRack: String? = nil
    var addRack: ((AssemblyNetworkAction) throws -> String?)? = nil
    var popOnCommit = false
    let mount: (String, String, Int) throws -> String?
    @State private var title = ""
    @State private var rackID = ""
    @State private var slot = -1

    var body: some View {
        let candidates = project.layout.placements.compactMap { rack -> (rack: LabPlacement, slots: [Int])? in
            let slots = project.availableSlots(in: rack, model: equipment.rawValue)
            return slots.isEmpty ? nil : (rack, slots)
        }
        let slots = candidates.first { $0.rack.id == rackID }?.slots ?? []
        Form {
            Section("Modelo") {
                Text("\(equipment.title) · \(equipment.units) U")
                TextField("Nombre (opcional)", text: $title)
            }
            if candidates.isEmpty {
                Section {
                    Label("Ningún rack tiene \(equipment.units) U libres contiguas para este equipo.", systemImage: "exclamationmark.circle")
                        .foregroundStyle(.secondary)
                    if let addRack {
                        NavigationLink {
                            AssemblyRackForm(popOnCommit: assembly == nil, edit: addRack)
                        } label: {
                            Label("Crear rack", systemImage: "server.rack")
                        }
                    }
                }
            } else {
                Section("Ubicación") {
                    Picker("Rack", selection: $rackID) {
                        ForEach(candidates, id: \.rack.id) { candidate in
                            let rack = candidate.rack
                            let pending = assembly.map { $0.piece(.support(rack.id)) == nil } ?? false
                            Text(rack.title + (pending ? " · Por colocar" : "")).tag(rack.id)
                        }
                    }
                    if !slots.isEmpty {
                        Picker("Unidad inicial", selection: $slot) {
                            ForEach(slots, id: \.self) { Text("U \($0 + 1)").tag($0) }
                        }
                    }
                }
                AssemblyCommitButton("Montar en rack", disabled: !slots.contains(slot), pop: popOnCommit) {
                    try mount(title.optionalNetworkValue ?? equipment.title, rackID, slot)
                }
            }
        }
        .navigationTitle("Montar en rack")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: candidates.map(\.rack.id), initial: true) { _, ids in
            guard !ids.contains(rackID) else { return }
            rackID = ids.first { $0 == preferredRack } ?? ids.first ?? ""
        }
        .onChange(of: slots, initial: true) {
            if !slots.contains(slot) { slot = (equipment == .fans ? slots.last : slots.first) ?? -1 }
        }
    }
}

private struct AssemblyCableList: View {
    let topology: LabTopology
    let assembly: LabARAssembly
    let selected: LabARAssembly.Item?
    let edit: (AssemblyNetworkAction) throws -> String?
    @State private var search = ""

    var body: some View {
        let devices = Dictionary(uniqueKeysWithValues: topology.devices.map { ($0.id, $0.name) })
        let supports = Dictionary(uniqueKeysWithValues: topology.devices.map { ($0.id, $0.placementID) })
        List {
            ForEach(topology.links.filter { $0.circuitID == nil || $0.circuitID == $0.id }) { link in
                let circuit = topology.circuit(for: link)
                if search.isEmpty || circuit.contains(where: { segment in
                    [devices[segment.fromDeviceID], devices[segment.toDeviceID], segment.fromPort, segment.toPort]
                        .compactMap { $0 }.contains { $0.localizedStandardContains(search) }
                }) {
                    let end = circuit.last ?? link
                    let trunk = circuit.first { supports[$0.fromDeviceID] != supports[$0.toDeviceID] }
                        ?? circuit.first { $0.arRouteLevel != nil } ?? link
                    let from = (devices[link.fromDeviceID] ?? link.fromDeviceID) + " · " + link.fromPort
                    let to = (devices[end.toDeviceID] ?? end.toDeviceID) + " · " + end.toPort
                    NavigationLink {
                        AssemblyCableForm(link: trunk, from: from, to: to, points: assembly.waypoints?[trunk.id] ?? [], edit: edit)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(from)
                            Text(to).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Cables")
        .searchable(text: $search, prompt: "Buscar equipo o puerto")
        .onAppear {
            if case .device(let id) = selected, search.isEmpty { search = devices[id] ?? "" }
        }
    }
}

private struct AssemblyCableForm: View {
    let link: LabTopology.Link
    let from: String
    let to: String
    let points: [SIMD2<Float>]
    let edit: (AssemblyNetworkAction) throws -> String?
    @State private var level: LabCableLevel = .floor
    @State private var confirmingRemoval = false
    @State private var problem: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section(link.medium.title) {
                Text(from)
                Text(to)
                AssemblyCommitButton(points.isEmpty ? "Ver trazado" : "Arrastrar puntos en AR") { try edit(.trace(link.id)) }
            }
            Section("Canaleta") {
                AssemblyCableLevelPicker(level: $level)
                AssemblyCommitButton("Aplicar altura", pop: true) { try edit(.cableLevel(link.id, level)) }
            }
            Section("Puntos de paso") {
                ForEach(points.indices, id: \.self) { index in
                    AssemblyCommitButton("Mover punto \(index + 1)") { try edit(.placeWaypoint(link.id, index)) }
                }
                if points.count < 4 {
                    AssemblyCommitButton("Añadir punto en AR") { try edit(.placeWaypoint(link.id, points.count)) }
                }
                if let last = points.indices.last {
                    AssemblyCommitButton("Quitar último punto", pop: true) { try edit(.removeWaypoint(link.id, last)) }
                }
            }
            Button("Desconectar", role: .destructive) { confirmingRemoval = true }
        }
        .navigationTitle("Editar cable")
        .onAppear { level = link.arRouteLevel ?? .floor }
        .confirmationDialog("¿Desconectar este cable?", isPresented: $confirmingRemoval, titleVisibility: .visible) {
            Button("Desconectar", role: .destructive) {
                do { _ = try edit(.disconnect(link.id)); dismiss() }
                catch { problem = error.localizedDescription }
            }
        }
        .alert("No se pudo desconectar", isPresented: Binding(
            get: { problem != nil }, set: { if !$0 { problem = nil } }
        )) { Button("Aceptar", role: .cancel) {} } message: { Text(problem ?? "") }
    }
}

struct AssemblyRackSlotForm: View {
    let project: LabProject
    let rack: LabPlacement
    let initialSlot: Int?
    let edit: (AssemblyNetworkAction) throws -> String?
    var popOnCommit = false
    @State private var slot = 0
    @State private var equipment: RackMount.Equipment?
    @State private var name = ""

    private var available: [RackMount.Equipment] {
        RackMount.Equipment.allCases.filter { project.availableSlots(in: rack, model: $0.rawValue).contains(slot) }
    }

    var body: some View {
        let freeSlots = Set(project.availableSlots(in: rack))
        let groupedEquipment = Dictionary(grouping: available) { HardwareCatalog.reference($0.rawValue)?.group }
        Form {
            Picker("Unidad inicial", selection: $slot) {
                ForEach(0..<RackMount.capacity(height: rack.size.y), id: \.self) { index in
                    let free = freeSlots.contains(index)
                    Text("U \(index + 1)" + (free ? "" : " · ocupada")).tag(index)
                }
            }
            if groupedEquipment.isEmpty {
                Label("Unidad ocupada. Elige una unidad libre.", systemImage: "exclamationmark.circle")
            } else {
                Section("Equipos que caben") {
                    Picker("Equipo", selection: $equipment) {
                        Text("Selecciona").tag(nil as RackMount.Equipment?)
                        ForEach(HardwareItem.Group.allCases, id: \.self) { group in
                            if let items = groupedEquipment[group] {
                                Section(group.rawValue) {
                                    ForEach(items) { item in
                                        Label("\(item.title) · \(item.units) U", systemImage: group.symbol).tag(Optional(item))
                                    }
                                }
                            }
                        }
                    }
                    .pickerStyle(.navigationLink)
                    if let equipment {
                        TextField("Nombre", text: $name)
                        AssemblyCommitButton("Montar en U \(slot + 1)", pop: popOnCommit) {
                            try edit(.mount(equipment, name.trimmedForNetwork.isEmpty ? equipment.title : name, rack: rack.id, slot: slot))
                        }
                    }
                }
            }
        }
        .navigationTitle("Unidades · \(rack.title)")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { slot = initialSlot ?? project.availableSlots(in: rack).first ?? 0 }
        .onChange(of: slot) { if let equipment, !available.contains(equipment) { self.equipment = nil } }
    }
}

struct AssemblyRackMonitorForm: View {
    let rack: LabPlacement
    let assembly: LabARAssembly
    let layout: LabLayout
    let topology: LabTopology
    let servers: [LabTopology.Device]
    let initialSide: RackMount.Side?
    var current: LabARAssembly.RackMonitor? = nil
    var popOnCommit = false
    let mount: (String, LabMonitorConfiguration.Panel, RackMount.Side, Int) throws -> Void
    @State private var side: RackMount.Side = .left
    @State private var row = -1
    @State private var server = ""
    @State private var panel: LabMonitorConfiguration.Panel = .services

    private var rows: [Int] { assembly.freeMonitorRows(on: rack, side: side, in: layout, topology: topology) }

    var body: some View {
        let available = rows
        Form {
            Picker("Costado", selection: $side) {
                ForEach(RackMount.Side.allCases) { Text($0.title).tag($0) }
            }
            .accessibilityIdentifier("lab.rack.monitor.side")
            if available.isEmpty {
                Label("Sin espacio en este costado. Prueba el otro.", systemImage: "rectangle.slash")
            }
            else {
                Picker("Posición desde arriba", selection: $row) {
                    ForEach(available, id: \.self) { Text("Soporte \($0 + 1)").tag($0) }
                }
            }
            AssemblyDevicePicker(devices: servers, selection: $server, title: "Servidor")
            Picker("Información", selection: $panel) {
                ForEach(LabMonitorConfiguration.Panel.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            AssemblyCommitButton(current == nil ? "Montar monitor" : "Guardar monitor",
                                 disabled: server.isEmpty || !available.contains(row), pop: popOnCommit) {
                try mount(server, panel, side, row)
                return nil
            }
            .accessibilityIdentifier("lab.rack.monitor.mount")
        }
        .navigationTitle(current == nil ? "Añadir monitor" : "Editar monitor")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            side = current?.side ?? initialSide ?? .left
            row = current?.row ?? rows.first ?? -1
            server = current?.device ?? servers.first(where: { $0.placementID == rack.id })?.id ?? servers.first?.id ?? ""
            panel = current?.panel ?? .services
        }
        .onChange(of: available) { _, updated in
            if !updated.contains(row) { row = updated.first ?? -1 }
        }
    }
}

struct LabRackMonitorsEditor: View {
    let rack: LabPlacement
    let assembly: LabARAssembly
    let layout: LabLayout
    let topology: LabTopology
    let initialSide: RackMount.Side?
    let save: ([LabARAssembly.RackMonitor]) throws -> Void
    @State var monitors: [LabARAssembly.RackMonitor]
    @State private var removing: LabARAssembly.RackMonitor?
    @State private var error: String?

    var body: some View {
        List {
            NavigationLink { form(for: nil) } label: {
                Label("Añadir monitor", systemImage: "display")
            }
            ForEach(monitors) { monitor in
                NavigationLink { form(for: monitor) } label: {
                    VStack(alignment: .leading) {
                        Text(topology.devices.first { $0.id == monitor.device }?.name ?? "Monitor")
                        Text("\(monitor.side.title) · Soporte \(monitor.row + 1) · \(monitor.panel.rawValue)")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .swipeActions {
                    Button("Quitar", role: .destructive) { removing = monitor }
                }
            }
        }
        .navigationTitle("Monitores del rack")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("¿Quitar monitor?", isPresented: Binding(
            get: { removing != nil }, set: { if !$0 { removing = nil } }
        ), titleVisibility: .visible, presenting: removing) { monitor in
            Button("Quitar monitor", role: .destructive) {
                do { try update(monitors.filter { $0.id != monitor.id }) }
                catch { self.error = error.localizedDescription }
            }
        }
        .alert("Revisa la edición", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("Aceptar", role: .cancel) {}
        } message: { Text(error ?? "") }
    }

    private func form(for current: LabARAssembly.RackMonitor?) -> some View {
        var available = assembly
        for monitor in available.rackMonitors(on: rack.id) { available.remove(monitor.item) }
        for monitor in monitors where monitor.id != current?.id { available.set(monitor.piece(on: rack)) }
        return AssemblyRackMonitorForm(rack: rack, assembly: available, layout: layout, topology: topology,
            servers: topology.devices.filter { $0.visualModelID.hasPrefix("server-") }, initialSide: initialSide,
            current: current, popOnCommit: true) { device, panel, side, row in
                let monitor = LabARAssembly.RackMonitor(id: current?.id ?? UUID(), device: device, panel: panel, side: side, row: row)
                var updated = monitors
                if let index = updated.firstIndex(where: { $0.id == monitor.id }) { updated[index] = monitor }
                else { updated.append(monitor) }
                try update(updated)
            }
    }

    private func update(_ updated: [LabARAssembly.RackMonitor]) throws {
        try save(updated)
        monitors = updated
    }
}

struct LabRackDeviceMoveForm: View {
    let project: LabProject
    let device: LabTopology.Device
    let assembly: LabARAssembly?
    let move: (String, Int) async throws -> Void
    var onFloor = false
    var onDesk = false
    var putOnFloor: (() throws -> Void)? = nil
    var putOnDesk: (() throws -> Void)? = nil
    var delete: (() throws -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var rackID = ""
    @State private var slot = -1
    @State private var saving = false
    @State private var error: String?
    @State private var confirmDeletion = false

    private var racks: [LabPlacement] {
        project.layout.placements.filter { rack in
            rack.kind == .rack && (assembly.map { $0.piece(.support(rack.id)) != nil } ?? true)
        }
    }

    private var slots: [Int] {
        racks.first { $0.id == rackID }.map {
            project.availableSlots(in: $0, model: device.visualModelID, excluding: device.id)
        } ?? []
    }

    private var currentSlot: Int { RackMount.slot(device.visualModelID, near: device.offset.y) }

    var body: some View {
        Form {
            if onFloor || onDesk {
                Label(onDesk ? "En la mesa · Red pendiente" : "En el piso · Red pendiente", systemImage: "cable.connector.slash")
                    .foregroundStyle(.secondary)
            }
            Section {
                if racks.isEmpty {
                    Text("Coloca un rack para montar el equipo.").foregroundStyle(.secondary)
                } else {
                    Picker("Rack", selection: $rackID) {
                        ForEach(racks) { Text($0.title).tag($0.id) }
                    }
                    if slots.isEmpty {
                        Label("No hay unidades libres contiguas para este equipo.", systemImage: "exclamationmark.circle")
                    } else {
                        Picker("Unidad inicial", selection: $slot) {
                            ForEach(slots, id: \.self) {
                                Text("U \($0 + 1)" + (rackID == device.placementID && $0 == currentSlot ? " · actual" : "")).tag($0)
                            }
                        }
                    }
                }
            } footer: {
                Text("El cableado se vuelve a acomodar al guardar.")
            }
            Button(onFloor || onDesk ? "Montar en rack" : "Mover equipo", systemImage: "arrow.up.arrow.down") {
                saving = true
                Task {
                    defer { saving = false }
                    do {
                        try await move(rackID, slot)
                        dismiss()
                    } catch { self.error = error.localizedDescription }
                }
            }
            .disabled(!slots.contains(slot) || (rackID == device.placementID && slot == currentSlot))
            if saving { ProgressView("Acomodando cables…") }
            if putOnFloor != nil || putOnDesk != nil {
                Section {
                    if let putOnFloor { Button("Elegir lugar en el piso", systemImage: "arrow.down.to.line") { finish(putOnFloor) } }
                    if let putOnDesk { Button("Elegir lugar en una mesa", systemImage: "table.furniture") { finish(putOnDesk) } }
                } footer: {
                    Text("Libera la unidad del rack. Las conexiones de red quedan pendientes hasta que vuelvas a montar el equipo.")
                }
            }
            if delete != nil {
                Section {
                    Button("Eliminar del laboratorio", systemImage: "trash", role: .destructive) { confirmDeletion = true }
                }
            }
        }
        .disabled(saving)
        .interactiveDismissDisabled(saving)
        .navigationTitle(device.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard rackID.isEmpty else { return }
            rackID = racks.contains(where: { $0.id == device.placementID }) ? device.placementID : racks.first?.id ?? ""
            slot = rackID == device.placementID ? currentSlot : slots.first ?? -1
        }
        .onChange(of: rackID) {
            slot = rackID == device.placementID ? currentSlot : slots.first ?? -1
        }
        .confirmationDialog("¿Eliminar \(device.name)?", isPresented: $confirmDeletion, titleVisibility: .visible) {
            Button("Eliminar equipo", role: .destructive) { if let delete { finish(delete) } }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Se eliminarán el equipo, su configuración y sus enlaces de este laboratorio.")
        }
        .alert("No se pudo guardar el cambio", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("Aceptar", role: .cancel) {}
        } message: { Text(error ?? "") }
    }

    private func finish(_ action: () throws -> Void) {
        do { try action(); dismiss() }
        catch { self.error = error.localizedDescription }
    }
}

struct LabRackMoveLink: View {
    let destination: AnyView

    var body: some View {
        NavigationLink {
            destination
        } label: {
            Label("Mover o retirar equipo", systemImage: "arrow.up.arrow.down")
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.bordered)
        .padding(.horizontal, 16).padding(.vertical, 4)
        .background(Color(uiColor: .systemBackground))
    }
}

private struct AssemblyServerList: View {
    let servers: [LabTopology.Device]
    let vlans: [LabTopology.VLAN]
    let selected: LabARAssembly.Item?
    let edit: (AssemblyNetworkAction) throws -> String?
    @State private var search = ""

    var body: some View {
        List(servers.filter { search.isEmpty || $0.name.localizedStandardContains(search) }) { device in
            NavigationLink(device.name) { AssemblyServiceForm(device: device, vlans: vlans, edit: edit) }
        }
        .navigationTitle("Configurar servidores")
        .searchable(text: $search, prompt: "Buscar servidor")
        .onAppear {
            if case .device(let id) = selected, search.isEmpty { search = servers.first { $0.id == id }?.name ?? "" }
        }
    }
}

private struct AssemblyServiceForm: View {
    let device: LabTopology.Device
    let vlans: [LabTopology.VLAN]
    let edit: (AssemblyNetworkAction) throws -> String?
    @State private var name = ""
    @State private var address = ""
    @State private var vlan = 0
    @State private var dns = false
    @State private var dnsName = ""
    @State private var dnsAddress = ""
    @State private var dhcp = false
    @State private var poolStart = ""
    @State private var poolEnd = ""
    @State private var gateway = ""
    @State private var resolver = ""
    @State private var http = false
    @State private var page = ""

    var body: some View {
        Form {
            Section("Red") {
                TextField("Nombre del servidor", text: $name)
                ipv4("IPv4 estática", $address)
                Picker("VLAN", selection: $vlan) {
                    Text("Sin VLAN").tag(0)
                    ForEach(vlans) { Text("VLAN \($0.id) · \($0.name)").tag($0.id) }
                }
            }
            Section("Servicios simulados") {
                Toggle("DNS", isOn: $dns)
                if dns {
                    TextField("Dominio, por ejemplo app.lab", text: $dnsName).textInputAutocapitalization(.never)
                    ipv4("IPv4 del registro A", $dnsAddress)
                }
                Toggle("DHCP", isOn: $dhcp)
                if dhcp {
                    ipv4("Inicio del rango", $poolStart)
                    ipv4("Fin del rango", $poolEnd)
                    ipv4("Puerta de enlace (opcional)", $gateway)
                    ipv4("Servidor DNS (opcional)", $resolver)
                }
                Toggle("HTTP", isOn: $http)
                if http { TextField("Título de la página", text: $page) }
            }
            AssemblyCommitButton("Guardar configuración", pop: true) {
                let services = LabServerServices(
                    dns: dns ? .init(hostname: dnsName.trimmedForNetwork.lowercased(), address: dnsAddress.trimmedForNetwork) : nil,
                    dhcp: dhcp ? .init(start: poolStart.trimmedForNetwork, end: poolEnd.trimmedForNetwork,
                                      gateway: gateway.optionalNetworkValue, dns: resolver.optionalNetworkValue) : nil,
                    httpTitle: http ? page.trimmedForNetwork : nil)
                return try edit(.configure(device.id, name: name.trimmedForNetwork, address: address.optionalNetworkValue,
                                           vlan: vlan == 0 ? nil : vlan, services))
            }
        }
        .navigationTitle(device.name)
        .onAppear {
            name = device.name
            address = device.ipv4 ?? ""
            vlan = device.vlan ?? 0
            let services = device.serverServices
            dns = services?.dns != nil
            dnsName = services?.dns?.hostname ?? ""
            dnsAddress = services?.dns?.address ?? ""
            dhcp = services?.dhcp != nil
            poolStart = services?.dhcp?.start ?? ""
            poolEnd = services?.dhcp?.end ?? ""
            gateway = services?.dhcp?.gateway ?? ""
            resolver = services?.dhcp?.dns ?? ""
            http = services?.httpTitle != nil
            page = services?.httpTitle ?? ""
        }
    }

    private func ipv4(_ label: String, _ input: Binding<String>) -> some View {
        TextField(label, text: input).keyboardType(.numbersAndPunctuation).autocorrectionDisabled()
    }
}

private struct AssemblyMonitorForm: View {
    let servers: [LabTopology.Device]
    let edit: (AssemblyNetworkAction) throws -> String?
    @State private var server = ""
    @State private var panel: LabMonitorConfiguration.Panel = .services

    var body: some View {
        Form {
            AssemblyDevicePicker(devices: servers, selection: $server, title: "Servidor")
            Picker("Información", selection: $panel) {
                ForEach(LabMonitorConfiguration.Panel.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            AssemblyCommitButton("Colocar pantalla en AR", disabled: server.isEmpty) { try edit(.monitor(server, panel)) }
        }
        .navigationTitle("Añadir pantalla")
    }
}

private struct AssemblyNetworkTest: View {
    let topology: LabTopology
    let selected: LabARAssembly.Item?
    let edit: (AssemblyNetworkAction) throws -> String?
    @State private var source = ""
    @State private var target = ""
    @State private var hostname = ""
    @State private var vlan = 0

    var body: some View {
        Form {
            Section("Cliente") {
                AssemblyDevicePicker(devices: topology.devices, selection: $source)
            }
            Section("DHCP") {
                Picker("VLAN", selection: $vlan) {
                    Text("Selecciona").tag(0)
                    ForEach(topology.vlans) { Text("VLAN \($0.id) · \($0.name)").tag($0.id) }
                }
                AssemblyCommitButton("Solicitar dirección", disabled: source.isEmpty || vlan == 0) { try edit(.dhcp(source, vlan)) }
            }
            Section("DNS") {
                TextField("Dominio", text: $hostname).textInputAutocapitalization(.never)
                AssemblyCommitButton("Resolver nombre", disabled: source.isEmpty || hostname.trimmedForNetwork.isEmpty) {
                    try edit(.dns(source, hostname.trimmedForNetwork.lowercased()))
                }
            }
            Section("HTTP") {
                AssemblyDevicePicker(devices: topology.devices.filter { $0.serverServices?.httpTitle != nil },
                                     selection: $target, title: "Servidor HTTP")
                AssemblyCommitButton("Abrir página simulada", disabled: source.isEmpty || target.isEmpty) { try edit(.http(source, target)) }
            }
        }
        .navigationTitle("Probar servicios")
        .onAppear { if case .device(let id) = selected, source.isEmpty { source = id } }
        .onChange(of: source) { vlan = topology.devices.first { $0.id == source }?.vlan ?? 0 }
    }
}

private struct AssemblyDevicePicker: View {
    let devices: [LabTopology.Device]
    @Binding var selection: String
    var title = "Equipo"

    var body: some View {
        Picker(title, selection: $selection) {
            Text("Selecciona").tag("")
            ForEach(devices) { Text($0.name).tag($0.id) }
        }
    }
}

private struct AssemblyCableLevelPicker: View {
    @Binding var level: LabCableLevel

    var body: some View {
        Picker("Canaleta", selection: $level) {
            Text("Por piso").tag(LabCableLevel.floor)
            Text("Por arriba").tag(LabCableLevel.overhead)
        }
    }
}

private struct AssemblyVLANPicker: View {
    let vlans: [LabTopology.VLAN]
    @Binding var selection: Int

    var body: some View {
        Picker("Red", selection: $selection) {
            Text("Sin VLAN asignada").tag(-2)
            ForEach(vlans) { Text("VLAN \($0.id) · \($0.name)").tag($0.id) }
            if !vlans.isEmpty { Text("Troncal · todas las VLAN").tag(0) }
        }
    }
}

struct AssemblyCommitButton: View {
    let title: String
    let systemImage: String?
    let disabled: Bool
    let pop: Bool
    let action: () throws -> String?
    @State private var message: String?
    @State private var failed = false
    @Environment(\.dismiss) private var dismiss

    init(_ title: String, systemImage: String? = nil, disabled: Bool = false, pop: Bool = false,
         action: @escaping () throws -> String?) {
        self.title = title
        self.systemImage = systemImage
        self.disabled = disabled
        self.pop = pop
        self.action = action
    }

    var body: some View {
        Button {
            do {
                failed = false
                message = try action()
                if pop && message == nil { dismiss() }
            } catch {
                failed = true
                message = error.localizedDescription
            }
        } label: {
            if let systemImage { Label(title, systemImage: systemImage) }
            else { Text(title) }
        }
        .disabled(disabled)
        .alert(failed ? "Revisa la edición" : "Resultado", isPresented: Binding(
            get: { message != nil }, set: { if !$0 { message = nil } }
        )) { Button("Aceptar", role: .cancel) {} } message: { Text(message ?? "") }
    }
}

private extension String {
    var trimmedForNetwork: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    var optionalNetworkValue: String? { trimmedForNetwork.isEmpty ? nil : trimmedForNetwork }
}

enum LabEquipmentEdit {
    case rack(RackMount.Height, String)
    case mount(RackMount.Equipment, String, rack: String, slot: Int)
    case equipment(LabDeskEquipment, String, desk: String?, mode: LabClientConnection, accessPoint: String?)
    case desk(String, width: Float, depth: Float)
    case resizeDesk(String, width: Float, depth: Float)
    case connection(String, LabClientConnection, accessPoint: String?)
    case routing(String, LabCableLevel)
}

struct LabWorkspaceEquipment<Catalog: View>: View {
    let project: LabProject
    let assembly: LabARAssembly?
    let edit: (LabEquipmentEdit) throws -> String?
    let connect: (AssemblyPortRoute, LabTopology.Port) async throws -> String
    @ViewBuilder let catalog: () -> Catalog

    var body: some View {
        List {
            Section {
                NavigationLink(destination: catalog) {
                    Label("Añadir equipo", systemImage: "plus")
                }
            }
            Section("Mobiliario") {
                NavigationLink {
                    LabDeskDimensionsForm(desk: nil, edit: edit)
                } label: { Label("Añadir mesa", systemImage: "table.furniture") }
                NavigationLink {
                    AssemblyRackForm { action in
                        guard case .rack(let height, let name) = action else { return nil }
                        return try edit(.rack(height, name))
                    }
                } label: { Label("Añadir rack", systemImage: "server.rack") }
            }
            let desks = project.layout.placements.filter { $0.kind == .workstation }
            if !desks.isEmpty {
                Section("Medidas de las mesas") {
                    ForEach(desks) { desk in
                        NavigationLink(desk.title) { LabDeskDimensionsForm(desk: desk, edit: edit) }
                    }
                }
            }
            Section("Conexiones") {
                NavigationLink {
                    LabWorkspaceCableForm(topology: project.topology, assembly: assembly, connect: connect)
                } label: { Label("Conectar cable", systemImage: "cable.connector") }

                ForEach(project.topology.devices.filter(\.supportsWiFi)) { device in
                    NavigationLink {
                        LabClientConnectionForm(device: device, accessPoints: project.topology.devices.filter(\.isAccessPoint), edit: edit)
                    } label: { Label(device.name, systemImage: "wifi") }
                }
            }
            let cables = project.topology.links.filter { $0.circuitID == nil || $0.autoPatchTrunk == true || $0.id == $0.circuitID }
            let circuits = Dictionary(grouping: cables, by: { $0.circuitID ?? $0.id })
            if !circuits.isEmpty {
                NavigationLink {
                    List(circuits.keys.sorted(), id: \.self) { id in
                        if let cable = circuits[id]?.first {
                            let segments = project.topology.circuit(for: cable)
                            let start = project.topology.devices.first { $0.id == segments.first?.fromDeviceID }?.name ?? cable.fromPort
                            let end = project.topology.devices.first { $0.id == segments.last?.toDeviceID }?.name ?? cable.toPort
                            NavigationLink("\(start) → \(end)") {
                                LabWorkspaceCableLevel(cable: cable, edit: edit)
                            }
                        }
                    }
                    .navigationTitle("Canaletas")
                } label: {
                    Label("Canaletas de los cables", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                }
            }
        }
        .navigationTitle("Editar laboratorio")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct LabWorkspaceCableLevel: View {
    let cable: LabTopology.Link
    let edit: (LabEquipmentEdit) throws -> String?
    @State private var level = LabCableLevel.overhead

    var body: some View {
        Form {
            AssemblyCableLevelPicker(level: $level)
            AssemblyCommitButton("Guardar recorrido", pop: true) { try edit(.routing(cable.id, level)) }
        }
        .navigationTitle("Recorrido del cable")
        .onAppear { level = cable.arRouteLevel ?? .overhead }
    }
}

struct LabDeskEquipmentForm: View {
    let project: LabProject
    let assembly: LabARAssembly?
    let preferredSupport: String?
    let equipment: LabDeskEquipment
    let edit: (LabEquipmentEdit) throws -> String?
    @State private var name = ""
    @State private var desk = ""
    @State private var mode = LabClientConnection.ethernet
    @State private var accessPoint = ""

    private var desks: [LabPlacement] {
        project.layout.placements.filter { project.deskOffset(for: equipment, on: $0) != nil }
    }

    private var recommended: String? {
        if let preferredSupport, desks.contains(where: { $0.id == preferredSupport }) { return preferredSupport }
        return desks.first(where: { assembly?.piece(.support($0.id)) != nil })?.id ?? desks.first?.id
    }

    var body: some View {
        Form {
            Section("Modelo") {
                Text(equipment.title)
                TextField("Nombre (opcional)", text: $name)
            }
            Section {
                Picker("Colocar en", selection: $desk) {
                    Text("Crear mesa a medida").tag("")
                    ForEach(desks) { candidate in
                        Text(candidate.title + (candidate.id == recommended ? " · Recomendada" : "")).tag(candidate.id)
                    }
                }
            } footer: {
                if desk.isEmpty {
                    let dimensions = equipment.minimumDesk * 100
                    Text("Mesa automática de \(Int(dimensions.x.rounded())) × \(Int(dimensions.y.rounded())) cm.")
                }
            }
            if equipment.supportsWiFi {
                LabWiFiFields(phone: equipment == .phone, accessPoints: project.topology.devices.filter(\.isAccessPoint),
                              mode: $mode, accessPoint: $accessPoint)
            }
            AssemblyCommitButton("Colocar en mesa") {
                try edit(.equipment(equipment, name.optionalNetworkValue ?? equipment.title,
                                    desk: desk.isEmpty ? nil : desk, mode: equipment == .phone ? .wifi : mode,
                                    accessPoint: accessPoint.isEmpty ? nil : accessPoint))
            }
        }
        .navigationTitle("Colocar en mesa")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            desk = recommended ?? ""
            mode = equipment == .phone ? .wifi : .ethernet
            accessPoint = project.topology.devices.first(where: \.isAccessPoint)?.id ?? ""
        }
    }
}

struct LabDeskDimensionsForm: View {
    let desk: LabPlacement?
    let edit: (LabEquipmentEdit) throws -> String?
    @State private var title = ""
    @State private var width = 120
    @State private var depth = 65

    var body: some View {
        Form {
            if desk == nil { TextField("Nombre de la mesa", text: $title) }
            dimension("Ancho (cm)", value: $width)
            dimension("Fondo (cm)", value: $depth)
            if desk == nil {
                Picker("Tamaño de referencia", selection: Binding(get: { width }, set: { size in
                    width = size
                    depth = size == 50 ? 45 : size == 120 ? 65 : 85
                })) {
                    Text("Compacta").tag(50)
                    Text("Mediana").tag(120)
                    Text("Grande").tag(180)
                    if ![50, 120, 180].contains(width) { Text("Personalizado").tag(width) }
                }
            }
            AssemblyCommitButton(desk == nil ? "Añadir mesa" : "Guardar medidas",
                disabled: !(26...300).contains(width) || !(26...200).contains(depth), pop: true) {
                if let desk {
                    return try edit(.resizeDesk(desk.id, width: Float(width) / 100, depth: Float(depth) / 100))
                }
                return try edit(.desk(title.trimmedForNetwork.isEmpty ? "Mesa" : title,
                                      width: Float(width) / 100, depth: Float(depth) / 100))
            }
        }
        .navigationTitle(desk?.title ?? "Añadir mesa")
        .onAppear {
            if let desk {
                width = Int((desk.size.x * 100).rounded())
                depth = Int((desk.size.z * 100).rounded())
            }
        }
    }

    private func dimension(_ title: String, value: Binding<Int>) -> some View {
        LabeledContent(title) {
            TextField(title, value: value, format: .number)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .accessibilityLabel(title)
        }
    }
}

private struct LabClientConnectionForm: View {
    let device: LabTopology.Device
    let accessPoints: [LabTopology.Device]
    let edit: (LabEquipmentEdit) throws -> String?
    @State private var mode = LabClientConnection.ethernet
    @State private var accessPoint = ""

    var body: some View {
        Form {
            LabWiFiFields(phone: device.modelID == "pt-smartphone", accessPoints: accessPoints,
                          mode: $mode, accessPoint: $accessPoint)
            AssemblyCommitButton("Guardar conexión", pop: true) {
                try edit(.connection(device.id, mode, accessPoint: accessPoint.isEmpty ? nil : accessPoint))
            }
        }
        .navigationTitle(device.name)
        .onAppear {
            mode = device.connectionMode ?? (device.modelID == "pt-smartphone" ? .wifi : .ethernet)
            accessPoint = device.wifiAccessPointID ?? accessPoints.first?.id ?? ""
        }
    }
}

private struct LabWiFiFields: View {
    let phone: Bool
    let accessPoints: [LabTopology.Device]
    @Binding var mode: LabClientConnection
    @Binding var accessPoint: String

    var body: some View {
        Section("Conexión simulada") {
            if !phone {
                Picker("Modo", selection: $mode) {
                    ForEach(LabClientConnection.allCases) { Text($0.title).tag($0) }
                }
            }
            if phone || mode != .ethernet {
                Picker("Punto de acceso", selection: $accessPoint) {
                    Text("Sin asociar").tag("")
                    ForEach(accessPoints) { Text($0.name).tag($0.id) }
                }
                if accessPoints.isEmpty {
                    Text("Añade un punto de acceso para usar Wi-Fi.").foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct LabWorkspaceCableForm: View {
    let topology: LabTopology
    let assembly: LabARAssembly?
    let connect: (AssemblyPortRoute, LabTopology.Port) async throws -> String
    @State private var origin: LabTopology.Port?
    @State private var destination: LabTopology.Port?
    @State private var source = ""
    @State private var target = ""
    @State private var vlan = -2
    @State private var level = LabCableLevel.floor
    @State private var status: String?
    @State private var running = false

    private func ports(_ device: LabTopology.Device, after origin: LabTopology.Port? = nil) -> [LabTopology.Port] {
        if let assembly { return assembly.connectionPorts(on: device, in: topology, from: origin) }
        if let origin {
            guard origin.deviceID != device.id, let medium = topology.medium(at: origin) else { return [] }
            return topology.freePorts(on: device, matching: medium)
        }
        return topology.freePorts(on: device)
    }

    var body: some View {
        let sources = topology.devices.filter { !ports($0).isEmpty && !$0.modelID.hasPrefix("patch-") }
        let targets = origin.map { start in
            sources.filter { !ports($0, after: start).isEmpty }
        } ?? []
        Form {
            Section("Origen") {
                AssemblyDevicePicker(devices: sources, selection: $source)
                if let selected = sources.first(where: { $0.id == source }) {
                    portPicker(ports(selected), selection: $origin)
                }
            }
            Section("Destino") {
                AssemblyDevicePicker(devices: targets, selection: $target)
                if let selected = targets.first(where: { $0.id == target }), let origin {
                    portPicker(ports(selected, after: origin), selection: $destination)
                }
            }
            if origin != nil && destination != nil {
                AssemblyCableLevelPicker(level: $level)
                if !topology.vlans.isEmpty { AssemblyVLANPicker(vlans: topology.vlans, selection: $vlan) }
                Button("Conectar automáticamente", systemImage: "cable.connector") {
                    guard let origin, let destination else { return }
                    running = true
                    status = nil
                    Task {
                        defer { running = false }
                        do {
                            status = try await connect(.init(origin: origin, vlan: vlan, level: level), destination)
                            source = ""
                        } catch { status = error.localizedDescription }
                    }
                }
            }
            if running { ProgressView("Acomodando cable…") }
            if let status { Text(status).accessibilityIdentifier("lab.workspace.cable.status") }
        }
        .disabled(running)
        .navigationTitle("Conectar cable")
        .onChange(of: source) {
            origin = sources.first(where: { $0.id == source }).flatMap { ports($0).first }
        }
        .onChange(of: origin) {
            target = ""
            destination = nil
            vlan = origin.flatMap(topology.suggestedVLAN) ?? -2
        }
        .onChange(of: target) {
            if let origin, let device = targets.first(where: { $0.id == target }) {
                destination = ports(device, after: origin).first
                if vlan == -2 { vlan = topology.suggestedVLAN(at: destination ?? origin) ?? -2 }
            }
        }
    }

    private func portPicker(_ ports: [LabTopology.Port], selection: Binding<LabTopology.Port?>) -> some View {
        Picker("Puerto", selection: selection) {
            Text("Selecciona").tag(nil as LabTopology.Port?)
            ForEach(ports, id: \.self) { Text($0.name).tag(Optional($0)) }
        }
    }
}
