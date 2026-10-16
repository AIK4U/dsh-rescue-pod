# check-buildtest-stamp.ps1 -- has the builder been edited since the last GREEN
# failure-injection test?
#
# WHY THIS EXISTS
#   The standing rule is "whenever you touch build-pod.ps1, re-run pod-failtest.ps1".
#   Measured 2026-10-16, during the very session that fixed the builder: the fix was
#   applied in an interrupted round and NOTHING ON DISK said "this builder is untested
#   now". The only way to notice was to compare timestamps by hand.
#
#   A rule with no evidence trail lives in someone's memory. This is the trail: the
#   test writes <pkg>\_selftest\buildtest-last-ok.json on a full pass, and this checker
#   compares the builder hash recorded there against the bytes on disk.
#
# Read-only, no side effects. EXIT CODES -- "cannot tell" must never read as OK:
#   0 = the builder on disk is the one that passed the test
#   1 = STALE: the builder changed after the last green test, or was never tested
#   2 = cannot tell: no builder, or the stamp is missing/unreadable/not ours
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\check-buildtest-stamp.ps1
#   ... -BuildScript <path> -StampPath <path>     (for fault injection, used by the tests)
#
# ASCII-only.

[CmdletBinding()]
param(
  [string]$PkgDir,
  [string]$BuildScript,
  [string]$StampPath
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($PkgDir)) { $PkgDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'example\pkg' }
if ([string]::IsNullOrWhiteSpace($BuildScript)) { $BuildScript = Join-Path $PkgDir '_guard\build-pod.ps1' }
if ([string]::IsNullOrWhiteSpace($StampPath))   { $StampPath   = Join-Path $PkgDir '_selftest\buildtest-last-ok.json' }
$rerun = 're-run: powershell -NoProfile -ExecutionPolicy Bypass -File example\pkg\_selftest\pod-failtest.ps1'

Write-Host '== builder vs last green failure-injection test =='
Write-Host ('builder : ' + $BuildScript)

if (-not (Test-Path -LiteralPath $BuildScript)) {
  Write-Host ('B2 CANNOT TELL: no builder at ' + $BuildScript)
  exit 2
}
$diskHash = (Get-FileHash -LiteralPath $BuildScript -Algorithm SHA256).Hash
Write-Host ('disk sha: ' + $diskHash)

if (-not (Test-Path -LiteralPath $StampPath)) {
  Write-Host ('B2 STALE: no record at ' + $StampPath)
  Write-Host 'B2 -> this builder has never passed the failure-injection test here.'
  Write-Host ('B2 ' + $rerun)
  exit 1
}

$stamp = $null
try {
  $stamp = Get-Content -LiteralPath $StampPath -Raw -Encoding UTF8 | ConvertFrom-Json
} catch {
  Write-Host ('B2 CANNOT TELL: the stamp is unreadable (' + $_.Exception.Message + ')')
  exit 2
}
if (-not $stamp.builderSha256) {
  Write-Host 'B2 CANNOT TELL: the stamp carries no builderSha256'
  exit 2
}
if ($stamp.builder -and ([string]$stamp.builder -ne $BuildScript)) {
  Write-Host ('B2 CANNOT TELL: the stamp is about a different builder (' + [string]$stamp.builder + ')')
  exit 2
}

Write-Host ('last ok : ' + [string]$stamp.testedAtUtc + '   assertions=' + [string]$stamp.assertionsPassed)
Write-Host ('stamp sha: ' + [string]$stamp.builderSha256)
if ($diskHash -ne [string]$stamp.builderSha256) {
  Write-Host 'B2 STALE: the builder changed after the last green test.'
  Write-Host ('B2 ' + $rerun)
  exit 1
}
Write-Host 'OK: the builder on disk is the one that passed the failure-injection test.'
exit 0
