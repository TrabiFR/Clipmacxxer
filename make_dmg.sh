#!/bin/zsh
# Packages build/Clipmacxxer.app into dist/Clipmacxxer.dmg with the classic
# drag-to-Applications layout. Run build_app.sh first (or this will).
set -euo pipefail
cd "$(dirname "$0")"

[ -d build/Clipmacxxer.app ] || ./build_app.sh

STAGE="dist/dmg-stage"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -R build/Clipmacxxer.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f dist/Clipmacxxer.dmg
hdiutil create -volname "Clipmacxxer" -srcfolder "$STAGE" -ov -format UDZO dist/Clipmacxxer.dmg
rm -rf "$STAGE"
echo "Built dist/Clipmacxxer.dmg"
