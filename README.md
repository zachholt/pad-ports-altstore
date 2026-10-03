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

- 30 current `chrissotraidis` project repositories, plus DuskLight and OpenGOAL;
  unavailable CTRPad is preserved in `catalog/unavailable-projects.json`.
- All 32 active repositories are pinned to exact commits in
  `catalog/projects.json`. Twenty prior pins were refreshed; existing ignored
  `upstreams/` checkouts were not synchronized to those commits.
- Ten existing projects have automated local build recipes. They were not
  rebuilt against the refreshed pins. Manual, PadMint-template, rights-review,
  and port-required projects remain visible but excluded where appropriate.
- Two apps currently enter the AltStore source: DuskLight and RAtouch; their
  installable versions are hash-pinned direct links to project-owned releases.
  DuskLight v2.0.3 adds a local-network usage declaration and passes the package
  structure audit.
- Nine previously listed projects have no current public IPA asset. Their
  catalog entries and prior audited versions remain, marked with
  `upstreamIPAWithdrawn`. SunPad, KartPad, and MeleePad publish app shells that
  need a private PadMint build before installation; recipes and shell metadata
  are tracked separately in `catalog/padmint-releases.json`.
- AgePad and KidPad remain excluded pending Steam integration and artwork
  distribution review, respectively. No personal game builds are stored here.

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
`--tag TAG` for an exact release. GitHub Actions is disabled for cost, so its
committed workflows are inactive; run the scripts locally for this refresh.

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

### Make a personal IPA with PadMint

Double-click [Make IPAs.command](Make%20IPAs.command) to open the official local
PadMint page. Choose a currently supported port, select your own game file,
review PadMint's preflight and downloads, then start the build. PadMint runs on
your Mac and keeps your input and personal IPA local. The launcher verifies and
extracts the pinned PadMint release before starting it; it does not build games
or install build tools until you choose a build in PadMint.

See [the personal IPA guide](docs/MAKE-IPAS.md) for command-line preflight and
advanced use. Personal game-code IPAs are never added to the public AltStore
source.

Generate the source locally:

```sh
./scripts/generate-store-source.sh
```

The online generator redownloads every referenced app asset, verifies its release
tag, size, SHA-256, and IPA contents, and atomically writes
`altstore/source.json`. Use `--offline` only for a cache-only audit. No live
Pages deployment is part of local generation.

## Automation

Workflow definitions remain in the repository, but GitHub Actions is currently
disabled for cost. No scheduled release imports, automatic pull requests, builds,
or Pages deployments run. Use the local commands above to discover changes,
review source pins, audit an upstream release, and generate the source. Enabling
Actions or publishing Pages is a separate operational decision.

See [the build pipeline](docs/BUILD-PIPELINE.md),
[AltStore publication](docs/ALTSTORE-SOURCE.md), and
[the policy boundary](docs/ARCHITECTURE.md).
