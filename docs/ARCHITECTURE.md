# Arquitectura de CISCO NEXUS AR

App iPhone 0.3.0 (build 3): SwiftUI, RoomPlan, ARKit y RealityKit. Unity es opcional.
Exportador Packet Tracer macOS GPL independiente, comunicado por JSON; sus dependencias Python
no se incorporan al ejecutable iPhone.

## Entradas y estado

| Entrada | Generación | AR |
| --- | --- | --- |
| Captura RoomPlan | Guardar estructura→distribución→topología educativa | 1:1, sesión conservada |
| Sala de prueba | Sala sintética fija 16×12×3,5 m | Maqueta 1:10 colocada en superficie |
| .nexus.json | Validación→sala/distribución sintética | Maqueta 1:10 colocada en superficie |

Guardar estructura antes del planificador conserva el escaneo si falla la distribución.
Importar valida y distribuye antes de reemplazar el guardado. Preferencia activeLaboratory
recuerda scan/demo/imported; al restaurar se abre en 3D.

## Responsabilidades

| Archivo | Responsabilidad |
| --- | --- |
| NexusRoomCaptureApp.swift | Flujo SwiftUI, laboratorio activo, importación, modos y hojas |
| CaptureController.swift | Permisos, RoomPlan, sesión, restauración y diagnóstico |
| RoomPlanExport.swift / RoomStructure.swift | Contrato estructural, validación y escritura atómica |
| LabLayout.swift | Geometría, triangulación y distribución del cuarto |
| LabTopology.swift | Dispositivos, enlaces, VLAN, validación y fábricas |
| LabImport.swift | Límites de entrada, nueva distribución y persistencia |
| LabScene.swift | Modelos RealityKit, cámaras, selección, rutas por guías/bandejas y seguimiento AR |
| LabStereoView.swift | Vista virtual por ojo y orientación con el giroscopio del iPhone |
| TopologyInspector.swift | Instancias, enlaces, datos de red y criterios Tier IV |
| HardwareCatalog.swift | Diez referencias y fuentes oficiales |
| Tools/PacketTracerExporter/ | Conversor .pkt Python y GUI AppKit independiente |

Archivos Swift en NativeCapture/Sources. No existe motor de red. La topología es un valor
independiente del renderer, pero no calcula protocolos, alcance, políticas ni servicios.

## Coordenadas y geometría

RoomStructure JSON v1 guarda identificador, fecha ISO8601, metros, marco nativo dextrógiro con
Y vertical y superficies RoomPlan: dimensiones, matriz column-major, contorno y pared padre.
Sin mobiliario ni fotos. Curvas pueden conservarse como datos; el renderer no admite toda
geometría curva/inclinada ni completa superficies ausentes.

La ARSession de RoomCaptureView se conserva al terminar con stop(pauseARSession: false).
RealityKit reutiliza ese origen para AR 1:1 y muestra los equipos con seguimiento normal. El visor
lee la transformación de la cámara para dibujar posición y dirección en el plano. La oclusión LiDAR
permite que la geometría física tape equipos virtuales. La vista 3D orbital corta muros a 0,65 m.

Demo/importación usan otra ARWorldTrackingConfiguration, detección de superficie y colocación
por toque. Escala de escena 0,1, rotulada Maqueta AR 1:10; no se alinea artificialmente al cuarto.
El ARWorldMap se guarda con el ID del cuarto al alcanzar mapeo suficiente. Tras reiniciar, la sesión
1:1 lo carga y espera a que ARKit recupere el origen. La maqueta requiere nueva colocación.

Planificador del cuarto: suelo válido, altura, huellas y accesos, sin solapamientos, máximo
seis racks/dos puestos. Heurística determinista de pasillo recto, no optimizador ni certificación.
RoomPlan aporta medidas estimadas; no hay editor manual de dimensiones.

## Topología y render

LabTopology contiene nombre, dispositivos, enlaces, VLAN y notas. Dispositivo: identidad, modelo,
placementID, offset de centro local, IPv4/VLAN opcionales, servicios y puertos. sourceModel,
configuration y sourcePortNames conservan identidad/configuración/interfaces PT originales.
El renderer transforma centro y puertos por posición/yaw de la colocación.

Enlace: dos IDs/puertos, medio y VLAN. Validación: IDs únicos, modelos, puertos, ocupación única,
extremos distintos, IPv4, VLAN/subred y medio compatible. Validación espacial: soportes, suelo,
límites y solapamientos. No comprueba forwarding, STP, negociación de velocidad ni configuración IOS.
Consola/energía no tienen host/conectores verificados en este catálogo y no generan enlaces admitidos.

R42612 se dibuja desde placement, nunca como dispositivo activo dentro de otro rack. Modelos
procedurales exteriores, tamaños cotejados sólo donde existen en catálogo. Cobre azul/fibra naranja
tienen codos, conectores, selección y ficha de extremos; no son instalación certificada ni tráfico.

Plantilla: 192 m² de ejemplo, seis racks de TI, dos gabinetes de energía, cuatro InRow y tres puestos.
`TierFacility.fit` registra la planta sobre el origen RoomPlan sin cambiar escalas. Los 46 equipos activos y
70 circuitos de red conservan su identidad. Los tramos físicos conservan el ID de circuito. Energía y climatización viven en la escena de infraestructura.
`switchedPath` atraviesa switches y el par correspondiente de cada patch panel, respetando puertos
deshabilitados. Las PCs y laptops abren una consola al seleccionarlas. Los cambios de nombres,
direcciones, interfaces y dominios persisten por plantilla e ID de equipo.

[Tier IV de Uptime Institute](https://uptimeinstitute.com/tiers) incluye mantenibilidad concurrente,
tolerancia a fallos, aislamiento físico y refrigeración continua. Sin diseño constructivo ni
certificación en la demo; 16×12 m es ejemplo, no una dimensión normativa.

## HomeLab y cámaras

`LabDemo.homeLab` comparte la topología y la escala entre los visores. Si parte de RoomPlan, ajusta
la distribución en coordenadas del escaneo. Al colocar en el piso, el centro del rack se registra
con un ARAnchor nombrado en el ARWorldMap local. La escena se activa cuando el seguimiento es normal
y se reconoce el ancla. `LabTravelView` usa una cámara de primera persona y colisiones con el
contorno y huellas de los equipos. En estéreo ambas vistas usan la misma posición de recorrido.

[Guía de montaje y operación](../Tools/Operations/README.md)

## Packet Tracer y límites

Nexus Packet Exporter.app usa diálogos AppKit y Process fuera del hilo principal para ejecutar
Python local, sin shell, servidor o subidas. Bundle con código, licencia y exportador; Info.plist
guarda la ruta absoluta del intérprete. Por defecto usa
~/Library/Application Support/NexusPacketExporter/python/bin/python;
NEXUS_PYTHON_EXECUTABLE permite elegir otra ruta al construir. El entorno se movió desde Documents
tras observar arranque bloqueado leyendo pyvenv.cfg. Watchdog de 120 segundos termina procesos
que exceden ese tiempo. Firma ad hoc local, sin notarización; reconstruir copia el exportador final.

Python fija packet-tracer-pkt-format==0.4.1. Valida contenedor y convierte modelos/medios admitidos.
Server-PT, PC-PT y Laptop-PT conservan identidad y se dibujan con referencias del catálogo.
Modelos desconocidos, actividades y evaluaciones se rechazan. Configuración como texto; GPL/Python
fuera del target Swift. Límites del contenedor y campos en README del exportador.

iPhone: hasta 8 MiB, 96 dispositivos, 192 enlaces, 64 VLAN. Descarta coordenadas externas y asigna
hasta 12 racks/24 puestos en sala sintética con separación de huellas. No inserta importaciones
en el cuarto medido. Errores conservan el laboratorio anterior.

## Persistencia y diagnóstico

- Documentos/Captures: estructuras atómicas con nombre único, guardadas antes de planificar.
- Documentos/Labs/last-import.nexus.json: última importación válida, guardada atómicamente.
- activeLaboratory: selección a restaurar; demo regenerada, importación redistribuida.
- Documentos/Diagnostics/capture-status.json: permiso, fase, configuración, frame, seguimiento
  y tamaño de preview. Sin fotografías ni coordenadas de la habitación.

JSON importado puede conservar credenciales del original: revisar antes de compartir.
Datos reales, builds y entornos fuera de Git. Encendido temporal, sin configuración de red
persistida. Fuentes externas del catálogo requieren conectividad.

El incidente de cámara negra también aparecía en Cámara de iOS con DeviceHubViewScreen abierta.
Cerrar la duplicación restauró imagen; usuario confirmó AR anclada y diagnóstico mostró frame
disponible/seguimiento normal. Evitar duplicación simultánea en pruebas de captura/AR.

## Evidencia y pendientes

Checks de estructura, geometría, distribución, topología e importación aprobados: JSON, determinismo,
puertos y rechazos. Captura real: 11 equipos/10 enlaces. Builds finales 0.3.0 (3) de simulador y
dispositivo aprobados; actualización instalada en iPhone. El bloqueo del teléfono impidió lanzamiento
automático final, por lo que falta abrir la app y probar Maqueta AR 1:10 físicamente.

QA final de simulador aprobado: restauración de demo al relanzar; seis racks/dos puestos/34 equipos/
44 enlaces; Red y conexiones→puertos→inspector de enlace; foco desde menú y toque directo de puerto
3D que resolvió Teléfono SW→2960 Fa0/1. Incluye zoom +/− y enfoque al inspeccionar. Orientación,
texto grande y oscuro revisados previamente.

Retest GUI Python Application Support aprobado en menos de dos segundos en esta prueba: .pkt→JSON
con cinco dispositivos/cuatro enlaces; LabImport validó tres colocaciones. Utilidad compilada,
firma ad hoc y --help comprobados. Unity, Hub, DeviceHub, Xcode y exportador cerrados al terminar;
inventario de simuladores arrancados vacío.

Confirmación previa de cámara/AR 1:1 no certifica precisión métrica ni rendimiento comparativo;
estas mediciones y la prueba física de Maqueta AR 1:10 quedan pendientes. Futuro: motor de red
calculado, subconjunto CLI y prácticas probadas; no atribuir
esos comportamientos a las fichas/cables actuales.
