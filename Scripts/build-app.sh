#!/bin/zsh
set -euo pipefail

cd "${0:A:h}/.."
swift build -c release --triple arm64-apple-macosx14.0 --product ROMCover
swift build -c release --triple x86_64-apple-macosx14.0 --product ROMCover

app_path="$PWD/dist/ROMCover.app"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
lipo -create \
    .build/arm64-apple-macosx/release/ROMCover \
    .build/x86_64-apple-macosx/release/ROMCover \
    -output "$app_path/Contents/MacOS/ROMCover"

icon_source="$PWD/Assets/AppIcon.png"
icon_work=$(mktemp -d)
trap 'rm -rf "$icon_work"' EXIT
iconset_path="$icon_work/AppIcon.iconset"
mkdir -p "$iconset_path"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$icon_source" --out "$iconset_path/icon_${size}x${size}.png" >/dev/null
    doubled=$((size * 2))
    sips -z "$doubled" "$doubled" "$icon_source" --out "$iconset_path/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset_path" -o "$app_path/Contents/Resources/AppIcon.icns"

cat > "$app_path/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
    <key>CFBundleExecutable</key><string>ROMCover</string>
    <key>CFBundleIdentifier</key><string>app.romcover.mac</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>ROMCover</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.2.0</string>
    <key>CFBundleVersion</key><string>2</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$app_path"
echo "Built $app_path"
