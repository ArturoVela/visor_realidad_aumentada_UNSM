import SwiftUI
import UniformTypeIdentifiers

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

    var body: some View {
        NavigationStack {
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
                        NavigationLink { DeviceInspector(device: device, topology: topology, locateTitle: locateTitle, onLocate: onLocate) } label: {
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
                                                           segments: cablePlan?.segments ?? []) } label: {
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
            .toolbar { DismissButton() }
            .task {
                guard let room, let layout else { return }
                do { cablePlan = try await Self.buildPlan(topology, room: room, layout: layout) }
                catch { exportError = error.localizedDescription }
            }
        }
    }
    @concurrent private static func buildPlan(_ topology: LabTopology, room: RoomStructure,
                                              layout: LabLayout) async throws -> LabCablePlan {
        try LabCablePlan.make(topology, room: room, layout: layout)
    }

    private func name(_ id: String) -> String { topology.devices.first { $0.id == id }?.name ?? id }
}

struct DeviceInspector: View {
    let device: LabTopology.Device
    let topology: LabTopology
    var locateTitle = "Ver en 3D"
    var onLocate: ((LabInspectionDestination) -> Void)? = nil

    var consoleBase: LabTopology? = nil
    var poweredOff: Set<String> = []

    private var links: [LabTopology.Link] {
        topology.links.filter { $0.fromDeviceID == device.id || $0.toDeviceID == device.id }
    }
    var body: some View {
        Form {
            Section {
                Text(device.name).font(.title3.bold())
                if let sourceModel = device.sourceModel { LabeledContent("Modelo del archivo", value: sourceModel) }
                if let hardware = HardwareCatalog.reference(device.modelID) {
                    NavigationLink("Referencia física: \(hardware.name)") { HardwareDetail(item: hardware) }
                }
                if let consoleBase {
                    NavigationLink {
                        LabConsoleView(base: consoleBase, device: device, poweredOff: poweredOff)
                    } label: {
                        Label("Abrir consola", systemImage: "terminal")
                    }
                }
                if let address = device.ipv4 { LabeledContent("IPv4", value: address).monospaced() }
                if let vlan = device.vlan { LabeledContent("VLAN", value: String(vlan)) }
                if let onLocate {
                    Button(locateTitle, systemImage: "viewfinder") { onLocate(.init(deviceID: device.id)) }
                }
            }
            if !device.services.isEmpty {
                Section("Servicios del diseño") {
                    ForEach(device.services, id: \.self) { Text($0) }
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
                    ForEach(device.ports, id: \.self) { port in
                        if let link = links.first(where: {
                            ($0.fromDeviceID == device.id && $0.fromPort == port)
                            || ($0.toDeviceID == device.id && $0.toPort == port)
                        }) {
                            NavigationLink { LinkInspector(link: link, topology: topology, locateTitle: locateTitle, onLocate: onLocate) } label: {
                                LabeledContent {
                                    if device.shutdownPorts?.contains(port) == true { Text("Deshabilitado") }
                                } label: {
                                    Label(port, systemImage: "cable.connector").font(.callout.monospaced())
                                }
                            }
                        } else if let onLocate {
                            Button { onLocate(.init(deviceID: device.id, port: port)) } label: {
                                Label(port, systemImage: "viewfinder").font(.callout.monospaced())
                            }.accessibilityHint("Puerto sin cable")
                        } else {
                            LabeledContent(port, value: "Sin cable").font(.callout.monospaced())
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

struct LinkInspector: View {
    let link: LabTopology.Link
    let topology: LabTopology
    var locateTitle = "Ver en 3D"
    var onLocate: ((LabInspectionDestination) -> Void)? = nil
    var segments: [LabCablePlan.Segment] = []

    var body: some View {
        let circuit = topology.circuit(for: link)
        let first = circuit.first ?? link, last = circuit.last ?? link
        Form {
            Section("Extremo A") { endpoint(first.fromDeviceID, port: first.fromPort, accessibilityID: "connection-end-a") }
            Section("Extremo B") { endpoint(last.toDeviceID, port: last.toPort, accessibilityID: "connection-end-b") }
            Section("Cable") {
                LabeledContent("Etiqueta del tramo", value: link.id)
                LabeledContent("Tipo", value: link.medium.title)
                if let geometry = segments.first(where: { $0.link.id == link.id }) {
                    LabeledContent("Longitud simulada", value: geometry.length.formatted(.number.precision(.fractionLength(2))) + " m")
                    LabeledContent("Radio del modelo", value: (geometry.bendRadius * 1000).formatted() + " mm")
                }
                LabeledContent("VLAN indicadas", value: link.vlanIDs.isEmpty ? "No especificadas" : link.vlanIDs.map(String.init).joined(separator: ", "))
                if let onLocate {
                    Button("Seguir cable", systemImage: "point.topleft.down.to.point.bottomright.curvepath") {
                        onLocate(.init(deviceID: link.fromDeviceID, port: link.fromPort, linkID: link.id))
                    }.accessibilityHint(locateTitle)
                }
                if link.medium == .copper {
                    Text("Conectores RJ45. La categoría y longitud física dependen de la instalación.")
                        .font(.footnote).foregroundStyle(.secondary)
                } else if link.medium == .fiber {
                    Text("Enlace óptico del plano. Confirma la compatibilidad de transceptores y conectores.")
                        .font(.footnote).foregroundStyle(.secondary)
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
        NavigationStack {
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
            .toolbar { DismissButton() }
        }
    }
}


struct HomeLabGuide: View {
    let onFollowCable: (String) -> Void

    var body: some View {
        NavigationStack {
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
            .toolbar { DismissButton() }
        }
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
