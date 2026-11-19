# Red de pruebas de la plantilla Nexus AR

VLAN 20, subred `192.168.20.0/24`, servidor HTTP TCP `8080`. Los cuatro equipos pertenecen a la misma subred. La prueba no necesita puerta de enlace ni Internet.

| Equipo | IPv4 | Puerto en la plantilla |
| --- | --- | --- |
| Servidor LAB · Cisco UCS C220 M5 | `192.168.20.10` | LOM1 → Acceso Aplicaciones A Gi0/1. LOM2 → Acceso Aplicaciones B Gi0/1 |
| PC-01 | `192.168.20.101` | Switch Red A Fa0/1 |
| PC-02 | `192.168.20.102` | Switch Red B Fa0/2 |
| PC-03 | `192.168.20.103` | Switch Red A Fa0/3 |

## Prueba en un equipo

Python 3.10 o posterior. Este comando abre un puerto de loopback temporal, lanza el servicio y hace tres solicitudes HTTP concurrentes.

```sh
python3 Tools/TierLab/lab.py self-test
```

Para mantener el servicio abierto, ejecuta `python3 Tools/TierLab/lab.py serve` y prueba en otra terminal con `python3 Tools/TierLab/lab.py check`. `/healthz` devuelve el estado y `/api/status?pc=PC-01` devuelve el resultado para ese cliente.

## Prueba con tres PCs en una red aislada

1. Crea VLAN 20 en los switches. Configura los puertos indicados como acceso y permite VLAN 20 en los troncales del diseño. Para la primera prueba, conecta LOM1 y conserva LOM2 para probar la ruta alternativa con una segunda configuración.
2. Asigna al servidor y a los PCs las direcciones de la tabla con prefijo `/24`. En el servidor, ejecuta `python3 Tools/TierLab/lab.py serve --bind 192.168.20.10`.
3. Ejecuta el siguiente comando en PC-01. En los otros dos equipos, cambia `--pc` por `PC-02` y `PC-03`.

```sh
python3 Tools/TierLab/lab.py check --url http://192.168.20.10:8080 --pc PC-01
```

El campo `remote_address` de cada respuesta identifica la IP de origen observada por el servidor. El identificador `pc` selecciona el equipo del escenario. La prueba local utiliza loopback y comprueba el servicio HTTP; la prueba física verifica además la configuración y el cableado de VLAN. La continuidad entre LOM1 y LOM2 requiere configurar y ensayar la conmutación en el servidor y en los switches.
