$ErrorActionPreference = 'Stop'
& (Join-Path $PSScriptRoot 'sogou-adblock.ps1') -Action Restore
exit $LASTEXITCODE
