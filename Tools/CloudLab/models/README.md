# Modelo de inspección del Catalyst 2960

El USDZ es un modelo original de referencia del 2960-24TT-L para Nexus AR.
El chasis está centrado, en metros y con el panel de red sobre el eje −Z.
Los nodos `Port_01` a `Port_26` siguen el orden de puertos de Nexus AR. La app
comprueba sus posiciones antes de mostrar el detalle dentro del rack.

## Generación y comprobación

Desde la raíz del repositorio:

```sh
blender -b --factory-startup --python-exit-code 1 \
  --python Tools/CloudLab/models/build_catalyst2960.py -- /tmp/switch-2960-next.usdz
xcrun usdchecker --arkit /tmp/switch-2960-next.usdz
```

La versión publicada pesa 394 571 bytes. Para publicar otra revisión, usa una
clave nueva en R2 y actualiza la ruta, el tamaño y el SHA-256 de la aplicación.
La v1 se guarda en `public-models/switch-2960/v1.usdz`. El Worker
`nexus-ar-models` sirve ese objeto con GET y HEAD desde el bucket configurado.
`wrangler.example.jsonc` muestra la configuración del Worker.

Desde `NativeCapture/`, la comprobación con RealityKit valida el USDZ,
los anclajes, el fallo sin caché y la reapertura sin red:

```sh
xcrun swiftc -swift-version 6 Sources/RoomStructure.swift Sources/HardwareCatalog.swift \
  Sources/LabLayout.swift Sources/LabTopology.swift Sources/LabARAssembly.swift \
  Sources/Catalyst2960Inspection.swift Tests/Catalyst2960InspectionCheck.swift \
  -o /tmp/nexus-catalyst-inspection-check
/tmp/nexus-catalyst-inspection-check ../Tools/CloudLab/models/switch-2960-v1.usdz --remote
```
