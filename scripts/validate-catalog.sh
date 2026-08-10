#!/usr/bin/env bash
set -euo pipefail

workspace_dir="$(cd "$(dirname "$0")/.." && pwd)"
catalog_file="${PAD_PORTS_CATALOG:-$workspace_dir/catalog/projects.json}"
verify_remote=0

if [[ "${1:-}" == "--verify-remote" ]]; then
  verify_remote=1
  shift
fi
if [[ $# -ne 0 ]]; then
  echo "Usage: $0 [--verify-remote]" >&2
  exit 2
fi

command -v jq >/dev/null || { echo "jq is required." >&2; exit 1; }
[[ -f "$catalog_file" ]] || { echo "Catalog not found: $catalog_file" >&2; exit 1; }

jq -e '
  .schemaVersion == 1
  and (.accountOwner | type == "string" and length > 0)
  and (.source.name | type == "string" and length > 0)
  and (.source.subtitle | type == "string" and length > 0)
  and (.source.description | type == "string" and length > 0)
  and (.source.tintColor | test("^#[0-9A-Fa-f]{6}$"))
  and (.projects | type == "array" and length > 0)
  and all(.projects[];
    (.id | type == "string" and test("^[a-z0-9][a-z0-9._-]*$"))
    and (.name | type == "string" and length > 0)
    and (.repository.slug | type == "string" and test("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$"))
    and (.repository.defaultBranch | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._/-]*$") and (contains("..") | not))
    and (.repository.revision | type == "string" and test("^[0-9a-f]{40}$"))
    and (.repository.checkoutDirectory | type == "string" and test("^[A-Za-z0-9._-]+$") and . != "." and . != "..")
    and (.repository.checkoutPolicy | IN("default", "optIn"))
    and (.repository.submodules | IN("none", "recipe", "recursive"))
    and (.technical.status | IN("buildRecipeReady", "auditBlocked", "manualBuild", "ciStubOnly", "auditedUpstreamArtifact", "portRequired"))
    and (.technical.note | type == "string" and length > 0)
    and (.legal.spdxExpression | type == "string" and length > 0)
    and (.legal.distributionReview | IN("approvedForDirectLink", "approvedForRehost", "upstreamLinkOnly", "conditionalRehost", "blocked"))
    and (.legal.rehostAllowed | type == "boolean")
    and (.legal.note | type == "string" and length > 0)
    and (.build.state | IN("ready", "auditBlocked", "manual", "none", "upstreamArtifact"))
    and (.build.runner | type == "string" and length > 0)
    and (.build.brewPackages | type == "array" and all(.[]; test("^[a-z0-9@+_.-]+$")))
    and (if (.build.state == "ready" or .build.state == "auditBlocked")
      then
        (.build.recipe | type == "string" and test("^recipes/[a-z0-9._-]+/build\\.sh$"))
        and (.build.expectedBundleIdentifier | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9.-]+$"))
      elif .build.state == "upstreamArtifact"
      then
        .build.recipe == null
        and (.build.expectedBundleIdentifier | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9.-]+$"))
      else
        .build.recipe == null
        and .build.expectedBundleIdentifier == null
      end)
    and (.altStore.status | IN("eligible", "excluded"))
    and (.altStore.delivery | IN("upstreamRelease", "centralRelease", "none"))
    and (.altStore.exclusionReasons | type == "array")
    and (.altStore.versions | type == "array")
    and (if .altStore.status == "excluded"
      then (.altStore.exclusionReasons | length > 0)
      else
        (.altStore.exclusionReasons | length == 0)
        and (.legal.distributionReview == "approvedForDirectLink")
        and (.altStore.delivery == "upstreamRelease")
        and (.altStore.app.name | type == "string" and length > 0)
        and (.altStore.app.developerName | type == "string" and length > 0)
        and (.altStore.app.subtitle | type == "string" and length > 0)
        and (.altStore.app.localizedDescription | type == "string" and length > 0)
        and (.altStore.app.category | type == "string" and IN("games", "utilities", "entertainment"))
        and (.altStore.app.tintColor | test("^#[0-9A-Fa-f]{6}$"))
        and (.altStore.app.iconURL | type == "string" and startswith("https://"))
        and (.altStore.versions | length > 0)
        and ((.repository.slug) as $repositorySlug
          | all(.altStore.versions[]; (.artifactRepository // $repositorySlug) == $repositorySlug))
        and all(.altStore.versions[];
          (.tag | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._+-]*$"))
          and (.sourceRevision | test("^[0-9a-f]{40}$"))
          and (.pageURL | startswith("https://github.com/"))
          and (.assetName | test("^[A-Za-z0-9._-]+\\.ipa$"))
          and (.downloadURL | startswith("https://github.com/"))
          and (.publishedAt | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
          and (.size | type == "number" and . > 0)
          and (.sha256 | test("^[0-9a-f]{64}$"))
          and (.audit.bundleIdentifier | type == "string" and length > 0)
          and (.audit.version | type == "string" and length > 0)
          and (.audit.buildVersion | type == "string" and length > 0)
          and (.audit.minimumOS | type == "string" and length > 0)
          and (.audit.deviceFamilies | type == "array" and index(2) != null)
          and (.audit.architectures == ["arm64"])
          and (.audit.supportedPlatforms == ["iPhoneOS"])
          and (.audit.entitlements | type == "array")
          and (.audit.privacy | type == "object")
          and (.audit.machOCount | type == "number" and . >= 1)
          and (.audit.embeddedFrameworkCount | type == "number" and . >= 0)
          and (.audit.maximumEntryCount | type == "number" and . > 0)
          and (.audit.maximumUncompressedSize | type == "number" and . > 0)
          and (.audit.forbiddenGameDataExtensions | type == "array" and length > 0)
        )
      end)
  )
  and (([.projects[].id] | length) == ([.projects[].id] | unique | length))
  and (([.projects[].repository.slug | ascii_downcase] | length) == ([.projects[].repository.slug | ascii_downcase] | unique | length))
  and (([.projects[].repository.checkoutDirectory | ascii_downcase] | length) == ([.projects[].repository.checkoutDirectory | ascii_downcase] | unique | length))
  and all(.projects[] | select(.altStore.status == "eligible");
    (.altStore.versions[0].audit.bundleIdentifier) as $bundleIdentifier
    | all(.altStore.versions[]; .audit.bundleIdentifier == $bundleIdentifier)
    and ([.altStore.versions[].publishedAt] == ([.altStore.versions[].publishedAt] | sort | reverse))
    and (([.altStore.versions[] | "\(.audit.version)|\(.audit.buildVersion)"] | length)
      == ([.altStore.versions[] | "\(.audit.version)|\(.audit.buildVersion)"] | unique | length))
  )
  and (([.projects[] | select(.altStore.status == "eligible") | .altStore.versions[0].audit.bundleIdentifier] | length)
    == ([.projects[] | select(.altStore.status == "eligible") | .altStore.versions[0].audit.bundleIdentifier] | unique | length))
' "$catalog_file" >/dev/null || {
  echo "Project catalog failed structural or policy validation." >&2
  exit 1
}

while IFS= read -r recipe; do
  recipe_file="$workspace_dir/$recipe"
  [[ -f "$recipe_file" ]] || { echo "Build recipe is missing: $recipe" >&2; exit 1; }
  [[ -x "$recipe_file" ]] || { echo "Build recipe is not executable: $recipe" >&2; exit 1; }
done < <(jq -r '.projects[] | select(.build.state == "ready" or .build.state == "auditBlocked") | .build.recipe' "$catalog_file")

if [[ "$verify_remote" -eq 1 ]]; then
  command -v gh >/dev/null || { echo "gh is required for --verify-remote." >&2; exit 1; }
  while IFS=$'\t' read -r project_id slug revision; do
    resolved_revision="$(gh api "repos/$slug/commits/$revision" --jq .sha 2>/dev/null)" || {
      echo "$project_id revision is not reachable from $slug: $revision" >&2
      exit 1
    }
    [[ "$resolved_revision" == "$revision" ]] || {
      echo "$project_id revision resolved unexpectedly: $resolved_revision" >&2
      exit 1
    }
  done < <(jq -r '.projects[] | [.id, .repository.slug, .repository.revision] | @tsv' "$catalog_file")

  while IFS=$'\t' read -r project_id slug tag source_revision; do
    resolved_revision="$(gh api "repos/$slug/commits/$tag" --jq .sha 2>/dev/null)" || {
      echo "$project_id release tag is not reachable from $slug: $tag" >&2
      exit 1
    }
    [[ "$resolved_revision" == "$source_revision" ]] || {
      echo "$project_id $tag resolves to $resolved_revision, expected $source_revision" >&2
      exit 1
    }
  done < <(jq -r '.projects[] | select(.altStore.status == "eligible") | .id as $id | .repository.slug as $slug | .altStore.versions[] | [$id, (.artifactRepository // $slug), .tag, .sourceRevision] | @tsv' "$catalog_file")
fi

echo "Validated $(jq '.projects | length' "$catalog_file") projects."
