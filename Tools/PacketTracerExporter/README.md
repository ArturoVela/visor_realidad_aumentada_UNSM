# Exportador Packet Tracer → Nexus

Herramienta CLI independiente para Mac, Python 3.10 o posterior. Convierte un laboratorio local
`.pkt` a datos `.nexus.json` para importar en la app. Funciona offline y no necesita abrir Packet Tracer.
No ejecuta configuraciones ni contacta equipos, servidores o servicios de red.

## Uso

Con `packet-tracer-pkt-format==0.4.1` instalado en el Python que ejecutes:

```sh
python export_pkt.py mi-laboratorio.pkt -o mi-laboratorio.nexus.json
```

La carpeta de salida debe existir. Un archivo existente se conserva; para sustituirlo usa `--force`.
La escritura es atómica. El `.pkt` original se conserva. Para preparar otro entorno Python, instalar
las versiones de `requirements.txt`; el exportador nunca instala paquetes automáticamente.

## Qué conserva

- Dispositivos, nombres y modelos originales (`sourceModel`). Los extremos se resuelven por
  `dev_addr`, nunca por nombre, orden ni coordenadas del lienzo.
- Puertos declarados en cables/configuración, adaptados al nombre de conector del catálogo.
  `sourcePortNames` conserva el nombre original Packet Tracer de cada conector representado.
  La biblioteca no expone nombres para todos los puertos desconectados: esos puertos no se inventan.
- IPv4 principal, VLAN explícita, configuración IOS como texto y metadatos de interfaces/servicios
  accesibles en el archivo. Si existen varias IPv4, todas quedan en metadatos de configuración.
- VLAN declaradas, nombres y subredes de SVI/subinterfaces cuando se identifican explícitamente.
  Access/dot1Q etiquetan los enlaces; el texto completo de trunks se conserva para inspección.
- Posiciones lógicas, áreas rectangulares, colores y etiquetas del lienzo raíz. Los puertos
  Serial WAN de los módulos de 2811 y 2911 conservan su numeración del archivo.

`configuration` es texto: configuración original seguida, cuando corresponde, por un bloque de
metadatos claramente rotulado. La app no debe ejecutarlo como comandos IOS.

## Modelos admitidos

| Modelo Packet Tracer | Referencia de la app |
| --- | --- |
| 2960-24TT / 2960-24TT-L | switch-2960 |
| 3560-24PS | switch-3560 |
| 3650-24PS | switch-3650 |
| 1941 / 2811 / 2911 | router-1941 / router-2811 / router-2911 |
| 5505 / ASA5505 | firewall-asa5505 |
| 7960 / 7960G | phone-7960 |
| Server-PT | pt-server |
| PC-PT | pt-desktop |
| Laptop-PT | pt-laptop |
| AccessPoint-PT | pt-access-point |
| Printer-PT, TabletPC-PT, SMARTPHONE-PT y Power Distribution Device | Formas y medidas ilustrativas de cada tipo |

Los ocho tipos genéricos conservan su identidad y usan modelos 3D ilustrativos. Medios importables
son cobre, fibra y Serial WAN compatibles con los conectores admitidos. Los uplinks Gigabit
de 3560 y las ranuras SFP de 3650 se validan como fibra. Los enlaces de consola, los medios
no admitidos y los modelos desconocidos generan un error explícito.

PC/Laptop/Printer `FastEthernet0` o `GigabitEthernet0` y AccessPoint-PT `Port 0` se representan como
`Ethernet`. Server-PT usa `Ethernet` y añade `Ethernet 2` si el archivo declara ambas interfaces.
Teléfono `Switch` se representa como `SW`. Puertos Cisco admitidos conservan su nombre completo.
Interfaces lógicas (VLAN, subinterfaces, loopback) quedan en configuración, no como conectores físicos.

## Contrato y límites

El JSON contiene `name`, `devices`, `links`, `vlans`, `notes` y, cuando está disponible,
`logicalPlan` con coordenadas del lienzo. Los cables conservan el tipo de origen en `sourceCableType`.
Cada equipo puede incluir `packetTracer` con su descripción, sus interfaces IPv4 y sus pools DHCP.
El exportador recupera una IPv4 ausente si el archivo identifica el servidor DHCP y contiene una única concesión válida para la MAC del cliente. Conserva la configuración IOS y los registros de los pools para consulta.
Cada equipo lleva `placementID: "unplaced"` y `offset: [0,0,0]`. Nexus AR usa el plano lógico
y los enlaces del archivo para distribuir puestos y racks en una sala 3D de referencia.

Máximos: 16 MiB de entrada, 32 MiB de XML descomprimido, 8 MiB de salida, 96 equipos, 192 enlaces,
64 VLAN, nombres de hasta 160 caracteres y 64 KiB de configuración por equipo. Se rechazan puertos ocupados por dos cables,
direcciones internas ausentes/duplicadas y extremos que no se puedan resolver.

Se decodifican contenedores modernos y legacy reconocidos por la dependencia. Esquemas antiguos
que no expongan identificadores/campos necesarios producen error; no se reconstruyen por suposición.
`.pka`, actividades renombradas y evaluaciones se rechazan. No se extraen respuestas ni puntuaciones.
El JSON puede conservar credenciales presentes en la configuración original: permanece local y
debes revisar su contenido antes de compartirlo.

## Comprobación

```sh
python -B test_export.py
```

Genera una práctica propia temporal con dos PCs, switch 2960, router 1941 y servidor; crea `.pkt`
moderno y legacy con la biblioteca, decodifica y comprueba extremos, VLAN, IP, servicios y errores.
No incluye laboratorios de terceros ni archivos de evaluaciones. Los temporales se eliminan.

## Licencia y dependencia

Este directorio se distribuye bajo **GPL-3.0-or-later**; consulta [LICENSE](LICENSE).
Usa [packet-tracer-pkt-format](https://github.com/aacanadaa/packet-tracer-pkt-format), versión 0.4.1,
de aacanadaa, bajo GPL-3.0-or-later. `LICENSE` es copia íntegra de la licencia incluida en su distribución.
La dependencia no está vendorizada. La herramienta y sus imports permanecen fuera de la app Swift;
su intercambio con la app consiste únicamente en archivos JSON.
