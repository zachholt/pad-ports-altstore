#!/usr/bin/env bash
set -euo pipefail

: "${PAD_PORTS_PROJECT_DIR:?}"
: "${PAD_PORTS_OUTPUT_DIR:?}"

cd "$PAD_PORTS_PROJECT_DIR"
RATOUCH_RELEASE_DIR="$PAD_PORTS_OUTPUT_DIR" ./scripts/package-ios-ipa.sh
