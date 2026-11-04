# Test-StorePackage.ps1 - checks that a Memory Screen Saver Plus X installer is reachable at the
# Microsoft Store package host exactly the way Partner Center needs it.
#
# Standalone: needs only Windows PowerShell 5.1 (or pwsh) and internet access. No repo checkout,
# no dist folder, no Node, no credentials. Run it on ANY machine/network - its whole purpose is to
# prove the public URL works from somewhere other than the machine that uploaded the file.
#
# What it checks (each prints PASS/FAIL, exit code 0 only if all pass):
#   1. DNS: the host resolves from this machine.
#   2. HTTP 200 on the exact URL, with NO redirect (Partner Center rejects redirecting URLs).
#   3. Content-Length equals the published installer size.
#   4. Range requests are advertised (Accept-Ranges: bytes) - lets the Store resume downloads.
#   5. The downloaded bytes have the SHA-256 published in version.json.
#
# USAGE
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Test-StorePackage.ps1 -Version 2.9.51
#
#   Without -Version it tests the LATEST release described by version.json on GitHub.
#   The expected SHA-256 and size are read from that public version.json when it describes the
#   requested version; for any other version pass -Sha256 and -Size yourself.
#
#   Run straight from GitHub on a machine that has no copy of this repo:
#   powershell -NoProfile -Command "& ([scriptblock]::Create((Invoke-WebRequest -UseBasicParsing https://raw.githubusercontent.com/jalijaak/MemoryScreenSaverPlusX_Release/main/scripts/Test-StorePackage.ps1).Content)) -Version 2.9.51"

[CmdletBinding()]
param(
    # Release version to test (e.g. 2.9.51). Default: the latest version in version.json.
    [string] $Version = '',

    # Test this exact URL instead of building it from -Version (then pass -Sha256/-Size).
    [string] $Url = '',

    # Expected SHA-256 (hex). Default: taken from version.json when its version matches.
    [string] $Sha256 = '',

    # Expected size in bytes. Default: taken from version.json when its version matches.
    [long] $Size = 0,

    # Public custom-domain host of the R2 bucket (not a secret).
    [string] $StoreHost = 'downloads.memoryscreensaverplus.net',

    # Public release metadata used for the expected hash/size.
    [string] $MetadataUrl = 'https://raw.githubusercontent.com/jalijaak/MemoryScreenSaverPlusX_Release/main/version.json'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Windows PowerShell 5.1 (.NET Framework) can default to old TLS; the host needs 1.2+.
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch { }
Add-Type -AssemblyName System.Net.Http

$script:Failures = 0
function Write-Result {
    param([bool] $Ok, [string] $Name, [string] $Detail = '')
    if ($Ok) { Write-Host ("  PASS  {0}  {1}" -f $Name, $Detail) -ForegroundColor Green }
    else     { Write-Host ("  FAIL  {0}  {1}" -f $Name, $Detail) -ForegroundColor Red; $script:Failures++ }
}

# One client that never follows redirects, so a 301/302 is reported instead of hidden.
$handler = [System.Net.Http.HttpClientHandler]::new()
$handler.AllowAutoRedirect = $false
$client = [System.Net.Http.HttpClient]::new($handler)
$client.Timeout = [TimeSpan]::FromMinutes(15)

Write-Host '=== Store package access test ===' -ForegroundColor Cyan
Write-Host ("  Run on: {0}  ({1})" -f $env:COMPUTERNAME, (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))

# -- expected values from the public version.json ---------------------------------
$MetaVersion = ''
$MetaSha     = ''
$MetaSize    = 0
try {
    $text = $client.GetStringAsync($MetadataUrl).GetAwaiter().GetResult()
    if ($text.Length -gt 0 -and [int]$text[0] -eq 0xFEFF) { $text = $text.Substring(1) }
    $meta = $text | ConvertFrom-Json
    $MetaVersion = [string]$meta.version
    $win = @($meta.platforms.windows.installers | Where-Object { $_.rid -eq 'win-x64' })
    if ($win.Count -gt 0) { $MetaSha = ([string]$win[0].sha256).ToLower(); $MetaSize = [long]$win[0].size }
    Write-Host ("  version.json on GitHub describes v{0}" -f $MetaVersion)
} catch {
    Write-Host ("  (could not read {0}: {1})" -f $MetadataUrl, $_.Exception.Message) -ForegroundColor Yellow
}

if (-not $Url) {
    if (-not $Version) {
        if (-not $MetaVersion) { Write-Host 'Pass -Version (version.json could not be read).' -ForegroundColor Red; exit 1 }
        $Version = $MetaVersion
    }
    $FileName = "MemoryScreenSaverPlus-Setup-v$Version-win-x64.exe"
    $Url = "https://$StoreHost/downloads/$Version/$FileName"
}
if ($Version -and $Version -eq $MetaVersion) {
    if (-not $Sha256) { $Sha256 = $MetaSha }
    if ($Size -eq 0)  { $Size   = $MetaSize }
}
$Sha256 = $Sha256.ToLower()

Write-Host "  URL:      $Url"
if ($Sha256) { Write-Host "  Expected: SHA-256 $Sha256" } else { Write-Host '  Expected: (no SHA-256 known - pass -Sha256 to check the bytes)' -ForegroundColor Yellow }
if ($Size -gt 0) { Write-Host "  Expected: $Size bytes" }
Write-Host ''

# -- 1. DNS ----------------------------------------------------------------------
$UriHost = ([Uri]$Url).Host
try {
    $ips = [System.Net.Dns]::GetHostAddresses($UriHost) | ForEach-Object { $_.ToString() }
    Write-Result $true '1 DNS resolves' ($ips -join ', ')
} catch {
    Write-Result $false '1 DNS resolves' "$UriHost not found from this machine ($($_.Exception.Message)). A company/ISP resolver may be caching an old 'not found' - try another network."
    Write-Host ''
    Write-Host 'Stopped: nothing else can be tested without DNS.' -ForegroundColor Red
    exit 1
}

# -- 2/3/4. HEAD: status, redirect, length, ranges -------------------------------
try {
    $req  = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Head, $Url)
    $resp = $client.SendAsync($req).GetAwaiter().GetResult()
    $code = [int]$resp.StatusCode
    $loc  = if ($resp.Headers.Location) { $resp.Headers.Location.ToString() } else { '' }
    $len  = $resp.Content.Headers.ContentLength
    $rng  = ($resp.Headers.AcceptRanges -contains 'bytes')
    $ctype = if ($resp.Content.Headers.ContentType) { $resp.Content.Headers.ContentType.ToString() } else { '' }
    $resp.Dispose()

    Write-Result ($code -eq 200 -and -not $loc) '2 HTTP 200, no redirect' ("status {0}{1}" -f $code, $(if ($loc) { ", redirects to $loc" } else { '' }))
    if ($Size -gt 0) { Write-Result ($len -eq $Size) '3 Content-Length matches' ("server says {0}, expected {1}" -f $len, $Size) }
    else             { Write-Host ("  INFO  3 Content-Length  server says {0} (no expected size known)" -f $len) -ForegroundColor Yellow }
    Write-Result $rng '4 Range requests supported' ("Accept-Ranges: bytes; Content-Type: $ctype")
    $headOk = ($code -eq 200 -and -not $loc)
} catch {
    Write-Result $false '2 HTTP 200, no redirect' $_.Exception.Message
    $headOk = $false
}

# -- 5. download and hash --------------------------------------------------------
if (-not $headOk) {
    Write-Host '  SKIP  5 SHA-256 of downloaded bytes  (the URL did not answer 200 without a redirect)' -ForegroundColor Yellow
} else {
    try {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $resp = $client.GetAsync($Url, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
        $stream = $resp.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try { $bytes = $sha.ComputeHash($stream) } finally { $sha.Dispose(); $stream.Dispose(); $resp.Dispose() }
        $sw.Stop()
        $got = ([System.BitConverter]::ToString($bytes) -replace '-', '').ToLower()
        $secs = [Math]::Max($sw.Elapsed.TotalSeconds, 0.001)
        $info = "downloaded in {0:N1} s; SHA-256 {1}" -f $secs, $got
        if ($Sha256) { Write-Result ($got -eq $Sha256) '5 SHA-256 matches version.json' $info }
        else         { Write-Host "  INFO  5 SHA-256 (not compared)  $info" -ForegroundColor Yellow }
    } catch {
        Write-Result $false '5 SHA-256 of downloaded bytes' $_.Exception.Message
    }
}

Write-Host ''
if ($script:Failures -eq 0) {
    Write-Host 'ALL CHECKS PASSED - this URL is safe to give to Partner Center:' -ForegroundColor Green
    Write-Host "  $Url" -ForegroundColor Green
    exit 0
} else {
    Write-Host ("{0} CHECK(S) FAILED - do not submit this URL." -f $script:Failures) -ForegroundColor Red
    exit 1
}
