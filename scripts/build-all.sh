#!/usr/bin/env bash
set -euo pipefail

workspace_dir="$(cd "$(dirname "$0")/.." && pwd)"
catalog_file="${PAD_PORTS_CATALOG:-$workspace_dir/catalog/projects.json}"
dry_run=0
install_dependencies=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) dry_run=1 ;;
    --install-dependencies) install_dependencies=1 ;;
    *) echo "Usage: $0 [--dry-run] [--install-dependencies]" >&2; exit 2 ;;
  esac
  shift
done

"$workspace_dir/scripts/validate-catalog.sh" >/dev/null
report_items="$(mktemp)"
report_next="$(mktemp)"
trap 'rm -f "$report_items" "$report_next"' EXIT
printf '[]\n' > "$report_items"
failed=0

while IFS= read -r project_id; do
  arguments=()
  [[ "$dry_run" -eq 0 ]] || arguments+=(--dry-run)
  [[ "$install_dependencies" -eq 0 ]] || arguments+=(--install-dependencies)
  state="passed"
  log_file="$workspace_dir/.build/$project_id-build.log"
  mkdir -p "$workspace_dir/.build"
  if ! "$workspace_dir/scripts/build-project.sh" "${arguments[@]}" "$project_id" >"$log_file" 2>&1; then
    state="failed"
    failed=1
  fi
  jq --arg id "$project_id" --arg state "$state" --arg log "$log_file" \
    '. + [{id: $id, state: $state, log: $log}]' "$report_items" > "$report_next"
  mv "$report_next" "$report_items"
  echo "$project_id: $state"
done < <(jq -r '.projects[] | select(.build.state == "ready") | .id' "$catalog_file")

jq '{generatedAt: (now | todateiso8601), projects: .}' "$report_items" > "$workspace_dir/catalog/build-report.json"
echo "$workspace_dir/catalog/build-report.json"
exit "$failed"
