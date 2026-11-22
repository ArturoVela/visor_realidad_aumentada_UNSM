#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
set -eu

EXPORTER_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PYTHON_EXECUTABLE="${NEXUS_PYTHON_EXECUTABLE:-$HOME/Library/Application Support/NexusPacketExporter/python/bin/python}"
APP="${NEXUS_MAC_APP_PATH:-$EXPORTER_DIR/build/Nexus AR para Mac.app}"
TARGET_DEVICE="${NEXUS_TARGET_DEVICE:-}"
TARGET_DEVICE_NAME="${NEXUS_TARGET_DEVICE_NAME:-iPhone emparejado}"
ICON_SOURCE="$EXPORTER_DIR/../../NativeCapture/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
CONTENTS="$APP/Contents"
RESOURCES="$CONTENTS/Resources"

if [ ! -x "$PYTHON_EXECUTABLE" ]; then
    printf '%s\n' "Falta el entorno local: $PYTHON_EXECUTABLE" >&2
    printf '%s\n' 'Prepara el entorno de NexusPacketExporter con requirements.txt antes de compilar. Este script no descarga paquetes.' >&2
    exit 1
fi
for FILE in MacExporter.swift export_pkt.py requirements.txt LICENSE README.md; do
    if [ ! -f "$EXPORTER_DIR/$FILE" ]; then
        printf 'Falta el archivo: %s\n' "$EXPORTER_DIR/$FILE" >&2
        exit 1
    fi
done

mkdir -p "$CONTENTS/MacOS" "$RESOURCES/Source"
ICON_WORK=$(/usr/bin/mktemp -d)
trap 'rm -rf "$ICON_WORK"' EXIT
ICONSET="$ICON_WORK/NexusAR.iconset"
mkdir "$ICONSET"
for SIZE in 16 32 128 256 512; do
    /usr/bin/sips -z "$SIZE" "$SIZE" "$ICON_SOURCE" --out "$ICONSET/icon_${SIZE}x${SIZE}.png" >/dev/null
    DOUBLE=$((SIZE * 2))
    /usr/bin/sips -z "$DOUBLE" "$DOUBLE" "$ICON_SOURCE" --out "$ICONSET/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
done
/usr/bin/iconutil --convert icns "$ICONSET" --output "$RESOURCES/NexusAR.icns"
/usr/bin/xcrun swiftc -swift-version 6 -O -parse-as-library \
    -target "$(/usr/bin/uname -m)-apple-macos14.0" \
    -framework AppKit -framework UniformTypeIdentifiers \
    "$EXPORTER_DIR/MacExporter.swift" -o "$CONTENTS/MacOS/NexusPacketExporter"
for FILE in export_pkt.py requirements.txt LICENSE README.md; do
    /bin/cp "$EXPORTER_DIR/$FILE" "$RESOURCES/$FILE"
done
/bin/cp "$EXPORTER_DIR/MacExporter.swift" "$RESOURCES/Source/MacExporter.swift"
/bin/cp "$EXPORTER_DIR/build-mac-app.sh" "$RESOURCES/Source/build-mac-app.sh"
if [ -f "$EXPORTER_DIR/README-Mac.md" ]; then
    /bin/cp "$EXPORTER_DIR/README-Mac.md" "$RESOURCES/README-Mac.md"
fi

PLIST="$CONTENTS/Info.plist"
/usr/bin/plutil -create xml1 "$PLIST"
/usr/bin/plutil -insert CFBundleIdentifier -string 'pe.unsm.nexus.packet-exporter' "$PLIST"
/usr/bin/plutil -insert CFBundleName -string 'Nexus AR para Mac' "$PLIST"
/usr/bin/plutil -insert CFBundleDisplayName -string 'Nexus AR para Mac' "$PLIST"
/usr/bin/plutil -insert CFBundleIconFile -string 'NexusAR.icns' "$PLIST"
/usr/bin/plutil -insert CFBundleExecutable -string 'NexusPacketExporter' "$PLIST"
/usr/bin/plutil -insert CFBundlePackageType -string 'APPL' "$PLIST"
/usr/bin/plutil -insert CFBundleShortVersionString -string '1.2.0' "$PLIST"
/usr/bin/plutil -insert CFBundleVersion -string '3' "$PLIST"
/usr/bin/plutil -insert LSMinimumSystemVersion -string '14.0' "$PLIST"
/usr/bin/plutil -insert NSPrincipalClass -string 'NSApplication' "$PLIST"
/usr/bin/plutil -insert NSHighResolutionCapable -bool YES "$PLIST"
/usr/bin/plutil -insert NexusPythonExecutable -string "$PYTHON_EXECUTABLE" "$PLIST"
if [ -n "$TARGET_DEVICE" ]; then
    /usr/bin/plutil -insert NexusTargetDevice -string "$TARGET_DEVICE" "$PLIST"
    /usr/bin/plutil -insert NexusTargetDeviceName -string "$TARGET_DEVICE_NAME" "$PLIST"
    /usr/bin/plutil -insert UTImportedTypeDeclarations -json '[{
        "UTTypeIdentifier": "com.cisco.packettracer.pkt",
        "UTTypeDescription": "Packet Tracer Lab",
        "UTTypeConformsTo": ["public.data"],
        "UTTypeTagSpecification": {"public.filename-extension": ["pkt"]}
    }]' "$PLIST"
    /usr/bin/plutil -insert NSServices -json '[{
        "NSMenuItem": {"default": "Enviar a Nexus Home"},
        "NSMessage": "sendToNexus",
        "NSPortName": "Nexus AR para Mac",
        "NSSendFileTypes": ["com.cisco.packettracer.pkt", "dyn.ah62d4rv4ge81a45y"],
        "NSRequiredContext": {"NSApplicationIdentifier": "com.apple.finder"},
        "NSTimeout": "5000"
    }]' "$PLIST"
fi
/usr/bin/plutil -lint "$PLIST"
/usr/bin/codesign --force --sign - "$APP"
/usr/bin/codesign --verify --strict "$APP"
printf 'App compilada: %s\n' "$APP"
