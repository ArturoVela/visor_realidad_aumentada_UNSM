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
  suelo, altura y accesos. Captura nueva abre **Recorrer en AR** a escala 1:1 con la cámara activa.
  El plano muestra posición y dirección. Al apuntar a un cable o puerto conectado, pulsa **¿Adónde va?**
  para resaltar la ruta y ver equipo, puerto y ubicación de cada extremo.
- **Plantilla Tier IV:** sala virtual de 16×12×3,5 m, seis racks de TI, dos gabinetes de UPS y baterías,
  cuatro unidades InRow y tres puestos de operación. **Aplicar plantilla al cuarto** conserva la escala
  física si el contorno, altura y acceso medidos admiten la distribución.
- **Recorrer mi cuarto en AR:** desde la plantilla, aplica un escaneo con referencia AR o inicia uno nuevo.
  Espera **Anclado al cuarto · 1:1** y camina para ver los equipos desde ángulos distintos. Los controles,
  la mira y la ficha del cable se superponen a la cámara sin cambiar su encuadre. Si se pierde la posición,
  apunta a zonas reconocibles del escaneo o usa **Volver a alinear el cuarto** si el mapa está guardado.
- En **Cuarto y archivos → Importar topología exportada**, elige el .nexus.json convertido en Mac.
  La app valida y redistribuye los equipos mientras muestra el progreso. Las coordenadas de
  Packet Tracer se descartan al calcular la distribución.
- **Cuarto 3D:** girar, acercar con gestos o +/−, enfocar al inspeccionar y restablecer.
  Muros cortados visualmente a 0,65 m; archivo/AR
  conservan altura original.
- **Escala AR:** HomeLab y Plantilla Tier IV ofrecen 1:1, 1:2, 1:5, 1:10 y 1:20. Abre **Escala** en
  la vista 3D o antes de tocar para colocar. Cada opción muestra ancho, fondo, alto y superficie
  de la sala virtual. Una vez colocado, usa **Volver a colocar modelo** para elegir otra escala.
  Si abriste la plantilla sobre un escaneo, **Configurar maqueta AR** abre la vista independiente.
  Las importaciones mantienen su maqueta AR a 1:10.
- **Recorrido 3D:** desplázate con el control circular y arrastra la escena para mirar.
- En **Más opciones → Vista y recorrido**, **Modo VR** ofrece vista de una pantalla en vertical
  y horizontal y vista opcional para gafas en horizontal. Activa el control de movimiento del iPhone para orientar la mirada.
- **HomeLab Proxmox:** abre **Montar HomeLab** para colocar el rack a escala 1:1 en el piso, ajustar
  la planta a un cuarto escaneado o consultar la guía. [Servicios, NAS, NVR y automatizaciones](../Tools/Operations/README.md).
- **Operación desde el visor.** Toca una PC, su pantalla o la laptop para abrir la consola del plano.
  **Sitios** muestra 38 dominios asignados. La consola guarda nombres, IPv4, estado de puertos y destino de sitios por plantilla.

**Fijar equipo** está en el recorrido de una pantalla y en AR. Su menú permite elegir por mira
o por proximidad. Las flechas recorren los equipos según su orden en el rack y en la sala.
En AR se conserva el seguimiento del iPhone. En el recorrido 3D, la vista gira hacia el equipo
desde la posición actual y un arrastre devuelve el control de la mirada.

**Flujo simulado** representa ida en verde y retorno en naranja. Las luces verdes junto a los
puertos representan enlace, y las naranjas, actividad del ejemplo. La escena limita cuántos
circuitos anima simultáneamente y prioriza el trazado o el equipo fijado. Reducir movimiento
muestra el flujo en posiciones fijas. El menú permite apagar los pulsos.

Al abrir **Recorrido 3D**, la leyenda muestra los colores del cableado presente, el resaltado
y las dos direcciones del flujo. Pulsa **Entrar al recorrido** y toca el encabezado para
consultarla de nuevo. Los pulsos respetan el
grosor del cable y limitan su tamaño proyectado cuando te acercas. En una ficha de conexión,
toca un extremo o uno de los puertos de un tramo para encuadrarlo desde su lado y conservar
el circuito resaltado. La ficha de equipo también permite volver a su ubicación en la escena.

Tocar un equipo abre su ficha. En **Más opciones → Equipos**, **Equipos disponibles** muestra el
catálogo por familia y **Elementos de la escena** abre los racks, puestos y sus dispositivos.
Racks de 42 U con rieles, equipos montados y bandeja para el firewall de sobremesa. Los modelos se
generan con geometría y materiales propios a partir de referencias de catálogo. Cobre azul y fibra
naranja salen de sus puertos hacia guías interiores y bandejas. Fichas de extremos, IPv4, VLAN,
servicios y configuración importada. Encendido sólo modifica indicadores/pantallas.

La plantilla calcula el camino de los tres PCs al servidor LAB en VLAN 20. El servicio HTTP y los
clientes se ejecutan fuera de iOS. [Red de pruebas](../Tools/TierLab/README.md)

## Monitores y pruebas de las plantillas

- **Monitores de 14 pulgadas.** Cada servidor de las plantillas tiene una pantalla con base anclada al suelo, poste lateral, brazo articulado y placa VESA. Tócala o elige **Monitores de servidores** desde el menú de red, o desde **Ajustes de fijación** en el recorrido. El deslizador cambia entre estado, red y servicios. El apagado simulado afecta al tráfico y a los caminos de red.
- **Encuadre frontal.** En recorrido 3D y VR, fija un equipo y usa las flechas para moverte al próximo frente despejado. La inspección de un puerto conserva su lado físico. En AR la cámara se mueve contigo.
- **Red.** Tier IV cuenta con un par de firewalls de borde y otro de segmentación. En consola prueba `test <equipo> <puerto>` y `resolve <dominio>`. **Red y conexiones** exporta el CSV de los tramos con etiqueta, VLAN, extremos, largo y radio del modelo.
- **Sitios.** Desde **Cuarto y archivos → Sitios e inventarios** crea sitios y reabre importaciones. Los escaneos se guardan por sitio. El historial de configuración guarda hasta 20 cambios por plantilla y sitio. Puedes deshacer el último y exportar la ficha desde el monitor.
- **Referencia AR.** HomeLab y Tier IV guardan el punto de colocación por sitio y escala en un mapa AR. **Recalibrar punto de referencia** permite volver a marcar el piso. En iPhone con LiDAR, **Oclusión con espacio real** usa la malla de ARKit.
- **Infraestructura.** Generación exterior A/B en la sala virtual, módulos UPS y baterías, refrigeración en fila y bandejas. **Infraestructura y pruebas** registra escenarios simulados de mantenimiento, transferencia y continuidad térmica.

## Sesiones y persistencia

- CaptureController conserva sesión RoomCaptureView al terminar con stop(pauseARSession: false).
  RealityKit reutiliza coordenadas nativas para AR 1:1.
- Maquetas e importaciones usan una sesión ARWorldTrackingConfiguration independiente del escaneo.
- El mapa ARKit se guarda por ID de cuarto cuando hay suficiente seguimiento. Vive en Application
  Support/RoomWorldMaps con protección de archivos, fuera de la copia de seguridad y del JSON compartido.
  Tras reiniciar, abre **Recorrer en AR** en el mismo cuarto. El modelo aparece cuando ARKit recupera el origen.
  Capturas anteriores sin mapa requieren un escaneo nuevo. Las maquetas requieren nueva colocación.
  El HomeLab colocado en el piso guarda un mapa propio con su ancla 1:1. Volver al mismo sitio
  requiere que ARKit reconozca la ubicación nuevamente.
- Para verificar el recorrido físico en Debug, Library/Caches/NexusWalkthrough.json registra la máxima
  distancia del teléfono y del anclaje desde la primera muestra del recorrido 1:1 de la plantilla.
  El archivo local contiene la hora y distancias relativas. El simulador verifica el visor 3D y el encaje.
- Documentos/Captures: estructuras atómicas con nombre único, guardadas antes de planificar.
  Fallo de distribución conserva escaneo compartible; cancelar conserva capturas anteriores.
- Documentos/Labs/last-import.nexus.json: última importación validada, escrita atómicamente.
- activeLaboratory: escaneo, plantillas o importación. HomeLab ajustado al escaneo se reconstruye con el contorno guardado.
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

La infraestructura dibuja PDU, doble fuente y ATS de referencia, y aplica radios de modelo de 32 mm
para cobre y 40 mm para fibra. Para construir, valida el radio del producto seleccionado, los
pasamuros, soportes y separación según el proyecto, además de cargas y pruebas de fallo. Los
generadores, combustible y condensadores requieren levantamiento exterior y dimensionamiento.
[Tier IV](https://uptimeinstitute.com/tiers): mantenibilidad concurrente, tolerancia a fallos,
aislamiento físico y refrigeración continua; sin diseño constructivo ni certificación.
16×12 m es ejemplo, no norma. Fuentes en [HardwareCatalog.swift](Sources/HardwareCatalog.swift);
[arquitectura general](../docs/ARCHITECTURE.md).
