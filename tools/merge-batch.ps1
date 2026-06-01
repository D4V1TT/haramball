<#
================================================================
 Haramball - merge data/_batch.json into data/teams-all.json
----------------------------------------------------------------
 Reads data/_batch.json { "leagues":[...], "teams":[...] } and
 splices it into data/teams-all.json, preserving formatting and
 raw UTF-8. Idempotent: existing league names and team ids skipped.
 Build _batch.json first with tools/build-batch.ps1, then run this,
 then tools/generate-pages.ps1.

 Run from the repo root:
   powershell -ExecutionPolicy Bypass -File tools/merge-batch.ps1

 PS 5.1 gotchas baked in (do not "tidy" these away):
   * helper named Field, NOT gv (gv is an alias for Get-Variable).
   * NO param()/[CmdletBinding()] block here -- in this script it
     triggers a parse corruption where JSON parses to a raw string.
   * parse the batch BEFORE reading the big teams-all.json.
   * parse via JavaScriptSerializer, not ConvertFrom-Json.
================================================================
#>
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Web.Extensions
function Read-Json($p) {
  $t = [IO.File]::ReadAllText($p, [Text.Encoding]::UTF8)
  $ser = New-Object System.Web.Script.Serialization.JavaScriptSerializer
  $ser.MaxJsonLength = 134217728
  return $ser.DeserializeObject($t)
}
function Field($d, $k) { if ($d.ContainsKey($k) -and $null -ne $d[$k]) { return [string]$d[$k] } return '' }

$root = (Get-Location).Path
# Parse batch + existing data (as objects) BEFORE creating the big raw string.
$batch    = Read-Json (Join-Path $root 'data/_batch.json')
$existing  = Read-Json (Join-Path $root 'data/teams-all.json')

# Dedupe sets: skip a club already present by id OR by (name + league); skip a
# league already present by name. This makes it safe to feed full rosters for
# leagues we already partly cover (only the missing clubs get added).
$exIds = New-Object 'System.Collections.Generic.HashSet[string]'
$exNL  = New-Object 'System.Collections.Generic.HashSet[string]'
$exLg  = New-Object 'System.Collections.Generic.HashSet[string]'
foreach ($e in $existing['teams']) {
  [void]$exIds.Add([string]$e['id'])
  [void]$exNL.Add((([string]$e['name']) + '|' + ([string]$e['league'])).ToLowerInvariant())
}
foreach ($e in $existing['leagues']) { [void]$exLg.Add(([string]$e['name']).ToLowerInvariant()) }

$raw   = [IO.File]::ReadAllText((Join-Path $root 'data/teams-all.json'), [Text.Encoding]::UTF8)

$q = [char]34; $nl = [char]10
$lAnchor = $q + 'leagues' + $q + ': [' + $nl
$tAnchor = $q + 'teams'   + $q + ': [' + $nl
if (-not $raw.Contains($lAnchor) -or -not $raw.Contains($tAnchor)) { throw "Array openers not found." }
$lStart = $raw.IndexOf($lAnchor); $tStart = $raw.IndexOf($tAnchor)
$lSec = $raw.Substring($lStart, $tStart - $lStart)

$lf = ''; $addedL = 0
foreach ($l in $batch['leagues']) {
  $name = Field $l 'name'
  if ($exLg.Contains($name.ToLowerInvariant())) { continue }
  $tier = Field $l 'tier'; if (-not $tier) { $tier = '1' }
  $lf += '    {' + $nl
  $lf += '      ' + $q + 'name' + $q + ': ' + $q + $name + $q + ',' + $nl
  $lf += '      ' + $q + 'country' + $q + ': ' + $q + (Field $l 'country') + $q + ',' + $nl
  $lf += '      ' + $q + 'country_code' + $q + ': ' + $q + (Field $l 'country_code') + $q + ',' + $nl
  $lf += '      ' + $q + 'confederation' + $q + ': ' + $q + (Field $l 'confederation') + $q + ',' + $nl
  $lf += '      ' + $q + 'tier' + $q + ': ' + $tier + $nl
  $lf += '    },' + $nl
  $addedL++
}

$tf = ''; $addedT = 0
foreach ($t in $batch['teams']) {
  $id = Field $t 'id'
  $tname = Field $t 'name'; $tleague = Field $t 'league'
  $nl_key = ($tname + '|' + $tleague).ToLowerInvariant()
  if ($exIds.Contains($id) -or $exNL.Contains($nl_key)) { continue }
  [void]$exIds.Add($id); [void]$exNL.Add($nl_key)   # also dedupe within this batch
  $color = Field $t 'color'; if (-not $color) { $color = '#444' }
  $tf += '    {' + $nl
  $tf += '      ' + $q + 'id' + $q + ': ' + $q + $id + $q + ',' + $nl
  $tf += '      ' + $q + 'name' + $q + ': ' + $q + (Field $t 'name') + $q + ',' + $nl
  $tf += '      ' + $q + 'short_name' + $q + ': ' + $q + (Field $t 'short_name') + $q + ',' + $nl
  $tf += '      ' + $q + 'league' + $q + ': ' + $q + (Field $t 'league') + $q + ',' + $nl
  $tf += '      ' + $q + 'country' + $q + ': ' + $q + (Field $t 'country') + $q + ',' + $nl
  $tf += '      ' + $q + 'color' + $q + ': ' + $q + $color + $q + ',' + $nl
  $tf += '      ' + $q + 'city' + $q + ': ' + $q + (Field $t 'city') + $q + ',' + $nl
  $tf += '      ' + $q + 'confederation' + $q + ': ' + $q + (Field $t 'confederation') + $q + ',' + $nl
  $tf += '      ' + $q + 'country_code' + $q + ': ' + $q + (Field $t 'country_code') + $q + $nl
  $tf += '    },' + $nl
  $addedT++
}

if ($addedL -eq 0 -and $addedT -eq 0) { Write-Host "Nothing new to add (all present)." -ForegroundColor Yellow; return }

if ($lf) { $raw = $raw.Replace($lAnchor, $lAnchor + $lf) }
if ($tf) { $raw = $raw.Replace($tAnchor, $tAnchor + $tf) }
if ($raw -match '"team_count":\s*(\d+)')   { $n = [int]$Matches[1] + $addedT; $raw = $raw -replace '("team_count":\s*)\d+',   ('${1}' + $n) }
if ($raw -match '"league_count":\s*(\d+)') { $n = [int]$Matches[1] + $addedL; $raw = $raw -replace '("league_count":\s*)\d+', ('${1}' + $n) }

$utf8 = New-Object System.Text.UTF8Encoding($false)
[IO.File]::WriteAllText((Join-Path $root 'data/teams-all.json'), $raw, $utf8)
Write-Host "Merged: +$addedL leagues, +$addedT teams into data/teams-all.json." -ForegroundColor Green
Write-Host "Next: run tools/generate-pages.ps1" -ForegroundColor Cyan
