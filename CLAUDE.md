# CLAUDE.md — Memory Screen Saver Plus X — Release Packages

This repo is the **public download point** for Memory Screen Saver Plus X installers. It is
separate from the private application source repo (`MemoryScreenSaverPlusX`).

## Rule: never include the application's source code

This repo may only ever contain:

- `README.md`
- `version.json` — release/update-check metadata, rewritten each release
- `release-notes/v<version>.md` — per-release notes
- `scripts/` — release-publishing tooling (e.g. `Push-Release.ps1`)
- `.gitattributes` — `export-ignore` so GitHub's auto "Source code" archives stay empty

It must **never** contain Memory Screen Saver Plus X's application source code (`.cs`, `.csproj`,
`.axaml`, or any other project source/build artifact from the private repo). Scripts that manage
*this* repo's own releases are fine here; the application itself is not.

Installer binaries are published as GitHub Release assets (`gh release create`/`gh release
upload`), never committed to git — see `scripts/Push-Release.ps1`'s header comment for why (they
already run 60-100+ MB and only grow; GitHub Releases has no git-history cost, unlike committing
them or tracking them with Git LFS).

**Minimal release assets:** Windows `.exe` installer(s) + macOS `.tar.gz` (or signed `.dmg`/`.pkg`).
No `checksums-*.txt` sidecars — SHA-256 lives in `version.json`. GitHub always shows auto
"Source code" zip/tar.gz links for the tag; those are not product packages (`.gitattributes`
keeps them empty).

## Publishing a release

Run `scripts/Push-Release.ps1 [-Version <ver>]` from a machine with a local checkout of the
private source repo, with its installers already built (`dist/` populated). See the script's
header comment for full prerequisites and options (`-Force`, `-DryRun`, `-SourceDistDir`).
