#!/usr/bin/env bash
set -euo pipefail

: "${PAD_PORTS_PROJECT_DIR:?}"
: "${PAD_PORTS_OUTPUT_DIR:?}"
: "${PAD_PORTS_SOURCE_REVISION:?}"

cd "$PAD_PORTS_PROJECT_DIR"
./scripts/build-ios.sh --device
app_bundle="$PAD_PORTS_PROJECT_DIR/build-ios/Release-iphoneos/StarshipPad.app"
./scripts/package-ios.sh "$app_bundle" "$PAD_PORTS_OUTPUT_DIR/StarshipPad-${PAD_PORTS_SOURCE_REVISION:0:12}-unsigned.ipa"
