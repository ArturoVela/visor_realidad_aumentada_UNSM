# Aplicación nativa Nexus AR

App iPhone 0.3.0 (build 3), SwiftUI/RoomPlan/ARKit/RealityKit sin paquetes externos.
Cuarto escaneado, sala virtual e importación; hardware/cables seleccionables, fichas y vistas 3D/AR.
Unity es opcional y no ejecuta la vista móvil.

Proyecto/esquema NexusRoomCapture. Bundle org.unsm.NexusRoomCapture. Deployment target iOS 17.
Entorno comprobado: Xcode 27.2, SDK iOS 27.2, Swift 6.4.2, iPhone 16 Pro con iOS 27.0.

Builds finales de simulador/dispositivo aprobados y actualización instalada en iPhone 16 Pro.
El lanzamiento automático quedó detenido por el bloqueo del teléfono; falta abrirla y comprobar
Maqueta AR 1:10. Cámara y AR 1:1 habían sido confirmadas previamente por el usuario.
QA final de interfaz aprobado en simulador; éste no valida LiDAR ni AR física.

## Ejecutar y explorar

Abrir NexusRoomCapture.xcodeproj, elegir equipo propio en Signing & Capabilities y ejecutar en
iPhone compatible con RoomPlan. La captura solicita permiso de cámara.

- **Escanear→Terminar y generar:** guarda estructura y genera hasta seis racks/dos puestos según
  suelo, altura y accesos. Captura nueva abre AR 1:1 con su sesión conservada.
- **Sala de servidores de prueba:** desde Más opciones. 16×12×3,5 m, 192 m², seis racks/dos puestos,
  34 equipos/44 enlaces, VLAN 10/20/30/40/50. Sala sintética independiente del cuarto.
- **Importar topología exportada:** selecciona .nexus.json convertido en Mac; valida y redistribuye.
  Coordenadas PT no se usan como medidas reales.
- **Cuarto 3D:** girar, acercar con gestos o +/−, enfocar al inspeccionar y restablecer.
  Muros cortados visualmente a 0,65 m; archivo/AR
  conservan altura original.
- **Maqueta AR 1:10:** demo/importación; apuntar a superficie y tocar para colocar. Sesión propia,
  sin escaneo previo necesario.

Tocar equipo/cable abre datos. **Red y conexiones**/**Elementos colocados** ofrecen acceso en lista.
Cobre azul/fibra naranja con conectores y codos; fichas de extremos, IPv4, VLAN, servicios y
configuración importada. Encendido sólo modifica indicadores/pantallas.

SMTP/IMAP, DNS, HTTP, aplicaciones, backup y monitorización son descriptivos. Sin ejecución Cisco IOS,
CLI, VLAN, routing, paquetes o servicios. Cables dibujados no prueban conectividad calculada.

## Sesiones y persistencia

- CaptureController conserva sesión RoomCaptureView al terminar con stop(pauseARSession: false).
  RealityKit reutiliza coordenadas nativas para AR 1:1.
- Demo/importación: ARWorldTrackingConfiguration independiente, escala de escena 0,1.
- Sin ARWorldMap ni anclajes persistidos. Reinicio restaura 3D: AR del cuarto necesita nuevo
  escaneo; maqueta nueva colocación.
- Documentos/Captures: estructuras atómicas con nombre único, guardadas antes de planificar.
  Fallo de distribución conserva escaneo compartible; cancelar conserva capturas anteriores.
- Documentos/Labs/last-import.nexus.json: última importación validada, escrita atómicamente.
- activeLaboratory: cuarto/demo/importación; demo regenerada e importación redistribuida al restaurar.
- Documentos/Diagnostics/capture-status.json: permisos, fase, configuración, frame, seguimiento,
  tamaño del preview. Sin fotografías ni coordenadas del cuarto.

Cámara negra observada también en Cámara de iOS con DeviceHubViewScreen. Cerrar la duplicación
restauró imagen; usuario confirmó AR anclada y diagnóstico indicó frame disponible/seguimiento
normal. Evitar duplicación remota simultánea durante captura/AR.

## Contratos

RoomStructure JSON v1: schemaVersion, source, units, coordinateSystem, roomID, capturedAt ISO8601,
surfaces. Paredes, puertas, ventanas, accesos y suelo, con dimensiones, transformación column-major,
contorno, padre y curva opcional. Sin muebles/fotos. Metros, marco nativo dextrógiro, Y vertical y
origen de sesión. Conservar curvas no implica poder dibujarlas.

LabTopology: name, devices, links, vlans, notes. Instancia: identidad, modelo visual, colocación/centro
local, puertos y datos opcionales. sourceModel/configuration/sourcePortNames conservan modelo,
configuración e interfaces originales; no se ejecutan. Enlaces validan extremos, puertos,
ocupación, medios, IPv4 y VLAN.

LabImport: hasta 8 MiB, 96 equipos, 192 enlaces, 64 VLAN y distribución de hasta 12 racks/24 puestos.
Modelos/conectores no admitidos o datos excesivos producen error. Catálogo de diez modelos;
R42612 es colocación pasiva, no dispositivo activo importado. Genéricos Server-PT/PC-PT/Laptop-PT
conservan identidad y usan hardware del catálogo como representación.

## Convertir Packet Tracer en Mac

[Nexus Packet Exporter](../Tools/PacketTracerExporter/README-Mac.md), herramienta GPL-3.0-or-later
separada con AppKit/Python y packet-tracer-pkt-format==0.4.1. Elegir .pkt, guardar .nexus.json,
AirDrop al iPhone y **Importar topología exportada**. Sin servidor/subidas; GPL/Python fuera del
target iPhone. JSON puede conservar credenciales del original: revisar antes de compartir.
Modelos desconocidos, actividades y evaluaciones producen error.
El entorno Python local preparado está en ~/Library/Application Support/NexusPacketExporter/python;
NEXUS_PYTHON_EXECUTABLE permite cambiar intérprete al construir la utilidad. Hay un límite de
120 segundos por exportación. No se instala ni descarga Python desde la app iPhone.

## Comprobaciones reproducibles

Desde NativeCapture/:

    /usr/bin/xcrun swiftc Sources/RoomStructure.swift Tests/RoomStructureCheck.swift -o /tmp/nexus-room-structure-check
    /tmp/nexus-room-structure-check
    /usr/bin/xcrun swiftc Sources/RoomStructure.swift Sources/LabLayout.swift Tests/LabLayoutCheck.swift -o /tmp/nexus-lab-layout-check
    /tmp/nexus-lab-layout-check
    /usr/bin/xcrun swiftc Sources/RoomStructure.swift Sources/HardwareCatalog.swift Sources/LabLayout.swift Sources/LabTopology.swift Tests/LabTopologyCheck.swift -o /tmp/nexus-lab-topology-check
    /tmp/nexus-lab-topology-check
    /usr/bin/xcrun swiftc Sources/RoomStructure.swift Sources/HardwareCatalog.swift Sources/LabLayout.swift Sources/LabTopology.swift Sources/LabImport.swift Tests/LabImportCheck.swift -o /tmp/nexus-lab-import-check
    /tmp/nexus-lab-import-check
    /usr/bin/xcodebuild -project NexusRoomCapture.xcodeproj -scheme NexusRoomCapture -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/NexusRoomCaptureDerivedData CODE_SIGNING_ALLOWED=NO build

Checks de geometría/topología admiten captura real opcional como primer argumento.
Cubren contratos, contención, accesos, determinismo, JSON, puertos/medios/VLAN y datos inválidos.
Captura proporcionada: 11 equipos/10 enlaces en check. QA previo orientación/texto grande/oscuro.
QA final de simulador: restaurar demo al relanzar, seis racks/dos puestos/34 equipos/44 enlaces,
Red y conexiones→puertos→extremos/medio/VLAN, zoom, enfoque desde menú y toque directo de puerto 3D
abriendo correctamente Teléfono SW→2960 Fa0/1.

Retest GUI Mac con Python Application Support aprobado: .pkt→JSON en menos de dos segundos en esta
prueba; cinco equipos/cuatro enlaces y tres colocaciones validadas por LabImport.
Pendientes: Maqueta AR 1:10 física en la versión instalada y mediciones de precisión métrica y
rendimiento comparativo. Al terminar: Unity, Hub, DeviceHub, Xcode y exportador cerrados, simuladores apagados.

## Límites físicos y educativos

RoomPlan estima medidas. Sin editor manual ni optimización total. Curvas, suelos inclinados y
capturas incompletas pueden generar errores/avisos; no se completan muros o accesos ausentes.
El blanco puede ocultar muebles en pantalla que siguen físicamente presentes.

Demo ilustra A/B sin PDU o fuentes inventadas.
[Tier IV](https://uptimeinstitute.com/tiers): mantenibilidad concurrente, tolerancia a fallos,
aislamiento físico y refrigeración continua; sin diseño constructivo ni certificación.
16×12 m es ejemplo, no norma. Fuentes en [HardwareCatalog.swift](Sources/HardwareCatalog.swift);
[arquitectura general](../docs/ARCHITECTURE.md).
