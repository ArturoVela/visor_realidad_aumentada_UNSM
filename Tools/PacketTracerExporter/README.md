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

`configuration` es texto: configuración original seguida, cuando corresponde, por un bloque de
metadatos claramente rotulado. La app no debe ejecutarlo como comandos IOS.

## Modelos admitidos

| Modelo Packet Tracer | Referencia de la app |
| --- | --- |
| 2960-24TT / 2960-24TT-L | switch-2960 |
| 3560-24PS | switch-3560 |
| 1941 / 2911 | router-1941 / router-2911 |
| 5505 / ASA5505 | firewall-asa5505 |
| 7960 / 7960G | phone-7960 |
| Server-PT | server-c220m5 |
| PC-PT | pc-optiplex7010 |
| Laptop-PT | laptop-latitude5420 |

Servidor, PC y laptop genéricos usan referencias visuales del catálogo; no se convierten en ese
hardware físico. El rack es una colocación que genera la app, no un equipo inferido del archivo.
Un modelo desconocido genera error explícito. Medios importables: cobre y fibra compatibles con
los conectores documentados. En 3560 los dos uplinks Gigabit son fibra en el catálogo actual.
Consola genera error: no hay un host serie documentado entre los diez modelos; no se inventa RS232
en los Dell. Otros medios y enlaces sin cable también generan error.

PC/Laptop `FastEthernet0` o `GigabitEthernet0` se representa como `Ethernet`; Server-PT usa `LOM1`.
Sólo se habilita `LOM2` si el archivo contiene al menos dos interfaces y nombra esa segunda interfaz.
Teléfono `Switch` se representa como `SW`. Puertos Cisco admitidos conservan su nombre completo.
Interfaces lógicas (VLAN, subinterfaces, loopback) quedan en configuración, no como conectores físicos.

## Contrato y límites

Objeto raíz: `name`, `devices`, `links`, `vlans`, `notes`, compatible con `LabTopology`.
Cada equipo lleva `placementID: "unplaced"` y `offset: [0,0,0]`; la app asigna ubicación al importar.
No se importan coordenadas físicas de Packet Tracer al cuarto escaneado.

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
