# Nexus AR para Mac

Utilidad macOS independiente, bajo GPL-3.0-or-later. Usa el exportador Python de este directorio
y sus límites; consulta README.md y LICENSE. No forma parte del ejecutable de la app iPhone.

El entorno de esta máquina ya está preparado en `~/Library/Application Support/NexusPacketExporter/python`.
Para reproducirlo en otro Mac con Python 3.12:

```sh
python3.12 -m venv "$HOME/Library/Application Support/NexusPacketExporter/python"
"$HOME/Library/Application Support/NexusPacketExporter/python/bin/python" -m pip install -r requirements.txt
```

Después compila:

```sh
sh build-mac-app.sh
```

Se genera `build/Nexus AR para Mac.app`, compilada para la arquitectura de este Mac y macOS
14 o posterior. Incluye exportador, requisitos, licencia y código fuente de la interfaz.
La firma es ad hoc local; no está notarizada ni preparada para distribución a otros Macs.
La app conserva en Info.plist la ruta absoluta de ese entorno. Si lo mueves o borras, debes
prepararlo y compilar de nuevo. `NEXUS_PYTHON_EXECUTABLE` permite elegir otra ruta al compilar.
El entorno queda fuera de Documentos para evitar bloqueos de lectura durante el arranque.
La app no instala dependencias. Una exportación se interrumpe si supera dos minutos.

Abre la app, pulsa **Elegir archivo .pkt…** y selecciona el iPhone configurado. La app convierte el
laboratorio y lo envía al seleccionarlo. Puedes seguir el estado en la ventana.

**Guardar JSON…** crea una copia local para importar desde Archivos. Si eliges un destino existente,
macOS pide confirmar la sustitución y la app lo reemplaza después de convertir correctamente.

## Enviar al iPhone desde Finder

Haz clic derecho sobre un solo `.pkt` y elige **Servicios → Enviar a Nexus Home**. El exportador
convierte el archivo y envía el laboratorio al iPhone configurado por identificador. Cuando termine,
abre **Nexus AR → Más opciones → Laboratorios guardados → Recibidos del Mac**. Si ya tenías abierta
la lista, deslízala hacia abajo para actualizar. Reenviar el mismo laboratorio conserva una sola copia.
En la vista principal del iPhone aparece **Laboratorio recibido** con un botón para abrirlo.

El envío usa el enlace de desarrollo de Xcode con el iPhone emparejado y Nexus AR instalado por
Xcode. El iPhone debe estar disponible para el Mac, por cable o por la conexión que muestra Xcode.

Para volver a configurar la acción en un Mac, ejecuta desde este directorio con el identificador
del iPhone que muestra `xcrun devicectl list devices`:

```sh
nexus_app="$HOME/Applications/Nexus AR para Mac.app"
NEXUS_TARGET_DEVICE="<identificador-del-iPhone>" NEXUS_TARGET_DEVICE_NAME="<nombre-del-iPhone>" \
  NEXUS_MAC_APP_PATH="$nexus_app" sh build-mac-app.sh
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$nexus_app"
"$nexus_app/Contents/MacOS/NexusPacketExporter" --register-services
```

Para comprobar el ejecutable sin abrir la interfaz:

```sh
"build/Nexus AR para Mac.app/Contents/MacOS/NexusPacketExporter" --help
```
