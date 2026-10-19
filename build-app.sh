#!/bin/zsh
# Compila MiNotch en release y arma MiNotch.app (con LSUIElement) en esta carpeta.
set -euo pipefail

cd "$(dirname "$0")"

swift build -c release

APP="MiNotch.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$(swift build -c release --show-bin-path)/MiNotch" "$APP/Contents/MacOS/MiNotch"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>MiNotch</string>
    <key>CFBundleIdentifier</key>
    <string>com.frandercarrillo.MiNotch</string>
    <key>CFBundleName</key>
    <string>MiNotch</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

# Firma con un certificado fijo para que macOS recuerde los permisos (Grabación de pantalla)
# entre compilaciones; con la firma ad-hoc ("-") cada build cuenta como una app nueva.
IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ { print $2; exit }')
if [[ -z "$IDENTITY" ]]; then
    echo "Aviso: no hay certificado Apple Development; firma ad-hoc (los permisos se piden de nuevo en cada build)."
    IDENTITY="-"
fi
codesign --force --sign "$IDENTITY" "$APP"
echo "Listo: $(pwd)/$APP"
