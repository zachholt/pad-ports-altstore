# AltStore source workflow

Only projects with `altStore.status: eligible` in `catalog/projects.json` enter
the generated source. Excluded projects must retain at least one machine-readable
reason and cannot accidentally acquire an install entry by gaining a build or a
public release.

## Artifact requirements

Every eligible version uses a tag-addressed GitHub Release URL and pins:

- source commit and release tag;
- exact byte size and SHA-256;
- bundle ID, version, build number, minimum OS, and iPad device family; the
  declared minimum OS must cover the highest Mach-O deployment target;
- an exact arm64 architecture set and `iPhoneOS` Mach-O platform;
- expected Mach-O inventory, entitlements, privacy declarations, and framework count;
- bounded archive entry and expansion limits; and
- project-specific forbidden game-data extensions.

The auditor additionally rejects traversal paths, symlinks, nested apps and
extensions, simulator slices, unexpected Mach-O files, existing code signatures,
encrypted executables, profiles, private keys, certificates, and recognized
ROM/disc/game-data files anywhere in the archive.

`upstreamRelease` entries always point to the project owner's asset. The
generator verifies that repository, tag, resolved source commit, and asset path
agree and never mirrors the IPA. The current validator fails closed on eligible
`centralRelease` entries; a future central-release evidence model must encode
explicit rehost approval, corresponding source, notices, and device acceptance
before that delivery mode can be enabled.

## Local generation

```sh
./scripts/generate-store-source.sh
```

The result is `altstore/source.json`. Online generation redownloads every asset,
so a deleted or replaced upstream download cannot be hidden by a stale cache.
The file is replaced only after every eligible version passes; a failed download
or changed artifact leaves the last passing source untouched.

GitHub currently reports these upstream releases as mutable. Regeneration
detects a changed or missing asset, but cannot prevent an owner from changing it
after deployment. The published size and SHA-256 preserve the reviewed identity;
projects requiring custody guarantees need a separately approved rehost policy.

For an entirely cached audit:

```sh
./scripts/generate-store-source.sh --offline
```

## GitHub Pages

After pushing this workspace to its intended GitHub repository:

1. enable GitHub Pages with **GitHub Actions** as the source;
2. protect the `github-pages` environment as desired; and
3. merge a validated catalog/source change or dispatch **Update AltStore
   source** manually.

The workflow runs the audit with read-only repository permission, uploads only
`site/source.json`, and grants Pages/id-token write permission solely to the
deployment job. Its source URL will normally be:

```text
https://OWNER.github.io/REPOSITORY/source.json
```

Add that HTTPS URL in AltStore. These are unsigned IPAs; AltStore signs them for
the installing user's device and account.
