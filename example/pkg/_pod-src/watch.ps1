# watch.ps1 -- EXAMPLE WATCHDOG (a stand-in).
#
# The real one in the parent project re-heals a bundle that a package manager wiped,
# and compares a snapshot against the installed copy every fifteen seconds. What
# matters for this repository is only that a watchdog WRITES TO watch.log while the
# pod is live -- that is the file lock which makes an in-place rebuild fail halfway,
# and the reason the builder assembles into a staging directory instead.
#
# Pure ASCII on purpose (see rescue.ps1).

[CmdletBinding()]
param(
  [string]$LogPath,
  [int]$Rounds = 1,
  [int]$IntervalSeconds = 0
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($LogPath)) { $LogPath = Join-Path $PSScriptRoot 'watch.log' }
if ($Rounds -lt 1) { throw 'Rounds must be at least 1' }
if ($IntervalSeconds -lt 0) { throw 'IntervalSeconds cannot be negative' }

for ($i = 1; $i -le $Rounds; $i++) {
  Add-Content -LiteralPath $LogPath -Value ('round ' + $i + ' @ ' + (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'))
  if ($IntervalSeconds -gt 0) { Start-Sleep -Seconds $IntervalSeconds }
}
Write-Host ('watch example: wrote ' + $Rounds + ' round(s) to ' + $LogPath)
