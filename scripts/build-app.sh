#!/bin/zsh
set -euo pipefail
cd -- "${0:A:h:h}"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
export SWIFT_MODULECACHE_PATH="$PWD/.build/module-cache"
mkdir -p .build/module-cache
swift build -c release --disable-sandbox --scratch-path .build
swift scripts/make-icon.swift Assets
APP="$PWD/build/Citadel.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/CitadelGitWorker "$APP/Contents/MacOS/CitadelGitWorker"
codesign --force --sign - "$APP/Contents/MacOS/CitadelGitWorker"
cp .build/release/Citadel "$APP/Contents/MacOS/Citadel"
cp Assets/Citadel.icns "$APP/Contents/Resources/CitadelLighthouse.icns"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Citadel</string>
<key>CFBundleDisplayName</key><string>Citadel</string>
<key>CFBundleIdentifier</key><string>local.alex.Citadel</string>
<key>CFBundleVersion</key><string>2</string>
<key>CFBundleShortVersionString</key><string>0.2.0</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleExecutable</key><string>Citadel</string>
<key>CFBundleIconFile</key><string>CitadelLighthouse</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHumanReadableCopyright</key><string>Citadel · A personal Git workbench</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
printf 'Built %s\n' "$APP"
