import Foundation

nonisolated struct HardwareItem: Identifiable, Sendable {
    enum Family: String, CaseIterable, Sendable {
        case network = "Red y telefonía"
        case computing = "Servidores y puestos"
        case racks = "Racks"
        case power = "Energía"
        case cooling = "Refrigeración"
    }

    let id: String
    let name: String
    let family: Family
    let category: String
    let summary: String
    /// Anchura, altura y fondo del equipo en metros; nil cuando no se han cotejado.
    let size: SIMD3<Float>?
    let ports: String
    let sourceURL: URL
    let sourceTitle: String
    var dimensionsSourceURL: URL? = nil
}

nonisolated enum HardwareCatalog {
    // Selección educativa representativa; no es un ranking de ventas o uso mundial.
    // Las referencias históricas se conservan por su relación con prácticas de Packet Tracer.
    static let items: [HardwareItem] = [
        HardwareItem(id: "rack-r42612", name: "Cisco R42612", family: .racks, category: "Rack de 42 U",
                     summary: "Rack físico de referencia. Dimensiones externas sin embalaje; representación 3D aproximada, no plano de ingeniería certificado.",
                     size: SIMD3(0.597, 2.013, 1.266), ports: "Gabinete pasivo; la conectividad depende de los equipos montados.",
                     sourceURL: URL(string: "https://www.cisco.com/c/en/us/products/collateral/servers-unified-computing/r-series-racks/datasheet-c78-738217.html")!, sourceTitle: "Cisco R42612 Rack Data Sheet — tabla 2"),
        HardwareItem(id: "patch-copper", name: "Patch panel Cat 6", family: .network, category: "Panel pasivo de 1 U",
                     summary: "24 acopladores pasantes. Las caras frontal y posterior comparten numeración.",
                     size: SIMD3(0.445, 0.0432, 0.10), ports: "24 pares RJ45 F01/R01 a F24/R24.",
                     sourceURL: URL(string: "https://chriskirby.net/setting-up-and-leveling-up-your-homelab-a-comprehensive-guide/#rack-mounting")!,
                     sourceTitle: "Montaje de referencia · paneles con acopladores"),
        HardwareItem(id: "patch-fiber", name: "Patch panel LC dúplex", family: .network, category: "Panel pasivo de 1 U",
                     summary: "Bandeja de 12 acopladores LC dúplex. Chasis de referencia.",
                     size: SIMD3(0.445, 0.0432, 0.19), ports: "12 pares F01/R01 a F12/R12.",
                     sourceURL: URL(string: "https://chriskirby.net/setting-up-and-leveling-up-your-homelab-a-comprehensive-guide/#rack-mounting")!,
                     sourceTitle: "Montaje de referencia · pasantes de fibra"),
        HardwareItem(id: "switch-2960", name: "Cisco Catalyst 2960-24TT-L", family: .network, category: "Switch de acceso",
                     summary: "Referencia histórica para prácticas de switching. Modelo 3D exterior aproximado.",
                     size: SIMD3(0.445, 0.044, 0.236), ports: "24 Ethernet 10/100BASE-T y 2 uplinks Ethernet 10/100/1000BASE-T.",
                     sourceURL: URL(string: "https://www.cisco.com/c/en/us/td/docs/switches/lan/catalyst2960/hardware/installation/guide/2960_hg/higspec.html")!, sourceTitle: "Cisco Catalyst 2960 — especificaciones del 2960-24TT-L"),
        HardwareItem(id: "switch-3560", name: "Cisco Catalyst 3560-24PS", family: .network, category: "Switch multicapa",
                     summary: "Familia clásica para prácticas de VLAN y enrutamiento; sin asumir licencia de software. Modelo 3D exterior aproximado.",
                     size: SIMD3(0.445, 0.044, 0.301), ports: "24 Ethernet 10/100 con PoE y 2 ranuras para módulos SFP.",
                     sourceURL: URL(string: "https://www.cisco.com/c/en/us/td/docs/switches/lan/catalyst3560/hardware/installation/guide/3560hig/hgspecs.pdf")!, sourceTitle: "Cisco Catalyst 3560 — especificaciones del 3560-24PS"),
        HardwareItem(id: "router-1941", name: "Cisco ISR 1941", family: .network, category: "Router",
                     summary: "Router clásico ISR G2 de 2 U. Capacidades de software dependen de licencia y configuración; exterior 3D aproximado.",
                     size: SIMD3(0.3429, 0.0889, 0.2921),
                     ports: "2 Gigabit Ethernet RJ45; 2 ranuras EHWIC; 2 USB-A; consola mini-USB y RJ45; AUX. Sin SFP integrado.",
                     sourceURL: URL(string: "https://www.cisco.com/c/en/us/products/collateral/routers/1900-series-integrated-services-routers-isr/data_sheet_c78_556319.html")!, sourceTitle: "Cisco 1941 Integrated Services Routers Data Sheet — tabla 7"),
        HardwareItem(id: "router-2911", name: "Cisco ISR 2911", family: .network, category: "Router",
                     summary: "Router clásico ISR G2 modular de 2 U. Capacidades de software dependen de licencia y configuración; exterior 3D aproximado.",
                     size: SIMD3(0.4382, 0.0889, 0.3048),
                     ports: "3 Gigabit Ethernet RJ45; 4 ranuras EHWIC y 1 SM; 2 USB 2.0; consola USB y serie; AUX. Sin SFP integrado.",
                     sourceURL: URL(string: "https://www.cisco.com/c/en/us/products/collateral/routers/2900-series-integrated-services-routers-isr/data_sheet_c78_553896.html")!, sourceTitle: "Cisco 2900 Series Integrated Services Routers Data Sheet — tabla 7"),
        HardwareItem(id: "firewall-asa5505", name: "Cisco ASA 5505", family: .network, category: "Firewall",
                     summary: "Firewall clásico de escritorio; no es un chasis de 19 pulgadas. Modelo 3D exterior aproximado.",
                     size: SIMD3(0.2004, 0.0445, 0.1745),
                     ports: "Switch integrado de 8 puertos Fast Ethernet 10/100, 2 de ellos con PoE; 3 USB 2.0: 1 frontal y 2 posteriores.",
                     sourceURL: URL(string: "https://www.cisco.com/c/en/us/products/collateral/security/asa-5500-series-next-generation-firewalls/datasheet-c78-733510.html")!, sourceTitle: "Cisco ASA 5505 Adaptive Security Appliance Data Sheet"),
        HardwareItem(id: "server-c220m5", name: "Cisco UCS C220 M5 SFF", family: .computing, category: "Servidor de rack de 1 U",
                     summary: "Chasis SFF con capacidad de hasta 10 bahías de 2,5 pulgadas. Se ilustra esa configuración; ocupación y adaptadores varían. Exterior 3D aproximado.",
                     size: SIMD3(0.429, 0.0432, 0.757), ports: "2 puertos LOM 10GBASE-T. El montaje de referencia equipa dos fuentes intercambiables.",
                     sourceURL: URL(string: "https://www.cisco.com/c/en/us/products/collateral/servers-unified-computing/ucs-c-series-rack-servers/datasheet-c78-739281.html")!, sourceTitle: "Cisco UCS C220 M5 Rack Server Data Sheet — chasis SFF",
                     dimensionsSourceURL: URL(string: "https://www.cisco.com/c/en/us/td/docs/unified_computing/ucs/c/hw/C220M5/install/C220M5/C220M5_appendix_011.html")!),
        HardwareItem(id: "server-firewall", name: "Cisco UCS C220 M5 SFF · nodo firewall", family: .network,
                     category: "Servidor de seguridad de 1 U",
                     summary: "Chasis UCS con interfaces dedicadas a red interna, tránsito y estado HA en el plano.",
                     size: SIMD3(0.429, 0.0432, 0.757), ports: "Tres RJ45 etiquetados en la plantilla. Alimentación A/B.",
                     sourceURL: URL(string: "https://www.cisco.com/c/en/us/products/collateral/servers-unified-computing/ucs-c-series-rack-servers/datasheet-c78-739281.html")!,
                     sourceTitle: "Cisco UCS C220 M5 Rack Server Data Sheet"),
        HardwareItem(id: "phone-7960", name: "Cisco IP Phone 7960G", family: .network, category: "Teléfono IP",
                     summary: "Teléfono clásico con 6 botones programables de línea/función y 4 teclas contextuales. Modelo 3D exterior aproximado.",
                     size: nil, ports: "2 conexiones Ethernet 10/100BASE-T RJ45 para red y PC, y conexión dedicada de auriculares.",
                     sourceURL: URL(string: "https://www.cisco.com/web/ANZ/cpp/refguide/hview/ipt/phone.html")!, sourceTitle: "Cisco Unified IP Phones 7900 Series — CP-7960G"),
        HardwareItem(id: "raspberry-pi5", name: "Raspberry Pi 5", family: .computing, category: "Controlador de servicios",
                     summary: "Representación de placa con disipador sobre bandeja ventilada. Tamaño exterior de la envolvente del montaje.",
                     size: SIMD3(0.10, 0.029, 0.077), ports: "Ethernet, alimentación USB-C, USB y GPIO.",
                     sourceURL: URL(string: "https://www.raspberrypi.com/products/raspberry-pi-5/")!,
                     sourceTitle: "Raspberry Pi · Raspberry Pi 5"),
        HardwareItem(id: "access-point", name: "Punto de acceso Wi-Fi", family: .network, category: "AP con SSID y VLAN",
                     summary: "Envolvente de montaje de referencia. Vincula el SSID IoT a la VLAN 50 y el de clientes a la VLAN 30.",
                     size: SIMD3(0.16, 0.032, 0.16), ports: "RJ45 Ethernet de subida. Alimentación local o inyector compatible.",
                     sourceURL: URL(string: "https://www.wi-fi.org/discover-wi-fi")!, sourceTitle: "Wi-Fi Alliance · Wi-Fi"),
        HardwareItem(id: "camera-ip", name: "Cámara IP RTSP", family: .network, category: "Videovigilancia · Ethernet",
                     summary: "Modelo de referencia con lente, iluminadores y soporte regulable. Elige posición y medidas según el equipo instalado.",
                     size: SIMD3(0.082, 0.076, 0.132), ports: "RJ45 Ethernet. Alimentación local o inyector compatible.",
                     sourceURL: URL(string: "https://www.onvif.org/profiles/profile-t/")!, sourceTitle: "ONVIF · Profile T"),
        HardwareItem(id: "pc-optiplex7010", name: "Dell OptiPlex 7010 Mini Tower (2012)", family: .computing, category: "Computadora de prueba",
                     summary: "PC físico de referencia; Packet Tracer representa PCs genéricos. Modelo 3D exterior aproximado.",
                     size: SIMD3(0.175, 0.36, 0.417),
                     ports: "1 Ethernet RJ45; 6 USB 2.0 (2 frontales y 4 posteriores) y 4 USB 3.0 (2 frontales y 2 posteriores).",
                     sourceURL: URL(string: "https://www.dell.com/support/manuals/es-pe/optiplex-7010/opti7010_usff/specifications?guid=guid-157e8495-34d3-4efa-ab61-1d9efba4c90e&lang=en-us")!, sourceTitle: "Dell OptiPlex 7010 — Specifications, columna Mini Tower"),
        HardwareItem(id: "laptop-latitude5420", name: "Dell Latitude 5420", family: .computing, category: "Laptop de prueba",
                     summary: "Laptop física de referencia. Dimensiones del chasis cerrado, con altura posterior máxima; exterior 3D abierto aproximado.",
                     size: SIMD3(0.32135, 0.0209, 0.212),
                     ports: "2 USB 3.2 Gen 1 (1 con PowerShare), 2 Thunderbolt 4/USB4 con DisplayPort y Power Delivery, 1 HDMI 2.0, 1 RJ45 y audio.",
                     sourceURL: URL(string: "https://www.dell.com/support/manuals/es-pe/latitude-5420-laptop/5420_sp14_setupspecs/ports-and-connectors?guid=guid-38d3f374-dd76-4ab5-97ec-d5a0aa87bd32&lang=en-us")!, sourceTitle: "Dell Latitude 5420 — Ports and connectors",
                     dimensionsSourceURL: URL(string: "https://www.dell.com/support/manuals/es-pe/latitude-5420-laptop/5420_sp14_setupspecs/dimensions-and-weight?guid=guid-7df32f47-45cf-4a08-ad99-b01eec4f3ce6&lang=en-us")!)
    ]

    static func item(_ id: String) -> HardwareItem? { items.first { $0.id == id } }

    static let infrastructure: [HardwareItem] = [
        HardwareItem(id: "ups-9px", name: "Eaton 9PX3000IRT2U", family: .power, category: "UPS de doble conversión · 2 U",
                     summary: "Referencia de chasis para el banco A y el banco B. La potencia y autonomía se dimensionan con la carga del sitio.",
                     size: SIMD3(0.44, 0.0865, 0.605), ports: "Alimentación AC, salidas IEC y conector para módulo de batería.",
                     sourceURL: URL(string: "https://www.eaton.com/gb/en-gb/skuPage.9PX3000IRT2U.html")!, sourceTitle: "Eaton · 9PX3000IRT2U"),
        HardwareItem(id: "battery-9px", name: "Eaton 9PXEBM72RT2U", family: .power, category: "Batería de expansión · 2 U",
                     summary: "Módulo de referencia de 72 V. La cantidad de módulos de la plantilla es ilustrativa.",
                     size: SIMD3(0.44, 0.0865, 0.605), ports: "Interfaz de batería de expansión del UPS compatible.",
                     sourceURL: URL(string: "https://www.eaton.com/gb/en-gb/skuPage.9PXEBM72RT2U.html")!, sourceTitle: "Eaton · 9PXEBM72RT2U"),
        HardwareItem(id: "cooling-inrow", name: "Schneider Uniflair ACRD301P", family: .cooling, category: "Refrigeración en fila · DX",
                     summary: "Unidad interior de referencia. El condensador remoto y la capacidad bajo fallo requieren cálculo y levantamiento del sitio.",
                     size: SIMD3(0.300, 1.991, 1.095), ports: "Circuito frigorífico hacia condensador exterior, drenaje, alimentación y control.",
                     sourceURL: URL(string: "https://www.apc.com/us/en/product/ACRD301P/")!, sourceTitle: "Schneider Electric · ACRD301P")
    ]

    static let byFamily = Dictionary(grouping: items + infrastructure, by: \.family)

    static func reference(_ id: String) -> HardwareItem? {
        item(id) ?? infrastructure.first { $0.id == id }
    }

    static func renderSize(_ id: String) -> SIMD3<Float> {
        if let size = reference(id)?.size { return size }
        switch id {
        case "phone-7960": return SIMD3(0.19, 0.08, 0.23)
        default: preconditionFailure("Uncatalogued hardware: \(id)")
        }
    }
}

nonisolated enum RackMount {
    static let unit: Float = 0.04445
    static let base: Float = 0.105
    static let frontInset: Float = 0.082

    static func units(_ model: String) -> Int {
        switch model {
        case "router-1941", "router-2911", "firewall-asa5505", "ups-9px": 2
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
}
