#!/usr/bin/env bash
set -euo pipefail

workspace_dir="$(cd "$(dirname "$0")/.." && pwd)"
catalog_file="${PAD_PORTS_CATALOG:-$workspace_dir/catalog/projects.json}"
project_id=""
update_all=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project)
      [[ $# -ge 2 ]] || { echo "--project requires an ID." >&2; exit 2; }
      project_id="$2"
      shift 2
      ;;
    --all)
      update_all=1
      shift
      ;;
    *)
      echo "Usage: $0 (--project ID | --all)" >&2
      exit 2
      ;;
  esac
done

if [[ "$update_all" -eq 1 && -n "$project_id" ]] || [[ "$update_all" -eq 0 && -z "$project_id" ]]; then
  echo "Choose exactly one of --project ID or --all." >&2
  exit 2
fi

for dependency in gh jq; do
  command -v "$dependency" >/dev/null || { echo "$dependency is required." >&2; exit 1; }
done
"$workspace_dir/scripts/validate-catalog.sh" >/dev/null

if [[ -n "$project_id" ]]; then
  jq -e --arg id "$project_id" 'any(.projects[]; .id == $id)' "$catalog_file" >/dev/null || {
    echo "Unknown project: $project_id" >&2
    exit 1
  }
fi

working_file="$(mktemp "$(dirname "$catalog_file")/projects.update.XXXXXX")"
trap 'rm -f "$working_file"' EXIT
cp "$catalog_file" "$working_file"

selector='.projects[]'
if [[ -n "$project_id" ]]; then
  selector=".projects[] | select(.id == \"$project_id\")"
fi

while IFS=$'\t' read -r current_id slug branch old_revision; do
  new_revision="$(gh api "repos/$slug/commits/$branch" --jq .sha)"
  if [[ "$new_revision" == "$old_revision" ]]; then
    echo "$current_id already current at $old_revision"
    continue
  fi
  next_file="$(mktemp "$(dirname "$catalog_file")/projects.update.XXXXXX")"
  jq --arg id "$current_id" --arg revision "$new_revision" \
    '(.projects[] | select(.id == $id) | .repository.revision) = $revision' \
    "$working_file" > "$next_file"
  mv "$next_file" "$working_file"
  echo "$current_id: $old_revision -> $new_revision"
done < <(jq -r "$selector | [.id, .repository.slug, .repository.defaultBranch, .repository.revision] | @tsv" "$catalog_file")

PAD_PORTS_CATALOG="$working_file" "$workspace_dir/scripts/validate-catalog.sh" >/dev/null
mv "$working_file" "$catalog_file"
trap - EXIT
echo "Updated $catalog_file"
