#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PYTHON=""
for candidate in /usr/bin/python3 python3.12 python3.11 python3.10 python3; do
  if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import sys; raise SystemExit(sys.version_info < (3, 9))' >/dev/null 2>&1; then
    PYTHON="$(command -v "$candidate")"
    break
  fi
done
if [[ -z "$PYTHON" ]]; then
  echo "PadMint needs Python 3.9 or newer. Install Python 3.12, then run this command again." >&2
  read -r -p "Press Enter to close this window. " || true
  exit 1
fi
if "$PYTHON" "$SCRIPT_DIR/scripts/make-ipas.py" "$@"; then
  exit 0
else
  status=$?
  read -r -p "Press Enter to close this window. " || true
  exit "$status"
fi
