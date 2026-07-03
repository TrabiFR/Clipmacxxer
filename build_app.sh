#!/bin/zsh
# Builds Clipmacxxer.app into ./build. Run the app from there so macOS
# attributes the Screen Recording permission to a stable, signed bundle.
set -euo pipefail
cd "$(dirname "$0")"

APP_DIR="build/Clipmacxxer.app"
BUNDLE_ID="com.fredi.clipmacxxer"

# Remember the previous build's code hash — TCC ties the Screen Recording
# grant to it when the app is ad-hoc signed.
OLD_CDHASH=""
if [ -d "$APP_DIR" ]; then
  OLD_CDHASH=$(codesign -dvvv "$APP_DIR" 2>&1 | awk -F= '/^CDHash=/{print $2}')
fi

swift build -c release

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp .build/release/Clipmacxxer "$APP_DIR/Contents/MacOS/Clipmacxxer"
cp Support/Info.plist "$APP_DIR/Contents/Info.plist"

# Optional app icon: drop your logo at assets/logo.png (1024x1024 works best).
if [ -f assets/logo.png ]; then
  ICONSET="build/AppIcon.iconset"
  rm -rf "$ICONSET"
  mkdir -p "$ICONSET"
  for size in 16 32 128 256 512; do
    sips -z $size $size assets/logo.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) assets/logo.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP_DIR/Contents/Resources/AppIcon.icns"
fi

# A real certificate gives the app a stable identity, so Screen Recording
# permission survives rebuilds. Set CODESIGN_ID to override auto-detection.
IDENTITY="${CODESIGN_ID:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development|Developer ID Application/{print $2; exit}')}"

if [ -n "$IDENTITY" ]; then
  codesign --force --sign "$IDENTITY" "$APP_DIR"
  echo "Signed as: $IDENTITY"
else
  # Ad-hoc fallback: the signature is tied to this exact binary, so a changed
  # binary leaves a stale Screen Recording grant that fails silently. Reset
  # the grant so macOS re-prompts on next launch instead.
  codesign --force --sign - "$APP_DIR"
  NEW_CDHASH=$(codesign -dvvv "$APP_DIR" 2>&1 | awk -F= '/^CDHash=/{print $2}')
  if [ -n "$OLD_CDHASH" ] && [ "$NEW_CDHASH" != "$OLD_CDHASH" ]; then
    tccutil reset ScreenCapture "$BUNDLE_ID" >/dev/null 2>&1 || true
    tccutil reset Microphone "$BUNDLE_ID" >/dev/null 2>&1 || true
    echo "Ad-hoc signed and binary changed: Screen Recording permission was"
    echo "reset — macOS will ask again on next launch (this avoids the stale"
    echo "grant that silently breaks capture)."
  fi
fi
echo "Built $APP_DIR"
echo "Launch with: open $APP_DIR"
