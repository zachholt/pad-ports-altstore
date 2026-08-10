#!/usr/bin/env bash
set -euo pipefail

: "${PAD_PORTS_PROJECT_DIR:?}"
: "${PAD_PORTS_OUTPUT_DIR:?}"

cd "$PAD_PORTS_PROJECT_DIR"
git submodule update --init --recursive
./scripts/fetch-deps.sh
./scripts/build-device.sh
OUTPUT_DIR="$PAD_PORTS_OUTPUT_DIR" ./scripts/package-ios.sh
