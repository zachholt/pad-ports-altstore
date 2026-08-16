# Pad Ports AltStore

This workspace tracks iPhone and iPad decompilation and source-port projects as
**separate apps**. It pins every source repository, provides project-specific
build recipes where a reproducible iOS package exists, audits every installable
IPA, and generates one AltStore source.

It is not an emulator or an all-in-one launcher. No ROM, disc image, BIOS,
commercial game data, signing identity, or provisioning profile belongs in this
repository or its release artifacts. AltStore performs user-side signing of the
unsigned IPAs.

## Current inventory

- 20 iPhone/iPad game-port projects from `chrissotraidis`, plus DuskLight and
  OpenGOAL.
- All 22 repositories are pinned to exact 40-character commits in
  `catalog/projects.json` and available under ignored `upstreams/` checkouts.
- 11 projects have automated local build recipes. Ten are in the normal build
  matrix; CTRPad remains available as a diagnostic recipe because its IPA is
  audit-blocked. Manual, Unity-only, and port-required projects remain visible.
- Twelve project-owned release IPAs currently pass the archive, arm64, iPhoneOS,
  iPad-family, metadata, entitlement, privacy, nested-bundle, and recognized
  game-data checks: AnnePad, BearBirdPad, BrawlerPad, DuskLight, F0X,
  HarkinianPad, MaskPad, PaperPad, RAtouch, SpaghettiPad, StarshipPad, and
  SunPad.
- CTRPad has an IPA release, but the current artifact is excluded because its
  bundle does not declare `CFBundleSupportedPlatforms = [iPhoneOS]`.
- Every included IPA is linked directly from a project-owned GitHub Release and
  pinned by size and SHA-256. This workspace does not mirror those binaries.

## Day-to-day flow

Validate the tracked policy and repository pins:

```sh
./scripts/validate-catalog.sh --verify-remote
```

Discover new account repositories and report newer branch heads or releases:

```sh
./scripts/discover-repositories.sh
./scripts/report-updates.sh
./scripts/report-releases.sh
```

Import a newer project-owned IPA after the report identifies one:

```sh
./scripts/import-upstream-release.sh --project annepad
```

The importer audits first and changes only `catalog/projects.json`; use
`--tag TAG` for an exact release. The same guarded flow is exposed as the
manual **Import upstream release** GitHub workflow, which opens a reviewable
pull request.

Update a reviewed source pin, then synchronize the exact revision:

```sh
./scripts/update-project-pins.sh --project starshippad
./scripts/sync-repositories.sh --project starshippad
```

Synchronize every default project, or include opt-in research projects such as
OpenGOAL:

```sh
./scripts/sync-repositories.sh --default
./scripts/sync-repositories.sh --all-tracked
```

Preview the build cohort and run one project recipe:

```sh
./scripts/build-all.sh --dry-run
./scripts/build-project.sh --install-dependencies starshippad
```

An explicitly selected `auditBlocked` recipe can be run locally to reproduce
its failure, but it is intentionally absent from the default build matrix.

Successful builds land under ignored
`artifacts/builds/PROJECT_ID/SOURCE_REVISION/` with an IPA, audit JSON, and
toolchain/source provenance JSON. A successful build is not publication
approval; `altStore.status` remains a separate hard gate.

Generate the source locally:

```sh
./scripts/generate-store-source.sh
```

The normal generator redownloads every referenced asset, verifies its release tag,
size, SHA-256, and IPA contents, and atomically writes `altstore/source.json`.
Use `--offline` only for a deliberately cache-only local audit.

## Automation

- **Validate pipeline** checks every catalog/policy change and regenerates the
  audited source on macOS.
- **Refresh project pins** reports new account repositories and opens a pull
  request for newer source commits. It never silently publishes them.
- **Import upstream release** audits one project-owned release IPA and opens
  a catalog pull request; permission or packaging changes stop the import.
- **Build standalone apps** builds one selected recipe or the complete
  build-ready matrix on isolated macOS runners and uploads short-lived proof
  artifacts.
- **Update AltStore source** regenerates the audited source and deploys only the
  JSON file to GitHub Pages after changes reach the default branch.

See [the build pipeline](docs/BUILD-PIPELINE.md),
[AltStore publication](docs/ALTSTORE-SOURCE.md), and
[the policy boundary](docs/ARCHITECTURE.md).
