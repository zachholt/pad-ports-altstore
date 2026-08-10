#!/usr/bin/env bash
set -euo pipefail

workspace_dir="$(cd "$(dirname "$0")/.." && pwd)"
catalog_file="${PAD_PORTS_CATALOG:-$workspace_dir/catalog/projects.json}"
project_id=""
requested_tag=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project)
      [[ $# -ge 2 ]] || { echo "--project requires an ID." >&2; exit 2; }
      project_id="$2"
      shift 2
      ;;
    --tag)
      [[ $# -ge 2 ]] || { echo "--tag requires a release tag." >&2; exit 2; }
      requested_tag="$2"
      shift 2
      ;;
    *)
      echo "Usage: $0 --project ID [--tag TAG]" >&2
      exit 2
      ;;
  esac
done

[[ -n "$project_id" ]] || { echo "--project is required." >&2; exit 2; }
if [[ -n "$requested_tag" && ! "$requested_tag" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]]; then
  echo "Release tags must contain only letters, numbers, dot, underscore, plus, and hyphen." >&2
  exit 2
fi

for dependency in gh jq shasum stat unzip; do
  command -v "$dependency" >/dev/null || { echo "$dependency is required." >&2; exit 1; }
done
[[ -x /usr/bin/curl ]] || { echo "/usr/bin/curl is required." >&2; exit 1; }
"$workspace_dir/scripts/validate-catalog.sh" >/dev/null

project_json="$(jq -ce --arg id "$project_id" '.projects[] | select(.id == $id)' "$catalog_file")" || {
  echo "Unknown project: $project_id" >&2
  exit 1
}

[[ "$(jq -r '.altStore.status' <<<"$project_json")" == "eligible" ]] || {
  echo "$project_id is not approved for publication." >&2
  exit 1
}
[[ "$(jq -r '.altStore.delivery' <<<"$project_json")" == "upstreamRelease" ]] || {
  echo "$project_id does not use project-owned upstream releases." >&2
  exit 1
}
[[ "$(jq -r '.legal.distributionReview' <<<"$project_json")" == "approvedForDirectLink" ]] || {
  echo "$project_id is not approved for direct linking." >&2
  exit 1
}

repository_slug="$(jq -r '.repository.slug' <<<"$project_json")"
artifact_repository="$(jq -r --arg fallback "$repository_slug" '.altStore.versions[0].artifactRepository // $fallback' <<<"$project_json")"
[[ "$artifact_repository" == "$repository_slug" ]] || {
  echo "Automated imports require the release asset and source tag to share the project repository." >&2
  exit 1
}

if [[ -n "$requested_tag" ]]; then
  release_json="$(gh api "repos/$artifact_repository/releases/tags/$requested_tag")" || {
    echo "Release not found: $artifact_repository $requested_tag" >&2
    exit 1
  }
else
  release_json="$(gh api "repos/$artifact_repository/releases?per_page=100" | jq -ce '
    [.[]
      | select(.draft == false)
      | . as $release
      | [$release.assets[]? | select(.name | ascii_downcase | endswith(".ipa"))] as $ipas
      | select(($ipas | length) == 1)
    ][0]
  ')" || {
    echo "No published release with exactly one IPA was found for $artifact_repository." >&2
    exit 1
  }
fi

[[ "$(jq -r '.draft' <<<"$release_json")" == "false" ]] || {
  echo "Draft releases cannot be imported." >&2
  exit 1
}

release_tag="$(jq -r '.tag_name' <<<"$release_json")"
[[ "$release_tag" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]] || {
  echo "The selected release tag is not safe for the deterministic asset cache: $release_tag" >&2
  exit 1
}

ipa_count="$(jq '[.assets[]? | select(.name | ascii_downcase | endswith(".ipa"))] | length' <<<"$release_json")"
[[ "$ipa_count" -eq 1 ]] || {
  echo "The selected release must contain exactly one IPA; found $ipa_count." >&2
  exit 1
}

asset_json="$(jq -ce '[.assets[] | select(.name | ascii_downcase | endswith(".ipa"))][0]' <<<"$release_json")"
asset_name="$(jq -r '.name' <<<"$asset_json")"
[[ "$asset_name" =~ ^[A-Za-z0-9._-]+\.ipa$ ]] || {
  echo "IPA asset name is not safe: $asset_name" >&2
  exit 1
}
download_url="$(jq -r '.browser_download_url' <<<"$asset_json")"
expected_url="https://github.com/$artifact_repository/releases/download/$release_tag/$asset_name"
[[ "$download_url" == "$expected_url" ]] || {
  echo "GitHub returned an unexpected asset URL." >&2
  exit 1
}

if jq -e --arg tag "$release_tag" '.altStore.versions[] | select(.tag == $tag)' <<<"$project_json" >/dev/null; then
  echo "$project_id already contains $release_tag; no catalog change was made."
  exit 0
fi

source_revision="$(gh api "repos/$repository_slug/commits/$release_tag" --jq .sha)" || {
  echo "The release tag does not resolve to a source commit in $repository_slug." >&2
  exit 1
}
[[ "$source_revision" =~ ^[0-9a-f]{40}$ ]] || {
  echo "The release tag did not resolve to a full commit SHA." >&2
  exit 1
}

working_dir="$(mktemp -d)"
trap 'rm -rf "$working_dir"' EXIT
ipa_file="$working_dir/$asset_name"
/usr/bin/curl --fail --location --silent --show-error "$download_url" --output "$ipa_file"

file_size() {
  stat -f '%z' "$1" 2>/dev/null || stat -c '%s' "$1"
}

actual_size="$(file_size "$ipa_file")"
reported_size="$(jq -r '.size' <<<"$asset_json")"
[[ "$actual_size" == "$reported_size" ]] || {
  echo "Downloaded IPA size does not match GitHub's live asset metadata." >&2
  exit 1
}
actual_sha256="$(shasum -a 256 "$ipa_file" | awk '{print $1}')"

audit_file="$working_dir/audit.json"
"$workspace_dir/scripts/audit-ipa.sh" --output "$audit_file" "$ipa_file" >/dev/null

previous_audit="$(jq -ce '.altStore.versions[0].audit' <<<"$project_json")"
assert_equal() {
  local actual_query="$1"
  local expected_query="$2"
  local label="$3"
  local actual_value expected_value
  actual_value="$(jq -c "$actual_query" "$audit_file")"
  expected_value="$(jq -c "$expected_query" <<<"$previous_audit")"
  [[ "$actual_value" == "$expected_value" ]] || {
    echo "$project_id $release_tag changed $label; review it manually before publication." >&2
    exit 1
  }
}

assert_equal '.app.bundleIdentifier' '.bundleIdentifier' 'the bundle identifier'
assert_equal '.app.deviceFamilies | sort' '.deviceFamilies | sort' 'device families'
assert_equal '.app.architectures | sort' '.architectures | sort' 'architectures'
assert_equal '.app.supportedPlatforms | sort' '.supportedPlatforms | sort' 'supported platforms'
assert_equal '.app.entitlements | sort' '.entitlements | sort' 'entitlements'
assert_equal '.app.privacy | to_entries | sort_by(.key)' '.privacy | to_entries | sort_by(.key)' 'privacy declarations'
assert_equal '.app.machOCount' '.machOCount' 'the Mach-O inventory'
assert_equal '.app.embeddedFrameworkCount' '.embeddedFrameworkCount' 'the embedded-framework count'

entry_count="$(jq -r '.archive.entryCount' "$audit_file")"
uncompressed_size="$(jq -r '.archive.uncompressedSize' "$audit_file")"
maximum_entry_count="$(jq -r '.maximumEntryCount' <<<"$previous_audit")"
maximum_uncompressed_size="$(jq -r '.maximumUncompressedSize' <<<"$previous_audit")"
[[ "$entry_count" -le "$maximum_entry_count" ]] || {
  echo "$project_id $release_tag exceeds the reviewed archive-entry bound." >&2
  exit 1
}
[[ "$uncompressed_size" -le "$maximum_uncompressed_size" ]] || {
  echo "$project_id $release_tag exceeds the reviewed uncompressed-size bound." >&2
  exit 1
}

while IFS= read -r forbidden_extension; do
  if unzip -Z1 "$ipa_file" | awk -v extension="$forbidden_extension" 'BEGIN {IGNORECASE=1} $0 ~ "\\." extension "$" {found=1} END {exit found ? 0 : 1}'; then
    echo "$project_id $release_tag contains forbidden game-data extension .$forbidden_extension." >&2
    exit 1
  fi
done < <(jq -r '.forbiddenGameDataExtensions[]' <<<"$previous_audit")

release_audit="$(jq -n \
  --arg bundleIdentifier "$(jq -r '.app.bundleIdentifier' "$audit_file")" \
  --arg version "$(jq -r '.app.version' "$audit_file")" \
  --arg buildVersion "$(jq -r '.app.buildVersion' "$audit_file")" \
  --arg minimumOS "$(jq -r '.app.minimumOS' "$audit_file")" \
  --argjson deviceFamilies "$(jq -c '.app.deviceFamilies' "$audit_file")" \
  --argjson architectures "$(jq -c '.app.architectures' "$audit_file")" \
  --argjson supportedPlatforms "$(jq -c '.app.supportedPlatforms' "$audit_file")" \
  --argjson entitlements "$(jq -c '.app.entitlements' "$audit_file")" \
  --argjson privacy "$(jq -c '.app.privacy' "$audit_file")" \
  --argjson machOCount "$(jq -c '.app.machOCount' "$audit_file")" \
  --argjson embeddedFrameworkCount "$(jq -c '.app.embeddedFrameworkCount' "$audit_file")" \
  --argjson maximumEntryCount "$maximum_entry_count" \
  --argjson maximumUncompressedSize "$maximum_uncompressed_size" \
  --argjson forbiddenGameDataExtensions "$(jq -c '.forbiddenGameDataExtensions' <<<"$previous_audit")" \
  '{
    bundleIdentifier: $bundleIdentifier,
    version: $version,
    buildVersion: $buildVersion,
    minimumOS: $minimumOS,
    deviceFamilies: $deviceFamilies,
    architectures: $architectures,
    supportedPlatforms: $supportedPlatforms,
    entitlements: $entitlements,
    privacy: $privacy,
    machOCount: $machOCount,
    embeddedFrameworkCount: $embeddedFrameworkCount,
    maximumEntryCount: $maximumEntryCount,
    maximumUncompressedSize: $maximumUncompressedSize,
    forbiddenGameDataExtensions: $forbiddenGameDataExtensions
  }')"

project_name="$(jq -r '.name' <<<"$project_json")"
published_at="$(jq -r '.published_at' <<<"$release_json")"
release_version="$(jq -n \
  --arg tag "$release_tag" \
  --arg sourceRevision "$source_revision" \
  --arg pageURL "https://github.com/$artifact_repository/releases/tag/$release_tag" \
  --arg assetName "$asset_name" \
  --arg downloadURL "$download_url" \
  --arg publishedAt "$published_at" \
  --arg sha256 "$actual_sha256" \
  --arg versionDescription "Project-owned $project_name $release_tag IPA, audited as a ROM-free arm64 iPhoneOS build." \
  --argjson size "$actual_size" \
  --argjson audit "$release_audit" \
  '{
    tag: $tag,
    sourceRevision: $sourceRevision,
    pageURL: $pageURL,
    assetName: $assetName,
    downloadURL: $downloadURL,
    publishedAt: $publishedAt,
    size: $size,
    sha256: $sha256,
    versionDescription: $versionDescription,
    audit: $audit
  }')"

next_catalog="$working_dir/projects.json"
jq --arg id "$project_id" --argjson version "$release_version" '
  (.projects[] | select(.id == $id) | .altStore.versions) |= ([$version] + . | sort_by(.publishedAt) | reverse)
' "$catalog_file" > "$next_catalog"

PAD_PORTS_CATALOG="$next_catalog" "$workspace_dir/scripts/validate-catalog.sh" >/dev/null
cache_dir="${PAD_PORTS_ASSET_CACHE:-$workspace_dir/.build/store-source/assets}/$project_id/$release_tag"
mkdir -p "$cache_dir"
cp "$ipa_file" "$cache_dir/$asset_name"
mv "$next_catalog" "$catalog_file"

echo "Imported $project_id $release_tag"
echo "  version: $(jq -r '.app.version' "$audit_file") ($(jq -r '.app.buildVersion' "$audit_file"))"
echo "  source:  $source_revision"
echo "  SHA-256: $actual_sha256"
echo "Review the catalog diff, then regenerate the AltStore source."
