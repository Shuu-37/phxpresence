# Bundles the runtime addon into a distributable zip under release/.
# Includes only what Ashita loads at runtime (lua + assets) plus LICENSE.
# Excludes dev files: CLAUDE.md, README.md, .gitignore, docs/, tools/,
# data/zones.lua (dormant), and runtime config/ + settings/.

$ErrorActionPreference = 'Stop'

$root    = Split-Path -Parent $PSScriptRoot
$version = (Select-String -Path (Join-Path $root 'phxpresence.lua') -Pattern "addon.version\s*=\s*'([^']+)'").Matches[0].Groups[1].Value
$name    = 'phxpresence'

$releaseDir = Join-Path $root 'release'
$stageDir   = Join-Path $releaseDir $name
$zipPath    = Join-Path $releaseDir "$name-$version.zip"

# Clean staging + prior zip for this version.
if (Test-Path $stageDir) { Remove-Item $stageDir -Recurse -Force }
if (Test-Path $zipPath)  { Remove-Item $zipPath -Force }
New-Item -ItemType Directory -Path $stageDir -Force | Out-Null

# Runtime files/dirs to ship, relative to repo root.
$items = @(
    'phxpresence.lua',
    'presence',
    'discord',
    'assets',
    'LICENSE'
)

foreach ($item in $items) {
    $src = Join-Path $root $item
    if (-not (Test-Path $src)) { throw "Missing expected item: $item" }
    Copy-Item $src (Join-Path $stageDir $item) -Recurse -Force
}

# Zip with the phxpresence/ folder at the archive root so users extract
# straight into their Ashita\addons directory.
Compress-Archive -Path $stageDir -DestinationPath $zipPath -CompressionLevel Optimal

Write-Host "Built $zipPath (v$version)"
Get-ChildItem -Recurse -File $stageDir | ForEach-Object {
    Write-Host ("  " + $_.FullName.Substring($stageDir.Length + 1))
}
