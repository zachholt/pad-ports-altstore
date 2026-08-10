#!/usr/bin/env bash
set -euo pipefail

workspace_dir="$(cd "$(dirname "$0")/.." && pwd)"
catalog_file="${PAD_PORTS_CATALOG:-$workspace_dir/catalog/projects.json}"
dry_run=0
install_dependencies=0
skip_sync=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      dry_run=1
      shift
      ;;
    --install-dependencies)
      install_dependencies=1
      shift
      ;;
    --skip-sync)
      skip_sync=1
      shift
      ;;
    --)
      shift
      break
      ;;
    -*)
      echo "Unknown option: $1" >&2
      exit 2
      ;;
    *)
      break
      ;;
  esac
done

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 [--dry-run] [--install-dependencies] [--skip-sync] PROJECT_ID" >&2
  exit 2
fi
project_id="$1"

for dependency in git jq shasum; do
  command -v "$dependency" >/dev/null || { echo "$dependency is required." >&2; exit 1; }
done
"$workspace_dir/scripts/validate-catalog.sh" >/dev/null

project_json="$(jq -ce --arg id "$project_id" '.projects[] | select(.id == $id)' "$catalog_file")" || {
  echo "Unknown project: $project_id" >&2
  exit 1
}
build_state="$(jq -r '.build.state' <<<"$project_json")"
[[ "$build_state" == "ready" || "$build_state" == "auditBlocked" ]] || {
  echo "$project_id does not have an automated build recipe (state: $build_state)." >&2
  exit 1
}
if [[ "$build_state" == "auditBlocked" ]]; then
  echo "Warning: $project_id has a known IPA audit blocker; this build is diagnostic only." >&2
fi

recipe_relative="$(jq -r '.build.recipe' <<<"$project_json")"
recipe_file="$workspace_dir/$recipe_relative"
revision="$(jq -r '.repository.revision' <<<"$project_json")"
checkout_name="$(jq -r '.repository.checkoutDirectory' <<<"$project_json")"
project_dir="$workspace_dir/upstreams/$checkout_name"
submodule_mode="$(jq -r '.repository.submodules' <<<"$project_json")"
packages="$(jq -r '.build.brewPackages[]' <<<"$project_json")"

echo "Project:  $project_id"
echo "Revision: $revision"
echo "Recipe:   $recipe_relative"
if [[ -n "$packages" ]]; then
  echo "Homebrew: $(tr '\n' ' ' <<<"$packages" | xargs)"
fi

if [[ "$dry_run" -eq 1 ]]; then
  exit 0
fi

if [[ "$install_dependencies" -eq 1 && -n "$packages" ]]; then
  command -v brew >/dev/null || { echo "Homebrew is required to install recipe dependencies." >&2; exit 1; }
  while IFS= read -r package_name; do
    if brew list --versions "$package_name" >/dev/null 2>&1; then
      continue
    fi
    if ! HOMEBREW_NO_AUTO_UPDATE=1 brew install "$package_name"; then
      # Homebrew can install a formula successfully but return nonzero when an
      # unrelated executable already occupies one of its link destinations.
      brew list --versions "$package_name" >/dev/null 2>&1 || exit 1
      echo "Warning: $package_name installed but Homebrew reported a link conflict; continuing to the build." >&2
    fi
  done <<<"$packages"
fi

if [[ "$skip_sync" -eq 0 ]]; then
  "$workspace_dir/scripts/sync-repositories.sh" --project "$project_id"
fi
[[ -d "$project_dir/.git" ]] || { echo "Checkout is missing: $project_dir" >&2; exit 1; }
[[ -z "$(git -C "$project_dir" status --porcelain)" ]] || { echo "Refusing dirty checkout: $project_id" >&2; exit 1; }
[[ "$(git -C "$project_dir" rev-parse HEAD)" == "$revision" ]] || { echo "Checkout revision does not match the catalog." >&2; exit 1; }

build_root="$workspace_dir/.build/standalone-builds"
mkdir -p "$build_root"
working_dir="$(mktemp -d "$build_root/$project_id.XXXXXX")"
recipe_output="$working_dir/output"
mkdir -p "$recipe_output"
recipe_source="$working_dir/source"
git -C "$project_dir" worktree add --detach "$recipe_source" "$revision" >/dev/null
cleanup_recipe_source() {
  git -C "$project_dir" worktree remove --force --force "$recipe_source" >/dev/null 2>&1 || {
    echo "Warning: could not remove isolated recipe worktree: $recipe_source" >&2
  }
}
trap cleanup_recipe_source EXIT

if [[ "$submodule_mode" == "recursive" ]]; then
  git -C "$recipe_source" submodule update --init --recursive --depth=1
fi

PAD_PORTS_PROJECT_ID="$project_id" \
PAD_PORTS_PROJECT_DIR="$recipe_source" \
PAD_PORTS_OUTPUT_DIR="$recipe_output" \
PAD_PORTS_SOURCE_REVISION="$revision" \
  "$recipe_file"

ipa_count="$(find "$recipe_output" -maxdepth 1 -type f -name '*.ipa' -print | wc -l | tr -d ' ')"
[[ "$ipa_count" -eq 1 ]] || {
  echo "Recipe must produce exactly one IPA in $recipe_output; found $ipa_count." >&2
  exit 1
}
ipa_file="$(find "$recipe_output" -maxdepth 1 -type f -name '*.ipa' -print -quit)"
audit_file="$working_dir/audit.json"
"$workspace_dir/scripts/audit-ipa.sh" --project "$project_id" --output "$audit_file" "$ipa_file" >/dev/null

final_dir="$workspace_dir/artifacts/builds/$project_id/$revision"
mkdir -p "$final_dir"
final_ipa="$final_dir/$(basename "$ipa_file")"
final_audit="$final_dir/audit.json"
cp "$ipa_file" "$final_ipa"
cp "$audit_file" "$final_audit"

xcode_version="$(xcodebuild -version 2>/dev/null | tr '\n' ' ' | xargs || true)"
sdk_version="$(xcrun --sdk iphoneos --show-sdk-version 2>/dev/null || true)"
cmake_version="$(cmake --version 2>/dev/null | awk 'NR == 1 {print $3}' || true)"
recipe_sha256="$(shasum -a 256 "$recipe_file" | awk '{print $1}')"
provenance_file="$final_dir/provenance.json"
jq -n \
  --arg projectId "$project_id" \
  --arg repository "$(jq -r '.repository.slug' <<<"$project_json")" \
  --arg sourceRevision "$revision" \
  --arg recipe "$recipe_relative" \
  --arg recipeSHA256 "$recipe_sha256" \
  --arg workflowRevision "${GITHUB_SHA:-local}" \
  --arg xcode "$xcode_version" \
  --arg sdk "$sdk_version" \
  --arg cmake "$cmake_version" \
  --arg builtAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --slurpfile audit "$final_audit" \
  '{
    projectId: $projectId,
    repository: $repository,
    sourceRevision: $sourceRevision,
    recipe: $recipe,
    recipeSHA256: $recipeSHA256,
    orchestratorRevision: $workflowRevision,
    toolchain: {xcode: $xcode, iphoneOSSDK: $sdk, cmake: $cmake},
    builtAt: $builtAt,
    artifact: $audit[0]
  }' > "$provenance_file"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    echo "ipa=$final_ipa"
    echo "artifact_directory=$final_dir"
  } >> "$GITHUB_OUTPUT"
fi

echo "$final_ipa"
echo "$provenance_file"
