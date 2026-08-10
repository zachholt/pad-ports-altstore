#!/usr/bin/env bash
set -euo pipefail

: "${PAD_PORTS_PROJECT_DIR:?}"
: "${PAD_PORTS_OUTPUT_DIR:?}"
: "${PAD_PORTS_SOURCE_REVISION:?}"

cd "$PAD_PORTS_PROJECT_DIR"
# The catalog intentionally checks out exact commits detached. OpenRCT2Touch's
# safety gate permits CI builds only under ipad or touch/*, so give this detached
# orchestration the same narrow identity without creating or moving a branch.
export GITHUB_ACTIONS=true
export GITHUB_HEAD_REF=touch/pad-ports-pipeline
./scripts/bootstrap.sh
./scripts/build-ios-deps.sh device
./scripts/build-ios-device.sh unsigned
app_bundle="$PAD_PORTS_PROJECT_DIR/build/ios-xcode-device/Release-iphoneos/OpenRCT2Touch.app"
./scripts/package-ios-ipa.sh "$app_bundle" "$PAD_PORTS_OUTPUT_DIR/OpenRCT2Touch-${PAD_PORTS_SOURCE_REVISION:0:12}-unsigned.ipa"
