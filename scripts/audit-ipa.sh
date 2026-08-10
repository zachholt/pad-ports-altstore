#!/usr/bin/env bash
set -euo pipefail

workspace_dir="$(cd "$(dirname "$0")/.." && pwd)"
catalog_file="${PAD_PORTS_CATALOG:-$workspace_dir/catalog/projects.json}"
project_id=""
output_file=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project)
      [[ $# -ge 2 ]] || { echo "--project requires an ID." >&2; exit 2; }
      project_id="$2"
      shift 2
      ;;
    --output)
      [[ $# -ge 2 ]] || { echo "--output requires a file." >&2; exit 2; }
      output_file="$2"
      shift 2
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
  echo "Usage: $0 [--project ID] [--output FILE] IPA" >&2
  exit 2
fi
ipa_file="$1"

for dependency in file find jq lipo plutil shasum stat unzip zipinfo xcrun; do
  command -v "$dependency" >/dev/null || { echo "$dependency is required." >&2; exit 1; }
done
[[ -f "$ipa_file" ]] || { echo "IPA not found: $ipa_file" >&2; exit 1; }

version_at_least() {
  awk -v actual="$1" -v required="$2" 'BEGIN {
    actual_count = split(actual, actual_parts, ".")
    required_count = split(required, required_parts, ".")
    count = actual_count > required_count ? actual_count : required_count
    for (part_index = 1; part_index <= count; part_index++) {
      actual_part = part_index <= actual_count ? actual_parts[part_index] + 0 : 0
      required_part = part_index <= required_count ? required_parts[part_index] + 0 : 0
      if (actual_part > required_part) exit 0
      if (actual_part < required_part) exit 1
    }
    exit 0
  }'
}

expected_bundle_id=""
source_revision=""
if [[ -n "$project_id" ]]; then
  "$workspace_dir/scripts/validate-catalog.sh" >/dev/null
  project_json="$(jq -ce --arg id "$project_id" '.projects[] | select(.id == $id)' "$catalog_file")" || {
    echo "Unknown project: $project_id" >&2
    exit 1
  }
  expected_bundle_id="$(jq -r '.build.expectedBundleIdentifier // empty' <<<"$project_json")"
  source_revision="$(jq -r '.repository.revision' <<<"$project_json")"
fi

inspection_dir="$(mktemp -d)"
report_file="$(mktemp)"
trap 'rm -rf "$inspection_dir"; rm -f "$report_file"' EXIT

entries_file="$inspection_dir/archive-entries.txt"
details_file="$inspection_dir/archive-details.txt"
unzip -Z1 "$ipa_file" > "$entries_file"
zipinfo -l "$ipa_file" > "$details_file"

if grep -Eq '(^/|(^|/)\.\.(/|$))' "$entries_file"; then
  echo "IPA contains an unsafe archive path." >&2
  exit 1
fi
if awk '$1 ~ /^l/ { found = 1 } END { exit found ? 0 : 1 }' "$details_file"; then
  echo "IPA contains a symlink." >&2
  exit 1
fi

entry_count="$(wc -l < "$entries_file" | tr -d ' ')"
uncompressed_size="$(awk '$1 ~ /^[-d]/ { total += $4 } END { printf "%.0f", total }' "$details_file")"
[[ "$entry_count" -le 100000 ]] || { echo "IPA contains too many archive entries." >&2; exit 1; }
[[ "$uncompressed_size" -le 4294967296 ]] || { echo "IPA expands beyond the 4 GiB audit limit." >&2; exit 1; }

unzip -tqq "$ipa_file"
unzip -qq "$ipa_file" -d "$inspection_dir/extracted"

payload_dir="$inspection_dir/extracted/Payload"
[[ -d "$payload_dir" ]] || { echo "IPA has no Payload directory." >&2; exit 1; }
app_count="$(find "$payload_dir" -maxdepth 1 -type d -name '*.app' -print | wc -l | tr -d ' ')"
[[ "$app_count" -eq 1 ]] || { echo "IPA must contain exactly one top-level app." >&2; exit 1; }
app_bundle="$(find "$payload_dir" -maxdepth 1 -type d -name '*.app' -print -quit)"

if find "$app_bundle" -mindepth 1 -type d \( -name '*.app' -o -name '*.appex' \) -print -quit | grep -q .; then
  echo "IPA contains a nested app or extension bundle." >&2
  exit 1
fi

info_file="$app_bundle/Info.plist"
[[ -f "$info_file" ]] || { echo "App has no Info.plist." >&2; exit 1; }
info_json="$inspection_dir/Info.json"
plutil -convert json -o "$info_json" "$info_file"

bundle_id="$(jq -r '.CFBundleIdentifier // empty' "$info_json")"
app_name="$(jq -r '.CFBundleDisplayName // .CFBundleName // empty' "$info_json")"
version="$(jq -r '.CFBundleShortVersionString // empty' "$info_json")"
build_version="$(jq -r '.CFBundleVersion // empty' "$info_json")"
minimum_os="$(jq -r '.MinimumOSVersion // .LSMinimumSystemVersion // empty' "$info_json")"
executable_name="$(jq -r '.CFBundleExecutable // empty' "$info_json")"
device_families="$(jq -c '.UIDeviceFamily // [] | sort' "$info_json")"
supported_platforms="$(jq -c '.CFBundleSupportedPlatforms // [] | sort' "$info_json")"
privacy_keys="$(jq -c 'with_entries(select(.key | endswith("UsageDescription"))) | keys | sort' "$info_json")"
privacy="$(jq -c 'with_entries(select(.key | endswith("UsageDescription")))' "$info_json")"

[[ -n "$bundle_id" && -n "$version" && -n "$build_version" && -n "$minimum_os" ]] || {
  echo "App metadata is incomplete." >&2
  exit 1
}
[[ "$minimum_os" =~ ^[0-9]+([.][0-9]+){0,2}$ ]] || {
  echo "App declares an invalid minimum OS version: $minimum_os" >&2
  exit 1
}
[[ "$executable_name" =~ ^[^/]+$ ]] || { echo "CFBundleExecutable must be a basename." >&2; exit 1; }
jq -e '(.UIDeviceFamily // []) | index(2) != null' "$info_json" >/dev/null || {
  echo "App does not declare iPad support." >&2
  exit 1
}
[[ "$supported_platforms" == '["iPhoneOS"]' ]] || {
  echo "App is not an iPhoneOS device bundle: $supported_platforms" >&2
  exit 1
}
if [[ -n "$expected_bundle_id" && "$bundle_id" != "$expected_bundle_id" ]]; then
  echo "Bundle ID mismatch: expected $expected_bundle_id, got $bundle_id." >&2
  exit 1
fi

executable_file="$app_bundle/$executable_name"
[[ -f "$executable_file" ]] || { echo "App executable is missing." >&2; exit 1; }
file -b "$executable_file" | grep -q 'Mach-O' || {
  echo "CFBundleExecutable is not a Mach-O executable." >&2
  exit 1
}

mach_o_count=0
maximum_binary_minimum_os=""
while IFS= read -r candidate_file; do
  if ! file -b "$candidate_file" | grep -q 'Mach-O'; then
    continue
  fi
  mach_o_count=$((mach_o_count + 1))
  architectures="$(lipo -archs "$candidate_file" | xargs)"
  [[ "$architectures" == "arm64" ]] || {
    echo "Mach-O architecture set is not exactly arm64: ${candidate_file#"$app_bundle/"} ($architectures)" >&2
    exit 1
  }
  build_metadata="$(xcrun vtool -show-build "$candidate_file" 2>/dev/null)"
  platform="$(awk '$1 == "platform" { print $2; exit }' <<<"$build_metadata")"
  [[ "$platform" == "IOS" ]] || {
    echo "Mach-O is not built for iPhoneOS: ${candidate_file#"$app_bundle/"} ($platform)" >&2
    exit 1
  }
  binary_minimum_os="$(awk '$1 == "minos" { print $2; exit }' <<<"$build_metadata")"
  [[ "$binary_minimum_os" =~ ^[0-9]+([.][0-9]+){0,2}$ ]] || {
    echo "Mach-O has no valid deployment target: ${candidate_file#"$app_bundle/"}" >&2
    exit 1
  }
  if [[ -z "$maximum_binary_minimum_os" ]] || ! version_at_least "$maximum_binary_minimum_os" "$binary_minimum_os"; then
    maximum_binary_minimum_os="$binary_minimum_os"
  fi
  if xcrun otool -l "$candidate_file" 2>/dev/null | awk '
    $1 == "cmd" && ($2 == "LC_ENCRYPTION_INFO" || $2 == "LC_ENCRYPTION_INFO_64") { capture = 1; next }
    capture && $1 == "cryptid" { if ($2 != 0) encrypted = 1; capture = 0 }
    END { exit encrypted ? 0 : 1 }
  '; then
    echo "Mach-O is encrypted and cannot be redistributed for user-side signing: ${candidate_file#"$app_bundle/"}" >&2
    exit 1
  fi
done < <(find "$app_bundle" -type f -print)
[[ "$mach_o_count" -gt 0 ]] || { echo "App contains no Mach-O executable." >&2; exit 1; }
version_at_least "$minimum_os" "$maximum_binary_minimum_os" || {
  echo "Info.plist minimum OS $minimum_os is lower than the Mach-O deployment target $maximum_binary_minimum_os." >&2
  exit 1
}

for forbidden_extension in iso gcm rvz wia wbfs ciso gcz nfs tgc z64 n64 v64 rom nes sfc smc gb gbc gba nds 3ds cia chd mpq; do
  if find "$inspection_dir/extracted" -type f -iname "*.$forbidden_extension" -print -quit | grep -q .; then
    echo "IPA contains forbidden game-data extension .$forbidden_extension." >&2
    exit 1
  fi
done
if find "$inspection_dir/extracted" -type f \( \
  -name embedded.mobileprovision \
  -o -iname '*.p12' \
  -o -iname '*.p8' \
  -o -iname '*.pem' \
  -o -iname '*.key' \
  -o -iname '*.cer' \
  -o -iname '*.mobileprovision' \
\) -print -quit | grep -q .; then
  echo "IPA contains provisioning or signing material." >&2
  exit 1
fi

signed=false
entitlements='[]'
if [[ -d "$app_bundle/_CodeSignature" ]]; then
  signed=true
  signed_entitlements="$inspection_dir/entitlements.plist"
  if codesign -d --entitlements :- "$app_bundle" > "$signed_entitlements" 2>/dev/null; then
    plutil -convert json -o "$inspection_dir/entitlements.json" "$signed_entitlements"
    entitlements="$(jq -c 'keys | map(select(. != "application-identifier" and . != "com.apple.developer.team-identifier")) | sort' "$inspection_dir/entitlements.json")"
  fi
fi
[[ "$signed" == "false" ]] || {
  echo "IPA contains an existing code signature; publish an unsigned package for user-side signing." >&2
  exit 1
}

framework_count="$(find "$app_bundle" -type d -name '*.framework' -print | wc -l | tr -d ' ')"
ipa_size="$(stat -f '%z' "$ipa_file" 2>/dev/null || stat -c '%s' "$ipa_file")"
ipa_sha256="$(shasum -a 256 "$ipa_file" | awk '{print $1}')"

jq -n \
  --arg projectId "$project_id" \
  --arg sourceRevision "$source_revision" \
  --arg fileName "$(basename "$ipa_file")" \
  --arg bundleIdentifier "$bundle_id" \
  --arg appName "$app_name" \
  --arg version "$version" \
  --arg buildVersion "$build_version" \
  --arg minimumOS "$minimum_os" \
  --arg binaryMinimumOS "$maximum_binary_minimum_os" \
  --arg sha256 "$ipa_sha256" \
  --argjson size "$ipa_size" \
  --argjson entryCount "$entry_count" \
  --argjson uncompressedSize "$uncompressed_size" \
  --argjson deviceFamilies "$device_families" \
  --argjson supportedPlatforms "$supported_platforms" \
  --argjson privacyKeys "$privacy_keys" \
  --argjson privacy "$privacy" \
  --argjson entitlements "$entitlements" \
  --argjson signed "$signed" \
  --argjson machOCount "$mach_o_count" \
  --argjson embeddedFrameworkCount "$framework_count" \
  '{
    projectId: $projectId,
    sourceRevision: $sourceRevision,
    fileName: $fileName,
    size: $size,
    sha256: $sha256,
    archive: {entryCount: $entryCount, uncompressedSize: $uncompressedSize},
    app: {
      name: $appName,
      bundleIdentifier: $bundleIdentifier,
      version: $version,
      buildVersion: $buildVersion,
      minimumOS: $minimumOS,
      binaryMinimumOS: $binaryMinimumOS,
      deviceFamilies: $deviceFamilies,
      supportedPlatforms: $supportedPlatforms,
      architectures: ["arm64"],
      machOCount: $machOCount,
      embeddedFrameworkCount: $embeddedFrameworkCount,
      signed: $signed,
      entitlements: $entitlements,
      privacyKeys: $privacyKeys,
      privacy: $privacy
    }
  }' > "$report_file"

if [[ -n "$output_file" ]]; then
  mkdir -p "$(dirname "$output_file")"
  cp "$report_file" "$output_file"
  jq . "$output_file"
else
  jq . "$report_file"
fi
