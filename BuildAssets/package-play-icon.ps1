# Compatibility entry point: package the current approved three-bar artwork.
$ErrorActionPreference = 'Stop'
& (Join-Path $PSScriptRoot 'package-lineup-icon.ps1')
