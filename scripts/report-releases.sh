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

items_file="$(mktemp)"
next_file="$(mktemp)"
report_file="$(mktemp)"
trap 'rm -f "$items_file" "$next_file" "$report_file"' EXIT
printf '[]\n' > "$items_file"

while IFS=$'\t' read -r project_id slug current_tag current_asset_name current_size current_sha256; do
  release_json="$(gh api "repos/$slug/releases?per_page=20" | jq -c '
    [
      .[] as $release
      | [$release.assets[]? | select(.name | ascii_downcase | endswith(".ipa"))] as $ipas
      | select(($ipas | length) == 1)
      | {
          tag: $release.tag_name,
          publishedAt: $release.published_at,
          assetName: $ipas[0].name,
          assetSize: $ipas[0].size,
          assetDigest: ($ipas[0].digest // ""),
          downloadURL: $ipas[0].browser_download_url
        }
    ][0] // null
  ')"

  if [[ "$release_json" == "null" ]]; then
    state="noSingleIPARelease"
    latest_tag=""
    asset_name=""
    asset_size=""
    asset_digest=""
    published_at=""
    download_url=""
  else
    latest_tag="$(jq -r '.tag' <<<"$release_json")"
    asset_name="$(jq -r '.assetName' <<<"$release_json")"
    asset_size="$(jq -r '.assetSize' <<<"$release_json")"
    asset_digest="$(jq -r '.assetDigest | sub("^sha256:"; "")' <<<"$release_json")"
    published_at="$(jq -r '.publishedAt' <<<"$release_json")"
    download_url="$(jq -r '.downloadURL' <<<"$release_json")"
    state="current"
    if [[ "$latest_tag" != "$current_tag" ]]; then
      state="updateAvailable"
    elif [[ "$asset_name" != "$current_asset_name" || "$asset_size" != "$current_size" ]]; then
      state="artifactChanged"
    elif [[ -n "$asset_digest" && "$asset_digest" != "$current_sha256" ]]; then
      state="artifactChanged"
    elif [[ -z "$asset_digest" ]]; then
      state="digestUnavailable"
    fi
  fi

  jq --arg id "$project_id" \
     --arg repository "$slug" \
     --arg currentTag "$current_tag" \
     --arg currentAssetName "$current_asset_name" \
     --arg currentSHA256 "$current_sha256" \
     --arg latestTag "$latest_tag" \
     --arg assetName "$asset_name" \
     --arg assetDigest "$asset_digest" \
     --arg publishedAt "$published_at" \
     --arg downloadURL "$download_url" \
     --arg state "$state" \
     --argjson currentSize "${current_size:-0}" \
     --argjson assetSize "${asset_size:-0}" \
     '. + [{id: $id, repository: $repository, currentTag: $currentTag, currentAssetName: $currentAssetName, currentSize: $currentSize, currentSHA256: $currentSHA256, latestTag: $latestTag, assetName: $assetName, assetSize: $assetSize, assetDigest: $assetDigest, publishedAt: $publishedAt, downloadURL: $downloadURL, state: $state}]' \
     "$items_file" > "$next_file"
  mv "$next_file" "$items_file"
done < <(jq -r '.projects[] | select(.altStore.delivery == "upstreamRelease") | [.id, .repository.slug, (.altStore.versions[0].tag // ""), (.altStore.versions[0].assetName // ""), (.altStore.versions[0].size // 0), (.altStore.versions[0].sha256 // "")] | @tsv' "$catalog_file")

jq '{generatedAt: (now | todateiso8601), updates: [.[] | select(.state == "updateAvailable")], alerts: [.[] | select(.state != "current" and .state != "updateAvailable")], projects: .}' \
  "$items_file" > "$report_file"

if [[ -n "$output_file" ]]; then
  mkdir -p "$(dirname "$output_file")"
  mv "$report_file" "$output_file"
  final_report="$output_file"
else
  final_report="$report_file"
fi
jq . "$final_report"
