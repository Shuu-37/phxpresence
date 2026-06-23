<#
.SYNOPSIS
    Resolves an external image URL for each FFXI zone and writes them into
    data/zones.lua. No images are downloaded or stored in the repo - the URLs
    point at the bg-wiki CDN and are used directly as the Discord large_image.

.DESCRIPTION
    Reads the zone names already in data/zones.lua and resolves each to a bg-wiki
    image URL. bg-wiki names its area images after the zone (e.g. the zone
    "SEALIONS DEN" -> File:Sealions_Den.jpg), so this first tries the exact
    File:<Title>.jpg / .png page, then falls back to a File-namespace search.
    data/zones.lua is rewritten as { [id] = { name = "...", image = "https://..." } }.
    Zones with no resolvable image are written without an 'image' field and show no
    artwork at runtime. A coverage summary is printed at the end.

.PARAMETER KeepExisting
    Don't re-resolve zones that already have an image URL.

.EXAMPLE
    pwsh tools/build_zone_urls.ps1
#>
[CmdletBinding()]
param(
    [switch]$KeepExisting
)

$ErrorActionPreference = 'Stop'
$root      = Split-Path -Parent $PSScriptRoot
$zonesLua  = Join-Path $root 'data\zones.lua'
$api       = 'https://www.bg-wiki.com/api.php'
$thumbSize = 512

# Zones with no meaningful art (system / placeholder). No image resolved.
$skip = @(0, 210, 219)

# Optional title overrides (bg-wiki File: base name, no extension) for zones whose
# image file doesn't match the derived title.
$override = @{
}

# --- Parse existing id -> { name, image } from data/zones.lua ------------------
# Normal hashtable: integer keys index by value (an [ordered] dict would treat an
# int as a positional index instead).
$zones = @{}
$raw = Get-Content $zonesLua -Raw
foreach ($m in [regex]::Matches($raw, '\[\s*(\d+)\s*\]\s*=\s*\{\s*name\s*=\s*"((?:[^"\\]|\\.)*)"(?:\s*,\s*image\s*=\s*"((?:[^"\\]|\\.)*)")?')) {
    $id = [int]$m.Groups[1].Value
    $zones[$id] = @{ name = $m.Groups[2].Value; image = $m.Groups[3].Value }
}

$ua = @{ 'User-Agent' = 'phx-presence-url-build/1.0' }

# ALL CAPS zone name -> a bg-wiki File title base (Title_Case, underscores).
function ConvertTo-Title([string]$name) {
    return ((Get-Culture).TextInfo.ToTitleCase($name.ToLower())) -replace '\s+', '_'
}

# bg-wiki sits behind Cloudflare, which rate-limits bursts (HTTP 429 / "error code:
# 1015"). Retry with escalating backoff so a throttle doesn't turn into a miss.
function Invoke-Api([string]$qs) {
    $backoff = @(0, 10, 25, 60)
    for ($a = 0; $a -lt $backoff.Count; $a++) {
        if ($backoff[$a] -gt 0) { Start-Sleep -Seconds $backoff[$a] }
        try {
            return Invoke-RestMethod -Uri "$api`?$qs" -Headers $ua -TimeoutSec 25
        } catch {
            if ($a -lt ($backoff.Count - 1)) {
                Write-Host ("  throttled, backing off {0}s" -f $backoff[$a + 1]) -ForegroundColor DarkGray
            }
        }
    }
    return $null
}

function Build-Qs([hashtable]$params) {
    return ($params.GetEnumerator() | ForEach-Object { "$($_.Key)=$([uri]::EscapeDataString([string]$_.Value))" }) -join '&'
}

# bg-wiki names area banners after the zone (File:<Zone>.jpg). Our zone names lack
# apostrophes, so for zones whose file uses one we generate likely variants:
# "San Doria" -> "San d'Oria", "Rulude" -> "Ru'Lude", and possessives (a word
# ending in 's' -> "...'s" / "...s'"). The base name is always tried first.
function Get-Candidates([string]$title) {
    $cands = New-Object System.Collections.Generic.List[string]
    $cands.Add($title) | Out-Null

    $special = $title -replace 'San_Doria', "San_d'Oria" -replace 'Rulude', "Ru'Lude"
    if ($special -ne $title) { $cands.Add($special) | Out-Null }

    $words = $title.Split('_')
    for ($i = 0; $i -lt $words.Count; $i++) {
        $w = $words[$i]
        if ($w.Length -gt 2 -and $w.EndsWith('s')) {
            foreach ($repl in @(($w.Substring(0, $w.Length - 1) + "'s"), ($w + "'"))) {
                $copy = $words.Clone(); $copy[$i] = $repl
                $cands.Add(($copy -join '_')) | Out-Null
            }
        }
    }
    return ($cands | Select-Object -Unique)
}

# Normalizes a File base name to the key used in the found-image map.
function Get-MapKey([string]$base) {
    return (($base -replace '^File:', '') -replace '\.(jpg|png)$', '' -replace '_', ' ').ToLower()
}

# Returns the first candidate's URL present in the found-image map.
function Resolve-FromMap($cands, $found) {
    foreach ($c in $cands) {
        $key = Get-MapKey $c
        if ($found.ContainsKey($key)) { return $found[$key] }
    }
    return $null
}

# --- Build work items -----------------------------------------------------------
# Each item carries the zone's ordered candidate File base names.
$work = New-Object System.Collections.Generic.List[object]
$have = 0
$miss = New-Object System.Collections.Generic.List[string]
foreach ($id in ($zones.Keys | Sort-Object)) {
    if ($skip -contains $id) { continue }
    if ($KeepExisting -and $zones[$id].image) { $have++; continue }
    $title = if ($override.ContainsKey($id)) { $override[$id] } else { ConvertTo-Title $zones[$id].name }
    $work.Add([pscustomobject]@{ id = $id; name = $zones[$id].name; cands = @(Get-Candidates $title) })
}

# --- Resolve in batches ---------------------------------------------------------
# bg-wiki's API accepts up to 50 titles per query, so we pack several zones into
# one request. This keeps the whole run to ~40 requests and well under the
# Cloudflare rate limit.
$maxTitles = 45
$batchNum = 0
$batch = New-Object System.Collections.Generic.List[object]
$titlesInBatch = 0

function Invoke-Batch($batch) {
    if ($batch.Count -eq 0) { return }
    $script:batchNum++

    $titles = New-Object System.Collections.Generic.List[string]
    foreach ($w in $batch) { foreach ($c in $w.cands) { $titles.Add("File:$c.jpg"); $titles.Add("File:$c.png") } }
    $uniq = $titles | Select-Object -Unique

    $resp = Invoke-Api (Build-Qs @{
        action = 'query'; titles = ($uniq -join '|'); prop = 'imageinfo'
        iiprop = 'url'; iiurlwidth = $thumbSize; redirects = 1; format = 'json'
    })

    $found = @{}
    if ($resp -and $resp.query) {
        foreach ($p in $resp.query.pages.PSObject.Properties.Value) {
            if ($p.imageinfo) {
                $ii = $p.imageinfo[0]
                $found[(Get-MapKey $p.title)] = $(if ($ii.thumburl) { $ii.thumburl } else { $ii.url })
            }
        }
    }

    foreach ($w in $batch) {
        $url = Resolve-FromMap $w.cands $found
        if ($url) {
            $zones[$w.id].image = $url; $script:have++
            Write-Host ("  ok   {0} ({1})" -f $w.name, $w.id) -ForegroundColor Green
        } else {
            $zones[$w.id].image = ''; $script:miss.Add("$($w.id)`t$($w.name)")
            Write-Host ("  miss {0} ({1})" -f $w.name, $w.id) -ForegroundColor DarkYellow
        }
    }
}

for ($k = 0; $k -lt $work.Count; $k++) {
    $w = $work[$k]
    $wTitles = $w.cands.Count * 2
    if ($batch.Count -gt 0 -and ($titlesInBatch + $wTitles) -gt $maxTitles) {
        Write-Host ("batch {0} ({1} zones)..." -f ($batchNum + 1), $batch.Count) -ForegroundColor Cyan
        Invoke-Batch $batch
        $batch = New-Object System.Collections.Generic.List[object]
        $titlesInBatch = 0
        Start-Sleep -Seconds 2
    }
    $batch.Add($w); $titlesInBatch += $wTitles
}
if ($batch.Count -gt 0) {
    Write-Host ("batch {0} ({1} zones)..." -f ($batchNum + 1), $batch.Count) -ForegroundColor Cyan
    Invoke-Batch $batch
}

# --- Rewrite data/zones.lua ----------------------------------------------------
$header = @'
--[[
* phx-presence - Discord Rich Presence for FFXI
* Copyright (c) 2026 Shuu-37 [github.com/Shuu-37/phx-presence]
* MIT License
*
* data/zones.lua
* Zone id -> { name, image } map. 'image' is an external image URL (served from
* the ffxiclopedia CDN) used directly as the Discord large_image; zones without
* an image simply show no artwork. Regenerated by tools/build_zone_urls.ps1.
--]]

return {
'@
$lines = foreach ($id in ($zones.Keys | Sort-Object)) {
    $n = $zones[$id].name -replace '\\','\\' -replace '"','\"'
    if ($zones[$id].image) {
        $img = $zones[$id].image -replace '\\','\\' -replace '"','\"'
        "    [$id] = { name = `"$n`", image = `"$img`" },"
    } else {
        "    [$id] = { name = `"$n`" },"
    }
}
Set-Content -Path $zonesLua -Value ($header + "`n" + ($lines -join "`n") + "`n}`n") -Encoding utf8

Write-Host ""
Write-Host ("Done. images={0} missing={1} of {2}" -f $have, $miss.Count, $zones.Count) -ForegroundColor Cyan
if ($miss.Count -gt 0) {
    Write-Host "Missing (no artwork at runtime):" -ForegroundColor DarkYellow
    $miss | ForEach-Object { Write-Host "  $_" }
}
