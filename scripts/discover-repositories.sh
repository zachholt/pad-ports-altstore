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

account_owner="$(jq -r '.accountOwner' "$catalog_file")"
live_file="$(mktemp)"
report_file="$(mktemp)"
trap 'rm -f "$live_file" "$report_file"' EXIT

gh api --paginate --slurp "users/$account_owner/repos?per_page=100&type=public&sort=full_name" \
  | jq 'add | map(select((.name | ascii_downcase | endswith("pad")) or (.name | ascii_downcase | endswith("touch")))) | sort_by(.full_name | ascii_downcase)' \
  > "$live_file"

jq -n --slurpfile catalog "$catalog_file" --slurpfile live "$live_file" '
  ($catalog[0].projects | map(select(.repository.slug | startswith($catalog[0].accountOwner + "/")))) as $tracked
  | ($live[0]) as $repos
  | {
      generatedAt: (now | todateiso8601),
      account: $catalog[0].accountOwner,
      livePortRepositoryCount: ($repos | length),
      trackedAccountProjectCount: ($tracked | length),
      additions: [
        $repos[]
        | select(.full_name as $slug | all($tracked[]; .repository.slug != $slug))
        | {slug: .full_name, defaultBranch: .default_branch, pushedAt: .pushed_at}
      ],
      missing: [
        $tracked[]
        | select(.repository.slug as $slug | all($repos[]; .full_name != $slug))
        | {id, slug: .repository.slug}
      ],
      branchChanges: [
        $tracked[] as $project
        | $repos[]
        | select(.full_name == $project.repository.slug and .default_branch != $project.repository.defaultBranch)
        | {id: $project.id, slug: .full_name, tracked: $project.repository.defaultBranch, live: .default_branch}
      ]
    }
' > "$report_file"

if [[ -n "$output_file" ]]; then
  mkdir -p "$(dirname "$output_file")"
  mv "$report_file" "$output_file"
  final_report="$output_file"
else
  final_report="$report_file"
fi

jq . "$final_report"
