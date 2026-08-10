#!/usr/bin/env bash
set -euo pipefail

: "${PAD_PORTS_PROJECT_DIR:?}"
: "${PAD_PORTS_OUTPUT_DIR:?}"
: "${PAD_PORTS_SOURCE_REVISION:?}"

cd "$PAD_PORTS_PROJECT_DIR"
./scripts/fetch-sources.sh
./scripts/package-ios.sh
source_ipa="$PAD_PORTS_PROJECT_DIR/artifacts/AnnePad-0.1.0-unsigned.ipa"
[[ -f "$source_ipa" ]] || { echo "AnnePad package was not produced." >&2; exit 1; }
cp "$source_ipa" "$PAD_PORTS_OUTPUT_DIR/AnnePad-${PAD_PORTS_SOURCE_REVISION:0:12}-unsigned.ipa"
