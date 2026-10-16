# rescue.ps1 -- EXAMPLE ENTRY (a stand-in, not a real rescue).
#
# Pure ASCII on purpose. The builder's self-check counts bytes > 127 in every script
# it ships, because PowerShell 5.1 reads a BOM-less .ps1 as ANSI on a CJK locale and
# a mangled byte can eat the NEXT LINE of code. A real rescue script may carry a
# UTF-8 BOM instead; it may not be non-ASCII without one.

[CmdletBinding()]
param(
  [ValidateSet('check', 'fix', 'boot')]
  [string]$Mode = 'check'
)

$ErrorActionPreference = 'Stop'

Write-Host ('rescue example: mode=' + $Mode)

switch ($Mode) {
  'check' { Write-Host '  nothing to check in the example pod'; exit 0 }
  'fix'   { Write-Host '  nothing to repair in the example pod'; exit 0 }
  'boot'  { Write-Host '  the example does not boot anything';   exit 0 }
  default { throw ('unknown mode: ' + $Mode) }
}
