# run-tests.ps1 -- the repository's own test suite.
#
# Two things are being verified, and they fail in different ways:
#
#   1. the GUARANTEE -- a failed build must leave the live package untouched and leave
#      no staging tree behind, and a clean build must really swap in. Verified by
#      example\pkg\_selftest\pod-failtest.ps1, which injects the failure.
#
#   2. the GATE that keeps (1) honest -- check-buildtest-stamp.ps1 must return 0 only
#      when the stamp matches the builder on disk, and must never return 0 when it
#      cannot tell. A gate that is never seen failing is a decoration, so every branch
#      gets a scenario here with a fixture crafted to trigger it.
#
# The gate scenarios run against a COPY of the builder in a temporary directory; the
# real builder is never modified. The guarantee scenario runs against the real example
# package, which is why running this suite also clears the gate.
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests\run-tests.ps1
#
# Exit: 0 = every scenario passed, 1 = at least one failed.
# ASCII-only.

[CmdletBinding()]
param(
  [switch]$KeepFixture
)

$ErrorActionPreference = 'Stop'
$script:failCount = 0
$script:caseCount = 0

function Check([string]$name, [bool]$ok, [string]$detail) {
  if ($ok) { $tag = 'PASS' } else { $tag = 'FAIL'; $script:failCount += 1 }
  Write-Host ('  [' + $tag + '] ' + $name + '   ' + $detail)
}

function Invoke-Ps1([string]$script, [string[]]$extra) {
  $argv = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script)
  if ($extra) { $argv += $extra }
  # A failed build writes to stderr by design; with $ErrorActionPreference = 'Stop' the
  # first stderr line would become a terminating error in the PARENT and the child's
  # real output would never be captured.
  $ErrorActionPreference = 'Continue'
  $text = (& powershell @argv 2>&1 | Out-String)
  $code = $LASTEXITCODE
  return [pscustomobject]@{ code = $code; text = $text }
}

# ------------------------------------------------------------------ the layout
$repo      = Split-Path -Parent $PSScriptRoot
$pkg       = Join-Path $repo 'example\pkg'
$buildTest = Join-Path $pkg '_selftest\pod-failtest.ps1'
$gate      = Join-Path $repo 'tools\check-buildtest-stamp.ps1'
$builder   = Join-Path $pkg '_guard\build-pod.ps1'
$stamp     = Join-Path $pkg '_selftest\buildtest-last-ok.json'

foreach ($f in @($buildTest, $gate, $builder)) {
  if (-not (Test-Path -LiteralPath $f)) { throw ('missing file: ' + $f) }
}

$work = Join-Path $env:TEMP 'dsh-rescue-pod-tests'
if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
New-Item -ItemType Directory -Path $work -Force | Out-Null

try {
  # ============================ 1. the guarantee ============================
  $script:caseCount += 1
  Write-Host '[1] the guarantee: a failed build must not touch the live package'
  $r = Invoke-Ps1 $buildTest @()
  Check 'pod-failtest passes end to end' ($r.code -eq 0) ('exit code = ' + $r.code)
  if ($r.code -ne 0) { Write-Host $r.text }

  # ============================== 2. the gate ===============================
  $script:caseCount += 1
  Write-Host '[2] the gate: 0 only when the stamp matches the builder on disk'
  $r = Invoke-Ps1 $gate @()
  Check 'a fresh green run opens the gate' ($r.code -eq 0) ('exit code = ' + $r.code)

  # Fixture: a copy of the builder plus a stamp that describes it exactly.
  $fxGuard = Join-Path $work 'guard'
  $fxSelf  = Join-Path $work '_selftest'
  New-Item -ItemType Directory -Path $fxGuard, $fxSelf -Force | Out-Null
  $fxBuilder = Join-Path $fxGuard 'build-pod.ps1'
  $fxStamp   = Join-Path $fxSelf 'buildtest-last-ok.json'
  Copy-Item -LiteralPath $builder -Destination $fxBuilder
  $fxHash = (Get-FileHash -LiteralPath $fxBuilder -Algorithm SHA256).Hash

  function New-Stamp([string]$sha, [string]$about) {
    # 16 is the real assertion count today, but the gate deliberately ignores this
    # field -- it exists so a human reading the stamp knows what was run.
    [pscustomobject]@{
      testedAtUtc = '2026-01-01T00:00:00Z'; assertionsPassed = 16
      builder = $about; builderSha256 = $sha
    } | ConvertTo-Json | Set-Content -LiteralPath $fxStamp -Encoding UTF8
  }

  $script:caseCount += 1
  Write-Host '[3] the gate, branch by branch (each fixture is crafted to trip one)'
  New-Stamp $fxHash $fxBuilder
  $r = Invoke-Ps1 $gate @('-BuildScript', $fxBuilder, '-StampPath', $fxStamp)
  Check 'stamp matches          -> 0' ($r.code -eq 0) ('exit code = ' + $r.code)

  Add-Content -LiteralPath $fxBuilder -Value ' '
  $r = Invoke-Ps1 $gate @('-BuildScript', $fxBuilder, '-StampPath', $fxStamp)
  Check 'builder edited        -> 1' ($r.code -eq 1) ('exit code = ' + $r.code)

  Copy-Item -LiteralPath $builder -Destination $fxBuilder -Force
  Remove-Item -LiteralPath $fxStamp -Force
  $r = Invoke-Ps1 $gate @('-BuildScript', $fxBuilder, '-StampPath', $fxStamp)
  Check 'never tested          -> 1' ($r.code -eq 1) ('exit code = ' + $r.code)

  New-Stamp $fxHash $fxBuilder
  Remove-Item -LiteralPath $fxBuilder -Force
  $r = Invoke-Ps1 $gate @('-BuildScript', $fxBuilder, '-StampPath', $fxStamp)
  Check 'no builder at all     -> 2' ($r.code -eq 2) ('exit code = ' + $r.code)

  Copy-Item -LiteralPath $builder -Destination $fxBuilder -Force
  Set-Content -LiteralPath $fxStamp -Value '{not json' -Encoding UTF8
  $r = Invoke-Ps1 $gate @('-BuildScript', $fxBuilder, '-StampPath', $fxStamp)
  Check 'unreadable stamp      -> 2' ($r.code -eq 2) ('exit code = ' + $r.code)

  New-Stamp $fxHash 'D:\somewhere-else\build-pod.ps1'
  $r = Invoke-Ps1 $gate @('-BuildScript', $fxBuilder, '-StampPath', $fxStamp)
  Check 'stamp for another tree-> 2' ($r.code -eq 2) ('exit code = ' + $r.code)
} finally {
  if ($KeepFixture) {
    Write-Host ('  fixture kept: ' + $work)
  } elseif (Test-Path -LiteralPath $work) {
    Remove-Item -LiteralPath $work -Recurse -Force
  }
}

Write-Host ''
if ($script:failCount -gt 0) {
  Write-Host ('FAILED: ' + $script:failCount + ' assertion(s)') -ForegroundColor Red
  exit 1
}
Write-Host 'ALL TESTS PASSED' -ForegroundColor Green
exit 0
