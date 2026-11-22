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

### Demo de VLAN y ping

Abre **Demo de VLAN y ping** desde el inicio o **Más opciones → Plantillas de laboratorio**.
En **Probar ping**, toca cada pareja y usa **Ver en escena** para seguir los cables.

| Prueba | Resultado inicial | Recorrido |
| --- | --- | --- |
| PC-A → PC-B | 4 de 4 respuestas | VLAN 10 por el troncal 802.1Q. |
| PC-A → PC-C | 0 de 4 respuestas | R-VLAN descarta la solicitud ICMP de A mediante `NEXUS-ICMP-IN`. |
| PC-B → PC-C | 4 de 4 respuestas | R-VLAN enruta de la VLAN 10 a la 20. |

- **Red.** PC-A usa `192.168.10.11`, PC-B usa `192.168.10.12` y PC-C usa `192.168.20.13`, con máscara `/24` y puerta de enlace `.1` en sus VLAN. En consola usa `ping PC-C`, `show interfaces trunk` en SW-A o `show running-config` en R-VLAN.
- **Alimentación y pantallas.** El rack de 24 U reúne dos switches, router, servidor, patch panel, ventilación, UPS y PDU. Las pantallas laterales muestran tráfico y servicios de SRV-DEMO. Abre **Más opciones → Elementos de la escena → Rack de prácticas → UPS-01** y activa **Simular corte de alimentación**. Repite un ping y desactiva el corte para restaurar la red.
- **Servicios y visor.** Desde PC-B, `resolve demo.lab` y `test SRV-DEMO 80` prueban DNS y HTTP. En la copia editable, usa PC-B para solicitar DHCP en la VLAN 10. Explora en 3D, recorrido o VR. En un iPhone compatible, abre la vista AR y coloca el laboratorio.

### Otras plantillas y captura

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
- En **Más opciones → Laboratorios guardados**, abre, renombra y organiza los laboratorios recibidos
  del Mac o importados en el sitio activo. Puedes pausar su flujo simulado, archivarlos o moverlos a
  la papelera y recuperarlos desde el menú de la biblioteca.
- En **Más opciones → Archivos**, **Importar topología exportada** abre un .nexus.json. Nexus AR usa
  las áreas y conexiones de Packet Tracer para distribuir equipos sobre puestos y racks de referencia.
- Desde **Plantilla Tier IV**, abre **Colocar en AR** para elegir racks, servidores, puestos completos,
  PC, portátiles, equipos de red, bancos de UPS y baterías, tableros eléctricos o refrigeración.
  Busca por nombre y coloca el equipo sobre una superficie. En iOS 18 o posterior puedes mostrar
  el contexto atenuado.
- En **Montajes AR**, elige **Por piso** o **Por arriba** antes de colocar una pieza. **Colocar todo**
  aplica esa elección a las piezas nuevas. Puedes cambiarla para una pieza desde sus opciones.
  Selecciona un equipo y pulsa **Ajustar** para moverlo o girarlo con el joystick. **Listo** guarda
  la posición y el ángulo en ese montaje. **Cancelar** restaura la posición y el ángulo anteriores.
  Mientras ajustas la pieza, sus cables y las canaletas se actualizan con ella.
  Los enlaces entre soportes comparten canaletas y una subida entre niveles. Las conexiones internas
  de un soporte pasan por su guía local. Si la ruta simulada queda sin espacio para su radio de
  referencia, el visor pide revisar el trazado.
  En 3D y AR, cada cable de cobre usa el diámetro exterior nominal de 5,69 mm del
  [Belden 2412](https://www.belden.com/products/cable/ethernet-cable/category-6-cable/2412).
  Cada tramo compartido conserva los cables individuales, con separación y guías dimensionadas
  según su ocupación. Las canaletas terminan en la entrada del rack o en la salida del puesto.
  Los latiguillos siguen los organizadores del rack con tramos horizontales y verticales.
  Cada extremo de cobre muestra el conector RJ45 encajado en su puerto en 3D y RA.
  Los codos unen la base y los laterales de la canaleta y dejan el recorrido a la vista.
  Las bifurcaciones usan cajas de derivación.
  El visor marca las guías sin capacidad suficiente con un objetivo de ocupación del 40 % para
  este modelo. Los recorridos que no admiten su radio de referencia se señalan para revisión.
  El modelo sirve para planificar recorridos con base en la [EM.020 del RNE](https://www.gob.pe/institucion/vivienda/informes-publicaciones/2309793-reglamento-nacional-de-edificaciones-rne),
  [TIA-569](https://tiaonline.org/standard/tia-569/)
  e [ISO/IEC 14763-2](https://www.iso.org/standard/73337.html). La conformidad de una instalación requiere
  medidas del lugar, especificaciones del cable y revisión en obra.
- En la vista **3D**, pulsa **Organizar en 3D**, elige un rack o puesto y usa **Mover** o **Girar**.
  El cableado y las canaletas siguen al equipo durante el ajuste. **Guardar** conserva la
  distribución 3D. Activa **Sincronizar con AR** y elige un montaje que ya tenga el equipo
  colocado para trasladar a ese montaje el mismo desplazamiento y giro al guardar.
  Desde **Gestos de cámara** puedes consultar los atajos. Arrastra con un dedo para orbitar,
  usa dos para desplazar, ampliar o girar, y usa tres para una órbita más precisa.
  Un toque con cuatro dedos restablece el encuadre.
- Los modelos propios de ISR 1941, 2811 y 2911 y Catalyst 2960, 3560 y 3650 se usan en AR y 3D.
  Las fichas Cisco de cada equipo están en el catálogo de Nexus. Los módulos serie aparecen
  donde el archivo trae interfaces para ese módulo.
- En **Montajes AR → Red**, crea una copia editable. La copia aparece en **Laboratorios** y conserva
  su montaje. Añade racks de 12, 24 o 42 U y monta servidores en unidades libres. Desde **Editar cables**
  puedes cambiar de canaleta, ajustar hasta cuatro puntos de paso o desconectar un enlace.
- En el montaje, toca un puerto libre o abre **Conectar en AR → Elegir puerto**. El origen queda
  resaltado. Toca o elige un destino compatible para que Nexus acomode y guarde el cable.
  Para cobre o fibra en un rack, Nexus usa el par libre del patch panel compatible más cercano
  y lleva el tramo exterior por detrás. Completa hasta tres niveles de panel en 42 U, dos en 24 U
  y uno en 12 U según las unidades disponibles.
  Al abrir plantillas y laboratorios guardados, Nexus completa los paneles y conserva los puertos
  de origen y destino de los enlaces. Las importaciones de Packet Tracer también montan los equipos
  compatibles en racks con paneles.
- En RA, selecciona un rack de hasta 16 U y abre **Ajustar → Altura**. Mueve el control hacia arriba
  o abajo y pulsa **Listo**. Los equipos, paneles y cables acompañan al rack. En racks mayores de
  16 U, **Ajustar** ofrece **Girar**.
  La huella se marca en rojo al apuntar a un espacio ocupado y Nexus detiene el ajuste al topar con otro equipo.
  **Canaleta y VLAN** ajusta las opciones antes de elegir el destino.
  En un cable con puntos de paso, **Arrastrar puntos en AR** permite moverlos sobre la
  altura del tendido. El punto vuelve a su posición guardada si la nueva ruta queda sin espacio.
- Selecciona un rack y pulsa **Rack**. Toca una unidad frontal para montar equipo compatible,
  o toca un costado para añadir pantallas vinculadas a un servidor. **Unidades** y **Pantallas**
  ofrecen los mismos controles mediante una lista. Las pantallas laterales siguen al rack al moverlo.
- Configura **DNS**, **DHCP** y **HTTP** en el mismo servidor si lo necesitas. **Probar servicios**
  verifica la concesión, el registro A y la respuesta HTTP en la VLAN simulada. **Añadir pantalla**
  vincula una pantalla colocable al panel de estado, red o servicios del servidor.
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

- **Monitores de 14 pulgadas.** Cada servidor de las plantillas tiene una pantalla con base anclada al suelo, poste lateral, brazo articulado y placa VESA. Tócala o elige **Monitores de servidores** en **Más opciones**, dentro de **Red y conexiones**. En el recorrido, ábrelo desde **Ajustes de fijación**. En **Ajustes del monitor**, elige la vista y el formato del gráfico. **Automático** usa anillos para CPU y memoria, y columnas para el tráfico de red. La configuración se guarda por servidor y sitio y también se aplica a la pantalla del visor. El apagado simulado afecta al tráfico y a los caminos de red.
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

LabImport admite hasta 8 MiB, 96 equipos, 192 enlaces y 64 VLAN. Conserva el plano de origen cuando
está disponible y genera una sala de hasta 12 racks y 24 puestos. PC-PT, Laptop-PT y Server-PT se
representan con modelos Dell y Cisco de referencia. Su ficha identifica el modelo original y la
referencia 3D. Se mantienen los puertos, la configuración y los enlaces registrados, incluidos los seriales WAN.

## Convertir Packet Tracer en Mac

[Nexus Packet Exporter](../Tools/PacketTracerExporter/README-Mac.md), herramienta GPL-3.0-or-later
separada con AppKit/Python y packet-tracer-pkt-format==0.4.1. La acción de Finder **Enviar a Nexus Home**
convierte y guarda el laboratorio en el iPhone emparejado con Xcode. También se puede exportar el
.nexus.json manualmente. GPL/Python quedan fuera del target iPhone.
Modelos desconocidos, actividades y evaluaciones producen error.
El entorno Python local preparado está en ~/Library/Application Support/NexusPacketExporter/python;
NEXUS_PYTHON_EXECUTABLE permite cambiar intérprete al construir la utilidad. Hay un límite de
120 segundos por exportación. No se instala ni descarga Python desde la app iPhone.

## Comprobaciones reproducibles

Desde NativeCapture/:

    /usr/bin/xcrun swiftc Sources/RoomStructure.swift Tests/RoomStructureCheck.swift -o /tmp/nexus-room-structure-check
    /tmp/nexus-room-structure-check
    /usr/bin/xcrun swiftc Sources/RoomStructure.swift Sources/HardwareCatalog.swift Sources/LabLayout.swift Sources/LabTopology.swift Sources/LabARAssembly.swift Tests/LabLayoutCheck.swift -o /tmp/nexus-lab-layout-check
    /tmp/nexus-lab-layout-check
    /usr/bin/xcrun swiftc Sources/RoomStructure.swift Sources/HardwareCatalog.swift Sources/LabLayout.swift Sources/LabTopology.swift Sources/LabARAssembly.swift Tests/LabTopologyCheck.swift -o /tmp/nexus-lab-topology-check
    /tmp/nexus-lab-topology-check
    /usr/bin/xcrun swiftc Sources/RoomStructure.swift Sources/HardwareCatalog.swift Sources/LabLayout.swift Sources/LabTopology.swift Sources/LabARAssembly.swift Sources/LabImport.swift Tests/LabImportCheck.swift -o /tmp/nexus-lab-import-check
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
