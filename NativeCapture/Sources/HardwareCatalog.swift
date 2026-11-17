import Foundation

nonisolated struct HardwareItem: Identifiable, Sendable {
    let id: String
    let name: String
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
        HardwareItem(id: "rack-r42612", name: "Cisco R42612", category: "Rack de 42 U",
                     summary: "Rack físico de referencia. Dimensiones externas sin embalaje; representación 3D aproximada, no plano de ingeniería certificado.",
                     size: SIMD3(0.597, 2.013, 1.266), ports: "Gabinete pasivo; la conectividad depende de los equipos montados.",
                     sourceURL: URL(string: "https://www.cisco.com/c/en/us/products/collateral/servers-unified-computing/r-series-racks/datasheet-c78-738217.html")!, sourceTitle: "Cisco R42612 Rack Data Sheet — tabla 2"),
        HardwareItem(id: "switch-2960", name: "Cisco Catalyst 2960-24TT-L", category: "Switch de acceso",
                     summary: "Referencia histórica para prácticas de switching. Modelo 3D exterior aproximado.",
                     size: nil, ports: "24 Ethernet 10/100BASE-T y 2 uplinks Ethernet 10/100/1000BASE-T.",
                     sourceURL: URL(string: "https://www.cisco.com/c/en/us/td/docs/switches/lan/catalyst3750/software/release/12-2_50_se/release/notes/OL18263.html")!, sourceTitle: "Cisco IOS 12.2(50)SE Release Notes — Supported Hardware"),
        HardwareItem(id: "switch-3560", name: "Cisco Catalyst 3560-24PS", category: "Switch multicapa",
                     summary: "Familia clásica para prácticas de VLAN y enrutamiento; sin asumir licencia de software. Modelo 3D exterior aproximado.",
                     size: nil, ports: "24 Ethernet 10/100 con PoE y 2 ranuras para módulos SFP.",
                     sourceURL: URL(string: "https://www.cisco.com/c/en/us/td/docs/switches/lan/catalyst3750/software/release/12-2_50_se/release/notes/OL18263.html")!, sourceTitle: "Cisco IOS 12.2(50)SE Release Notes — Supported Hardware"),
        HardwareItem(id: "router-1941", name: "Cisco ISR 1941", category: "Router",
                     summary: "Router clásico ISR G2 de 2 U. Capacidades de software dependen de licencia y configuración; exterior 3D aproximado.",
                     size: SIMD3(0.3429, 0.0889, 0.2921),
                     ports: "2 Gigabit Ethernet RJ45; 2 ranuras EHWIC; 2 USB-A; consola mini-USB y RJ45; AUX. Sin SFP integrado.",
                     sourceURL: URL(string: "https://www.cisco.com/c/en/us/products/collateral/routers/1900-series-integrated-services-routers-isr/data_sheet_c78_556319.html")!, sourceTitle: "Cisco 1941 Integrated Services Routers Data Sheet — tabla 7"),
        HardwareItem(id: "router-2911", name: "Cisco ISR 2911", category: "Router",
                     summary: "Router clásico ISR G2 modular de 2 U. Capacidades de software dependen de licencia y configuración; exterior 3D aproximado.",
                     size: SIMD3(0.4382, 0.0889, 0.3048),
                     ports: "3 Gigabit Ethernet RJ45; 4 ranuras EHWIC y 1 SM; 2 USB 2.0; consola USB y serie; AUX. Sin SFP integrado.",
                     sourceURL: URL(string: "https://www.cisco.com/c/en/us/products/collateral/routers/2900-series-integrated-services-routers-isr/data_sheet_c78_553896.html")!, sourceTitle: "Cisco 2900 Series Integrated Services Routers Data Sheet — tabla 7"),
        HardwareItem(id: "firewall-asa5505", name: "Cisco ASA 5505", category: "Firewall",
                     summary: "Firewall clásico de escritorio; no es un chasis de 19 pulgadas. Modelo 3D exterior aproximado.",
                     size: SIMD3(0.2004, 0.0445, 0.1745),
                     ports: "Switch integrado de 8 puertos Fast Ethernet 10/100, 2 de ellos con PoE; 3 USB 2.0: 1 frontal y 2 posteriores.",
                     sourceURL: URL(string: "https://www.cisco.com/c/en/us/products/collateral/security/asa-5500-series-next-generation-firewalls/datasheet-c78-733510.html")!, sourceTitle: "Cisco ASA 5505 Adaptive Security Appliance Data Sheet"),
        HardwareItem(id: "server-c220m5", name: "Cisco UCS C220 M5 SFF", category: "Servidor de rack de 1 U",
                     summary: "Chasis SFF con capacidad de hasta 10 bahías de 2,5 pulgadas. Se ilustra esa configuración; ocupación y adaptadores varían. Exterior 3D aproximado.",
                     size: nil, ports: "2 puertos LOM 10GBASE-T integrados con Intel X550; conexiones adicionales dependen de los adaptadores instalados.",
                     sourceURL: URL(string: "https://www.cisco.com/c/en/us/products/collateral/servers-unified-computing/ucs-c-series-rack-servers/datasheet-c78-739281.html")!, sourceTitle: "Cisco UCS C220 M5 Rack Server Data Sheet — chasis SFF"),
        HardwareItem(id: "phone-7960", name: "Cisco IP Phone 7960G", category: "Teléfono IP",
                     summary: "Teléfono clásico con 6 botones programables de línea/función y 4 teclas contextuales. Modelo 3D exterior aproximado.",
                     size: nil, ports: "2 conexiones Ethernet 10/100BASE-T RJ45 para red y PC, y conexión dedicada de auriculares.",
                     sourceURL: URL(string: "https://www.cisco.com/web/ANZ/cpp/refguide/hview/ipt/phone.html")!, sourceTitle: "Cisco Unified IP Phones 7900 Series — CP-7960G"),
        HardwareItem(id: "pc-optiplex7010", name: "Dell OptiPlex 7010 Mini Tower (2012)", category: "Computadora de prueba",
                     summary: "PC físico de referencia; Packet Tracer representa PCs genéricos. Modelo 3D exterior aproximado.",
                     size: SIMD3(0.175, 0.36, 0.417),
                     ports: "1 Ethernet RJ45; 6 USB 2.0 (2 frontales y 4 posteriores) y 4 USB 3.0 (2 frontales y 2 posteriores).",
                     sourceURL: URL(string: "https://www.dell.com/support/manuals/es-pe/optiplex-7010/opti7010_usff/specifications?guid=guid-157e8495-34d3-4efa-ab61-1d9efba4c90e&lang=en-us")!, sourceTitle: "Dell OptiPlex 7010 — Specifications, columna Mini Tower"),
        HardwareItem(id: "laptop-latitude5420", name: "Dell Latitude 5420", category: "Laptop de prueba",
                     summary: "Laptop física de referencia. Dimensiones del chasis cerrado, con altura posterior máxima; exterior 3D abierto aproximado.",
                     size: SIMD3(0.32135, 0.0209, 0.212),
                     ports: "2 USB 3.2 Gen 1 (1 con PowerShare), 2 Thunderbolt 4/USB4 con DisplayPort y Power Delivery, 1 HDMI 2.0, 1 RJ45 y audio.",
                     sourceURL: URL(string: "https://www.dell.com/support/manuals/es-pe/latitude-5420-laptop/5420_sp14_setupspecs/ports-and-connectors?guid=guid-38d3f374-dd76-4ab5-97ec-d5a0aa87bd32&lang=en-us")!, sourceTitle: "Dell Latitude 5420 — Ports and connectors",
                     dimensionsSourceURL: URL(string: "https://www.dell.com/support/manuals/es-pe/latitude-5420-laptop/5420_sp14_setupspecs/dimensions-and-weight?guid=guid-7df32f47-45cf-4a08-ad99-b01eec4f3ce6&lang=en-us")!)
    ]

    static func item(_ id: String) -> HardwareItem? { items.first { $0.id == id } }
}
