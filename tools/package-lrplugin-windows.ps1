[CmdletBinding()]
param([string]$Cargo = 'cargo.exe')

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$target = 'x86_64-pc-windows-msvc'
$targetDir = Join-Path $repo 'target'
$source = Join-Path $repo 'lightroom\tohdr.lrplugin'
$output = Join-Path $repo 'out'
$plugin = Join-Path $output 'windows-x64\HDR Gain Map HEIC.lrplugin'
$archive = Join-Path $output 'HDR-Gain-Map-HEIC-windows-x64.zip'

Push-Location -LiteralPath $repo
try {
    & $Cargo build --locked --release --target $target --target-dir $targetDir -p tohdr-cli
    if ($LASTEXITCODE -ne 0) { throw "Cargo build failed with exit code $LASTEXITCODE" }

    New-Item -ItemType Directory -Path $plugin -Force | Out-Null
    Get-ChildItem -LiteralPath $source -Filter '*.lua' -File | Copy-Item -Destination $plugin
    Copy-Item -LiteralPath (Join-Path $targetDir "$target\release\tohdr.exe") -Destination $plugin
    Copy-Item -LiteralPath (Join-Path $repo 'LICENSE-APACHE'), (Join-Path $repo 'LICENSE-MIT') -Destination $plugin
    Copy-Item -LiteralPath (Join-Path $repo 'lightroom\README-Windows.md') -Destination (Join-Path $plugin 'README.md')
    Compress-Archive -LiteralPath $plugin -DestinationPath $archive -CompressionLevel Optimal -Force
    Get-Item -LiteralPath $archive
} finally {
    Pop-Location
}
