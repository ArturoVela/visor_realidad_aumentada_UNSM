# Operación de Tier IV y HomeLab

Las dos plantillas guardan la asignación de 38 dominios de velaarturo.com. En el visor toca la PC, su monitor o la laptop y abre **Sitios** para consultar la asignación simulada de cada dominio. En **Terminal** puedes elegir equipos, editar sus nombres e IPv4 y habilitar o deshabilitar puertos. Los cambios se guardan por plantilla en el iPhone. La asignación, el tráfico y las comprobaciones forman parte de la simulación del plano.

```text
connect SW-HOME
show interfaces
interface FastEthernet0/1
shutdown
no shutdown
connect PC-ADMIN
ping PVE-01
site move torneo.velaarturo.com home-web
```

El diagnóstico `ping` sigue el cableado y los puertos habilitados de una VLAN. Los perfiles de ejemplo usan redes privadas. El despliegue físico necesita sus propias direcciones, cuentas y reglas.

## HomeLab Proxmox

1. Monta SW-HOME en U16 y PP-CAT6 en U18. Lleva todo el Ethernet por el panel. GW-HOME ocupa U12–13. PVE-01 ocupa U8, NAS-01 U6 y BACKUP-HOME U4. Deja libre ventilación frontal y trasera.
2. Enlaza GW-HOME con SW-HOME por Gi0/2 y etiqueta las VLAN 10, 20, 30, 40, 50 y 60. Usa una subinterfaz con dirección .1 por VLAN. Lleva gestión nativa y VLAN 20 y 40 etiquetadas a Gi0/1 de SW-HOME hacia PVE-01. En Proxmox, activa VLAN-aware en vmbr0 y verifica acceso a gestión antes de migrar servicios.
3. En Fa0/10, conecta AP-HOME con gestión en VLAN 10 y asigna los SSID Casa y Casa-IoT a VLAN 30 y 50. Coloca cámaras en VLAN 60, como CAM-ACCESO en Fa0/11. El Catalyst del modelo es de acceso Fast Ethernet. Para transferencias frecuentes de NAS y varias cámaras, usa un switch Gigabit administrable, con PoE compatible o alimentación independiente en los dispositivos.
4. Despliega los orígenes de publicación en VMs de VLAN 20. Separa el proxy inverso, la bóveda Vaultwarden y Ollama en invitados con permisos distintos. El proxy resuelve por nombre hacia el origen privado correspondiente. Restringe la bóveda y la API de IA a gestión o a una red privada autorizada. Revisa la capacidad de cómputo y RAM del host antes de cargar modelos.
5. En PI-DNS (U9, 192.168.60.53), instala Raspberry Pi OS y Pi-hole. Autoriza TCP y UDP 53 desde las VLAN que deban resolver. Configura resoluciones locales y bloqueos y revisa excepciones en el historial. Entrega DNS por DHCP en las redes correspondientes.
6. En PI-DOMÓTICA (U11, 192.168.64.10), monta SSD, ventilación y un coordinador Zigbee por USB. Instala Home Assistant OS y Mosquitto. Activa autenticación del broker y concede a cada cliente MQTT permisos sobre sus temas. Registra los sensores y actuadores. Copia [home-assistant-automations.yaml](home-assistant-automations.yaml) al archivo de automatizaciones de esa instalación tras adaptar los identificadores; conserva las reglas preexistentes y valida la configuración antes de recargar. Abre cada traza para comprobar el movimiento nocturno, los límites del ventilador y el aviso de fuga.
7. Monta NAS-01 en espejo ZFS y BACKUP-HOME en otro destino físico. Autoriza SMB o NFS por grupo. Programa copias de invitados en el destino de respaldo, otra copia fuera del rack y una restauración periódica en una red aislada. Reserva una cuota aparte para las grabaciones de NVR-HOME.

## Sala de referencia Tier IV

- **NAS-PRINCIPAL** usa RAIDZ2 como configuración prevista y **NAS-RÉPLICA** recibe instantáneas. Asigna Backups, Películas, Datos, Trabajos, Universidad y Privado a conjuntos independientes, con acceso por grupo y cuota. Publica Películas a Jellyfin en lectura. Protege Privado con ACL individual.
- **PBS-PRINCIPAL** y **PBS-RÉPLICA** verifican copias y recuperaciones. **NVR-SEGURIDAD** recibe cámaras por una red de vídeo separada. **DNS-FILTRO-A/B**, **PROXY-INVERSO-A/B**, **BÓVEDA-DE-CONTRASEÑAS**, **IA-LOCAL** y **LABORATORIO-AISLADO** tienen fichas y conexiones independientes.
- La denominación Tier IV describe el objetivo de diseño. Valida redundancia, autonomía, refrigeración continua, trazados independientes y tolerancia a fallos en sitio antes de buscar certificación.

## Comprobaciones en Mac o Linux

Estos comandos usan Python 3.9+. La grabación requiere FFmpeg en el PATH.

```sh
python3 Tools/Operations/ops.py self-test
python3 Tools/Operations/ops.py init-nas "$HOME/nexus-nas"
mkdir -p "$HOME/nexus-copias"
SHA=$(python3 Tools/Operations/ops.py backup "$HOME/nexus-nas/Universidad" "$HOME/nexus-copias/universidad.tar.gz")
python3 Tools/Operations/ops.py verify "$HOME/nexus-copias/universidad.tar.gz" --sha256 "$SHA"
python3 Tools/Operations/ops.py restore "$HOME/nexus-copias/universidad.tar.gz" "$HOME/nexus-recuperacion" --sha256 "$SHA"
python3 Tools/Operations/ops.py record "$HOME/nexus-copias/CAM-ACCESO" --seconds 60
```

El comando de cámara solicita la URL RTSP en la terminal y escribe segmentos MKV en un directorio nuevo. La copia de archivos archiva directorios estables. Para máquinas virtuales activas usa instantáneas y copias nativas de Proxmox/ZFS. Conserva el SHA-256 en un registro independiente al programar verificaciones.

El [servicio HTTP y SQLite de HomeLab](../HomeLab/README.md) también se conserva como comprobación local del hipervisor.
