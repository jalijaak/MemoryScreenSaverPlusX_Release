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
#                                 [-UploadStorePackage] [-StorePackageOnly]
#   (also runs under Windows PowerShell 5.1:
#    powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Push-Release.ps1 ...)
#
# MICROSOFT STORE PACKAGE HOST (optional, opt-in):
#   -UploadStorePackage  after the normal publish, also upload the Windows x64 installer to the
#                        Cloudflare R2 bucket that backs https://downloads.memoryscreensaverplus.net
#                        at  downloads/<version>/<installer file name>  and verify it the way
#                        Partner Center needs (HTTP 200, NO redirect, correct Content-Length,
#                        SHA-256 identical to version.json). Prints the Package URL to paste into
#                        Partner Center. A key is NEVER overwritten: if it already exists with the
#                        same bytes the step is a verified no-op; with different bytes it stops.
#   -StorePackageOnly    do ONLY that step for an already-published version (no git, no GitHub,
#                        no release-notes/README/version.json changes). Use it to (re)upload or
#                        re-verify the Store package without re-running the release.
#   R2 has no real folders: the key prefix downloads/<version>/ is created by the upload itself.
#   To test the public URL from another machine/network use scripts\Test-StorePackage.ps1.
#   Needs Node + Wrangler (`npm i -g wrangler`, or `npx` is used as a fallback) and a one-time
#   interactive `wrangler login` as the Cloudflare account owner. No token or secret is stored in
#   this repo or passed on the command line. Installers over ~300 MB exceed Wrangler's single-put
#   limit and must be uploaded another way.
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
    [switch] $DryRun,

    # After the normal publish, also upload the Windows x64 installer to the Microsoft
    # Store package host (Cloudflare R2) and verify it. See the header comment.
    [switch] $UploadStorePackage,

    # Do ONLY the Store package upload + verification for an existing build (no git/GitHub work).
    [switch] $StorePackageOnly,

    # R2 bucket and its public custom-domain host (public names, not secrets).
    [string] $StoreBucket = 'mssp-downloads',
    [string] $StoreHost   = 'downloads.memoryscreensaverplus.net'
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

# ── Microsoft Store package host (Cloudflare R2) ───────────────────────────────
#
# Partner Center installs an unpackaged (EXE/MSI) app by downloading it from the
# Package URL, so that URL must be a DIRECT, NON-REDIRECTING, versioned, immutable
# HTTPS link (REQ-WIN-REL-38). GitHub release assets redirect and are rejected.
# These helpers upload the signed installer to R2 and prove the public URL meets
# that contract. Nothing here touches git or the GitHub release.

# Returns @{ Exe; Prefix } for running Wrangler, or $null when neither wrangler nor npx exists.
function Get-WranglerLauncher {
    if (Get-Command wrangler -ErrorAction SilentlyContinue) { return @{ Exe = 'wrangler'; Prefix = @() } }
    if (Get-Command npx -ErrorAction SilentlyContinue)      { return @{ Exe = 'npx'; Prefix = @('--yes', 'wrangler@4') } }
    return $null
}

# One HttpClient that NEVER follows redirects, so a 301/302 is reported instead of hidden.
function New-NoRedirectHttpClient {
    Add-Type -AssemblyName System.Net.Http
    # Windows PowerShell 5.1 (.NET Framework) may default to old TLS; Cloudflare needs 1.2+.
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $handler = [System.Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false
    $client = [System.Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromMinutes(15)
    return $client
}

# HEAD the URL. Status 0 means the request itself failed (DNS, TLS, timeout) - see Error.
function Get-StoreObjectInfo {
    param($Client, [string] $Url)
    try {
        $req  = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Head, $Url)
        $resp = $Client.SendAsync($req).GetAwaiter().GetResult()
        $loc  = if ($resp.Headers.Location) { $resp.Headers.Location.ToString() } else { '' }
        $info = [pscustomobject]@{
            Status   = [int]$resp.StatusCode
            Length   = $resp.Content.Headers.ContentLength
            Location = $loc
            Error    = ''
        }
        $resp.Dispose()
        return $info
    } catch {
        return [pscustomobject]@{ Status = 0; Length = $null; Location = ''; Error = $_.Exception.Message }
    }
}

# Streams the object and returns its lowercase SHA-256, or $null if it is not a plain 200.
function Get-StoreObjectSha256 {
    param($Client, [string] $Url)
    $resp = $Client.GetAsync($Url, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
    try {
        if ([int]$resp.StatusCode -ne 200) { return $null }
        $stream = $resp.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try {
            $bytes = $sha.ComputeHash($stream)
        } finally {
            $sha.Dispose()
            $stream.Dispose()
        }
        return ([System.BitConverter]::ToString($bytes) -replace '-', '').ToLower()
    } finally {
        $resp.Dispose()
    }
}

# Uploads $FilePath to R2 as downloads/<Version>/<file name> and verifies the public URL.
# Never overwrites an existing key. -Preview prints the plan and changes nothing.
function Publish-StorePackage {
    param(
        [string] $Version,
        [string] $FilePath,
        [string] $ExpectedSha256 = '',
        [switch] $Preview
    )

    $FileName = Split-Path $FilePath -Leaf
    $Size     = (Get-Item $FilePath).Length
    $Key      = "downloads/$Version/$FileName"
    $Url      = "https://$StoreHost/$Key"
    $LocalSha = (Get-FileHash -Path $FilePath -Algorithm SHA256).Hash.ToLower()

    Write-Host "  File:    $FilePath"
    Write-Host "  Size:    $Size bytes"
    Write-Host "  SHA-256: $LocalSha"
    Write-Host "  Bucket:  $StoreBucket   Key: $Key"
    Write-Host "  URL:     $Url"

    if ($Size -gt 300MB) {
        Write-Error "Installer is $([math]::Round($Size / 1MB)) MB; Wrangler's single upload is limited to ~300 MB. Upload it with the S3-compatible API instead, then re-run with -StorePackageOnly to verify."
    }
    if ($ExpectedSha256 -and ($LocalSha -ne $ExpectedSha256.ToLower())) {
        Write-Error "Installer SHA-256 ($LocalSha) does not match version.json ($ExpectedSha256). Refusing to publish a package that disagrees with the release metadata."
    }

    $Client = New-NoRedirectHttpClient

    # Immutability: a versioned key is never overwritten (REQ-WIN-REL-38).
    $Existing = Get-StoreObjectInfo -Client $Client -Url $Url
    $AlreadyThere = $false
    switch ($Existing.Status) {
        200 {
            $RemoteSha = Get-StoreObjectSha256 -Client $Client -Url $Url
            if ($RemoteSha -eq $LocalSha) {
                Write-Host "  Key already exists with identical content - nothing to upload, verifying only." -ForegroundColor Green
                $AlreadyThere = $true
            } else {
                Write-Error "Key '$Key' already exists in '$StoreBucket' with DIFFERENT content (remote SHA-256: $RemoteSha). Store package keys are immutable and are never overwritten - build a new version instead."
            }
        }
        404 { Write-Host '  Key does not exist yet - will upload.' }
        0 {
            Write-Error "Could not check whether '$Url' already exists ($($Existing.Error)). This often means this machine's DNS has not picked up '$StoreHost' yet - retry in a few minutes or from another network. Not uploading blind, because an upload would silently overwrite an existing key."
        }
        default {
            Write-Error "Unexpected HTTP $($Existing.Status) from '$Url' before upload (Location: '$($Existing.Location)'). Expected 404 (new) or 200 (already uploaded). Check the R2 custom domain in Cloudflare."
        }
    }

    if ($Preview) {
        Write-Host "  -DryRun/-Preview: would $(if ($AlreadyThere) { 'verify' } else { 'upload and verify' }) $Url" -ForegroundColor DarkGray
        return
    }

    if (-not $AlreadyThere) {
        $Launcher = Get-WranglerLauncher
        if (-not $Launcher) {
            Write-Error ("Neither 'wrangler' nor 'npx' was found on PATH. One-time setup (normal window): " +
                "'winget install OpenJS.NodeJS.LTS', then CLOSE and REOPEN the terminal so PATH refreshes, " +
                "then 'npm i -g wrangler' and 'wrangler login' (sign in as the Cloudflare account owner). " +
                "Then re-run with -StorePackageOnly. (Alternative without installing anything: upload the file " +
                "in the Cloudflare dashboard to key '$Key', then re-run this script to verify it.)")
        }
        $Who = Invoke-Native -Exe $Launcher.Exe -NativeArgs ($Launcher.Prefix + @('whoami'))
        if ($Who -match '(?i)not authenticated|please run .?wrangler login') {
            Write-Error "Wrangler is not logged in. Run 'wrangler login' (opens a browser; sign in with the Cloudflare account that owns '$StoreBucket'), then re-run with -StorePackageOnly."
        }

        Write-Host "  Uploading to R2 (this can take a minute)..." -ForegroundColor Yellow
        # --remote: act on the real bucket, not Wrangler's local simulation.
        $PutArgs = $Launcher.Prefix + @('r2', 'object', 'put', "$StoreBucket/$Key",
            '--file', $FilePath, '--content-type', 'application/octet-stream', '--remote')
        $PutOut = Invoke-Native -Exe $Launcher.Exe -NativeArgs $PutArgs
        if ($LASTEXITCODE -ne 0) {
            $PutExit = $LASTEXITCODE
            if ($PutOut -match '(?i)non-interactive|not logged in') {
                # Wrangler sometimes needs a fresh OAuth login for R2 (the first `wrangler login` token
                # can lack it). It can only do that on a real console, not inside this captured call.
                $DirectCmd = "wrangler r2 object put $StoreBucket/$Key --file `"$FilePath`" --content-type application/octet-stream --remote"
                Write-Error ("Wrangler needs an interactive login for this upload. Run this ONCE directly in your own terminal " +
                    "(it may open a browser to sign in; keep the output attached to the console):`n  $DirectCmd`n" +
                    "then re-run this script with -StorePackageOnly to verify the public URL.`n`nWrangler said:`n$PutOut")
            }
            Write-Error "wrangler r2 object put failed (exit $PutExit):`n$PutOut"
        }
        Write-Host '  Upload finished.' -ForegroundColor Green
    }

    # Verify the PUBLIC url the way Partner Center will use it: 200, no redirect,
    # matching length, matching bytes. Retries cover brief propagation / DNS lag.
    Write-Host '  Verifying the public URL...' -ForegroundColor Yellow
    $Verified = $false
    $Problem  = ''
    for ($i = 1; $i -le 6 -and -not $Verified; $i++) {
        $Info = Get-StoreObjectInfo -Client $Client -Url $Url
        if ($Info.Status -ne 200) {
            $Problem = "HTTP $($Info.Status) $($Info.Error) (Location: '$($Info.Location)')"
        } elseif ($Info.Location) {
            $Problem = "unexpected redirect to '$($Info.Location)'"
        } elseif ($Info.Length -ne $Size) {
            $Problem = "Content-Length $($Info.Length) does not match local size $Size"
        } else {
            $RemoteSha = Get-StoreObjectSha256 -Client $Client -Url $Url
            if ($RemoteSha -eq $LocalSha) { $Verified = $true } else { $Problem = "SHA-256 mismatch (remote $RemoteSha)" }
        }
        if (-not $Verified -and $i -lt 6) {
            Write-Host "    attempt $i failed: $Problem - retrying in 10 s" -ForegroundColor DarkGray
            Start-Sleep -Seconds 10
        }
    }
    if (-not $Verified) {
        Write-Error "Store package verification FAILED for $Url : $Problem. Do not submit this URL to Partner Center."
    }

    Write-Host '  HTTP 200, no redirect, Content-Length and SHA-256 match.' -ForegroundColor Green
    Write-Host ''
    Write-Host "  Partner Center Package URL:" -ForegroundColor Cyan
    Write-Host "    $Url" -ForegroundColor Cyan
    Write-Host "  Submit it per docs/MICROSOFT-STORE.md (silent switches /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /STORE)." -ForegroundColor DarkGray
    Write-Host "  Never replace this file: the next release gets its own downloads/<version>/ key." -ForegroundColor DarkGray
    Write-Host ''
    Write-Host "  Test it from ANOTHER machine/network (no repo or Node needed there):" -ForegroundColor Cyan
    Write-Host "    powershell -NoProfile -ExecutionPolicy Bypass -File Test-StorePackage.ps1 -Version $Version" -ForegroundColor Cyan
    Write-Host "  (copy scripts\Test-StorePackage.ps1 over, or once it is pushed run it straight from GitHub:)" -ForegroundColor DarkGray
    Write-Host "    powershell -NoProfile -Command ""& ([scriptblock]::Create((Invoke-WebRequest -UseBasicParsing https://raw.githubusercontent.com/jalijaak/MemoryScreenSaverPlusX_Release/main/scripts/Test-StorePackage.ps1).Content)) -Version $Version""" -ForegroundColor DarkGray
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

# ── -StorePackageOnly: upload + verify the Store package and stop ────────────
# No git, GitHub, release-notes, README or version.json work happens on this path.
if ($StorePackageOnly) {
    Write-Host ''
    Write-Host '--- Microsoft Store package host (R2) - only ---' -ForegroundColor Yellow
    if (-not (Test-Path $WinExe)) {
        Write-Error "Windows x64 installer not found: $WinExe (build it first, or pass -Version / -SourceDistDir)."
    }
    # Cross-check against the already-published version.json when it describes this version.
    $PublishedSha = ''
    $PublishedJsonPath = Join-Path $RepoRoot 'version.json'
    if (Test-Path $PublishedJsonPath) {
        $PublishedObj = Get-Content $PublishedJsonPath -Raw | ConvertFrom-Json
        if ($PublishedObj.version -eq $Version) {
            $PublishedWin = @($PublishedObj.platforms.windows.installers | Where-Object { $_.rid -eq 'win-x64' })
            if ($PublishedWin.Count -gt 0) { $PublishedSha = [string]$PublishedWin[0].sha256 }
        } else {
            Write-Warning "version.json in this repo describes v$($PublishedObj.version), not v$Version - skipping the metadata cross-check."
        }
    }
    Publish-StorePackage -Version $Version -FilePath $WinExe -ExpectedSha256 $PublishedSha -Preview:$DryRun
    exit 0
}

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
$ManagedPaths = @('README.md', 'version.json', "release-notes/v$Version.md", 'scripts/Push-Release.ps1', 'scripts/Test-StorePackage.ps1', '.gitattributes', 'CLAUDE.md')
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

Free to use. Copyright (c) 2026 Quiet Hours Software. All rights reserved. The licence is shown by the installer.
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

foreach ($RelPath in @('README.md', 'version.json', "release-notes/v$Version.md", 'scripts/Push-Release.ps1', 'scripts/Test-StorePackage.ps1', '.gitattributes', 'CLAUDE.md')) {
    if (Test-Path (Join-Path $RepoRoot $RelPath)) {
        Invoke-Git -GitArgs @('add', '--', $RelPath) | Out-Null
    }
}

$StagedDiff = (Invoke-Git -GitArgs @('diff', '--cached', '--stat') -AllowFail).Trim()
if (-not $StagedDiff) {
    Write-Host '  Nothing to commit - already up to date for this push.' -ForegroundColor DarkGray
} else {
    Write-Host $StagedDiff

    # Surface source-repo Changes (from Publish-Release / REQ-REL-11) in this
    # public repo's commit message so `git log` / GitHub commit views show them —
    # not only the release-notes file diff.
    $CommitTitle = "Release v$Version"
    $CommitBody  = ''
    if (Test-Path $NotesDest) {
        $NotesRaw = Get-Content -LiteralPath $NotesDest -Raw
        $BulletMatches = [regex]::Matches($NotesRaw, '(?m)^(?:- |\* ).+$')
        if ($BulletMatches.Count -gt 0) {
            $CommitBody = ($BulletMatches | ForEach-Object { $_.Value.TrimEnd() }) -join "`n"
        } else {
            Write-Warning "release-notes/v$Version.md has an empty Changes section - source commit subjects were not captured. Re-run Publish-Release in the source repo (restore release-baseline.txt if needed) before pushing."
        }
    }

    if ($DryRun) {
        Write-Host '  -DryRun: skipping commit + push.' -ForegroundColor DarkGray
        if ($CommitBody) {
            Write-Host "  Would commit as:`n  $CommitTitle`n`n$CommitBody" -ForegroundColor DarkGray
        }
    } else {
        # Commit message goes through a temp file (`git commit -F`) rather than
        # `-m` on the command line. Release-notes bullets are free-form text and
        # may contain embedded double quotes (e.g. a quoted UI label) - PowerShell
        # builds native-command command lines by wrapping each argument in quotes,
        # and an embedded `"` prematurely closes that wrapper, splitting the rest
        # of the message into separate arguments that git then misparses as
        # pathspecs. Reading from a file sidesteps command-line quoting entirely.
        $CommitMsgFile = [System.IO.Path]::GetTempFileName()
        try {
            $CommitMsg = if ($CommitBody) { "$CommitTitle`n`n$CommitBody" } else { $CommitTitle }
            Set-Content -Path $CommitMsgFile -Value $CommitMsg -Encoding UTF8 -NoNewline
            Invoke-Git -GitArgs @('commit', '-F', $CommitMsgFile) | Out-Null
        } finally {
            Remove-Item -Path $CommitMsgFile -Force -ErrorAction SilentlyContinue
        }
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

# ── Microsoft Store package host (optional) ─────────────────────────────────

if ($UploadStorePackage) {
    Write-Host ''
    Write-Host '--- Microsoft Store package host (R2) ---' -ForegroundColor Yellow
    # $WinInstallers[0] is the win-x64 entry whose SHA-256 was written to version.json above.
    Publish-StorePackage -Version $Version -FilePath $WinExe -ExpectedSha256 ([string]$WinInstallers[0].sha256) -Preview:$DryRun
}
