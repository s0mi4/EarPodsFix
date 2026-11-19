#!/bin/zsh
# Собирает релиз EarPodsFix для публикации:
#   dist/EarPodsFix.app            — универсальное приложение (Apple Silicon + Intel), macOS 13+
#   dist/EarPodsFix-<версия>.zip   — архив для GitHub Releases
#   dist/EarPodsFix-<версия>.dmg   — образ диска с ярлыком «Программы»
set -e
VERSION="${1:-1.0.0}"
BUILD="${2:-1}"
DIR="${0:A:h}"
DIST="$DIR/dist"
WORK="$DIR/.build"
APP="$DIST/EarPodsFix.app"
SRC=("$DIR/Sources/AudioCore.swift" "$DIR/Sources/Engine.swift" "$DIR/Sources/UI.swift")
FW=(-framework AppKit -framework SwiftUI -framework CoreAudio -framework IOKit -framework ServiceManagement)

rm -rf "$DIST" "$WORK"
mkdir -p "$WORK" "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "▸ Компиляция arm64 + x86_64"
for arch in arm64 x86_64; do
  swiftc -O -parse-as-library -target "$arch-apple-macos13.0" "${SRC[@]}" "${FW[@]}" -o "$WORK/EarPodsFix-$arch"
done
lipo -create "$WORK/EarPodsFix-arm64" "$WORK/EarPodsFix-x86_64" -output "$APP/Contents/MacOS/EarPodsFix"

echo "▸ Иконка"
swift "$DIR/tools/make_icon.swift" "$WORK/icon_1024.png" >/dev/null
ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s "$WORK/icon_1024.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$WORK/icon_1024.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

echo "▸ Info.plist"
cat > "$APP/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>EarPodsFix</string>
  <key>CFBundleDisplayName</key><string>EarPodsFix</string>
  <key>CFBundleIdentifier</key><string>com.s0mi4.earpodsfix</string>
  <key>CFBundleExecutable</key><string>EarPodsFix</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array><string>en</string><string>ru</string></array>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHumanReadableCopyright</key><string>© 2026 s0mi4</string>
</dict></plist>
PL

echo "▸ Подпись (ad-hoc)"
codesign --force --deep --sign - "$APP"
codesign --verify --strict "$APP"

echo "▸ ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$DIST/EarPodsFix-$VERSION.zip"

echo "▸ DMG"
STAGE="$WORK/dmg"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "EarPodsFix $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DIST/EarPodsFix-$VERSION.dmg" >/dev/null

rm -rf "$WORK"
echo "✓ Готово:"
ls -lh "$DIST"
