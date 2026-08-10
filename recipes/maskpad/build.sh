#!/usr/bin/env bash
set -euo pipefail

: "${PAD_PORTS_PROJECT_DIR:?}"
: "${PAD_PORTS_OUTPUT_DIR:?}"
: "${PAD_PORTS_SOURCE_REVISION:?}"

cd "$PAD_PORTS_PROJECT_DIR"
./scripts/clone-sources.sh
./scripts/apply-patches.sh
./scripts/configure-ios.sh --device
./scripts/build-ios.sh --device
app_bundle="$PAD_PORTS_PROJECT_DIR/build-ios-device/Release-iphoneos/MaskPad.app"
./scripts/package-unsigned-ipa.sh "$app_bundle" "$PAD_PORTS_OUTPUT_DIR/MaskPad-${PAD_PORTS_SOURCE_REVISION:0:12}-unsigned.ipa"
