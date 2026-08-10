#!/usr/bin/env bash
set -euo pipefail

: "${PAD_PORTS_PROJECT_DIR:?}"
: "${PAD_PORTS_OUTPUT_DIR:?}"
: "${PAD_PORTS_SOURCE_REVISION:?}"

cd "$PAD_PORTS_PROJECT_DIR"
./scripts/package-release.sh "0.1.0-${PAD_PORTS_SOURCE_REVISION:0:12}" Release
source_ipa="$(find "$PAD_PORTS_PROJECT_DIR/out/release" -maxdepth 1 -type f -name '*.ipa' -print -quit)"
[[ -n "$source_ipa" ]] || { echo "VaultPad package was not produced." >&2; exit 1; }
cp "$source_ipa" "$PAD_PORTS_OUTPUT_DIR/VaultPad-${PAD_PORTS_SOURCE_REVISION:0:12}-unsigned.ipa"
