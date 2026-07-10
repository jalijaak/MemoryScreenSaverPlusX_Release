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

# ── Paths ─────────────────────────────────────────────────────────────────────

$RepoRoot = (Resolve-Path "$PSScriptRoot\..").Path

if (-not $SourceDistDir) {
    $SourceDistDir = Join-Path (Split-Path $RepoRoot -Parent) 'MemoryScreenSaverPlusX\dist'
}

Write-Host "=== Memory Screen Saver Plus X - Push Release ===" -ForegroundColor Cyan
Write-Host "  Release repo: $RepoRoot"
Write-Host "  Source dist:  $SourceDistDir"

# ── helpers ───────────────────────────────────────────────────────────────────

function Invoke-Git {
    param([string[]] $GitArgs, [switch] $AllowFail)
    Write-Host "  git $($GitArgs -join ' ')" -ForegroundColor DarkGray
    $out = & git -C $RepoRoot @GitArgs 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0 -and -not $AllowFail) {
        Write-Error "git $($GitArgs -join ' ') failed (exit $LASTEXITCODE):`n$out"
    }
    return $out
}

function Invoke-Gh {
    param([string[]] $GhArgs, [switch] $AllowFail)
    Write-Host "  gh $($GhArgs -join ' ')" -ForegroundColor DarkGray
    $out = & gh @GhArgs 2>&1 | Out-String
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

if (-not $Version) {
    $Version = $SourceVersionObj.version
    Write-Host "  No -Version given - using dist/version.json: v$Version"
}
Write-Host "  Target release: v$Version" -ForegroundColor Yellow

# ── Locate + validate per-platform artifacts for this version ──────────────

$WinDir    = Join-Path $SourceDistDir 'win64'
$WinArmDir = Join-Path $SourceDistDir 'win-arm64'
$MacDir    = Join-Path $SourceDistDir 'mac'

$WinExe         = Join-Path $WinDir "MemoryScreenSaverPlus-Setup-v$Version-win-x64.exe"
$WinChecksum    = Join-Path $WinDir "checksums-win64-v$Version.txt"
$WinArmExe      = Join-Path $WinArmDir "MemoryScreenSaverPlus-Setup-v$Version-win-arm64.exe"
$WinArmChecksum = Join-Path $WinArmDir "checksums-win-arm64-v$Version.txt"
$MacDmg         = Join-Path $MacDir "MemoryScreenSaverPlus-v$Version-macos.dmg"
$MacPkg         = Join-Path $MacDir "MemoryScreenSaverPlus-v$Version-macos.pkg"
$MacX64Tar      = Join-Path $MacDir "MemoryScreenSaverPlus-v$Version-macos-x64.tar.gz"
$MacArmTar      = Join-Path $MacDir "MemoryScreenSaverPlus-v$Version-macos-arm64.tar.gz"
$MacChecksum    = Join-Path $MacDir "checksums-macos-v$Version.txt"
$NotesFile      = Join-Path $SourceDistDir "ReleaseNotes-v$Version.md"

function Find-VersionsMatching {
    param([string] $Dir, [string] $Pattern)
    if (-not (Test-Path $Dir)) { return @() }
    $found = Get-ChildItem $Dir -File | ForEach-Object {
        if ($_.Name -match $Pattern) { $Matches['ver'] }
    }
    return @($found | Sort-Object -Unique)
}

$Missing = @()
if (-not (Test-Path $WinExe))      { $Missing += $WinExe }
if (-not (Test-Path $WinChecksum)) { $Missing += $WinChecksum }

$MacSigned   = (Test-Path $MacDmg) -and (Test-Path $MacPkg)
$MacArchived = (Test-Path $MacX64Tar) -and (Test-Path $MacArmTar)
if (-not $MacSigned -and -not $MacArchived) {
    $Missing += "$MacDmg + $MacPkg (signed)  --OR--  $MacX64Tar + $MacArmTar (archives)"
}
if (-not (Test-Path $MacChecksum)) { $Missing += $MacChecksum }
if (-not (Test-Path $NotesFile))   { $Missing += $NotesFile }

if ($Missing.Count -gt 0) {
    $WinVersions = Find-VersionsMatching $WinDir 'MemoryScreenSaverPlus-Setup-v(?<ver>[\d.]+)-win-x64\.exe'
    $MacVersions = Find-VersionsMatching $MacDir 'MemoryScreenSaverPlus-v(?<ver>[\d.]+)-macos(-x64|-arm64)?\.(dmg|tar\.gz)'
    $MissingList = ($Missing | ForEach-Object { "  - $_" }) -join "`n"
    Write-Error @"
Cannot push v$Version - missing required artifacts:
$MissingList

Available win64 versions: $($WinVersions -join ', ')
Available macOS versions: $($MacVersions -join ', ')

Build the missing artifacts in the source repo first, or pass -Version <ver> to
push a version that already has installers for every platform.
"@
}

Write-Host "  Windows x64 installer:  OK" -ForegroundColor Green
if (Test-Path $WinArmExe) { Write-Host "  Windows arm64 installer: OK" -ForegroundColor Green }
$MacKindLabel = if ($MacSigned) { 'OK (signed dmg/pkg)' } else { 'OK (unsigned tar.gz archives)' }
Write-Host "  macOS installer:        $MacKindLabel" -ForegroundColor Green
Write-Host "  Release notes:          $NotesFile" -ForegroundColor Green

$AssetPaths = @($WinExe, $WinChecksum)
if (Test-Path $WinArmExe)      { $AssetPaths += $WinArmExe }
if (Test-Path $WinArmChecksum) { $AssetPaths += $WinArmChecksum }
$AssetPaths += if ($MacSigned) { @($MacDmg, $MacPkg) } else { @($MacX64Tar, $MacArmTar) }
$AssetPaths += $MacChecksum

$VersionMatchesSource = ($SourceVersionObj.version -eq $Version)

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
$ManagedPaths = @('README.md', 'version.json', "release-notes/v$Version.md", 'scripts/Push-Release.ps1')
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
if ((Test-Path $NotesDest) -and -not $Force) {
    Write-Error "release-notes/v$Version.md already exists. Re-running would overwrite an already-published version's notes. Pass -Force if that's intended."
}
Copy-Item $NotesFile $NotesDest -Force
Write-Host "  release-notes/v$Version.md written."

# ── version.json (the "latest" pointer, rewritten to point at THIS repo) ───

Write-Host ''
Write-Host '--- version.json ---' -ForegroundColor Yellow

if ($VersionMatchesSource) {
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
        releaseDate   = $SourceVersionObj.releaseDate
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
} else {
    Write-Warning "Source dist/version.json describes v$($SourceVersionObj.version), not v$Version being pushed - leaving this repo's root version.json untouched."
}

# ── README.md "latest release" section ──────────────────────────────────────

Write-Host ''
Write-Host '--- README ---' -ForegroundColor Yellow

$ReadmePath        = Join-Path $RepoRoot 'README.md'
$LatestBeginMarker = '<!-- LATEST-RELEASE:BEGIN -->'
$LatestEndMarker   = '<!-- LATEST-RELEASE:END -->'

$AssetRows = ($AssetPaths | Where-Object { $_ -notmatch 'checksums-' } | ForEach-Object {
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
Checksums: attached alongside each installer on the release page.
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

foreach ($RelPath in @('README.md', "release-notes/v$Version.md", 'scripts/Push-Release.ps1')) {
    if (Test-Path (Join-Path $RepoRoot $RelPath)) {
        Invoke-Git -GitArgs @('add', '--', $RelPath) | Out-Null
    }
}
if ($VersionMatchesSource) {
    Invoke-Git -GitArgs @('add', '--', 'version.json') | Out-Null
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
    & gh auth status *> $null
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "gh is installed but not authenticated - run 'gh auth login', then run:`n  $ManualCommand"
    } elseif ($DryRun) {
        Write-Host "  -DryRun: would run:`n  $ManualCommand" -ForegroundColor DarkGray
    } else {
        & gh release view "v$Version" --repo $RepoSlug *> $null
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
