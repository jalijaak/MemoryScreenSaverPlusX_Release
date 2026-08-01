# Push-Release.ps1 - publishes a new release of Memory Screen Saver Plus X.
#
# This repo is the public download point for the installers - its git history
# holds ONLY this README, per-release notes, version.json, and this script.
# The actual installer binaries are never committed to git: they are attached
# as downloadable assets on a GitHub Release (tag v<version>), via `gh`.
# The application source lives in a separate, private repository.
#
# USAGE (from anywhere - it locates this repo via $PSScriptRoot):
#   pwsh scripts/Push-Release.ps1 [-Version <ver>] [-SourceDistDir <path>] [-Force] [-DryRun]
#
# PREREQUISITES:
#   - git on PATH, push access to this repo.
#   - gh (GitHub CLI, https://cli.github.com/) on PATH and authenticated
#     (`gh auth login`) - required to create the GitHub Release and upload
#     installer assets. If missing/unauthenticated, the git-tracked part of
#     the push (README/version.json/release notes) still completes, and the
#     exact manual `gh` command is printed for you to run afterwards.
#   - A local checkout of the source repo, with its installers already built,
#     sitting next to this repo (default assumed layout:
#     ..\MemoryScreenSaverPlusX\dist relative to this repo's root - override
#     with -SourceDistDir if your checkout lives elsewhere).

[CmdletBinding()]
param(
    # Version to push (e.g. 2.0.4.14). Defaults to <SourceDistDir>/version.json's version.
    [string] $Version = '',

    # Path to the source repo's build output (contains version.json, win64/, win-arm64/, mac/).
    [string] $SourceDistDir = '',

    # Re-upload/overwrite an already-published GitHub Release's assets, and
    # allow overwriting an already-committed release-notes/v<version>.md.
    [switch] $Force,

    # Stage + validate everything but skip the commit, push, and gh release.
    [switch] $DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# PowerShell 7.3+ otherwise turns routine stderr chatter from git/gh (e.g. git's
# "From https://..." fetch line, or gh's non-zero "release not found" exit when
# checking whether a release already exists) into a terminating NativeCommandError,
# even though the command itself succeeded/behaved as expected. This script already
# checks $LASTEXITCODE explicitly after every native call, so that's the only
# signal that should matter.
$PSNativeCommandUseErrorActionPreference = $false

# ── Paths ─────────────────────────────────────────────────────────────────────

$RepoRoot = (Resolve-Path "$PSScriptRoot\..").Path

if (-not $SourceDistDir) {
    $SourceDistDir = Join-Path (Split-Path $RepoRoot -Parent) 'MemoryScreenSaverPlusX\dist'
}

Write-Host "=== Memory Screen Saver Plus X - Push Release ===" -ForegroundColor Cyan
Write-Host "  Release repo: $RepoRoot"
Write-Host "  Source dist:  $SourceDistDir"

# ── helpers ───────────────────────────────────────────────────────────────────

# Runs a native command with stderr merged into the captured output, WITHOUT
# letting that stderr text become a terminating error. `2>&1` on a native
# command wraps each stderr line as a PowerShell ErrorRecord; with the
# script-wide $ErrorActionPreference = 'Stop' in effect, encountering ANY such
# record - even routine chatter like git's "From https://..." fetch header, or
# a merely-informative line - throws before $LASTEXITCODE can even be checked.
# Temporarily relaxing to 'Continue' for just the invocation avoids that, while
# still capturing the text (via Out-String) and leaving $LASTEXITCODE intact
# for the real, explicit success/failure check below.
function Invoke-Native {
    param([string] $Exe, [string[]] $NativeArgs)
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        return & $Exe @NativeArgs 2>&1 | Out-String
    } finally {
        $ErrorActionPreference = $prevEAP
    }
}

function Invoke-Git {
    param([string[]] $GitArgs, [switch] $AllowFail)
    Write-Host "  git $($GitArgs -join ' ')" -ForegroundColor DarkGray
    $out = Invoke-Native -Exe 'git' -NativeArgs (@('-C', $RepoRoot) + $GitArgs)
    if ($LASTEXITCODE -ne 0 -and -not $AllowFail) {
        Write-Error "git $($GitArgs -join ' ') failed (exit $LASTEXITCODE):`n$out"
    }
    return $out
}

function Invoke-Gh {
    param([string[]] $GhArgs, [switch] $AllowFail)
    Write-Host "  gh $($GhArgs -join ' ')" -ForegroundColor DarkGray
    $out = Invoke-Native -Exe 'gh' -NativeArgs $GhArgs
    if ($LASTEXITCODE -ne 0 -and -not $AllowFail) {
        Write-Error "gh $($GhArgs -join ' ') failed (exit $LASTEXITCODE):`n$out"
    }
    return $out
}

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Error 'git not found on PATH.'
}

# ── Resolve target version ───────────────────────────────────────────────────

$SourceVersionJsonPath = Join-Path $SourceDistDir 'version.json'
if (-not (Test-Path $SourceVersionJsonPath)) {
    Write-Error "'$SourceVersionJsonPath' not found. Build the installers in the source repo first, or pass -SourceDistDir to point at its dist/ folder."
}
$SourceVersionObj = Get-Content $SourceVersionJsonPath -Raw | ConvertFrom-Json

function Find-VersionsMatching {
    param([string] $Dir, [string] $Pattern)
    if (-not (Test-Path $Dir)) { return @() }
    $found = Get-ChildItem $Dir -File | ForEach-Object {
        if ($_.Name -match $Pattern) { $Matches['ver'] }
    }
    return @($found | Sort-Object -Unique)
}

$WinDirProbe = Join-Path $SourceDistDir 'win64'
$MacDirProbe = Join-Path $SourceDistDir 'mac'
$WinVersionsOnDisk = Find-VersionsMatching $WinDirProbe 'MemoryScreenSaverPlus-Setup-v(?<ver>[\d.]+)-win-x64\.exe'
$MacVersionsOnDisk = Find-VersionsMatching $MacDirProbe 'MemoryScreenSaverPlus-v(?<ver>[\d.]+)-macos(-x64|-arm64)?\.(dmg|pkg|tar\.gz)'

if (-not $Version) {
    $Version = $SourceVersionObj.version
    Write-Host "  No -Version given - using dist/version.json: v$Version"

    # If version.json drifted ahead of real installers (classic symptom: empty
    # sha256 stub written after the counter advanced), prefer the single version
    # that actually has both Windows + macOS artifacts on disk.
    $WinHasJson = $WinVersionsOnDisk -contains $Version
    $MacHasJson = $MacVersionsOnDisk -contains $Version
    if (-not $WinHasJson -or -not $MacHasJson) {
        $Common = @($WinVersionsOnDisk | Where-Object { $MacVersionsOnDisk -contains $_ })
        if ($Common.Count -eq 1) {
            Write-Warning ("dist/version.json is v{0} but installers on disk are v{1}. " +
                "Using v{1} (pass -Version explicitly to override). Re-run " +
                "installer/Build-All-Installers.ps1 so version.json stays aligned.") -f $Version, $Common[0]
            $Version = $Common[0]
        }
    }
}
Write-Host "  Target release: v$Version" -ForegroundColor Yellow

# ── Locate + validate per-platform artifacts for this version ──────────────

$WinDir    = Join-Path $SourceDistDir 'win64'
$WinArmDir = Join-Path $SourceDistDir 'win-arm64'
$MacDir    = Join-Path $SourceDistDir 'mac'

$WinExe    = Join-Path $WinDir "MemoryScreenSaverPlus-Setup-v$Version-win-x64.exe"
$WinArmExe = Join-Path $WinArmDir "MemoryScreenSaverPlus-Setup-v$Version-win-arm64.exe"
$MacDmg    = Join-Path $MacDir "MemoryScreenSaverPlus-v$Version-macos.dmg"
$MacPkg    = Join-Path $MacDir "MemoryScreenSaverPlus-v$Version-macos.pkg"
$MacX64Tar = Join-Path $MacDir "MemoryScreenSaverPlus-v$Version-macos-x64.tar.gz"
$MacArmTar = Join-Path $MacDir "MemoryScreenSaverPlus-v$Version-macos-arm64.tar.gz"
$NotesFile = Join-Path $SourceDistDir "ReleaseNotes-v$Version.md"

# Minimal GitHub Release asset list: installer binaries only.
# SHA-256 lives in version.json (REQ-XP-REL-15). No checksums-*.txt sidecars.
# GitHub always shows auto "Source code" zip/tar.gz links for the tag; those are
# not product downloads (see .gitattributes export-ignore in this repo).

$Missing = @()
if (-not (Test-Path $WinExe)) { $Missing += $WinExe }

$MacSigned   = (Test-Path $MacDmg) -and (Test-Path $MacPkg)
$MacArchived = (Test-Path $MacX64Tar) -and (Test-Path $MacArmTar)
if (-not $MacSigned -and -not $MacArchived) {
    $Missing += "$MacDmg + $MacPkg (signed)  --OR--  $MacX64Tar + $MacArmTar (archives)"
}
if (-not (Test-Path $NotesFile)) { $Missing += $NotesFile }

if ($Missing.Count -gt 0) {
    $WinVersions = $WinVersionsOnDisk
    $MacVersions = $MacVersionsOnDisk
    $MissingList = ($Missing | ForEach-Object { "  - $_" }) -join "`n"
    Write-Error @"
Cannot push v$Version - missing required artifacts:
$MissingList

Available win64 versions: $($WinVersions -join ', ')
Available macOS versions: $($MacVersions -join ', ')

Build the missing artifacts in the source repo first (installer/Build-All-Installers.ps1),
or pass -Version <ver> to push a version that already has installers for every platform.
"@
}

Write-Host "  Windows x64 installer:  OK" -ForegroundColor Green
if (Test-Path $WinArmExe) { Write-Host "  Windows arm64 installer: OK" -ForegroundColor Green }
$MacKindLabel = if ($MacSigned) { 'OK (signed dmg/pkg)' } else { 'OK (unsigned tar.gz archives)' }
Write-Host "  macOS installer:        $MacKindLabel" -ForegroundColor Green
Write-Host "  Release notes:          $NotesFile" -ForegroundColor Green

$AssetPaths = @($WinExe)
if (Test-Path $WinArmExe) { $AssetPaths += $WinArmExe }
$AssetPaths += if ($MacSigned) { @($MacDmg, $MacPkg) } else { @($MacX64Tar, $MacArmTar) }

if ($SourceVersionObj.version -ne $Version) {
    Write-Warning "Source dist/version.json describes v$($SourceVersionObj.version), not v$Version being pushed - regenerating release-repo version.json from the installer files on disk."
}

# ── Resolve this repo's GitHub slug (owner/repo) from the origin remote ────

$OriginUrl = (Invoke-Git -GitArgs @('remote', 'get-url', 'origin')).Trim()
if ($OriginUrl -notmatch 'github\.com[:/](?<owner>[^/]+)/(?<repo>[^/]+?)(\.git)?$') {
    Write-Error "Could not parse a GitHub owner/repo out of origin '$OriginUrl'."
}
$RepoSlug   = "$($Matches.owner)/$($Matches.repo)"
$RepoWebUrl = "https://github.com/$RepoSlug"
Write-Host "  GitHub repo: $RepoSlug"

# ── Sync this repo with origin before staging new content ──────────────────

Write-Host ''
Write-Host '--- Syncing with origin ---' -ForegroundColor Yellow

# This script only ever stages the specific paths it manages below - never a
# blanket "add everything" - so an unrelated dirty file in this PUBLIC repo
# can never be swept into a push by accident.
$ManagedPaths = @('README.md', 'version.json', "release-notes/v$Version.md", 'scripts/Push-Release.ps1', '.gitattributes', 'CLAUDE.md')
function Test-IsManagedPath {
    param([string] $RelPath)
    $Normalized = ($RelPath.Trim('"')) -replace '\\', '/'
    foreach ($p in $ManagedPaths) {
        $pNorm = $p -replace '\\', '/'
        if ($Normalized -eq $pNorm -or $Normalized.StartsWith("$pNorm/")) { return $true }
    }
    return $false
}

$StatusLines = @((Invoke-Git -GitArgs @('status', '--porcelain')) -split "`r?`n" | Where-Object { $_ -ne '' })
$UnexpectedDirty = @($StatusLines | Where-Object { -not (Test-IsManagedPath $_.Substring(3)) })
if ($UnexpectedDirty.Count -gt 0) {
    $UnexpectedList = ($UnexpectedDirty | ForEach-Object { "  $_" }) -join "`n"
    Write-Error "This repo has uncommitted changes outside the files this script manages ($($ManagedPaths -join ', ')) - resolve them manually first (this is a public repo; nothing outside that list is ever staged automatically):`n$UnexpectedList"
}

Invoke-Git -GitArgs @('fetch', 'origin') | Out-Null

$TargetBranch = (Invoke-Git -GitArgs @('branch', '--show-current') -AllowFail).Trim()
if (-not $TargetBranch) { $TargetBranch = 'main' }
Write-Host "  Branch: $TargetBranch"
Invoke-Git -GitArgs @('pull', '--ff-only', 'origin', $TargetBranch) -AllowFail | Out-Null

# ── release-notes/v<version>.md ──────────────────────────────────────────────

Write-Host ''
Write-Host '--- Release notes ---' -ForegroundColor Yellow

$NotesDir = Join-Path $RepoRoot 'release-notes'
New-Item -ItemType Directory -Force -Path $NotesDir | Out-Null
$NotesDest = Join-Path $NotesDir "v$Version.md"
$NotesRel  = "release-notes/v$Version.md"

# Only refuse overwrite when this version's notes are already committed in HEAD
# (i.e. a prior successful push). A leftover file from a failed/partial run is
# safe to replace without -Force so retries can finish cleanly.
$NotesCommitted = $false
if (Test-Path $NotesDest) {
    Invoke-Native -Exe 'git' -NativeArgs @('-C', $RepoRoot, 'cat-file', '-e', "HEAD:$NotesRel") | Out-Null
    $NotesCommitted = ($LASTEXITCODE -eq 0)
}
if ($NotesCommitted -and -not $Force) {
    Write-Error "release-notes/v$Version.md is already committed. Re-running would overwrite an already-published version's notes. Pass -Force if that's intended."
}
Copy-Item $NotesFile $NotesDest -Force
if ($NotesCommitted -and $Force) {
    Write-Host "  release-notes/v$Version.md overwritten (per -Force)."
} else {
    Write-Host "  release-notes/v$Version.md written."
}

# ── version.json (the "latest" pointer, rewritten to point at THIS repo) ───

Write-Host ''
Write-Host '--- version.json ---' -ForegroundColor Yellow

function New-InstallerEntry {
    param([string] $Rid, [string] $Path)
    $Filename = Split-Path $Path -Leaf
    [ordered]@{
        rid      = $Rid
        filename = $Filename
        sha256   = (Get-FileHash -Path $Path -Algorithm SHA256).Hash.ToLower()
        size     = (Get-Item $Path).Length
        url      = "$RepoWebUrl/releases/download/v$Version/$Filename"
    }
}

$WinInstallers = @(New-InstallerEntry -Rid 'win-x64' -Path $WinExe)
if (Test-Path $WinArmExe) { $WinInstallers += New-InstallerEntry -Rid 'win-arm64' -Path $WinArmExe }

$MacInstallers = if ($MacSigned) {
    @((New-InstallerEntry -Rid 'osx-universal' -Path $MacDmg), (New-InstallerEntry -Rid 'osx-universal' -Path $MacPkg))
} else {
    @((New-InstallerEntry -Rid 'osx-x64' -Path $MacX64Tar), (New-InstallerEntry -Rid 'osx-arm64' -Path $MacArmTar))
}

$VersionJson = [ordered]@{
    schemaVersion = '2'
    version       = $Version
    releaseDate   = $(if ($SourceVersionObj.releaseDate) { $SourceVersionObj.releaseDate } else { (Get-Date).ToString('yyyy-MM-dd') })
    releaseNotes  = "$RepoWebUrl/releases/tag/v$Version"
    platforms     = [ordered]@{
        windows = [ordered]@{
            requirements = $SourceVersionObj.platforms.windows.requirements
            installers   = $WinInstallers
        }
        macos = [ordered]@{
            requirements = $SourceVersionObj.platforms.macos.requirements
            installers   = $MacInstallers
        }
    }
}
$VersionJsonPath = Join-Path $RepoRoot 'version.json'
$VersionJson | ConvertTo-Json -Depth 10 | Set-Content -Path $VersionJsonPath -Encoding UTF8
Write-Host "  version.json regenerated for v$Version, pointing at $RepoWebUrl."

# ── README.md "latest release" section ──────────────────────────────────────

Write-Host ''
Write-Host '--- README ---' -ForegroundColor Yellow

$ReadmePath        = Join-Path $RepoRoot 'README.md'
$LatestBeginMarker = '<!-- LATEST-RELEASE:BEGIN -->'
$LatestEndMarker   = '<!-- LATEST-RELEASE:END -->'

$AssetRows = ($AssetPaths | ForEach-Object {
    $Filename = Split-Path $_ -Leaf
    "| $Filename | [$Filename]($RepoWebUrl/releases/download/v$Version/$Filename) |"
}) -join "`n"

$LatestSection = @"
$LatestBeginMarker
## Latest release: v$Version

Download from the [v$Version release page]($RepoWebUrl/releases/tag/v$Version):

| Platform | File |
|----------|------|
$AssetRows

Release notes: [release-notes/v$Version.md](release-notes/v$Version.md)

SHA-256 hashes for each installer are in [version.json](version.json). Use the installer
links above — ignore GitHub's auto-generated "Source code" zip/tar.gz (not product packages).
$LatestEndMarker
"@

if (-not (Test-Path $ReadmePath)) {
    Write-Host '  Creating README.md (first push)'
    $ReadmeBody = @"
# Memory Screen Saver Plus X - Release Packages

This repository is the public download point for **Memory Screen Saver Plus X**, a
cross-platform (Windows 10+ / macOS 12+) screensaver, live-presentation, and slideshow
application. The application source lives in a separate, private repository - this repo
holds only release notes and pointers to the installers.

No separate .NET runtime, codec, or media player install is required - each installer is
self-contained and bundles everything it needs.

Installers are published as [GitHub Releases]($RepoWebUrl/releases) (downloadable assets
attached to each version's release page) - this repo's git history holds only this README
and the per-release notes under ``release-notes/``, never the installer binaries themselves.
Release assets are installer binaries only; SHA-256 is in ``version.json``. Ignore GitHub's
auto-generated "Source code" zip/tar.gz links.

$LatestBeginMarker
$LatestEndMarker

## License

AGPL-3.0.
"@
    Set-Content -Path $ReadmePath -Value $ReadmeBody -Encoding UTF8
}

$ReadmeContent = Get-Content $ReadmePath -Raw
$BeginIdx = $ReadmeContent.IndexOf($LatestBeginMarker)
$EndIdx   = $ReadmeContent.IndexOf($LatestEndMarker)
if ($BeginIdx -ge 0 -and $EndIdx -ge 0) {
    $Before = $ReadmeContent.Substring(0, $BeginIdx)
    $After  = $ReadmeContent.Substring($EndIdx + $LatestEndMarker.Length)
    Set-Content -Path $ReadmePath -Value ($Before + $LatestSection + $After) -Encoding UTF8 -NoNewline
    Write-Host '  README.md "Latest release" section updated.'
} else {
    Write-Warning 'README.md exists but LATEST-RELEASE markers were not found - leaving it untouched. Add the markers manually if you want auto-updates.'
}

# ── Commit + push (git-tracked metadata only - no binaries) ────────────────

Write-Host ''
Write-Host '--- Committing ---' -ForegroundColor Yellow

foreach ($RelPath in @('README.md', 'version.json', "release-notes/v$Version.md", 'scripts/Push-Release.ps1', '.gitattributes', 'CLAUDE.md')) {
    if (Test-Path (Join-Path $RepoRoot $RelPath)) {
        Invoke-Git -GitArgs @('add', '--', $RelPath) | Out-Null
    }
}

$StagedDiff = (Invoke-Git -GitArgs @('diff', '--cached', '--stat') -AllowFail).Trim()
if (-not $StagedDiff) {
    Write-Host '  Nothing to commit - already up to date for this push.' -ForegroundColor DarkGray
} else {
    Write-Host $StagedDiff
    if ($DryRun) {
        Write-Host '  -DryRun: skipping commit + push.' -ForegroundColor DarkGray
    } else {
        Invoke-Git -GitArgs @('commit', '-m', "Release v$Version") | Out-Null
        Invoke-Git -GitArgs @('push', '-u', 'origin', $TargetBranch) | Out-Null
        $Sha = (Invoke-Git -GitArgs @('rev-parse', 'HEAD')).Trim()
        Write-Host "  Pushed metadata (commit $Sha)." -ForegroundColor Green
    }
}

# ── GitHub Release (the actual installer binaries) ──────────────────────────

Write-Host ''
Write-Host '--- GitHub Release ---' -ForegroundColor Yellow

$ManualCommand = "gh release create v$Version $($AssetPaths -join ' ') --repo $RepoSlug --title 'v$Version' --notes-file '$NotesFile'"

$GhCmd = Get-Command gh -ErrorAction SilentlyContinue
if (-not $GhCmd) {
    Write-Warning "gh (GitHub CLI) not found on PATH - install it (https://cli.github.com/), authenticate ('gh auth login'), then run:`n  $ManualCommand"
} else {
    Invoke-Native -Exe 'gh' -NativeArgs @('auth', 'status') | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "gh is installed but not authenticated - run 'gh auth login', then run:`n  $ManualCommand"
    } elseif ($DryRun) {
        Write-Host "  -DryRun: would run:`n  $ManualCommand" -ForegroundColor DarkGray
    } else {
        Invoke-Native -Exe 'gh' -NativeArgs @('release', 'view', "v$Version", '--repo', $RepoSlug) | Out-Null
        $ReleaseExists = ($LASTEXITCODE -eq 0)

        if ($ReleaseExists -and -not $Force) {
            Write-Warning "GitHub release v$Version already exists - skipping asset upload (pass -Force to re-upload/overwrite)."
        } elseif ($ReleaseExists -and $Force) {
            Write-Host "  Release v$Version exists - re-uploading assets (per -Force)."
            Invoke-Gh -GhArgs (@('release', 'upload', "v$Version") + $AssetPaths + @('--repo', $RepoSlug, '--clobber')) | Out-Null
        } else {
            Write-Host "  Creating GitHub release v$Version with $($AssetPaths.Count) asset(s)."
            Invoke-Gh -GhArgs (@('release', 'create', "v$Version") + $AssetPaths + @('--repo', $RepoSlug, '--title', "v$Version", '--notes-file', $NotesFile)) | Out-Null
        }
        Write-Host "=== v$Version published: $RepoWebUrl/releases/tag/v$Version ===" -ForegroundColor Green
    }
}
