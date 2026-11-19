# HomeLab Proxmox

La plantilla representa un HomeLab de un nodo. El visor muestra el equipo, el cableado físico y el plan de red. La aplicación de prueba corre fuera de iOS en un Mac, Linux o una VM Debian.

## 1. Valida el servicio en local

Desde la raíz del repositorio, con Python 3.9 o posterior:

```sh
python3 Tools/HomeLab/lab.py self-test
python3 Tools/HomeLab/lab.py serve --database /tmp/nexus-home-inventory.sqlite
```

Con el servicio en ejecución, abre [el portal local](http://127.0.0.1:8080/) o ejecuta en otra terminal:

```sh
python3 Tools/HomeLab/lab.py check
curl -fsS http://127.0.0.1:8080/metrics
```

| Ruta | Comportamiento |
| --- | --- |
| `/` | Portal con accesos a las pruebas |
| `/healthz` | HTTP 200 si SQLite responde. HTTP 503 si los datos están inaccesibles |
| `/api/inventory` | Lee el inventario persistente en SQLite |
| `/metrics` | Contador real de solicitudes y tamaño del inventario en formato Prometheus |

## 2. Coloca la plantilla y revisa el recorrido

En Nexus AR, abre **HomeLab Proxmox → Montar HomeLab**. **Elegir punto en el piso** coloca el centro del rack frente a ti a escala 1:1. Despeja la zona real, toca el piso y sigue moviendo la cámara hasta que la ubicación quede guardada. Para volver, abre **AR 1:1** en la misma habitación y apunta a las superficies que viste al colocarlo. Con LiDAR, **Escanear un cuarto** ajusta la distribución a las paredes medidas. Para esta planta reserva 4,32 × 3,4 m libres y 2,1 m de altura. El ajuste usa el contorno medido. Comprueba muebles y obstáculos en el cuarto.

Usa **Recorrido 3D** para caminar virtualmente con el control de movimiento y arrastrar para mirar. En **Modo VR** gira el teléfono según prefieras y, en horizontal, toca el icono de gafas para usar la vista estereoscópica. Toca equipos para ver su configuración. En AR, apunta a un cable o a un puerto conectado y toca **¿Adónde va?**. La ficha muestra los tramos y los puertos F/R del panel.

## 3. Monta el equipo y conecta los puertos

| Unidades desde abajo | Equipo | Medida aproximada del chasis (ancho × alto × fondo) |
| --- | --- | --- |
| U18 | PP-CAT6, panel pasante 24 puertos en rack de 19″ | 445 × 43 × 100 mm |
| U16 | SW-HOME, Catalyst 2960-24TT-L | 445 × 44 × 236 mm |
| U12–13 | GW-HOME, Cisco ISR 2911 | 438 × 89 × 305 mm |
| U8 | PVE-01, Cisco UCS C220 M5 | 429 × 43 × 757 mm |
| U6 | NAS-01, segundo chasis UCS C220 M5 | 429 × 43 × 757 mm |
| U1–2 | UPS-01, Eaton 9PX3000IRT2U | 440 × 87 × 605 mm |

El gabinete de referencia exterior mide 600 × 950 × 1.020 mm. Ajusta la distancia entre rieles a los kits del fabricante y comprueba el espacio para conectores y extracción de equipos. Confirma carga, anclaje, ventilación, alimentación y temperatura del fabricante. Para un reemplazo nuevo, los chasis Cisco representan equipos de laboratorio de referencia. Selecciona un switch gestionable actual con el número de puertos y la velocidad que requieras.

| Cable desde SW-HOME | Panel frontal / posterior | Extremo | Perfil |
| --- | --- | --- | --- |
| Gi0/1 | F01 / R01 | PVE-01 LOM1 | VLAN 10 nativa, 20 y 40 etiquetadas |
| Gi0/2 | F02 / R02 | GW-HOME Gi0/1 | VLAN 10, 20, 30 y 40 etiquetadas |
| Fa0/3 | F03 / R03 | NAS-01 LOM1 | Acceso VLAN 40 |
| Fa0/1 | F04 / R04 | PC-ADMIN Ethernet | Acceso VLAN 10 |
| Fa0/2 | F05 / R05 | PC-PRUEBAS Ethernet | Acceso VLAN 30 |

Etiqueta cada extremo con su destino y puerto. Asegura Cat 6 con guías y soportes, deja alivio de tracción y respeta el radio de curvatura de la ficha de cada cable. Usa canalizaciones separadas para datos y energía conforme al sitio y comprueba los pares con un comprobador de cableado. En cobre, Fa0/1–3 son puertos de 100 Mb/s del switch de referencia.

## 4. Configura la red y Proxmox

| VLAN | Subred | Gateway | Equipos |
| --- | --- | --- | --- |
| 10 Gestión | 192.168.60.0/24 | 192.168.60.1 | SW-HOME .2, PVE-01 .10 y PC-ADMIN .101 |
| 20 Servicios | 192.168.61.0/24 | 192.168.61.1 | VM 120 Debian .20 |
| 30 Clientes | 192.168.62.0/24 | 192.168.62.1 | PC-PRUEBAS .101 |
| 40 Almacenamiento | 192.168.63.0/24 | 192.168.63.1 | NAS-01 .10 y PVE-01 para copias .11 |

1. Configura las cuatro VLAN en el switch y las interfaces etiquetadas con IP de gateway en el router. Permite Gestión hacia TCP 8006 de PVE-01. Permite Clientes hacia TCP 8080 de VM 120 y bloquea el acceso de Clientes a Gestión y Almacenamiento. Usa el DNS de tu red o configura DNS interno en el gateway por separado.
2. Instala Proxmox VE en el host x86-64. Desde la consola de PVE, enlaza `vmbr0` a la interfaz Linux correspondiente a LOM1 y habilita **VLAN aware**. Dirección de gestión `192.168.60.10/24` sin etiqueta y gateway `192.168.60.1`. Conserva el acceso a consola mientras cambias red y contrasta la configuración nativa del switch.
3. Crea la VM **120** con Debian, 2 vCPU, 2 GiB de RAM y un disco local de 24 GB. Interfaz VirtIO en `vmbr0` con **VLAN Tag 20**. Configura `192.168.61.20/24` y gateway `192.168.61.1` dentro de Debian.
4. Copia `lab.py` a la VM y ejecútalo con una cuenta sin privilegios. Si usas otro plan IP, adapta la constante `GUEST_IP`, direcciones y ACL de forma coordinada.

```sh
python3 lab.py serve --bind 192.168.61.20 --database "$HOME/homelab/inventory.sqlite"
```

Desde PC-PRUEBAS comprueba las tres rutas HTTP y verifica que la red bloquea el acceso administrativo desde esa VLAN.

```sh
curl -fsS http://192.168.61.20:8080/healthz
curl -fsS http://192.168.61.20:8080/api/inventory
curl -fsS http://192.168.61.20:8080/metrics
```

Para mantener el portal en ejecución después de reiniciar Debian, instala el archivo como administrador de la VM y crea una cuenta de servicio.

```sh
sudo useradd --system --user-group --home-dir /var/lib/nexus-homelab --shell /usr/sbin/nologin homelab
sudo install -D -m 0644 lab.py /opt/nexus-homelab/lab.py
```

Guarda esta unidad como `/etc/systemd/system/nexus-homelab.service`.

```ini
[Unit]
Description=Nexus HomeLab VM 120
Wants=network-online.target
After=network-online.target

[Service]
User=homelab
StateDirectory=nexus-homelab
ExecStart=/usr/bin/python3 /opt/nexus-homelab/lab.py serve --bind 192.168.61.20 --database /var/lib/nexus-homelab/inventory.sqlite
Restart=on-failure
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true

[Install]
WantedBy=multi-user.target
```

Detén primero el proceso manual si usa 8080. Después inicia la unidad y consulta su estado.

```sh
sudo systemctl daemon-reload
sudo systemctl enable --now nexus-homelab
sudo systemctl status nexus-homelab
```

## 5. Copia y recupera el laboratorio

1. En Proxmox, añade una subinterfaz `vmbr0.40` con `192.168.63.11/24` y sin segundo gateway. En NAS-01, limita el recurso NFS a esa IP. Añade el destino en **Datacenter → Storage → Add → NFS** con contenido de copias.
2. Programa la copia de VM 120 en **Datacenter → Backup**. Conserva otra copia fuera del rack. Prueba una restauración con ID libre y NIC aislada. Verifica el portal, el inventario y las métricas antes de mover la VM restaurada a la red del laboratorio.
3. Para respaldar solo los datos de la aplicación en un sistema de archivos que admita enlaces duros, genera una copia SQLite con nombre nuevo. Puedes transferir ese archivo terminado al destino de respaldo. Para probarla, abre el servicio con esa copia en un puerto libre.

```sh
python3 lab.py backup "$HOME/homelab/inventory.sqlite" "$HOME/homelab/inventory-01.sqlite"
python3 lab.py serve --port 8081 --database "$HOME/homelab/inventory-01.sqlite"
python3 lab.py check --url http://127.0.0.1:8081
```

## Referencias

- Montaje, segmentación y evolución gradual del laboratorio. [Guía de Chris Kirby](https://chriskirby.net/setting-up-and-leveling-up-your-homelab-a-comprehensive-guide/)
- Puentes y VLAN. [Proxmox VE Network Configuration](https://pve.proxmox.com/wiki/Network_Configuration)
- Destinos de copia, planificación y restauración de VMs. [Proxmox VE Backup and Restore](https://pve.proxmox.com/wiki/Backup_and_Restore)
- Guardado y relocalización en la misma habitación. [Apple ARKit](https://developer.apple.com/documentation/arkit/saving-and-loading-world-data)
