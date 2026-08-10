#!/usr/bin/env bash
set -euo pipefail

workspace_dir="$(cd "$(dirname "$0")/.." && pwd)"
catalog_file="${PAD_PORTS_CATALOG:-$workspace_dir/catalog/projects.json}"
project_id=""
all_tracked=0
check_only=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project)
      [[ $# -ge 2 ]] || { echo "--project requires an ID." >&2; exit 2; }
      project_id="$2"
      shift 2
      ;;
    --all-tracked)
      all_tracked=1
      shift
      ;;
    --check)
      check_only=1
      shift
      ;;
    --default)
      shift
      ;;
    *)
      echo "Usage: $0 [--default | --project ID | --all-tracked] [--check]" >&2
      exit 2
      ;;
  esac
done

if [[ "$all_tracked" -eq 1 && -n "$project_id" ]]; then
  echo "Choose either --project ID or --all-tracked." >&2
  exit 2
fi

for dependency in git jq; do
  command -v "$dependency" >/dev/null || { echo "$dependency is required." >&2; exit 1; }
done
"$workspace_dir/scripts/validate-catalog.sh" >/dev/null
mkdir -p "$workspace_dir/upstreams" "$workspace_dir/catalog"

if [[ -n "$project_id" ]]; then
  jq -e --arg id "$project_id" 'any(.projects[]; .id == $id)' "$catalog_file" >/dev/null || {
    echo "Unknown project: $project_id" >&2
    exit 1
  }
fi

selection='.projects[] | select(.repository.checkoutPolicy == "default")'
if [[ "$all_tracked" -eq 1 ]]; then
  selection='.projects[]'
elif [[ -n "$project_id" ]]; then
  selection=".projects[] | select(.id == \"$project_id\")"
fi

report_items="$(mktemp)"
report_next="$(mktemp)"
trap 'rm -f "$report_items" "$report_next"' EXIT
printf '[]\n' > "$report_items"

while IFS=$'\t' read -r current_id checkout_name slug revision submodule_mode; do
  checkout_dir="$workspace_dir/upstreams/$checkout_name"
  clone_url="https://github.com/$slug.git"
  state="checked"

  [[ ! -L "$checkout_dir" ]] || { echo "Refusing symlinked checkout: $checkout_dir" >&2; exit 1; }

  if [[ ! -d "$checkout_dir/.git" ]]; then
    [[ "$check_only" -eq 0 ]] || { echo "$current_id checkout is missing: $checkout_dir" >&2; exit 1; }
    git clone --filter=blob:none --no-checkout "$clone_url" "$checkout_dir"
    state="cloned"
  fi

  origin_url="$(git -C "$checkout_dir" remote get-url origin 2>/dev/null)" || {
    echo "Refusing checkout without an origin remote: $current_id" >&2
    exit 1
  }
  normalized_origin="${origin_url%/}"
  normalized_origin="${normalized_origin%.git}.git"
  [[ "$normalized_origin" == "$clone_url" ]] || {
    echo "Refusing checkout with unexpected origin for $current_id: $origin_url" >&2
    exit 1
  }

  [[ -z "$(git -C "$checkout_dir" status --porcelain)" ]] || {
    echo "Refusing dirty checkout: $current_id" >&2
    exit 1
  }

  if [[ "$check_only" -eq 0 ]]; then
    git -C "$checkout_dir" fetch --depth=1 origin "$revision"
    git -C "$checkout_dir" checkout --detach "$revision"
    if [[ "$submodule_mode" == "recursive" ]]; then
      git -C "$checkout_dir" submodule sync --recursive
      git -C "$checkout_dir" submodule update --init --recursive --depth=1
    fi
    [[ "$state" == "cloned" ]] || state="synced"
  fi

  actual_revision="$(git -C "$checkout_dir" rev-parse HEAD)"
  [[ "$actual_revision" == "$revision" ]] || {
    echo "$current_id is at $actual_revision, expected $revision" >&2
    exit 1
  }

  jq --arg id "$current_id" --arg repository "$slug" --arg revision "$revision" --arg checkout "$checkout_dir" --arg state "$state" \
    '. + [{id: $id, repository: $repository, revision: $revision, checkout: $checkout, state: $state}]' \
    "$report_items" > "$report_next"
  mv "$report_next" "$report_items"
  echo "$current_id: $revision"
done < <(jq -r "$selection | [.id, .repository.checkoutDirectory, .repository.slug, .repository.revision, .repository.submodules] | @tsv" "$catalog_file")

jq '{generatedAt: (now | todateiso8601), projects: .}' "$report_items" > "$workspace_dir/catalog/sync-report.json"
echo "$workspace_dir/catalog/sync-report.json"
