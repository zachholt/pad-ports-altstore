#!/usr/bin/env bash
set -euo pipefail

: "${PAD_PORTS_PROJECT_DIR:?}"
: "${PAD_PORTS_OUTPUT_DIR:?}"
: "${PAD_PORTS_SOURCE_REVISION:?}"

cd "$PAD_PORTS_PROJECT_DIR"
./scripts/clone-sources.sh
python_prefix="$(brew --prefix python@3.11)"
"$python_prefix/bin/python3.11" -c 'from PIL import Image' >/dev/null 2>&1 || \
  "$python_prefix/bin/python3.11" -m pip install --user 'Pillow==11.3.0'
./scripts/build-ios-device.sh
app_bundle="$PAD_PORTS_PROJECT_DIR/ref/BattleShip/build-ios-device/Release-iphoneos/BrawlerPad.app"
./scripts/package-ios.sh "$app_bundle" "$PAD_PORTS_OUTPUT_DIR/BrawlerPad-${PAD_PORTS_SOURCE_REVISION:0:12}-unsigned.ipa"
