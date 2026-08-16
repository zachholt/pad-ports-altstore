#!/usr/bin/env bash
set -euo pipefail

workspace_dir="$(cd "$(dirname "$0")/.." && pwd)"
catalog_file="${PAD_PORTS_CATALOG:-$workspace_dir/catalog/projects.json}"
output_file="${PAD_PORTS_SOURCE_OUTPUT:-$workspace_dir/altstore/source.json}"
cache_dir="${PAD_PORTS_ASSET_CACHE:-$workspace_dir/.build/store-source/assets}"
offline=0

if [[ "${1:-}" == "--offline" ]]; then
  offline=1
  shift
fi
if [[ $# -ne 0 ]]; then
  echo "Usage: $0 [--offline]" >&2
  exit 2
fi

for dependency in git jq shasum stat unzip zipinfo; do
  command -v "$dependency" >/dev/null || { echo "$dependency is required." >&2; exit 1; }
done
[[ -x /usr/bin/curl ]] || { echo "/usr/bin/curl is required." >&2; exit 1; }
"$workspace_dir/scripts/validate-catalog.sh" >/dev/null

file_size() {
  stat -f '%z' "$1" 2>/dev/null || stat -c '%s' "$1"
}

working_dir="$(mktemp -d)"
trap 'rm -rf "$working_dir"' EXIT
apps_file="$working_dir/apps.json"
printf '[]\n' > "$apps_file"
mkdir -p "$cache_dir"

while IFS= read -r project; do
  project_id="$(jq -r '.id' <<<"$project")"
  repository_slug="$(jq -r '.repository.slug' <<<"$project")"
  delivery_mode="$(jq -r '.altStore.delivery' <<<"$project")"
  versions_file="$working_dir/$project_id-versions.json"
  printf '[]\n' > "$versions_file"

  while IFS= read -r release; do
    release_tag="$(jq -r '.tag' <<<"$release")"
    asset_name="$(jq -r '.assetName' <<<"$release")"
    download_url="$(jq -r '.downloadURL' <<<"$release")"
    artifact_repository="$(jq -r --arg fallback "$repository_slug" '.artifactRepository // $fallback' <<<"$release")"
    source_revision="$(jq -r '.sourceRevision' <<<"$release")"
    if [[ "$delivery_mode" == "upstreamRelease" && "$artifact_repository" != "$repository_slug" ]]; then
      echo "$project_id upstream releases must remain in the project's own repository." >&2
      exit 1
    fi
    expected_url="https://github.com/$artifact_repository/releases/download/$release_tag/$asset_name"
    [[ "$download_url" == "$expected_url" ]] || {
      echo "$project_id release URL does not match its approved artifact repository, tag, and asset." >&2
      exit 1
    }
    [[ "$(jq -r '.pageURL' <<<"$release")" == "https://github.com/$artifact_repository/releases/tag/$release_tag" ]] || {
      echo "$project_id release page does not match its approved artifact repository and tag." >&2
      exit 1
    }

    release_cache="$cache_dir/$project_id/$release_tag"
    mkdir -p "$release_cache"
    ipa_file="$release_cache/$asset_name"
    if [[ "$offline" -eq 0 ]]; then
      tag_refs="$(git ls-remote "https://github.com/$artifact_repository.git" \
        "refs/tags/$release_tag" "refs/tags/$release_tag^{}")"
      peeled_revision="$(awk '$2 ~ /\^\{\}$/ {print $1; exit}' <<<"$tag_refs")"
      direct_revision="$(awk '$2 !~ /\^\{\}$/ {print $1; exit}' <<<"$tag_refs")"
      resolved_revision="${peeled_revision:-$direct_revision}"
      [[ -n "$resolved_revision" && "$resolved_revision" == "$source_revision" ]] || {
        echo "$project_id $release_tag no longer resolves to its reviewed source commit." >&2
        exit 1
      }
      download_file="$working_dir/$project_id-$release_tag.download"
      /usr/bin/curl --fail --location --silent --show-error "$download_url" --output "$download_file"
      candidate_ipa="$download_file"
    else
      [[ -f "$ipa_file" ]] || { echo "Offline cache miss: $ipa_file" >&2; exit 1; }
      candidate_ipa="$ipa_file"
    fi

    actual_size="$(file_size "$candidate_ipa")"
    actual_sha256="$(shasum -a 256 "$candidate_ipa" | awk '{print $1}')"
    expected_size="$(jq -r '.size' <<<"$release")"
    expected_sha256="$(jq -r '.sha256' <<<"$release")"
    [[ "$actual_size" == "$expected_size" ]] || {
      echo "$project_id $release_tag size mismatch: expected $expected_size, got $actual_size." >&2
      exit 1
    }
    [[ "$actual_sha256" == "$expected_sha256" ]] || {
      echo "$project_id $release_tag SHA-256 mismatch." >&2
      exit 1
    }
    if [[ "$offline" -eq 0 ]]; then
      mv "$candidate_ipa" "$ipa_file"
    fi

    audit_file="$working_dir/$project_id-$release_tag-audit.json"
    "$workspace_dir/scripts/audit-ipa.sh" --output "$audit_file" "$ipa_file" >/dev/null
    expected_audit="$(jq -c '.audit' <<<"$release")"

    [[ "$(jq -r '.app.bundleIdentifier' "$audit_file")" == "$(jq -r '.bundleIdentifier' <<<"$expected_audit")" ]] || { echo "$project_id bundle ID changed." >&2; exit 1; }
    [[ "$(jq -r '.app.version' "$audit_file")" == "$(jq -r '.version' <<<"$expected_audit")" ]] || { echo "$project_id version changed." >&2; exit 1; }
    [[ "$(jq -r '.app.buildVersion' "$audit_file")" == "$(jq -r '.buildVersion' <<<"$expected_audit")" ]] || { echo "$project_id build version changed." >&2; exit 1; }
    [[ "$(jq -r '.app.minimumOS' "$audit_file")" == "$(jq -r '.minimumOS' <<<"$expected_audit")" ]] || { echo "$project_id minimum OS changed." >&2; exit 1; }
    [[ "$(jq -c '.app.deviceFamilies | sort' "$audit_file")" == "$(jq -c '.deviceFamilies | sort' <<<"$expected_audit")" ]] || { echo "$project_id device families changed." >&2; exit 1; }
    [[ "$(jq -c '.app.architectures | sort' "$audit_file")" == "$(jq -c '.architectures | sort' <<<"$expected_audit")" ]] || { echo "$project_id architectures changed." >&2; exit 1; }
    [[ "$(jq -c '.app.supportedPlatforms | sort' "$audit_file")" == "$(jq -c '.supportedPlatforms | sort' <<<"$expected_audit")" ]] || { echo "$project_id supported platforms changed." >&2; exit 1; }
    [[ "$(jq -c '.app.entitlements | sort' "$audit_file")" == "$(jq -c '.entitlements | sort' <<<"$expected_audit")" ]] || { echo "$project_id entitlements changed." >&2; exit 1; }
    [[ "$(jq -c '.app.privacy | to_entries | sort_by(.key)' "$audit_file")" == "$(jq -c '.privacy | to_entries | sort_by(.key)' <<<"$expected_audit")" ]] || { echo "$project_id privacy declarations changed." >&2; exit 1; }
    [[ "$(jq -r '.app.machOCount' "$audit_file")" == "$(jq -r '.machOCount' <<<"$expected_audit")" ]] || { echo "$project_id Mach-O inventory changed." >&2; exit 1; }
    [[ "$(jq -r '.app.embeddedFrameworkCount' "$audit_file")" == "$(jq -r '.embeddedFrameworkCount' <<<"$expected_audit")" ]] || { echo "$project_id embedded-framework count changed." >&2; exit 1; }

    entry_count="$(jq -r '.archive.entryCount' "$audit_file")"
    uncompressed_size="$(jq -r '.archive.uncompressedSize' "$audit_file")"
    [[ "$entry_count" -le "$(jq -r '.maximumEntryCount' <<<"$expected_audit")" ]] || { echo "$project_id archive entry bound exceeded." >&2; exit 1; }
    [[ "$uncompressed_size" -le "$(jq -r '.maximumUncompressedSize' <<<"$expected_audit")" ]] || { echo "$project_id archive expansion bound exceeded." >&2; exit 1; }

    while IFS= read -r forbidden_extension; do
      if unzip -Z1 "$ipa_file" | awk -v extension="$forbidden_extension" 'BEGIN {IGNORECASE=1} $0 ~ "\\." extension "$" {found=1} END {exit found ? 0 : 1}'; then
        echo "$project_id contains forbidden game-data extension .$forbidden_extension." >&2
        exit 1
      fi
    done < <(jq -r '.forbiddenGameDataExtensions[]' <<<"$expected_audit")

    while IFS= read -r forbidden_name; do
      if unzip -Z1 "$ipa_file" | awk -F/ -v name="$forbidden_name" '
        BEGIN { IGNORECASE=1 }
        $NF == name { found=1 }
        END { exit found ? 0 : 1 }
      '; then
        echo "$project_id contains forbidden game-data file $forbidden_name." >&2
        exit 1
      fi
    done < <(jq -r '.forbiddenGameDataNames[]?' <<<"$expected_audit")

    version_json="$(jq -n \
      --arg version "$(jq -r '.version' <<<"$expected_audit")" \
      --arg buildVersion "$(jq -r '.buildVersion' <<<"$expected_audit")" \
      --arg date "$(jq -r '.publishedAt' <<<"$release")" \
      --arg localizedDescription "$(jq -r '.versionDescription' <<<"$release")" \
      --arg downloadURL "$download_url" \
      --arg sha256 "$actual_sha256" \
      --arg minOSVersion "$(jq -r '.minimumOS' <<<"$expected_audit")" \
      --argjson size "$actual_size" \
      '{version: $version, buildVersion: $buildVersion, date: $date, localizedDescription: $localizedDescription, downloadURL: $downloadURL, size: $size, sha256: $sha256, minOSVersion: $minOSVersion}')"
    jq --argjson version "$version_json" '. + [$version]' "$versions_file" > "$working_dir/versions.next.json"
    mv "$working_dir/versions.next.json" "$versions_file"
    echo "Audited $project_id $release_tag"
  done < <(jq -c '.altStore.versions[]' <<<"$project")

  jq -e '([.[] | "\(.version)|\(.buildVersion)"] | length) == ([.[] | "\(.version)|\(.buildVersion)"] | unique | length)' "$versions_file" >/dev/null || {
    echo "$project_id repeats an AltStore version/build pair." >&2
    exit 1
  }

  newest_audit="$(jq -c '.altStore.versions[0].audit' <<<"$project")"
  app_json="$(jq -n \
    --arg name "$(jq -r '.altStore.app.name' <<<"$project")" \
    --arg bundleIdentifier "$(jq -r '.bundleIdentifier' <<<"$newest_audit")" \
    --arg developerName "$(jq -r '.altStore.app.developerName' <<<"$project")" \
    --arg subtitle "$(jq -r '.altStore.app.subtitle' <<<"$project")" \
    --arg localizedDescription "$(jq -r '.altStore.app.localizedDescription' <<<"$project")" \
    --arg iconURL "$(jq -r '.altStore.app.iconURL' <<<"$project")" \
    --arg tintColor "$(jq -r '.altStore.app.tintColor' <<<"$project")" \
    --arg category "$(jq -r '.altStore.app.category' <<<"$project")" \
    --slurpfile versions "$versions_file" \
    --argjson entitlements "$(jq -c '.entitlements | sort' <<<"$newest_audit")" \
    --argjson privacy "$(jq -c '.privacy' <<<"$newest_audit")" \
    '{
      name: $name,
      bundleIdentifier: $bundleIdentifier,
      developerName: $developerName,
      subtitle: $subtitle,
      localizedDescription: $localizedDescription,
      iconURL: $iconURL,
      tintColor: $tintColor,
      category: $category,
      versions: $versions[0],
      appPermissions: {
        entitlements: $entitlements,
        privacy: $privacy
      }
    }')"
  jq --argjson app "$app_json" '. + [$app]' "$apps_file" > "$working_dir/apps.next.json"
  mv "$working_dir/apps.next.json" "$apps_file"
done < <(jq -c '.projects[] | select(.altStore.status == "eligible")' "$catalog_file")

mkdir -p "$(dirname "$output_file")"
jq -n \
  --arg name "$(jq -r '.source.name' "$catalog_file")" \
  --arg subtitle "$(jq -r '.source.subtitle' "$catalog_file")" \
  --arg description "$(jq -r '.source.description' "$catalog_file")" \
  --arg tintColor "$(jq -r '.source.tintColor' "$catalog_file")" \
  --slurpfile apps "$apps_file" \
  '{name: $name, subtitle: $subtitle, description: $description, tintColor: $tintColor, apps: $apps[0], news: []}' \
  > "$working_dir/source.json"

jq -e '.apps | length > 0' "$working_dir/source.json" >/dev/null
mv "$working_dir/source.json" "$output_file"
echo "$output_file"
