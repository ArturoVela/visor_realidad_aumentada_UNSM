#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
set -eu

EXPORTER_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PYTHON_EXECUTABLE="${NEXUS_PYTHON_EXECUTABLE:-$HOME/Library/Application Support/NexusPacketExporter/python/bin/python}"
APP="$EXPORTER_DIR/build/Nexus Packet Exporter.app"
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
/usr/bin/plutil -insert CFBundleName -string 'Nexus Packet Exporter' "$PLIST"
/usr/bin/plutil -insert CFBundleDisplayName -string 'Nexus Packet Exporter' "$PLIST"
/usr/bin/plutil -insert CFBundleExecutable -string 'NexusPacketExporter' "$PLIST"
/usr/bin/plutil -insert CFBundlePackageType -string 'APPL' "$PLIST"
/usr/bin/plutil -insert CFBundleShortVersionString -string '1.0.0' "$PLIST"
/usr/bin/plutil -insert CFBundleVersion -string '1' "$PLIST"
/usr/bin/plutil -insert LSMinimumSystemVersion -string '14.0' "$PLIST"
/usr/bin/plutil -insert NSPrincipalClass -string 'NSApplication' "$PLIST"
/usr/bin/plutil -insert NSHighResolutionCapable -bool YES "$PLIST"
/usr/bin/plutil -insert NexusPythonExecutable -string "$PYTHON_EXECUTABLE" "$PLIST"
/usr/bin/plutil -lint "$PLIST"
/usr/bin/codesign --force --sign - "$APP"
/usr/bin/codesign --verify --strict "$APP"
printf 'App compilada: %s\n' "$APP"
