# CISCO NEXUS AR

<!-- impeccable:product-schema 1 -->

## Platform

ios

App principal iPhone. Utilidad macOS independiente para convertir Packet Tracer; Unity como
compañero opcional, sin formar parte del flujo móvil obligatorio.

## Stack

SwiftUI, RoomPlan, ARKit y RealityKit, con geometría, distribución y topología en Swift.
Persistencia JSON local. Exportador AppKit/Python con packet-tracer-pkt-format==0.4.1, GPL separado
del ejecutable iPhone. Sin servidor, cuentas, subidas ni sincronización obligatoria.
Unity 6.6 y URP se conservan para inspección de escritorio.

## Users

Estudiantes que exploran equipos, enlaces y datos de un laboratorio individual sin internet.
Configuraciones inspeccionables como texto; ejecutar protocolos, servicios, CLI y prácticas
evaluadas sigue fuera de esta revisión.

## Product Purpose

Generar un laboratorio en iPhone desde su cuarto, una sala de servidores de prueba o una topología
exportada de Packet Tracer. Explorar 3D/AR, seleccionar equipos/cables y consultar hardware,
IPv4, VLAN, servicios descriptivos y configuración disponible.

## Operating Context

- MacBook Pro M4 de 14 pulgadas e iPhone 16 Pro con iOS 27.
- Mi cuarto: escanear→guardar estructura→distribuir→AR 1:1 con la sesión conservada.
- Plantilla Tier IV: 16 × 12 × 3,5 m, seis racks TI, UPS/baterías A/B, cuatro InRow, tres puestos de operación, 31 equipos y 41 enlaces. Se puede aplicar a un cuarto con contorno y acceso compatibles.
- Importación: .pkt→exportador Mac local→.nexus.json→**Importar topología exportada**.
- Demo/importaciones: 3D y Maqueta AR 1:10, colocada por toque en superficie mediante
  ARWorldTracking independiente del escaneo.
- Paredes/suelo blancos opcionales en AR. Los muebles físicos permanecen; no se procesa vídeo
  para borrarlos. En 3D los muros se cortan a 0,65 m; AR conserva altura capturada.
- Restauración del laboratorio activo en 3D. Sin mapa AR persistente: cuarto requiere nuevo
  escaneo tras reiniciar y maquetas nueva colocación.
- Evitar duplicación remota simultánea de DeviceHub durante captura/AR; coincidió con cámara
  negra incluso en Cámara de iOS en el incidente observado.

## Capabilities and Constraints

Diez referencias físicas con fuentes oficiales y exteriores aproximados; fichas por instancia,
encendido visual y cables seleccionables: cobre azul y fibra naranja, con conectores y codos.
La vista 3D incluye zoom +/− y enfoca el equipo al inspeccionarlo.
Red y conexiones muestra extremos/puertos/VLAN. Alias importados preservan modelo e interfaces
originales. SMTP/IMAP, DNS, HTTP, aplicaciones, backup y monitorización son datos descriptivos.
Sin ejecución Cisco IOS, sistemas operativos, routing, VLAN, paquetes o servicios simulados.

Cuarto: máximo seis racks/dos puestos según geometría. Importación: 8 MiB, 96 equipos, 192 enlaces,
hasta 12 racks/24 puestos. Modelos, puertos y medios no admitidos generan error. Rack pasivo como
colocación; genéricos PT conservan identidad y usan referencias visuales del catálogo.

RoomPlan estima medidas; sin calibración manual ni precisión garantizada. La distribución no
certifica seguridad o instalación. La demo ilustra conceptos Tier IV: mantenibilidad concurrente,
tolerancia a fallos, aislamiento físico y refrigeración continua; sin diseño constructivo ni
certificación. Sus 16 × 12 m no son exigencia normativa.
[Fuente: Uptime Institute](https://uptimeinstitute.com/tiers).

## Brand Commitments

Nombre solicitado CISCO NEXUS AR; interfaz Nexus AR. Identidad propia, tipografía y controles
nativos, acento azul, paredes y suelos blancos. Diez referencias reconocibles para enseñanza
inspirada en Packet Tracer. No presentar como producto oficial Cisco, CAD certificado, ranking
mundial de popularidad, emulador completo o centro de datos certificado.

## Evidence on Hand

Proyecto 0.3.0 (build 3). Builds de simulador/dispositivo aprobados y actualización instalada en
iPhone 16 Pro; el lanzamiento automático quedó detenido por el bloqueo del teléfono. QA final en
simulador aprobó restaurar demo al relanzar, 6 racks/2 puestos/34 equipos/44 enlaces, inspección de
instancia/puertos y enlaces, enfoque y toque directo de puerto 3D con extremos correctos.
Checks de estructura/geometría/distribución/topología/importación aprobados; captura real con
11 equipos/10 enlaces. QA previo vertical/horizontal/texto grande/oscuro.

Usuario confirmó cámara visible y AR anclada tras cerrar DeviceHubViewScreen. Diagnóstico local:
hasCurrentFrame true y seguimiento normal. No acredita precisión métrica, rendimiento universal
ni todos los flujos. Utilidad Mac compilada, firma ad hoc y --help comprobados. Retest GUI con
Python en Application Support aprobado: exportación de cinco equipos/cuatro enlaces en menos
de dos segundos en esta prueba; LabImport validó tres colocaciones. Watchdog de 120 segundos.
Pendientes: prueba física de Maqueta AR 1:10 de la nueva versión y precisión métrica/rendimiento
comparativo. Unity, Hub, DeviceHub, Xcode y exportador quedaron cerrados; simuladores apagados.

Fuentes en [HardwareCatalog.swift](NativeCapture/Sources/HardwareCatalog.swift). Capturas y última
importación en sandbox; configuración importada puede incluir credenciales del original.
Diagnósticos de estado sin fotos ni coordenadas. Datos reales, entornos y builds fuera de Git.

## Product Principles

1. Resultado móvil automático, conservando el escaneo si falla la distribución.
2. Distinguir cuarto medido, sala sintética y escala AR 1:1/maqueta 1:10.
3. Conservar identidad/configuración importada sin ejecutarla ni atribuir hardware ficticio.
4. Distinguir especificaciones cotejadas, medidas estimadas y representación visual.
5. No presentar cables, indicadores y etiquetas como motor de red implementado.

## Accessibility & Inclusion

SwiftUI/AppKit nativos, áreas seguras, texto adaptable, hojas navegables y acento único.
Elementos de la escena y Red y conexiones ofrecen acceso a equipos y cables desde listas.
QA de orientación/texto grande/oscuro en simulador no sustituye validación física completa.
