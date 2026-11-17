# Nexus Packet Exporter para Mac

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

Se genera `build/Nexus Packet Exporter.app`, compilada para la arquitectura de este Mac y macOS
14 o posterior. Incluye exportador, requisitos, licencia y código fuente de la interfaz.
La firma es ad hoc local; no está notarizada ni preparada para distribución a otros Macs.
La app conserva en Info.plist la ruta absoluta de ese entorno. Si lo mueves o borras, debes
prepararlo y compilar de nuevo. `NEXUS_PYTHON_EXECUTABLE` permite elegir otra ruta al compilar.
El entorno queda fuera de Documentos para evitar bloqueos de lectura durante el arranque.
La app no instala dependencias. Una exportación se interrumpe si supera dos minutos.

Abre la app, pulsa **Elegir archivo .pkt…** y elige dónde guardar un nombre terminado en
`.nexus.json`. Si eliges un destino existente, el diálogo de macOS pide confirmar su sustitución;
el exportador sólo lo reemplaza después de convertir correctamente. El original `.pkt` se conserva.
La exportación ocurre fuera del hilo de interfaz; puedes ver su estado y cualquier error.

Cuando termine, usa **Mostrar archivo**. Envía el JSON por AirDrop al iPhone y selecciónalo desde
la opción Importar de Nexus AR. Revisa el contenido antes de compartirlo: puede incluir configuración
y credenciales presentes en el laboratorio original. La app interpreta la configuración como texto;
no ejecuta Cisco IOS, servicios ni comandos incluidos en el archivo.

Para comprobar el ejecutable sin abrir la interfaz:

```sh
"build/Nexus Packet Exporter.app/Contents/MacOS/NexusPacketExporter" --help
```
