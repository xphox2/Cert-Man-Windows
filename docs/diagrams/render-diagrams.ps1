<#
.SYNOPSIS
    Re-render every Mermaid source (src\*.mmd) to SVG and high-res PNG.

.DESCRIPTION
    Run this after editing any .mmd file (or the inline ```mermaid blocks, if you keep them
    in sync) to regenerate the slide-ready images in docs\diagrams\.

    Requires mermaid-cli:  npm install -g @mermaid-js/mermaid-cli

.PARAMETER Scale
    PNG resolution multiplier. Default 3 (crisp for slides/print).

.EXAMPLE
    .\render-diagrams.ps1
#>
[CmdletBinding()]
param([int]$Scale = 3)

$ErrorActionPreference = 'Stop'
$here   = Split-Path -Parent $MyInvocation.MyCommand.Path
$srcDir = Join-Path $here 'src'
$cfg    = Join-Path $here 'mmdc-config.json'

$mmdc = Join-Path $env:APPDATA 'npm\mmdc.cmd'
if (-not (Test-Path $mmdc)) { $mmdc = 'mmdc' }   # fall back to PATH

Write-Host "Rendering Mermaid diagrams from $srcDir (scale x$Scale)..." -ForegroundColor Cyan
Get-ChildItem "$srcDir\*.mmd" | ForEach-Object {
    $base = $_.BaseName
    $svg  = Join-Path $here "$base.svg"
    $png  = Join-Path $here "$base.png"
    & $mmdc -i $_.FullName -o $svg -c $cfg -b white *> $null
    & $mmdc -i $_.FullName -o $png -c $cfg -b white -s $Scale *> $null
    Write-Host ("  {0,-32} svg={1} png={2}" -f $base, (Test-Path $svg), (Test-Path $png))
}
Write-Host 'Done.' -ForegroundColor Green
