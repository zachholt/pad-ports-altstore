#!/usr/bin/env bash
set -euo pipefail

: "${PAD_PORTS_PROJECT_DIR:?}"
: "${PAD_PORTS_OUTPUT_DIR:?}"
: "${PAD_PORTS_SOURCE_REVISION:?}"

cd "$PAD_PORTS_PROJECT_DIR"
./package-ios.sh \
  --build \
  --source-commit "$PAD_PORTS_SOURCE_REVISION" \
  --output "$PAD_PORTS_OUTPUT_DIR/CTRPad-${PAD_PORTS_SOURCE_REVISION:0:12}-unsigned.ipa"
