import SwiftUI

struct TopologyInspector: View {
    let topology: LabTopology
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(topology.name).font(.headline)
                    Text("\(topology.devices.count) equipos · \(topology.links.count) conexiones")
                    Text("Vista del diseño. La conectividad y los servicios no se ejecutan en este visor.")
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
                        NavigationLink { DeviceInspector(device: device, topology: topology) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(device.name)
                                Text(device.services.isEmpty ? (HardwareCatalog.item(device.modelID)?.name ?? device.modelID)
                                     : device.services.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section("Conexiones") {
                    ForEach(topology.links) { link in
                        NavigationLink { LinkInspector(link: link, topology: topology) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(name(link.fromDeviceID)) → \(name(link.toDeviceID))")
                                Text("\(link.fromPort) ↔ \(link.toPort)").font(.caption).monospaced()
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
        }
    }
    private func name(_ id: String) -> String { topology.devices.first { $0.id == id }?.name ?? id }
}

struct DeviceInspector: View {
    let device: LabTopology.Device
    let topology: LabTopology
    private var links: [LabTopology.Link] {
        topology.links.filter { $0.fromDeviceID == device.id || $0.toDeviceID == device.id }
    }
    var body: some View {
        Form {
            Section {
                Text(device.name).font(.title3.bold())
                if let sourceModel = device.sourceModel { LabeledContent("Modelo del archivo", value: sourceModel) }
                if let hardware = HardwareCatalog.item(device.modelID) {
                    NavigationLink("Referencia física: \(hardware.name)") { HardwareDetail(item: hardware) }
                }
                if let address = device.ipv4 { LabeledContent("IPv4", value: address).monospaced() }
                if let vlan = device.vlan { LabeledContent("VLAN", value: String(vlan)) }
            }
            if !device.services.isEmpty {
                Section("Servicios del diseño") {
                    ForEach(device.services, id: \.self) { Text($0) }
                }
            }
            Section("Puertos") {
                ForEach(device.ports, id: \.self) { port in
                    if let link = links.first(where: {
                        ($0.fromDeviceID == device.id && $0.fromPort == port)
                        || ($0.toDeviceID == device.id && $0.toPort == port)
                    }) {
                        NavigationLink { LinkInspector(link: link, topology: topology) } label: {
                            Label(port, systemImage: "cable.connector").font(.callout.monospaced())
                        }
                    } else {
                        LabeledContent(port, value: "Sin cable").font(.callout.monospaced())
                    }
                }
            }
            if let configuration = device.configuration, !configuration.isEmpty {
                Section("Configuración del archivo") {
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
    var body: some View {
        Form {
            Section("Extremo A") { endpoint(link.fromDeviceID, port: link.fromPort) }
            Section("Extremo B") { endpoint(link.toDeviceID, port: link.toPort) }
            Section("Medio") {
                LabeledContent("Tipo", value: mediumName)
                if link.medium == .copper {
                    Text("Conexión Ethernet de cobre. La categoría del cable depende del archivo o del diseño; no se ha medido su longitud física.")
                } else if link.medium == .fiber {
                    Text("Enlace óptico ilustrativo. Verifica transceptores, conectores y fibra compatibles antes de una instalación real.")
                } else {
                    Text("Representación del enlace indicado por el diseño.")
                }
            }
            Section("Configuración") {
                LabeledContent("VLAN indicadas", value: link.vlanIDs.isEmpty ? "No especificadas" : link.vlanIDs.map(String.init).joined(separator: ", "))
                Text("El cable muestra los extremos del diseño. Su presencia no demuestra tráfico, enlace activo ni comunicación entre VLAN.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Conexión").navigationBarTitleDisplayMode(.inline)
    }
    @ViewBuilder private func endpoint(_ id: String, port: String) -> some View {
        if let device = topology.devices.first(where: { $0.id == id }) {
            Text(device.name).font(.headline)
            Text(port).monospaced().textSelection(.enabled)
            if let original = device.sourcePortNames?[port], original != port {
                LabeledContent("Interfaz en Packet Tracer", value: original).monospaced()
            }
            if let address = device.ipv4 { LabeledContent("IPv4", value: address).monospaced() }
        }
    }
    private var mediumName: String {
        switch link.medium {
        case .copper: "Ethernet de cobre"
        case .fiber: "Fibra óptica"
        case .console: "Consola"
        case .powerA: "Alimentación A"
        case .powerB: "Alimentación B"
        }
    }
}

struct DataCenterInfo: View {
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Centro de datos de demostración").font(.headline)
                    Text("Sala virtual de 16 × 12 m, altura de 3,5 m y seis racks de 42 U. Las medidas son un ejemplo de distribución, no requisitos universales de Tier IV.")
                }
                Section("Criterios de referencia Tier IV") {
                    Label("Mantenimiento de componentes sin interrumpir la operación", systemImage: "wrench.and.screwdriver")
                    Label("Tolerancia a fallos de componentes y rutas de distribución", systemImage: "arrow.triangle.branch")
                    Label("Sistemas redundantes independientes y físicamente aislados", systemImage: "square.split.2x1")
                    Label("Alimentación tolerante a fallos para los equipos TI", systemImage: "bolt")
                    Label("Refrigeración continua", systemImage: "snowflake")
                }
                Section("Alcance de esta sala") {
                    Text("Se muestran red, VLAN y servicios, con referencias a caminos A/B. No se han dimensionado ni validado generación eléctrica, UPS, distribución, aislamiento, combustible o refrigeración.")
                    Text("La demostración no constituye un diseño constructivo ni una certificación Tier IV. Uptime Institute evalúa el diseño y la instalación para esa acreditación.")
                }
                Section("Fuente") {
                    Link("Uptime Institute · Tier Classification System", destination: URL(string: "https://uptimeinstitute.com/tiers")!)
                }
            }
            .navigationTitle("Criterios Tier IV").navigationBarTitleDisplayMode(.inline)
            .toolbar { DismissButton() }
        }
    }
}
