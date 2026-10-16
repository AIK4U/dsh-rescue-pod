# pod-failtest.ps1 -- inject a failure into the builder and prove the live package
# survives it; then prove that a clean build really does swap in.
#
# WHY THIS EXISTS
#   The builder's whole guarantee is "a failed build leaves the existing package
#   byte-for-byte as it was". That guarantee is invisible: every healthy run looks
#   identical either way. So it gets its own test, and the failure is INJECTED rather
#   than waited for -- a satellite is written into _pod-src\_extra\ whose relative path
#   collides with a file the builder produces, which is a hard error by design.
#
# WHAT IT NEVER TOUCHES
#   The live package under test is a THROWAWAY directory created inside -WorkDir.
#   The real built package is never the subject. The one thing it does modify is the
#   real _pod-src\_extra\, and that is removed again in a `finally` (and asserted).
#
# Usage (from a shell):
#   powershell -NoProfile -ExecutionPolicy Bypass -File pod-failtest.ps1
#   ... -PkgDir <path> -WorkDir <path> -KeepFixture
#
# Exit: 0 = every assertion passed, 1 = at least one failed.
# On a full pass it writes <PkgDir>\_selftest\buildtest-last-ok.json, which
# tools\check-buildtest-stamp.ps1 compares against the builder on disk. A rule that
# lives only in someone's memory is not a rule.
#
# ASCII-only.

[CmdletBinding()]
param(
  [string]$PkgDir,
  [string]$WorkDir,
  [switch]$KeepFixture
)

$ErrorActionPreference = 'Stop'
$script:failCount = 0
$script:passCount = 0

function Check([string]$name, [bool]$ok, [string]$detail) {
  if ($ok) { $tag = 'PASS'; $script:passCount += 1 }
  else     { $tag = 'FAIL'; $script:failCount += 1 }
  Write-Host ('  [' + $tag + '] ' + $name + '   ' + $detail)
}

# Snapshot every file under $dir as "relative path -> sha256:length".
function Get-PodSnapshot([string]$dir) {
  $table = @{}
  if (-not (Test-Path -LiteralPath $dir)) { return $table }
  foreach ($f in (Get-ChildItem -LiteralPath $dir -Recurse -File -Force)) {
    $rel = $f.FullName.Substring($dir.Length).TrimStart('\')
    $table[$rel] = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash + ':' + $f.Length
  }
  return $table
}

function Test-SnapshotEqual($before, $after) {
  if ($before.Count -ne $after.Count) { return $false }
  foreach ($k in $before.Keys) {
    if (-not $after.ContainsKey($k)) { return $false }
    if ($after[$k] -ne $before[$k]) { return $false }
  }
  return $true
}

# A known throwaway live package, including a runtime log the builder must carry over.
function New-LivePod([string]$dir) {
  if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force }
  New-Item -ItemType Directory -Path (Join-Path $dir '_backup') -Force | Out-Null
  Set-Content -LiteralPath (Join-Path $dir 'MANIFEST.json') -Value '{"name":"RESCUE-POD","files":[]}' -Encoding UTF8
  Set-Content -LiteralPath (Join-Path $dir 'marker.txt')    -Value 'live package marker: must survive a failed build' -Encoding UTF8
  Set-Content -LiteralPath (Join-Path $dir 'watch.log')     -Value 'round 1' -Encoding UTF8
}

# Run the builder through Windows PowerShell 5.1 (the pod targets 5.1) and return both
# the text and the exit code.
function Invoke-Build([string]$buildScript, [string]$podDir, [string]$rootDir, [switch]$Zip) {
  $argv = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $buildScript,
            '-PodDir', $podDir, '-RootDir', $rootDir)
  if ($Zip) { $argv += '-Zip' }
  # MEASURED (2026-10-16): with $ErrorActionPreference = 'Stop', redirecting a NATIVE
  # command's stderr (2>&1) turns its first stderr line into a terminating error in the
  # PARENT -- the child's real output never reaches $text and the test dies with
  # "ScriptHalted". A failed build writes to stderr by design, so relax it here only.
  $ErrorActionPreference = 'Continue'
  $text = (& powershell @argv 2>&1 | Out-String)
  $code = $LASTEXITCODE
  return [pscustomobject]@{ code = $code; text = $text }
}

# Record a GREEN run so tools\check-buildtest-stamp.ps1 can tell whether the builder
# has been edited since the last passing test. Written ONLY on a full pass: an empty
# stamp is worse than no stamp, because it reports "tested" for an untested builder.
function Write-PassStamp([string]$pkg, [int]$passed) {
  if ($passed -le 0) { throw 'refusing to stamp a run with no passing assertions' }
  $builder = Join-Path $pkg '_guard\build-pod.ps1'
  if (-not (Test-Path -LiteralPath $builder)) {
    Write-Host ('  [warn] no builder at ' + $builder + ' -- stamp not written') -ForegroundColor Yellow
    return
  }
  $stamp = [ordered]@{
    testedAtUtc      = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    assertionsPassed = $passed
    builder          = $builder
    builderSha256    = (Get-FileHash -LiteralPath $builder -Algorithm SHA256).Hash
    host             = [string]$env:COMPUTERNAME
  }
  $path = Join-Path (Join-Path $pkg '_selftest') 'buildtest-last-ok.json'
  [System.IO.File]::WriteAllText($path, ($stamp | ConvertTo-Json -Depth 4), (New-Object System.Text.UTF8Encoding($false)))
  Write-Host ('stamp     : ' + $path)
  Write-Host ('            builder ' + ([string]$stamp.builderSha256).Substring(0, 16) + '...')
}

# ---------------------------------------------------------------- main
if ([string]::IsNullOrWhiteSpace($PkgDir)) {
  $PkgDir = Split-Path -Parent $PSScriptRoot           # <pkg>\_selftest\ -> <pkg>
}
if (-not (Test-Path -LiteralPath (Join-Path $PkgDir '_pod-src'))) {
  throw ('no _pod-src under -PkgDir ' + $PkgDir)
}
# The fixture root is the PARENT of -WorkDir (the builder resolves its zip path from
# -RootDir, which is passed as -WorkDir). Keeping one level of nesting is what lets the
# cleanup below recognise -- and therefore delete -- everything the run produced.
if ([string]::IsNullOrWhiteSpace($WorkDir)) { $WorkDir = Join-Path (Join-Path $PSScriptRoot '_podfail') 'ws' }

$buildScript = Join-Path $PkgDir '_guard\build-pod.ps1'
$extraDir    = Join-Path $PkgDir '_pod-src\_extra'
$livePod     = Join-Path $WorkDir 'live'
$stageDir    = $livePod + '.staging'
$legacyDir   = $livePod + '.replaced'
$injected    = Join-Path $extraDir 'README.md'

if (-not (Test-Path -LiteralPath $buildScript)) { throw ('no builder at ' + $buildScript) }
if (-not (Test-Path -LiteralPath $extraDir))    { throw ('no satellite dir at ' + $extraDir) }
if (Test-Path -LiteralPath $injected) {
  throw ('refusing to run: ' + $injected + ' already exists -- remove it first, it is not ours')
}
if (Test-Path -LiteralPath $WorkDir) { Remove-Item -LiteralPath $WorkDir -Recurse -Force }

$realExtra = @(Get-ChildItem -LiteralPath $extraDir -Recurse -File -Force)
Write-Host 'pod-failtest: a failed build must not touch the live package'
Write-Host ('  builder  : ' + $buildScript)
Write-Host ('  satellites in _pod-src\_extra: ' + $realExtra.Count)

try {
  New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null

  # ---- case 1: a colliding satellite must abort the build harmlessly
  New-LivePod $livePod
  $before = Get-PodSnapshot $livePod
  Write-Host ('  throwaway live package: ' + $before.Count + ' file(s)')
  Set-Content -LiteralPath $injected -Value 'satellite colliding with the pod README.md' -Encoding ASCII
  try {
    $r1 = Invoke-Build $buildScript $livePod $WorkDir
  } finally {
    if (Test-Path -LiteralPath $injected) { Remove-Item -LiteralPath $injected -Force }
  }

  Write-Host '-- case 1: build with a colliding satellite'
  Check 'build fails loudly'             ($r1.code -ne 0) ('exit code = ' + $r1.code)
  Check 'failure names the collision'    ($r1.text -match 'satellite collision') 'the offending path must survive the trap'
  Check 'staging tree cleaned up'        (-not (Test-Path -LiteralPath $stageDir)) ('staging exists = ' + (Test-Path -LiteralPath $stageDir))
  Check 'cleanup reported to the human'  ($r1.text -match 'staging cleaned up after a failure') ''
  Check 'legacy directory absent'        (-not (Test-Path -LiteralPath $legacyDir)) ('replaced exists = ' + (Test-Path -LiteralPath $legacyDir))
  $after = Get-PodSnapshot $livePod
  Check 'live package untouched'         (Test-SnapshotEqual $before $after) ('files before = ' + $before.Count + ', after = ' + $after.Count)
  Check 'injected satellite removed'     (-not (Test-Path -LiteralPath $injected)) 'the source tree must be left as found'

  # ---- case 2: with the collision gone, the same build must swap in cleanly
  $r2 = Invoke-Build $buildScript $livePod $WorkDir -Zip
  Write-Host '-- case 2: build without the collision'
  Check 'build succeeds'                 ($r2.code -eq 0) ('exit code = ' + $r2.code)
  Check 'build reports BUILD OK'         ($r2.text -match 'BUILD OK') ''
  Check 'no staging tree left over'      (-not (Test-Path -LiteralPath $stageDir)) ('staging exists = ' + (Test-Path -LiteralPath $stageDir))
  Check 'no replaced tree left over'     (-not (Test-Path -LiteralPath $legacyDir)) ('replaced exists = ' + (Test-Path -LiteralPath $legacyDir))
  Check 'live package was replaced'      (-not (Test-Path -LiteralPath (Join-Path $livePod 'marker.txt'))) 'the old marker.txt should be gone'
  Check 'runtime log was carried over'   (Test-Path -LiteralPath (Join-Path $livePod 'watch.log')) 'watch.log must survive a rebuild'
  Check 'satellite count matches'        ($r2.text -match ('satellites: ' + $realExtra.Count + ' file')) ('expected ' + $realExtra.Count)
  if ($script:failCount -gt 0) { Write-Host '--- build output (case 2) ---'; Write-Host $r2.text }

  # ---- case 3: the artifact itself must be internally consistent
  $manifestPath = Join-Path $livePod 'MANIFEST.json'
  $mismatch = 0
  if (Test-Path -LiteralPath $manifestPath) {
    $m = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($e in $m.files) {
      $p = Join-Path $livePod $e.path
      if (-not (Test-Path -LiteralPath $p)) { $mismatch += 1; continue }
      if ((Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash -ne $e.sha256) { $mismatch += 1 }
    }
  } else { $mismatch = -1 }
  Check 'manifest re-verifies from disk' ($mismatch -eq 0) ('unresolved entries = ' + $(if ($mismatch -lt 0) { 'no manifest' } else { $mismatch }))

  $zipPath = Join-Path $WorkDir 'RESCUE-POD-v1.0.zip'
  $badSlashes = -1
  if (Test-Path -LiteralPath $zipPath) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $z = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
    try { $badSlashes = @($z.Entries | Where-Object { $_.FullName -like '*\*' }).Count }
    finally { $z.Dispose() }
  }
  Check 'zip entry names use "/" only'   ($badSlashes -eq 0) ('entries with a backslash = ' + $(if ($badSlashes -lt 0) { 'no zip' } else { $badSlashes }) + ' -- a backslash unpacks as a flat filename off Windows')
} finally {
  # The fixture root is one level above -WorkDir, because the builder resolves its
  # zip path from -RootDir, which is passed as exactly that. The name guard is
  # fail-closed: never delete a directory that is not recognisably ours.
  $fixtureRoot = Split-Path -Parent $WorkDir
  if ($KeepFixture) {
    Write-Host ('  fixture kept: ' + $fixtureRoot)
  } elseif ((Split-Path -Leaf $fixtureRoot) -notlike '_podfail*') {
    Write-Host ('  [warn] NOT removing ' + $fixtureRoot + ': not a recognised fixture directory') -ForegroundColor Yellow
  } elseif (Test-Path -LiteralPath $fixtureRoot) {
    Remove-Item -LiteralPath $fixtureRoot -Recurse -Force
    Write-Host ('  fixture removed: ' + $fixtureRoot)
  }
}

if ($script:failCount -gt 0) {
  Write-Host ('FAILED: ' + $script:failCount + ' assertion(s), ' + $script:passCount + ' passed') -ForegroundColor Red
  Write-Host 'no stamp written -- the gate will keep reporting this builder as untested'
  exit 1
}
Write-Host ('ALL ASSERTIONS PASSED (' + $script:passCount + '/' + ($script:passCount + $script:failCount) + ')') -ForegroundColor Green
Write-PassStamp $PkgDir $script:passCount
exit 0
