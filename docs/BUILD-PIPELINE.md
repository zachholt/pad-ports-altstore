# Standalone build pipeline

## Contract

`catalog/projects.json` is the only authoritative inventory. Repository
discovery is report-only, and builds always use the exact recorded revision.
The catalog deliberately separates four questions:

1. Is the repository tracked and synchronized?
2. Does it have an automated build recipe?
3. Did a particular IPA pass the technical audit?
4. Is that exact artifact approved for an AltStore source?

Passing one question never implies the next.

Each ready project has a small `recipes/PROJECT_ID/build.sh`. The orchestrator
sets these variables:

```text
PAD_PORTS_PROJECT_ID
PAD_PORTS_PROJECT_DIR
PAD_PORTS_OUTPUT_DIR
PAD_PORTS_SOURCE_REVISION
```

The recipe must produce exactly one `.ipa` directly inside
`PAD_PORTS_OUTPUT_DIR`. It should delegate to the project's own fetch, patch,
build, package, and license-audit scripts instead of duplicating their logic.

## Local build

Inspect the recipe without running it:

```sh
./scripts/build-project.sh --dry-run ratouch
```

Build with already-installed dependencies:

```sh
./scripts/build-project.sh ratouch
```

Allow the runner to install declared Homebrew formulae:

```sh
./scripts/build-project.sh --install-dependencies ratouch
```

The orchestrator refuses an unknown project, a state without a recipe, a dirty
source checkout, an origin mismatch, or a source revision different from the
catalog. It creates a detached temporary worktree for the recipe, so fetch,
patch, and build steps cannot dirty the synchronized source checkout or make a
second run fail. It then audits the resulting IPA and records the source commit,
recipe digest, orchestrator commit, Xcode version, iPhoneOS SDK, CMake version,
artifact size, and artifact SHA-256.

`auditBlocked` is the one diagnostic exception: an explicitly selected recipe
may run to reproduce its known packaging defect, but it is omitted from the
default build matrix and can never produce a successful orchestrated artifact
until it passes the same central audit.

Builds can be expensive. `build-all.sh` continues through independent recipe
failures and writes ignored `catalog/build-report.json`, allowing one broken
port to be diagnosed without hiding the others.

## Updating projects

`report-updates.sh` compares every pin with its live default branch but changes
nothing. `update-project-pins.sh` requires an explicit project or `--all`, then
writes the new revisions atomically and revalidates the complete catalog.

The scheduled GitHub workflow performs that operation on a new branch and opens
a pull request. Review upstream changes and run the corresponding build recipe
before merging. Release tags and IPA audit records are independent of a moving
default branch and never change merely because a source pin advances.

Check project-owned release assets separately:

```sh
./scripts/report-releases.sh
```

For a project already approved for direct linking, import its newest published
release containing exactly one IPA with:

```sh
./scripts/import-upstream-release.sh --project annepad
```

Pass `--tag TAG` to select a particular release. The importer downloads the
selected GitHub asset, runs the full IPA audit, requires its bundle ID, device
families, architecture, platform, Mach-O inventory, entitlements, privacy
declarations, and embedded-framework count to match the last approved version,
enforces the reviewed archive bounds, and resolves the tag to a source commit.
Versions are then sorted by publication time so importing an older tag cannot
turn it into the newest AltStore update. Any security-relevant change is a
manual review instead of an automatic update. The artifact must remain unsigned
so the installer can apply the user's own signing identity.

The manual **Import upstream release** GitHub workflow runs this command on a
macOS runner and opens a pull request containing only the audited catalog
change. Merging that pull request triggers source regeneration; it does not
copy the IPA into this repository.

## Adding a recipe

1. Start with `build.state: manual` and `altStore.status: excluded`.
2. Reproduce a clean, ROM-free unsigned iPhoneOS device IPA locally.
3. Add a recipe which calls the project's own release scripts.
4. Set `build.state: ready`, record the required Homebrew formulae, and run the
   build through `build-project.sh`.
5. Review licensing, notices, corresponding-source obligations, artwork,
   trademarks, and a physical-device clean-install/import/launch test.
6. Only then add a hash-pinned release record and change `altStore.status`.

GPL and AGPL packages require exact corresponding source and notices beside the
IPA. Sustainable Use projects must remain free and noncommercial. Projects
without a redistribution grant may be built privately but cannot be rehosted.
These are engineering release gates, not jurisdiction-specific legal advice.

The static audit does not prove user-side signing, installation, first-run data
import, or gameplay on a physical device. That acceptance remains a recorded
manual gate for any centrally built artifact. Current source entries are direct
links to their project owners' releases and are not represented as independent
device-test results from this workspace.
