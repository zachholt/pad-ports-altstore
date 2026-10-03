# Make personal IPAs

Download or clone this repository on your Mac, then double-click
`Make IPAs.command`. It verifies the pinned PadMint macOS archive,
extracts the official release into your user cache, and opens PadMint's own
guided page on localhost. PadMint serves the page from your computer; it does
not upload your game file. Use PadMint's project list to choose a port, choose
your own game file, review the preflight (required downloads, sizes and free
space), and start the build. Build output and any game data are personal files;
keep them private and install the IPA with your sideloading tool.

The first launch downloads only the small, hash-pinned PadMint application. It
does not install compilers or start a game build. PadMint handles build tools
after you review its preflight and choose **Make my copy**. On Mac, iOS builds
need Apple Silicon and Xcode. Individual project recipes can be experimental,
unsupported on a given host, or blocked by project-specific requirements.
PadMint's live list and preflight are authoritative for the selected project.
After the personal IPA is ready, install it with AltStore or SideStore. F0x is
not currently in PadMint's supported player catalog.

The official release is pinned in `catalog/padmint-tool.json` by URL, byte
length, and SHA-256. The launcher rejects a mismatched archive and unsafe ZIP
paths, links, special files, duplicate paths, or oversized extraction. It
re-extracts the verified archive on each launch rather than trusting cached
program files. No personal IPA or game input is stored in this repository or
added to the public AltStore source.

## Terminal options

From the repository root:

```sh
"./Make IPAs.command" --prepare-only
"./Make IPAs.command" list
"./Make IPAs.command" doctor kartpad --target ios
"./Make IPAs.command" make kartpad ios --disc "$HOME/Downloads/your-own-game.iso"
```

`--prepare-only` verifies and prepares PadMint without opening it. `doctor`
checks the selected computer without installing tools. `make` is the official
PadMint CLI; if `--out` is omitted, the IPA is written under
`~/Downloads/PadPortsPersonalIPAs`, a directory the launcher keeps private to
your macOS account. You can pass an explicit output folder outside any Git
checkout. Arguments are forwarded as separate process
arguments, so spaces and shell punctuation in paths are preserved.

To use a previously downloaded release ZIP without network access, supply
`--archive /path/to/PadMint-v0.3.4-macos.zip`. Its exact pinned size and hash
are still required. `--help` prints launcher options without downloading or
opening PadMint.
