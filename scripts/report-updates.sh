#!/usr/bin/env bash
set -euo pipefail

workspace_dir="$(cd "$(dirname "$0")/.." && pwd)"
catalog_file="${PAD_PORTS_CATALOG:-$workspace_dir/catalog/projects.json}"
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

updates_file="$(mktemp)"
report_file="$(mktemp)"
trap 'rm -f "$updates_file" "$report_file"' EXIT
printf '[]\n' > "$updates_file"

while IFS=$'\t' read -r project_id slug branch pinned_revision; do
  remote_revision="$(gh api "repos/$slug/commits/$branch" --jq .sha)"
  state="current"
  [[ "$remote_revision" == "$pinned_revision" ]] || state="updateAvailable"
  jq --arg id "$project_id" \
     --arg slug "$slug" \
     --arg branch "$branch" \
     --arg pinned "$pinned_revision" \
     --arg remote "$remote_revision" \
     --arg state "$state" \
     '. + [{id: $id, repository: $slug, branch: $branch, pinnedRevision: $pinned, remoteRevision: $remote, state: $state}]' \
     "$updates_file" > "$report_file"
  mv "$report_file" "$updates_file"
done < <(jq -r '.projects[] | [.id, .repository.slug, .repository.defaultBranch, .repository.revision] | @tsv' "$catalog_file")

jq '{generatedAt: (now | todateiso8601), updates: [.[] | select(.state == "updateAvailable")], projects: .}' \
  "$updates_file" > "$report_file"

if [[ -n "$output_file" ]]; then
  mkdir -p "$(dirname "$output_file")"
  mv "$report_file" "$output_file"
  final_report="$output_file"
else
  final_report="$report_file"
fi

jq . "$final_report"
