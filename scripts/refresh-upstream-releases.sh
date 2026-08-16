#!/usr/bin/env bash
set -euo pipefail

workspace_dir="$(cd "$(dirname "$0")/.." && pwd)"
output_file=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)
      [[ $# -ge 2 ]] || { echo "--output requires a path." >&2; exit 2; }
      output_file="$2"
      shift 2
      ;;
    *)
      echo "Usage: $0 [--output FILE]" >&2
      exit 2
      ;;
  esac
done

for dependency in gh jq; do
  command -v "$dependency" >/dev/null || { echo "$dependency is required." >&2; exit 1; }
done

"$workspace_dir/scripts/validate-catalog.sh" >/dev/null

working_dir="$(mktemp -d)"
trap 'rm -rf "$working_dir"' EXIT
release_report="$working_dir/release-report.json"
imported_file="$working_dir/imported.json"
skipped_file="$working_dir/skipped.json"
summary_file="$working_dir/summary.json"
printf '[]\n' > "$imported_file"
printf '[]\n' > "$skipped_file"

"$workspace_dir/scripts/report-releases.sh" --output "$release_report" >/dev/null

while IFS=$'\t' read -r project_id release_tag; do
  import_log="$working_dir/$project_id.log"
  if "$workspace_dir/scripts/import-upstream-release.sh" \
      --project "$project_id" \
      --tag "$release_tag" >"$import_log" 2>&1; then
    cat "$import_log"
    jq --arg id "$project_id" --arg tag "$release_tag" \
      '. + [{id: $id, tag: $tag}]' "$imported_file" > "$working_dir/imported.next.json"
    mv "$working_dir/imported.next.json" "$imported_file"
  else
    status=$?
    cat "$import_log" >&2
    jq --arg id "$project_id" --arg tag "$release_tag" --argjson status "$status" \
      '. + [{id: $id, tag: $tag, status: $status, reason: "auditOrPolicyCheckFailed"}]' \
      "$skipped_file" > "$working_dir/skipped.next.json"
    mv "$working_dir/skipped.next.json" "$skipped_file"
  fi
done < <(jq -r '.updates[] | [.id, .latestTag] | @tsv' "$release_report")

imported_count="$(jq 'length' "$imported_file")"
if [[ "$imported_count" -gt 0 ]]; then
  "$workspace_dir/scripts/validate-catalog.sh" --verify-remote >/dev/null
  PAD_PORTS_SOURCE_OUTPUT="$working_dir/source.json" \
    "$workspace_dir/scripts/generate-store-source.sh" >/dev/null
fi

jq -n \
  --slurpfile report "$release_report" \
  --slurpfile imported "$imported_file" \
  --slurpfile skipped "$skipped_file" \
  '{
    generatedAt: (now | todateiso8601),
    updateCount: ($report[0].updates | length),
    imported: $imported[0],
    skipped: $skipped[0],
    alerts: $report[0].alerts
  }' > "$summary_file"

if [[ -n "$output_file" ]]; then
  mkdir -p "$(dirname "$output_file")"
  mv "$summary_file" "$output_file"
  final_summary="$output_file"
else
  final_summary="$summary_file"
fi

jq . "$final_summary"
