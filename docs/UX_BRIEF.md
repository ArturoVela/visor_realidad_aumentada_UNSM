# Experiencia móvil de Nexus AR

Revisión 0.3.0 (build 3): cuarto escaneado, sala de servidores e importación Packet Tracer.
La interfaz distingue espacio medido, sala sintética y maqueta AR; no presenta una representación
educativa como instalación real ni red funcionando.

## Flujos

| Entrada | Acciones | Resultado |
| --- | --- | --- |
| Mi cuarto | Escanear→Terminar y generar | Blanco/equipos; AR 1:1 tras captura nueva |
| Sala de prueba | Más opciones→Sala de servidores de prueba | 192 m², seis racks/dos puestos |
| Packet Tracer | Exportador Mac→AirDrop→Importar topología exportada | Sala sintética con datos del proyecto |

Escanear no requiere Mac. Guardar estructura antes de distribuir conserva el escaneo ante fallo.
Al reiniciar se restaura en 3D el laboratorio activo; AR 1:1 necesita nuevo escaneo.
Demo/importaciones ofrecen Maqueta AR 1:10: apuntar a superficie y tocar para colocar.

En 3D se gira y acerca la vista con gestos, +/− y restablecimiento; inspeccionar enfoca el equipo.
AR sigue el teléfono;
zoom 3D no cambia la escala física del cuarto. La maqueta muestra escala 1:10 e instrucción de
colocación. Se puede volver al cuarto sin borrar la última importación.

## Explorar equipos y red

Tocar hardware abre la instancia: referencia, IPv4, VLAN, servicios y configuración cuando existen.
Puertos originales PT se conservan como alias de conectores visuales. Fuentes oficiales distinguen
especificaciones de geometría aproximada.

Cobre azul/fibra naranja se distinguen también por nombre y ficha. Cables con conectores y codos;
selección muestra equipos, puertos y VLAN. **Red y conexiones** ofrece esos datos en lista;
**Mostrar cables** controla visibilidad. **Elementos colocados** permite abrir racks/puestos
sin acertar sobre hardware pequeño.

Encendido modifica indicadores/pantallas. DNS, SMTP/IMAP, HTTP, aplicaciones, backup y monitorización
son descripciones. No se promete tráfico, comandos ni Cisco IOS; configuración importada es texto
y nunca se ejecuta.

Demo: 34 equipos, 44 enlaces y cinco VLAN. **Criterios Tier IV** explica mantenibilidad concurrente,
tolerancia a fallos, aislamiento físico y refrigeración continua, con
[fuente Uptime Institute](https://uptimeinstitute.com/tiers). No presenta certificación ni 16×12 m
como norma de construcción.

## Composición y accesibilidad

SwiftUI, áreas seguras, controles nativos, hojas navegables, texto adaptable y acento azul.
La escena lidera; datos y acciones están en controles/fichas. Estructura blanca y hardware oscuro.
Información textual alternativa a colores y selección de objetos/cables.

En 3D los muros se cortan a 0,65 m; AR conserva altura y permite desactivar **Paredes y suelo blancos**.
Los muebles siguen físicamente presentes: blanco no significa espacio libre para caminar.

Orientación, texto grande y oscuro revisados previamente en simulador. Últimos controles/zoom,
enfoque e inspección de puertos/enlaces pasaron QA final en simulador. Es evidencia de esos flujos,
no una acreditación de accesibilidad o responsividad universal.

## Estados y recuperación

| Estado | Respuesta |
| --- | --- |
| Restaurando | Progreso mientras recupera el laboratorio activo en 3D |
| Preparando cámara | Permiso y errores con recuperación |
| Capturando | Guía RoomPlan, cancelar y terminar |
| Generando | Estado de creación; escaneo conservado antes del planificador |
| Sin espacio/geometría inválida | Aviso/repetir; no reducir hardware para forzarlo |
| Importando | Validación y nueva distribución antes de reemplazar el guardado |
| Importación rechazada | Explica formato/límites/modelo; conserva laboratorio anterior |
| Preparando maqueta | Apuntar a superficie y tocar para colocar |
| Seguimiento limitado | Mensaje contextual, sin presentar alineación como confirmada |
| Listo | Explorar, seleccionar, volver al cuarto o abrir otro laboratorio |

Cancelar conserva capturas previas. Última importación y laboratorio activo se recuperan localmente;
sin mapa AR persistente. Encendido temporal no se presenta como red guardada.

## Utilidad Mac

Nexus Packet Exporter ofrece diálogos nativos para elegir .pkt y guardar .nexus.json; loading
sin bloquear interfaz, errores del conversor, **Mostrar archivo** y **Exportar otro**.
El proceso tiene límite de 120 segundos para no mantener una conversión bloqueada indefinidamente.
Al terminar orienta a AirDrop y **Importar topología exportada** en iPhone.
La configuración conservada puede incluir datos que revisar antes de compartir.
Sin servidor, cuentas o subidas; modelos no admitidos producen error.

## Evidencia y pendientes

Usuario confirmó cámara visible y AR anclada tras cerrar DeviceHubViewScreen. También fallaba
Cámara de iOS mientras la duplicación estaba abierta; diagnóstico posterior con frame disponible y
seguimiento normal. Evitar duplicación remota simultánea. Diagnósticos sin fotos ni coordenadas.

Retest GUI con Python en Application Support aprobado: .pkt→JSON en menos de dos segundos en esta
prueba; cinco equipos/cuatro enlaces y tres colocaciones validadas por LabImport.
QA final de simulador aprobó restaurar demo tras relanzar, cantidades 6/2/34/44, navegar desde
Red y conexiones a puertos/enlaces, enfoque de rack y tocar puerto 3D para abrir el enlace correcto
Teléfono SW→2960 Fa0/1.

Builds finales aprobados y actualización 0.3.0 (3) instalada en iPhone; lanzamiento automático
detenido por teléfono bloqueado. Quedan prueba física de Maqueta AR 1:10 de esta versión y medición
de precisión métrica/rendimiento comparativo. AR 1:1/cámara habían sido confirmadas previamente.
Unity, Hub, DeviceHub, Xcode y exportador cerrados; simuladores apagados para la prueba física.
