# Memory Screen Saver Plus X - Release Packages

This repository is the public download point for **Memory Screen Saver Plus X**,
a cross-platform (Windows 10+ / macOS 12+) screensaver, live-presentation, and slideshow
application. The application source lives in a separate, private repository - this repo
holds only release notes and pointers to the installers.

No separate .NET runtime, codec, or media player install is required - each installer is
self-contained and bundles everything it needs.

Installers are published as [GitHub Releases](https://github.com/jalijaak/MemoryScreenSaverPlusX_Release/releases)
(downloadable assets attached to each version's release page) - this repo's git history
holds only this README and the per-release notes under `release-notes/`, never the
installer binaries themselves. Release assets are installer binaries only; SHA-256 is in
`version.json`. Ignore GitHub's auto-generated "Source code" zip/tar.gz links.

<!-- LATEST-RELEASE:BEGIN -->
## Latest release: v2.9.22

Download from the [v2.9.22 release page](https://github.com/jalijaak/MemoryScreenSaverPlusX_Release/releases/tag/v2.9.22):

| Platform | File |
|----------|------|
| MemoryScreenSaverPlus-Setup-v2.9.22-win-x64.exe | [MemoryScreenSaverPlus-Setup-v2.9.22-win-x64.exe](https://github.com/jalijaak/MemoryScreenSaverPlusX_Release/releases/download/v2.9.22/MemoryScreenSaverPlus-Setup-v2.9.22-win-x64.exe) |
| MemoryScreenSaverPlus-v2.9.22-macos-x64.tar.gz | [MemoryScreenSaverPlus-v2.9.22-macos-x64.tar.gz](https://github.com/jalijaak/MemoryScreenSaverPlusX_Release/releases/download/v2.9.22/MemoryScreenSaverPlus-v2.9.22-macos-x64.tar.gz) |
| MemoryScreenSaverPlus-v2.9.22-macos-arm64.tar.gz | [MemoryScreenSaverPlus-v2.9.22-macos-arm64.tar.gz](https://github.com/jalijaak/MemoryScreenSaverPlusX_Release/releases/download/v2.9.22/MemoryScreenSaverPlus-v2.9.22-macos-arm64.tar.gz) |

Release notes: [release-notes/v2.9.22.md](release-notes/v2.9.22.md)

SHA-256 hashes for each installer are in [version.json](version.json). Use the installer
links above â€” ignore GitHub's auto-generated "Source code" zip/tar.gz (not product packages).
<!-- LATEST-RELEASE:END -->

## Windows: "Windows protected your PC"

The Windows installer and the application are code-signed (Publisher: **Jaakov Johannes Jalink**).
Microsoft Defender SmartScreen may still show *"Windows protected your PC - unrecognized app"*
when you download a release: SmartScreen rates files by how many people have already run
software signed with the same certificate, so a new certificate starts without a reputation
and earns it over time. As long as the dialog names the publisher, the signature is valid -
click **More info**, then **Run anyway**.

If the dialog says **Unknown publisher** instead, do not run the file: download it again from
the release page and compare its SHA-256 with the value in [version.json](version.json).

## License

AGPL-3.0.
