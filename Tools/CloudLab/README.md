# Catálogo de prácticas UNSM

Nexus AR abre el catálogo desde **Catálogo UNSM**. Inicia sesión con correo y PIN de seis dígitos. El iPhone guarda los tokens en el llavero y renueva la sesión durante siete días desde el inicio. El token de acceso dura 15 minutos.

**Solicitar cuenta** y **Olvidé mi PIN** envían una solicitud para revisión. Solo `dev@velaarturo.com` puede aprobarla en **Usuarios y permisos**, asignar roles o desactivar cuentas. Verifica la identidad antes de aprobar y entrega el PIN generado por un canal privado. Restablecer un PIN revoca las sesiones anteriores de esa cuenta. Si la cuenta administradora perdió su última sesión, usa el procedimiento de recuperación de abajo.

Docentes y administradores crean **Aula → Sala → Rack → Servidor**. El catálogo admite racks de 12, 24 y 42 U.

En la ficha de un servidor, imprime **Etiqueta QR** y pégala en el equipo físico de prácticas. Prepara el laboratorio en Packet Tracer y pruébalo en ese equipo. Después elige el `.pkt` en la ficha, indica el nombre o ID exacto del nodo en Packet Tracer, confirma la prueba física y pulsa **Subir y publicar**. El nombre del nodo puede cambiar entre archivos. El QR sigue vinculado al mismo servidor del catálogo.

El Worker privado reutiliza `PacketTracerExporter` para convertir el `.pkt`. R2 guarda el original y la topología convertida en objetos privados. D1 confirma una versión correlativa después de guardar ambos archivos. Un `.pkt` rechazado conserva la publicación anterior. El estudiante escanea el QR o escribe su código, consulta la última versión y puede guardar una copia editable. La versión descargada se puede reabrir por código sin conexión mientras la sesión siga guardada en ese iPhone.

La topología distribuida elimina texto bruto de configuración y notas libres. Publica solo archivos de prácticas autorizados. El QR identifica el servidor. El acceso al catálogo requiere una cuenta. La confirmación física la registra el docente en la app.

## Conectar Cloudflare

Requisitos de desarrollo en Mac: Node.js, Wrangler y uv 0.13.4 o posterior. Usa una D1 y un bucket R2 privados para el laboratorio. Cambia los tres valores `REEMPLAZA_…` en una copia de `api/wrangler.example.jsonc` llamada `api/wrangler.jsonc`.

Desde la raíz del repositorio, prepara y publica el conversor privado antes de la API pública autenticada.

```sh
cp Tools/PacketTracerExporter/export_pkt.py Tools/CloudLab/converter/src/export_pkt.py
cd Tools/CloudLab/converter
uv run --python 3.13 pywrangler deploy
cd ../api
npx wrangler d1 migrations apply DB --remote
npx wrangler secret put AUTH_SECRET < /ruta/privada/archivo-secreto
npx wrangler deploy
```

## Activar o recuperar la cuenta administradora

Genera una vez `AUTH_SECRET` con `openssl rand -hex 32` y guarda el resultado en un archivo privado con permisos `0600` fuera del repositorio. Usa el mismo secreto en Cloudflare y en el comando de recuperación. Prepara otro archivo privado con seis dígitos para el PIN.

Desde la raíz, ejecuta lo siguiente. El SQL contiene el resumen criptográfico del PIN y revoca las sesiones anteriores de `dev@velaarturo.com`.

```sh
umask 077
node Tools/CloudLab/bootstrap-admin.mjs /ruta/privada/archivo-secreto /ruta/privada/archivo-pin > /ruta/privada/admin.sql
cd Tools/CloudLab/api
npx wrangler d1 execute DB --remote --file /ruta/privada/admin.sql
```

Borra el archivo temporal del PIN al terminar. La URL del catálogo se configura en `NativeCapture/Sources/LabCloud.swift`.

## Prueba local

Usa una copia de la configuración con nombres locales y un UUID de prueba para D1. Escribe `AUTH_SECRET` en `api/.dev.vars` con un secreto exclusivo de desarrollo. Aplica las migraciones y el SQL para el PIN administrador de prueba con `--local`. Tras copiar el exportador, ejecuta `uv run --python 3.13 pywrangler sync` en `converter` y después `npx wrangler dev --config wrangler.jsonc --config ../converter/wrangler.jsonc --ip 127.0.0.1 --port 8790` en `api`.

```sh
node Tools/CloudLab/check-local.mjs http://127.0.0.1:8790 /ruta/privada/archivo-pin 'docs/archivos_pkt/Project #2/Project #2.pkt'
```

El check cubre PIN, renovación, aprobación y restablecimiento, permisos, jerarquía, conversión, reintentos y versiones concurrentes. En una compilación Debug de simulador, configura `NEXUS_CATALOG_URL=http://127.0.0.1:8790` en el entorno de ejecución.
