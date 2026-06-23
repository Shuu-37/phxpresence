<#
.SYNOPSIS
    Downloads FFXI area artwork from ffxiclopedia (Fandom) for use as Discord
    Rich Presence zone images, and regenerates data/zones.lua.

.DESCRIPTION
    For each zone in data/zones.lua, this searches the ffxiclopedia wiki for the
    zone's page lead image and downloads it to assets/zones/<id>.png. It uses the
    MediaWiki search generator so it tolerates capitalization and apostrophe
    differences (e.g. "SOUTHERN SAN DORIA" -> "Southern San d'Oria").

    Zones it cannot resolve are logged and fall back to assets/zones/default.png
    at runtime. A coverage summary is printed at the end.

.PARAMETER Force
    Re-download images that already exist on disk.

.EXAMPLE
    pwsh tools/fetch_zone_assets.ps1
#>
[CmdletBinding()]
param(
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$root      = Split-Path -Parent $PSScriptRoot
$zonesLua  = Join-Path $root 'data\zones.lua'
$outDir    = Join-Path $root 'assets\zones'
$api       = 'https://ffxiclopedia.fandom.com/api.php'
$thumbSize = 512

New-Item -ItemType Directory -Force $outDir | Out-Null

# Zones with no meaningful art (system/instanced/transport placeholders). Skipped.
$skip = @(0, 210, 219)

# Optional name overrides for zones whose wiki page search is ambiguous.
$override = @{
    235 = 'Bastok Markets'
    230 = "Southern San d'Oria"
    243 = "Ru'Lude Gardens"
}

# --- Parse id -> name out of data/zones.lua -------------------------------------
$zones = @{}
foreach ($m in [regex]::Matches((Get-Content $zonesLua -Raw), '\[\s*(\d+)\s*\]\s*=\s*"([^"]*)"')) {
    $zones[[int]$m.Groups[1].Value] = $m.Groups[2].Value
}

# --- Convert ALL CAPS zone name to a search-friendly title ----------------------
function ConvertTo-Title([string]$name) {
    $ti = (Get-Culture).TextInfo
    return $ti.ToTitleCase($name.ToLower())
}

# --- Resolve a zone's lead-image thumbnail URL via the search generator ---------
function Get-ZoneImageUrl([string]$query) {
    $params = @{
        action      = 'query'
        generator   = 'search'
        gsrsearch   = $query
        gsrlimit    = 1
        prop        = 'pageimages'
        piprop      = 'thumbnail'
        pithumbsize = $thumbSize
        redirects   = 1
        format      = 'json'
    }
    $qs = ($params.GetEnumerator() | ForEach-Object { "$($_.Key)=$([uri]::EscapeDataString([string]$_.Value))" }) -join '&'
    try {
        $resp = Invoke-RestMethod -Uri "$api`?$qs" -Headers @{ 'User-Agent' = 'xipresence-asset-fetch/1.0' } -TimeoutSec 20
    } catch {
        return $null
    }
    if ($null -eq $resp.query) { return $null }
    foreach ($p in $resp.query.pages.PSObject.Properties.Value) {
        if ($p.thumbnail -and $p.thumbnail.source) { return $p.thumbnail.source }
    }
    return $null
}

# --- Main loop ------------------------------------------------------------------
$have = New-Object System.Collections.Generic.List[int]
$miss = New-Object System.Collections.Generic.List[string]
$i = 0
$total = $zones.Count

foreach ($id in ($zones.Keys | Sort-Object)) {
    $i++
    $name = $zones[$id]
    $dest = Join-Path $outDir "$id.png"

    if ($skip -contains $id) { continue }
    if ((Test-Path $dest) -and -not $Force) { $have.Add($id); continue }

    $query = if ($override.ContainsKey($id)) { $override[$id] } else { ConvertTo-Title $name }
    Write-Host ("[{0}/{1}] {2} ({3}) ... " -f $i, $total, $name, $id) -NoNewline

    $url = Get-ZoneImageUrl $query
    if (-not $url) {
        Write-Host 'no image' -ForegroundColor DarkYellow
        $miss.Add("$id`t$name")
        Start-Sleep -Milliseconds 150
        continue
    }

    try {
        Invoke-WebRequest -Uri $url -OutFile $dest -Headers @{ 'User-Agent' = 'xipresence-asset-fetch/1.0' } -TimeoutSec 30
        Write-Host 'ok' -ForegroundColor Green
        $have.Add($id)
    } catch {
        Write-Host 'download failed' -ForegroundColor Red
        $miss.Add("$id`t$name")
    }
    Start-Sleep -Milliseconds 150
}

# --- Write a coverage report ----------------------------------------------------
$report = Join-Path $root 'tools\asset_coverage.txt'
$lines = @("xipresence zone art coverage", "have: $($have.Count)  missing: $($miss.Count)  skipped: $($skip.Count)", "", "MISSING:") + $miss
Set-Content -Path $report -Value $lines -Encoding utf8

Write-Host ""
Write-Host ("Done. have={0} missing={1} skipped={2}" -f $have.Count, $miss.Count, $skip.Count) -ForegroundColor Cyan
Write-Host "Coverage report: $report"
Write-Host "Missing zones fall back to assets/zones/default.png at runtime."
