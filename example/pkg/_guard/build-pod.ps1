# build-pod.ps1 -- assemble a rescue package from its sources in one command.
#
# WHY A SCRIPT AT ALL
#   The first package was assembled with an ad-hoc command line. The second build
#   produced something different and nobody could say which one was right. One
#   command plus a self-check removes that whole class of doubt.
#
# ============================== THE GUARANTEE ================================
# A HALF-BUILT RESCUE PACKAGE IS WORSE THAN A STALE ONE: it looks present, and it
# fails at the moment you actually need it.
#
# So this script never writes into the live package. Every byte goes into a sibling
# "<pod>.staging" directory; the staging tree must pass the self-check; only then is
# the live package renamed aside and the staging tree renamed into place. A failure
# before that swap leaves the existing package byte-for-byte as it was.
#
# Measured, not assumed (2026-10-16):
#   * the previous in-place version deleted the live package as its FIRST act, so any
#     failure after that point left a 113 MB half-package sitting on disk;
#   * in PowerShell 5.1 a bare `throw` inside a `trap` REPLACES the original error
#     message with "ScriptHalted" -- the satellite-collision text naming the offending
#     file was thrown away, and the operator saw only "ScriptHalted". `throw $_`
#     re-raises the original error record intact (same exit code 1, message and id
#     preserved). A loud failure nobody can read is not loud.
#
# ============================= LAYOUT IT EXPECTS =============================
#   <root>\<workspace>\<pkg>\_guard\build-pod.ps1   <- this script
#   <pkg>\_pod-src\                                 <- the sources
#   <pkg>\_local-extensions\                        <- locally patched files (optional)
#   <pkg>\**\*dsh-memory-*.tgz                      <- offline payloads
# Produces <root>\RESCUE-POD\ and, with -Zip, <root>\RESCUE-POD-v<Version>.zip.
# Every one of those paths is overridable: -PkgDir / -RootDir / -PodDir / -PodName.
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File build-pod.ps1
#   ... -Zip                     also emit a portable zip (for ANOTHER disk or machine)
#   ... -PodDir <path>           build somewhere else (used by the failure-injection test)
#   ... -DeclaredVersion 1.2.3   pick the payload explicitly
#
# ASCII-only. See README.md for why that is not a style preference.

[CmdletBinding()]
param(
  [switch]$Zip,
  [string]$PodDir,
  [string]$PkgDir,
  [string]$RootDir,
  [string]$PodName = 'RESCUE-POD',
  [string]$Version = '1.0',
  [string]$DeclaredVersion,
  # Files copied verbatim from _pod-src\ (they must all exist). Anything else in
  # _pod-src\ is a build input and is NOT shipped -- add a file here when it must
  # ride along.
  [string[]]$SourceFiles = @('rescue.ps1', 'rescue.cmd', 'watch.ps1', 'watch.cmd', 'README.md'),
  # Never hashed, and declared so in the manifest.
  [string[]]$Volatile = @('MANIFEST.json', 'watch.log', 'replay.log'),
  [string]$PayloadGlob = '*dsh-memory-*.tgz',
  [string]$ExtractorName = 'tar-extract.mjs'
)

$ErrorActionPreference = 'Stop'

# ------------------------------------------------------------------- the paths
if ([string]::IsNullOrWhiteSpace($PkgDir))  { $PkgDir  = Split-Path -Parent $PSScriptRoot }
if ([string]::IsNullOrWhiteSpace($RootDir)) { $RootDir = Split-Path -Parent (Split-Path -Parent $PkgDir) }
$srcDir = Join-Path $PkgDir '_pod-src'
$snapDir = Join-Path $PkgDir '_local-extensions'
if (-not (Test-Path -LiteralPath $srcDir)) { throw ('no pod sources at ' + $srcDir) }
if ([string]::IsNullOrWhiteSpace($PodDir)) { $PodDir = Join-Path $RootDir $PodName }
$zipPath = Join-Path $RootDir ($PodName + '-v' + $Version + '.zip')

Write-Host ('build pod : ' + $PodDir)

# ---------------------------------------------------------------- two-phase build
# $PodDir is re-pointed at the staging tree; the live package is untouched until the
# swap near the bottom. Nothing below this block needs to know about the staging
# directory -- which is exactly why it is safe to add steps.
$finalPodDir = $PodDir
$stageDir    = $PodDir + '.staging'
$legacyDir   = $PodDir + '.replaced'

# Clean the staging tree on ANY failure, so a failed build does not leave a half-pod
# beside the real one. Two details are measured rather than assumed:
#   * `throw $_` (see the header) -- a bare `throw` would destroy the message;
#   * the guard `if ($stageDir -and ...)`: a failure before $stageDir is assigned must
#     not turn the handler itself into the error.
# This handler only knows $stageDir, so it can never touch the live package. After a
# successful swap the staging path no longer exists (it was renamed away), so a late
# failure -- the zip, say -- leaves the swapped-in package alone.
trap {
  if ($stageDir -and (Test-Path -LiteralPath $stageDir)) {
    Remove-Item -LiteralPath $stageDir -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host ('[info] staging cleaned up after a failure: ' + $stageDir) -ForegroundColor DarkGray
  }
  throw $_
}

foreach ($d in @($stageDir, $legacyDir)) {
  if (Test-Path -LiteralPath $d) { Remove-Item -LiteralPath $d -Recurse -Force }
}
$PodDir = $stageDir
Write-Host ('staging   : ' + $stageDir)

# --------------------------------------------------------------- what to ship
foreach ($f in $SourceFiles) {
  if (-not (Test-Path -LiteralPath (Join-Path $srcDir $f))) { throw ('missing pod source: ' + (Join-Path $srcDir $f)) }
}
# The human guide is the FIRST .txt in _pod-src\, so keep exactly one there. Its name
# is not hard-coded: a non-ASCII filename literal inside this ASCII-only script would
# break the encoding rule this project is built around.
$userDoc = Get-ChildItem -LiteralPath $srcDir -File | Where-Object { $_.Extension -eq '.txt' } | Select-Object -First 1
if (-not $userDoc) { throw ('no .txt user guide in ' + $srcDir) }

# ------------------------------------------------- declared version + payloads
if ([string]::IsNullOrWhiteSpace($DeclaredVersion)) {
  $dvFile = Join-Path $srcDir 'declared-version'
  if (Test-Path -LiteralPath $dvFile) {
    $DeclaredVersion = (Get-Content -LiteralPath $dvFile -Raw -Encoding UTF8).Trim()
  }
}
if ([string]::IsNullOrWhiteSpace($DeclaredVersion)) {
  throw ('cannot determine the declared version: pass -DeclaredVersion, or add ' + (Join-Path $srcDir 'declared-version'))
}

# Ship EVERY payload tarball we have: the declared version is the normal payload and
# the older ones are the rollback path -- a version upgrade must not remove the
# ability to go back.
# A scoped package packs as "<scope>-<name>-<version>.tgz", so the glob needs the
# LEADING wildcard. A "dsh-memory-*.tgz" filter silently misses every fresh download
# of a scoped package (measured: the 0.6.0 payload was invisible to the builder while
# a stale 0.4.11 stayed selected).
$tarballs = @(Get-ChildItem -LiteralPath $PkgDir -Recurse -File -ErrorAction SilentlyContinue |
              Where-Object { $_.Name -like $PayloadGlob } |
              Sort-Object -Property Name -Unique)
$payload = $tarballs | Where-Object { $_.Name -match ('-' + [regex]::Escape($DeclaredVersion) + '\.tgz$') } | Select-Object -First 1
if (-not $payload) {
  # Fail loud instead of quietly shipping an older payload: a newer store restored
  # from an older tarball is a DOWNGRADE, and the hash self-check below would still
  # call it CLEAR.
  throw ('no payload for the declared version ' + $DeclaredVersion + ' under ' + $PkgDir +
         ' -- refusing to ship an older one silently. Fetch it with: npm pack <name>@' + $DeclaredVersion)
}

# ------------------------------------------------------------------- assemble
# Keep the runtime logs: they are the evidence of what the watchdog did, and a
# rebuild used to delete them along with everything else. They are read from the LIVE
# package (a staging tree has none) and written into staging.
$keptLogs = @{}
foreach ($n in $Volatile) {
  $p = Join-Path $finalPodDir $n
  if (Test-Path -LiteralPath $p) { $keptLogs[$n] = Get-Content -LiteralPath $p -Raw -Encoding UTF8 }
}
if (Test-Path -LiteralPath $PodDir) { Remove-Item -LiteralPath $PodDir -Recurse -Force }
New-Item -ItemType Directory -Path $PodDir, (Join-Path $PodDir '_backup') -Force | Out-Null
foreach ($n in $keptLogs.Keys) {
  [System.IO.File]::WriteAllText((Join-Path $PodDir $n), $keptLogs[$n], (New-Object System.Text.UTF8Encoding($false)))
  Write-Host ('kept log  : ' + $n)
}

foreach ($f in $SourceFiles) { Copy-Item -LiteralPath (Join-Path $srcDir $f) -Destination $PodDir -Force }
# Every .cmd in _pod-src ships as well -- by WILDCARD, because a human-facing entry
# point is often named with non-ASCII characters and such a filename literal inside
# this .ps1 would break the encoding rule (H6 in the parent project).
Get-ChildItem -LiteralPath $srcDir -Filter '*.cmd' -File | ForEach-Object {
  Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $PodDir $_.Name) -Force
  Write-Host ('copied cmd: ' + $_.Name)
}
$extractor = Join-Path $PSScriptRoot $ExtractorName
if (Test-Path -LiteralPath $extractor) { Copy-Item -LiteralPath $extractor -Destination $PodDir -Force }
if (Test-Path -LiteralPath $snapDir) { Copy-Item -LiteralPath $snapDir -Destination $PodDir -Recurse -Force }
foreach ($t in $tarballs) { Copy-Item -LiteralPath $t.FullName -Destination (Join-Path $PodDir '_backup') -Force }
Write-Host ('payloads  : ' + (($tarballs | ForEach-Object { $_.Name }) -join ', '))

# ---------------------------------------------------- satellites (_pod-src\_extra)
# Files that must ride along but are NOT produced by this script live in _pod-src\
# _extra\. Two things went wrong when people dropped them straight into the built
# package instead: the next rebuild deleted them (this script removes the whole
# package first), and the manifest -- generated from what is on disk -- had already
# been written, so they were UNLISTED, which a verifier reports as EXTRA.
# One source of truth instead: copied verbatim, relative path preserved, BEFORE the
# manifest is built, so it is hashed and listed like everything else.
#
# A path that collides with something this script produces is a HARD ERROR, never an
# overwrite. Measured: a 33-byte satellite README.md silently replaced the package's
# real 5347-byte README.md and nothing said a word. Failing loudly costs one re-run.
# Two names are written AFTER this loop (the user guide and the manifest), so they
# cannot be detected by Test-Path here -- they are reserved by name instead.
$extraDir = Join-Path $srcDir '_extra'
if (Test-Path -LiteralPath $extraDir) {
  $reserved = @('MANIFEST.json', $userDoc.Name)
  $extraCount = 0
  foreach ($f in (Get-ChildItem -LiteralPath $extraDir -Recurse -File -Force)) {
    $rel  = $f.FullName.Substring($extraDir.Length).TrimStart('\')
    $dest = Join-Path $PodDir $rel
    if ((Test-Path -LiteralPath $dest) -or ($reserved -contains $rel)) {
      throw ('satellite collision: _pod-src\_extra\' + $rel + ' would overwrite ' + $dest +
             ' -- rename the satellite, or take it out of _extra. The live package was NOT touched:' +
             ' fix the collision and re-run.')
    }
    $destParent = Split-Path -Parent $dest
    if (-not (Test-Path -LiteralPath $destParent)) { New-Item -ItemType Directory -Path $destParent -Force | Out-Null }
    Copy-Item -LiteralPath $f.FullName -Destination $dest
    $extraCount += 1
  }
  Write-Host ('satellites: ' + $extraCount + ' file(s) from _pod-src\_extra')
} else {
  Write-Host 'satellites: none (_pod-src\_extra does not exist)'
}

# The guide must be readable in Notepad, which needs a BOM on a CJK locale.
$txt = Get-Content -LiteralPath $userDoc.FullName -Raw -Encoding UTF8
[System.IO.File]::WriteAllText((Join-Path $PodDir $userDoc.Name), $txt, (New-Object System.Text.UTF8Encoding($true)))

# ------------------------------------------------------------------- manifest
# The volatile files are deliberately EXCLUDED from hashing and DECLARED in the
# manifest, so a generic verifier can tell a deliberate exclusion from an unexpected
# file. An exclusion that exists only in a comment gets reported as EXTRA -- that is
# how a perfectly good package was once reported as broken.
$files = @(Get-ChildItem -LiteralPath $PodDir -Recurse -File |
           Where-Object { $Volatile -notcontains $_.Name } |
           Sort-Object FullName)
$list = foreach ($f in $files) {
  [pscustomobject]@{
    path   = $f.FullName.Substring($PodDir.Length).TrimStart('\')
    bytes  = $f.Length
    sha256 = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash
  }
}
$doc = [ordered]@{
  name            = $PodName
  version         = $Version
  builtAt         = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
  purpose         = 'Offline check/repair of a live installation, plus a clean-profile rescue boot and a watchdog.'
  entry           = 'rescue.cmd (no args = check only; fix = repair; boot = rescue session)'
  payload         = (($tarballs | ForEach-Object { $_.Name }) -join ', ')
  declaredVersion = $DeclaredVersion
  canonicalSource = ($PkgDir + ' (authoritative; this package is a frozen copy)')
  volatile        = $Volatile
  fileCount       = $list.Count
  files           = $list
}
[System.IO.File]::WriteAllText((Join-Path $PodDir 'MANIFEST.json'), ($doc | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false)))

# --------------------------------------------------------------- self-check
# Runs against the STAGING tree, before anything live is touched.
# Every .ps1 / .cmd that would ship must be pure ASCII or carry a UTF-8 BOM, and
# every .ps1 must parse. PowerShell 5.1 reads a BOM-less script as ANSI on a CJK
# locale; a mangled byte can swallow the NEXT LINE of code.
$bad = 0
$shipped = @(Get-ChildItem -LiteralPath $PodDir -Recurse -File -Force |
             Where-Object { $_.Extension -in '.ps1', '.cmd', '.bat' } |
             Sort-Object FullName)
foreach ($f in $shipped) {
  $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
  $bom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
  $nonAscii = @($bytes | Where-Object { $_ -gt 127 }).Count
  # Reset to an EMPTY ARRAY, not $null: @($null).Count is 1 in PS 5.1, which made this
  # self-check flag every non-.ps1 file as a parse failure.
  $errs = @()
  $parseNote = 'n/a'
  if ($f.Extension -eq '.ps1') {
    [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$errs)
    $parseNote = [string]$errs.Count
  }
  $ok = (($nonAscii -eq 0) -or $bom) -and ($errs.Count -eq 0)
  if (-not $ok) { $bad += 1 }
  Write-Host ('  [{0}] {1,-26} non-ascii={2,-6} bom={3,-6} parse-errors={4}' -f $(if ($ok) { 'ok  ' } else { 'CHECK' }), $f.Name, $nonAscii, $bom, $parseNote)
}
$sizeMb = [math]::Round(((Get-ChildItem -LiteralPath $PodDir -Recurse -File | Measure-Object Length -Sum).Sum / 1MB), 1)
Write-Host ('pod files : ' + $list.Count + '   size: ' + $sizeMb + ' MB')
if ($bad -gt 0) {
  throw ('pod self-check found problems in the staging tree; NOT swapping it in -- the live package is untouched: ' + $finalPodDir)
}

# ----------------------------------------------------------------------- swap
# Rename the live package aside, then rename staging into place. The window in which
# neither name is complete is one rename wide. If the aside-rename fails -- a watchdog
# still holding watch.log, say -- nothing has been destroyed yet and the failure is
# loud, which is the whole point of building in staging first.
if (Test-Path -LiteralPath $finalPodDir) {
  Rename-Item -LiteralPath $finalPodDir -NewName (Split-Path -Leaf $legacyDir)
}
Rename-Item -LiteralPath $stageDir -NewName (Split-Path -Leaf $finalPodDir)
$PodDir = $finalPodDir
Write-Host ('swapped   : ' + $stageDir + '  ->  ' + $finalPodDir)
if (Test-Path -LiteralPath $legacyDir) {
  try {
    Remove-Item -LiteralPath $legacyDir -Recurse -Force
  } catch {
    Write-Host ('[warn] could not delete ' + $legacyDir + ' (' + $_.Exception.Message + ')' +
                ' -- the new package IS in place; delete that leftover by hand once nothing holds it') -ForegroundColor Yellow
  }
}

# ------------------------------------------------------------------------ zip
# OFF by default. The zip only pays off when the package is carried to ANOTHER disk
# or machine; sitting beside the folder on the SAME drive it is pure duplication --
# if the drive survived, so did the folder, and if it died the zip died with it.
if ($Zip) {
  if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
  # WHY NOT Compress-Archive (measured on a real 28-entry package zip): Windows
  # PowerShell 5.1 AND .NET Framework's own ZipFile BOTH write entry names with
  # BACKSLASHES -- 14 entries with "\", 0 with "/". APPNOTE 4.4.17.1 requires "/", and
  # on a non-Windows host a backslash is an ordinary filename character, so the
  # archive can unpack as flat files literally named "_backup\x.tgz" instead of the
  # directory tree the package needs. That defeats the entire point of a zip you carry
  # to another machine. bsdtar (shipped as Windows' own tar.exe since 10-1803) writes
  # spec-compliant names AND preserves non-ASCII names; Expand-Archive still reads its
  # output. Its entries carry a harmless "./" prefix.
  $tarExe = Get-Command tar.exe -ErrorAction SilentlyContinue
  if ($tarExe) {
    & $tarExe.Source -a -c -f $zipPath -C $PodDir .
    if ($LASTEXITCODE -ne 0) { throw ('tar.exe failed to build the zip (exit ' + $LASTEXITCODE + ')') }
  } else {
    Write-Host '[warn] tar.exe not found: falling back to Compress-Archive, whose entry names use "\" and may not unpack correctly off Windows' -ForegroundColor Yellow
    Compress-Archive -Path (Join-Path $PodDir '*') -DestinationPath $zipPath -CompressionLevel Optimal
  }
  Write-Host ('zip       : ' + $zipPath)
}

Write-Host 'BUILD OK' -ForegroundColor Green
