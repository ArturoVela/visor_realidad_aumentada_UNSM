import Foundation

nonisolated struct HardwareItem: Identifiable, Sendable {
    enum Family: String, CaseIterable, Sendable {
        case network = "Red y telefonía"
        case computing = "Servidores y puestos"
        case racks = "Racks"
        case power = "Energía"
        case cooling = "Refrigeración"
    }

    enum Group: String, CaseIterable, Sendable {
        case servers = "Servidores"
        case routers = "Routers"
        case switches = "Switches"
        case wireless = "Wi-Fi y puntos de acceso"
        case computers = "PC y laptops"
        case mobile = "Celulares y tabletas"
        case security = "Firewalls y cámaras"
        case peripherals = "Telefonía IP y periféricos"
        case patchPanels = "Patch panels"
        case racks = "Racks y mobiliario"
        case power = "Energía"
        case cooling = "Refrigeración"

        var symbol: String {
            switch self {
            case .servers: "server.rack"
            case .routers: "point.3.connected.trianglepath.dotted"
            case .switches: "switch.2"
            case .wireless: "wifi"
            case .computers: "desktopcomputer"
            case .mobile: "iphone"
            case .security: "shield"
            case .peripherals: "printer"
            case .patchPanels: "cable.connector"
            case .racks: "cabinet"
            case .power: "bolt"
            case .cooling: "fan"
            }
        }

        func matches(_ query: String) -> Bool {
            query.isEmpty || rawValue.localizedStandardContains(query)
                || (self == .wireless && ["WiFi", "Access Point", "AP"].contains { $0.localizedStandardContains(query) })
        }
    }

    let id: String
    let name: String
    let family: Family
    let group: Group
    let category: String
    let summary: String
    /// Anchura, altura y fondo del equipo en metros; nil cuando no se han cotejado.
    let size: SIMD3<Float>?
    let ports: String
    let sourceURL: URL?
    let sourceTitle: String
    var dimensionsSourceURL: URL? = nil

    func matchesCatalogSearch(_ query: String) -> Bool {
        group.matches(query) || name.localizedStandardContains(query)
            || category.localizedStandardContains(query) || id.localizedStandardContains(query)
    }
}

nonisolated enum HardwareCatalog {
    // Selección educativa representativa; no es un ranking de ventas o uso mundial.
    // Las referencias históricas se conservan por su relación con prácticas de Packet Tracer.
    static let items: [HardwareItem] = [
        HardwareItem(id: "rack-r42612", name: "Cisco R42612", family: .racks, group: .racks, category: "Rack de 42 U",
                     summary: "Rack físico de referencia. Dimensiones externas sin embalaje; representación 3D aproximada, no plano de ingeniería certificado.",
                     size: SIMD3(0.597, 2.013, 1.266), ports: "Gabinete pasivo; la conectividad depende de los equipos montados.",
                     sourceURL: URL(string: "https://www.cisco.com/c/en/us/products/collateral/servers-unified-computing/r-series-racks/datasheet-c78-738217.html")!, sourceTitle: "Cisco R42612 Rack Data Sheet — tabla 2"),
        HardwareItem(id: "patch-copper", name: "Patch panel Cat 6", family: .network, group: .patchPanels, category: "Panel pasivo de 1 U",
                     summary: "24 acopladores pasantes. Las caras frontal y posterior comparten numeración.",
                     size: SIMD3(0.445, 0.0432, 0.10), ports: "24 pares RJ45 F01/R01 a F24/R24.",
                     sourceURL: URL(string: "https://chriskirby.net/setting-up-and-leveling-up-your-homelab-a-comprehensive-guide/#rack-mounting")!,
                     sourceTitle: "Montaje de referencia · paneles con acopladores"),
        HardwareItem(id: "patch-fiber", name: "Patch panel LC dúplex", family: .network, group: .patchPanels, category: "Panel pasivo de 1 U",
                     summary: "Bandeja de 12 acopladores LC dúplex. Chasis de referencia.",
                     size: SIMD3(0.445, 0.0432, 0.19), ports: "12 pares F01/R01 a F12/R12.",
                     sourceURL: URL(string: "https://chriskirby.net/setting-up-and-leveling-up-your-homelab-a-comprehensive-guide/#rack-mounting")!,
                     sourceTitle: "Montaje de referencia · pasantes de fibra"),
        HardwareItem(id: "switch-2960", name: "Cisco Catalyst 2960-24TT-L", family: .network, group: .switches, category: "Switch de acceso",
                     summary: "Referencia histórica para prácticas de switching. Modelo 3D exterior aproximado.",
                     size: SIMD3(0.445, 0.044, 0.236), ports: "24 Ethernet 10/100BASE-T y 2 uplinks Ethernet 10/100/1000BASE-T.",
                     sourceURL: URL(string: "https://www.cisco.com/c/en/us/td/docs/switches/lan/catalyst2960/hardware/installation/guide/2960_hg/higspec.html")!, sourceTitle: "Cisco Catalyst 2960 — especificaciones del 2960-24TT-L"),
        HardwareItem(id: "switch-3560", name: "Cisco Catalyst 3560-24PS", family: .network, group: .switches, category: "Switch multicapa",
                     summary: "Familia clásica para prácticas de VLAN y enrutamiento; sin asumir licencia de software. Modelo 3D exterior aproximado.",
                     size: SIMD3(0.445, 0.044, 0.301), ports: "24 Ethernet 10/100 con PoE y 2 ranuras para módulos SFP.",
                     sourceURL: URL(string: "https://www.cisco.com/c/en/us/td/docs/switches/lan/catalyst3560/hardware/installation/guide/3560hig/hgspecs.pdf")!, sourceTitle: "Cisco Catalyst 3560 — especificaciones del 3560-24PS"),
        HardwareItem(id: "switch-3650", name: "Cisco Catalyst 3650-24PS", family: .network, group: .switches, category: "Switch multicapa · 1 U",
                     summary: "Chasis frontal con 24 RJ45 y cuatro ranuras SFP de subida. Exterior 3D aproximado.",
                     size: SIMD3(0.445, 0.044, 0.448), ports: "24 Gigabit Ethernet RJ45 con PoE+ y cuatro uplinks Gigabit Ethernet SFP.",
                     sourceURL: URL(string: "https://www.cisco.com/c/en/us/products/collateral/switches/catalyst-3650-series-switches/data_sheet-c78-729449.html")!,
                     sourceTitle: "Cisco Catalyst 3650 Series Switches Data Sheet"),
        HardwareItem(id: "router-1941", name: "Cisco ISR 1941", family: .network, group: .routers, category: "Router",
                     summary: "Router clásico ISR G2 de 2 U. Capacidades de software dependen de licencia y configuración; exterior 3D aproximado.",
                     size: SIMD3(0.3429, 0.0889, 0.2921),
                     ports: "2 Gigabit Ethernet RJ45; 2 ranuras EHWIC; 2 USB-A; consola mini-USB y RJ45; AUX. Sin SFP integrado.",
                     sourceURL: URL(string: "https://www.cisco.com/c/en/us/products/collateral/routers/1900-series-integrated-services-routers-isr/data_sheet_c78_556319.html")!, sourceTitle: "Cisco 1941 Integrated Services Routers Data Sheet — tabla 7"),
        HardwareItem(id: "router-2811", name: "Cisco ISR 2811", family: .network, group: .routers, category: "Router modular · 1 U",
                     summary: "Chasis ISR modular. El importador conserva los puertos WAN de los módulos presentes en el laboratorio.",
                     size: nil, ports: "Dos Fast Ethernet integrados, cuatro ranuras HWIC, consola y AUX.",
                     sourceURL: URL(string: "https://www.cisco.com/web/ANZ/cpp/refguide/hview/router/2800.html")!,
                     sourceTitle: "Cisco 2800 Series Router Hardware View · Cisco 2811"),
        HardwareItem(id: "router-2911", name: "Cisco ISR 2911", family: .network, group: .routers, category: "Router",
                     summary: "Router clásico ISR G2 modular de 2 U. Capacidades de software dependen de licencia y configuración; exterior 3D aproximado.",
                     size: SIMD3(0.4382, 0.0889, 0.3048),
                     ports: "3 Gigabit Ethernet RJ45; 4 ranuras EHWIC y 1 SM; 2 USB 2.0; consola USB y serie; AUX. Sin SFP integrado.",
                     sourceURL: URL(string: "https://www.cisco.com/c/en/us/products/collateral/routers/2900-series-integrated-services-routers-isr/data_sheet_c78_553896.html")!, sourceTitle: "Cisco 2900 Series Integrated Services Routers Data Sheet — tabla 7"),
        HardwareItem(id: "firewall-asa5505", name: "Cisco ASA 5505", family: .network, group: .security, category: "Firewall",
                     summary: "Firewall clásico de escritorio; no es un chasis de 19 pulgadas. Modelo 3D exterior aproximado.",
                     size: SIMD3(0.2004, 0.0445, 0.1745),
                     ports: "Switch integrado de 8 puertos Fast Ethernet 10/100, 2 de ellos con PoE; 3 USB 2.0: 1 frontal y 2 posteriores.",
                     sourceURL: URL(string: "https://www.cisco.com/c/en/us/products/collateral/security/asa-5500-series-next-generation-firewalls/datasheet-c78-733510.html")!, sourceTitle: "Cisco ASA 5505 Adaptive Security Appliance Data Sheet"),
        HardwareItem(id: "server-c220m5", name: "Cisco UCS C220 M5 SFF", family: .computing, group: .servers, category: "Servidor de rack de 1 U",
                     summary: "Chasis SFF con capacidad de hasta 10 bahías de 2,5 pulgadas. Se ilustra esa configuración; ocupación y adaptadores varían. Exterior 3D aproximado.",
                     size: SIMD3(0.429, 0.0432, 0.757), ports: "2 puertos LOM 10GBASE-T. El montaje de referencia equipa dos fuentes intercambiables.",
                     sourceURL: URL(string: "https://www.cisco.com/c/en/us/products/collateral/servers-unified-computing/ucs-c-series-rack-servers/datasheet-c78-739281.html")!, sourceTitle: "Cisco UCS C220 M5 Rack Server Data Sheet — chasis SFF",
                     dimensionsSourceURL: URL(string: "https://www.cisco.com/c/en/us/td/docs/unified_computing/ucs/c/hw/C220M5/install/C220M5/C220M5_appendix_011.html")!),
        HardwareItem(id: "server-firewall", name: "Cisco UCS C220 M5 SFF · nodo firewall", family: .network, group: .servers,
                     category: "Servidor de seguridad de 1 U",
                     summary: "Chasis UCS con interfaces dedicadas a red interna, tránsito y estado HA en el plano.",
                     size: SIMD3(0.429, 0.0432, 0.757), ports: "Tres RJ45 etiquetados en la plantilla. Alimentación A/B.",
                     sourceURL: URL(string: "https://www.cisco.com/c/en/us/products/collateral/servers-unified-computing/ucs-c-series-rack-servers/datasheet-c78-739281.html")!,
                     sourceTitle: "Cisco UCS C220 M5 Rack Server Data Sheet"),
        HardwareItem(id: "phone-7960", name: "Cisco IP Phone 7960G", family: .network, group: .peripherals, category: "Teléfono IP",
                     summary: "Teléfono clásico con 6 botones programables de línea/función y 4 teclas contextuales. Modelo 3D exterior aproximado.",
                     size: nil, ports: "2 conexiones Ethernet 10/100BASE-T RJ45 para red y PC, y conexión dedicada de auriculares.",
                     sourceURL: URL(string: "https://www.cisco.com/web/ANZ/cpp/refguide/hview/ipt/phone.html")!, sourceTitle: "Cisco Unified IP Phones 7900 Series — CP-7960G"),
        HardwareItem(id: "raspberry-pi5", name: "Raspberry Pi 5", family: .computing, group: .servers, category: "Controlador de servicios",
                     summary: "Representación de placa con disipador sobre bandeja ventilada. Tamaño exterior de la envolvente del montaje.",
                     size: SIMD3(0.10, 0.029, 0.077), ports: "Ethernet, alimentación USB-C, USB y GPIO.",
                     sourceURL: URL(string: "https://www.raspberrypi.com/products/raspberry-pi-5/")!,
                     sourceTitle: "Raspberry Pi · Raspberry Pi 5"),
        HardwareItem(id: "access-point", name: "Punto de acceso Wi-Fi", family: .network, group: .wireless, category: "AP con SSID y VLAN",
                     summary: "Envolvente de montaje de referencia. Vincula el SSID IoT a la VLAN 50 y el de clientes a la VLAN 30.",
                     size: SIMD3(0.16, 0.032, 0.16), ports: "RJ45 Ethernet de subida. Alimentación local o inyector compatible.",
                     sourceURL: URL(string: "https://www.wi-fi.org/discover-wi-fi")!, sourceTitle: "Wi-Fi Alliance · Wi-Fi"),
        HardwareItem(id: "camera-ip", name: "Cámara IP RTSP", family: .network, group: .security, category: "Videovigilancia · Ethernet",
                     summary: "Modelo de referencia con lente, iluminadores y soporte regulable. Elige posición y medidas según el equipo instalado.",
                     size: SIMD3(0.082, 0.076, 0.132), ports: "RJ45 Ethernet. Alimentación local o inyector compatible.",
                     sourceURL: URL(string: "https://www.onvif.org/profiles/profile-t/")!, sourceTitle: "ONVIF · Profile T"),
        HardwareItem(id: "pc-optiplex7010", name: "Dell OptiPlex 7010 Mini Tower (2012)", family: .computing, group: .computers, category: "Computadora de prueba",
                     summary: "PC físico de referencia; Packet Tracer representa PCs genéricos. Modelo 3D exterior aproximado.",
                     size: SIMD3(0.175, 0.36, 0.417),
                     ports: "1 Ethernet RJ45; 6 USB 2.0 (2 frontales y 4 posteriores) y 4 USB 3.0 (2 frontales y 2 posteriores).",
                     sourceURL: URL(string: "https://www.dell.com/support/manuals/es-pe/optiplex-7010/opti7010_usff/specifications?guid=guid-157e8495-34d3-4efa-ab61-1d9efba4c90e&lang=en-us")!, sourceTitle: "Dell OptiPlex 7010 — Specifications, columna Mini Tower"),
        HardwareItem(id: "laptop-latitude5420", name: "Dell Latitude 5420", family: .computing, group: .computers, category: "Laptop de prueba",
                     summary: "Laptop física de referencia. Dimensiones del chasis cerrado, con altura posterior máxima; exterior 3D abierto aproximado.",
                     size: SIMD3(0.32135, 0.0209, 0.212),
                     ports: "2 USB 3.2 Gen 1 (1 con PowerShare), 2 Thunderbolt 4/USB4 con DisplayPort y Power Delivery, 1 HDMI 2.0, 1 RJ45 y audio.",
                     sourceURL: URL(string: "https://www.dell.com/support/manuals/es-pe/latitude-5420-laptop/5420_sp14_setupspecs/ports-and-connectors?guid=guid-38d3f374-dd76-4ab5-97ec-d5a0aa87bd32&lang=en-us")!, sourceTitle: "Dell Latitude 5420 — Ports and connectors",
                     dimensionsSourceURL: URL(string: "https://www.dell.com/support/manuals/es-pe/latitude-5420-laptop/5420_sp14_setupspecs/dimensions-and-weight?guid=guid-7df32f47-45cf-4a08-ad99-b01eec4f3ce6&lang=en-us")!)
    ]

    static func item(_ id: String) -> HardwareItem? {
        items.first { $0.id == id } ?? importedAccessories.first { $0.id == id }
    }

    static let infrastructure: [HardwareItem] = [
        HardwareItem(id: "rack-fans", name: "Bandeja de ventiladores", family: .cooling, group: .cooling, category: "Ventilación de rack · 1 U",
                     summary: "Bandeja con tres extractores. Colócala cerca de la parte superior y revisa el flujo simulado en la escena.",
                     size: SIMD3(0.44, 0.043, 0.32), ports: "Entrada de alimentación conectada automáticamente a la PDU del rack.",
                     sourceURL: nil, sourceTitle: "Modelo ilustrativo"),
        HardwareItem(id: "ups-9px", name: "Eaton 9PX3000IRT2U", family: .power, group: .power, category: "UPS de doble conversión · 2 U",
                     summary: "Referencia de chasis para el banco A y el banco B. La potencia y autonomía se dimensionan con la carga del sitio.",
                     size: SIMD3(0.44, 0.0865, 0.605), ports: "Alimentación AC, salidas IEC y conector para módulo de batería.",
                     sourceURL: URL(string: "https://www.eaton.com/gb/en-gb/skuPage.9PX3000IRT2U.html")!, sourceTitle: "Eaton · 9PX3000IRT2U"),
        HardwareItem(id: "battery-9px", name: "Eaton 9PXEBM72RT2U", family: .power, group: .power, category: "Batería de expansión · 2 U",
                     summary: "Módulo de referencia de 72 V. La cantidad de módulos de la plantilla es ilustrativa.",
                     size: SIMD3(0.44, 0.0865, 0.605), ports: "Interfaz de batería de expansión del UPS compatible.",
                     sourceURL: URL(string: "https://www.eaton.com/gb/en-gb/skuPage.9PXEBM72RT2U.html")!, sourceTitle: "Eaton · 9PXEBM72RT2U"),
        HardwareItem(id: "cooling-inrow", name: "Schneider Uniflair ACRD301P", family: .cooling, group: .cooling, category: "Refrigeración en fila · DX",
                     summary: "Unidad interior de referencia. El condensador remoto y la capacidad bajo fallo requieren cálculo y levantamiento del sitio.",
                     size: SIMD3(0.300, 1.991, 1.095), ports: "Circuito frigorífico hacia condensador exterior, drenaje, alimentación y control.",
                     sourceURL: URL(string: "https://www.apc.com/us/en/product/ACRD301P/")!, sourceTitle: "Schneider Electric · ACRD301P")
    ]

    private static let allItems = items + importedAccessories + infrastructure
    static let byFamily = Dictionary(grouping: allItems, by: \.family)
    static let byGroup = Dictionary(grouping: allItems, by: \.group)

    // Packet Tracer's generic devices have illustrative envelopes.
    static let importedAccessorySizes: [String: SIMD3<Float>] = [
        "pt-desktop": SIMD3(0.52, 0.42, 0.27),
        "pt-laptop": SIMD3(0.32, 0.021, 0.212),
        "pt-server": SIMD3(0.19, 0.40, 0.38),
        "pt-access-point": SIMD3(0.19, 0.032, 0.13),
        "pt-printer": SIMD3(0.35, 0.16, 0.28),
        "pt-tablet": SIMD3(0.17, 0.013, 0.24),
        "pt-smartphone": SIMD3(0.078, 0.012, 0.16),
        "pt-power-distribution": SIMD3(0.43, 0.044, 0.09)
    ]

    private static let importedAccessories: [HardwareItem] = [
        generic("pt-desktop", "PC-PT", .computing, .computers, "PC de escritorio", "Torre, monitor y teclado.", "Ethernet según el archivo."),
        generic("pt-laptop", "Laptop-PT", .computing, .computers, "Laptop", "Pantalla abatible, teclado y panel táctil.", "Ethernet según el archivo."),
        generic("pt-server", "Server-PT", .computing, .servers, "Servidor en torre", "Envolvente de servidor con bahías e indicadores.", "Interfaces Ethernet según el archivo."),
        generic("pt-access-point", "AccessPoint-PT", .network, .wireless, "Punto de acceso Wi-Fi", "Chasis de sobremesa con antenas e indicadores.", "Puerto de subida Ethernet."),
        generic("pt-printer", "Printer-PT", .computing, .peripherals, "Impresora", "Bandejas de entrada y salida.", "Ethernet según el archivo."),
        generic("pt-tablet", "TabletPC-PT", .computing, .mobile, "Tableta", "Equipo táctil portátil.", "Interfaces según el archivo."),
        generic("pt-smartphone", "SMARTPHONE-PT", .computing, .mobile, "Teléfono móvil", "Dispositivo táctil de bolsillo.", "Interfaces según el archivo."),
        generic("pt-power-distribution", "Power Distribution Device", .power, .power, "Distribución eléctrica", "Unidad de distribución de energía.", "Conexiones eléctricas según el archivo.")
    ]

    private static func generic(_ id: String, _ name: String, _ family: HardwareItem.Family, _ group: HardwareItem.Group,
                                _ category: String, _ summary: String, _ ports: String) -> HardwareItem {
        HardwareItem(id: id, name: name, family: family, group: group, category: category,
                     summary: summary + " Envolvente 3D ilustrativa para el modelo genérico del archivo.",
                     size: nil, ports: ports, sourceURL: nil, sourceTitle: "Modelo genérico de Packet Tracer")
    }

    static func reference(_ id: String) -> HardwareItem? {
        item(id) ?? infrastructure.first { $0.id == id }
    }

    static func renderSize(_ id: String) -> SIMD3<Float> {
        if let size = reference(id)?.size { return size }
        if let size = importedAccessorySizes[id] { return size }
        switch id {
        case "phone-7960": return SIMD3(0.19, 0.08, 0.23)
        case "router-2811": return SIMD3(0.438, 0.0445, 0.417)
        default: preconditionFailure("Uncatalogued hardware: \(id)")
        }
    }
}

nonisolated enum RackMount {
    enum Equipment: String, CaseIterable, Identifiable, Sendable {
        case server = "server-c220m5"
        case securityServer = "server-firewall"
        case switch24 = "switch-2960"
        case switch3560 = "switch-3560"
        case switchMultilayer = "switch-3650"
        case router1941 = "router-1941"
        case router2811 = "router-2811"
        case router = "router-2911"
        case firewall = "firewall-asa5505"
        case copperPanel = "patch-copper"
        case fiberPanel = "patch-fiber"
        case ups = "ups-9px"
        case battery = "battery-9px"
        case fans = "rack-fans"

        var id: String { rawValue }
        var title: String { HardwareCatalog.reference(rawValue)?.name ?? rawValue }
        var units: Int { RackMount.units(rawValue) }
    }

    enum Side: String, CaseIterable, Identifiable, Codable, Sendable {
        case left, right
        var id: Self { self }
        var sign: Float { self == .left ? -1 : 1 }
        var title: String { self == .left ? "Izquierdo" : "Derecho" }
    }

    enum Target: Equatable, Sendable { case unit(Int), side(Side) }

    enum Height: Int, CaseIterable, Identifiable, Sendable {
        case compact = 12, medium = 24, full = 42
        var id: Int { rawValue }
        var size: SIMD3<Float> {
            let reference = HardwareCatalog.renderSize("rack-r42612")
            return SIMD3(reference.x, reference.y - Float(42 - rawValue) * RackMount.unit, reference.z)
        }
    }

    enum CableFace: Int, Hashable, Sendable {
        case front = -1, rear = 1

        var sign: Float { Float(rawValue) }

        func railDepth(in size: SIMD3<Float>) -> Float {
            sign * (size.z / 2 - (self == .front ? RackMount.frontInset + 0.015 : 0.083))
        }

        func channelDepth(in size: SIMD3<Float>) -> Float {
            sign * (size.z / 2 - (self == .front ? 0.019 : 0.031))
        }
    }

    static let frontRailX: Float = 0.248
    static let cableSideInset: Float = 0.028

    static let unit: Float = 0.04445
    static let base: Float = 0.105
    static let frontInset: Float = 0.082

    static func units(_ model: String) -> Int {
        switch model {
        case "router-1941", "router-2911", "firewall-asa5505", "ups-9px", "battery-9px": 2
        default: 1
        }
    }

    static func capacity(height: Float) -> Int {
        min(42, max(0, Int(((height - base - 0.035) / unit).rounded(.down))))
    }

    static func center(_ model: String, rackDepth: Float, slot: Int) -> SIMD3<Float> {
        let size = HardwareCatalog.renderSize(model)
        let shelf: Float = model == "firewall-asa5505" ? 0.008 : 0
        return SIMD3(0, base + Float(slot) * unit + shelf + size.y / 2,
                     -rackDepth / 2 + frontInset + size.z / 2)
    }

    static func slot(_ model: String, near height: Float) -> Int {
        Int(((height - base - HardwareCatalog.renderSize(model).y / 2) / unit).rounded())
    }

    static func target(origin: SIMD3<Float>, direction: SIMD3<Float>, size: SIMD3<Float>) -> Target? {
        var hits: [(Float, Target)] = []
        if direction.z > 0.0001 {
            let distance = (-size.z / 2 - origin.z) / direction.z
            let hit = origin + direction * distance
            let offset = (hit.y - base) / unit
            if distance > 0, abs(hit.x) <= size.x / 2, offset >= 0, offset < Float(capacity(height: size.y)) {
                hits.append((distance, .unit(Int(offset))))
            }
        }
        for side in Side.allCases where side.sign * direction.x < -0.0001 {
            let distance = (side.sign * size.x / 2 - origin.x) / direction.x
            let hit = origin + direction * distance
            if distance > 0, (0...size.y).contains(hit.y), abs(hit.z) <= size.z / 2 {
                hits.append((distance, .side(side)))
            }
        }
        return hits.min { $0.0 < $1.0 }?.1
    }
}
