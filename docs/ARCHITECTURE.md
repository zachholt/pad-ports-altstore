# Architecture and release policy

## Product boundary

Every game port remains its own signed iOS application and sandbox. There is no
shared launcher process, runtime plug-in loader, downloaded native engine, or
cross-app game-data vault. The AltStore source is the common installation and
update surface.

This keeps project-specific lifecycle, rendering, input, save storage, imports,
licenses, and crashes isolated. It also lets each app update independently.

## Source flow

```text
GitHub repositories
        |
        v
catalog/projects.json  -- exact source pins + build/release policy
        |
        +--> upstreams/PROJECT (ignored, exact detached revision)
        |         |
        |         +--> recipes/PROJECT/build.sh
        |                    |
        |                    v
        |              IPA + audit + provenance
        |
        +--> hash-pinned project-owned GitHub Release IPA
                         |
                         v
                  full IPA audit
                         |
                         v
                 AltStore source.json
```

Repository synchronization, build eligibility, technical artifact acceptance,
and public-source eligibility are independent states. Live repository discovery
can report a project but cannot add it to a build or source. A build recipe can
produce an IPA but cannot publish it. A public IPA can still fail its audit.

## Distribution modes

- **Upstream release:** link directly to a hash-pinned project-owned release
  asset. This is the preferred mode for permission-limited projects and avoids
  independent mirroring or modification. GitHub release assets can still be
  replaced or deleted by their owner, so online generation always redownloads
  and rechecks them.
- **Central release:** allowed only after explicit rehosting review. Copyleft
  projects must publish corresponding source, notices, and required build or
  installation information beside the exact IPA.
- **None:** source-only, port-required, manual, or legally blocked projects
  remain tracked but cannot appear in the generated AltStore source.

Code licensing, commercial game data, and names/artwork/trademarks are separate
release gates. A permissive source license does not grant game assets or brand
rights. No checksum or user checkbox proves ownership of game data.

## Signing and game data

The automated recipes intentionally produce unsigned iPhoneOS arm64 packages.
They contain no provisioning profile, signing identity, ROM, disc image, BIOS,
or commercial data. AltStore applies user-side signing. Each installed app owns
its own Files/import flow and saves inside its own sandbox.

This policy is an engineering safeguard and not a substitute for legal advice.
