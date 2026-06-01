<#
================================================================
 Haramball - build data/_batch.json from a simple text input
----------------------------------------------------------------
 Input file (default data/_input.txt), UTF-8:
   #L|League Name|Country|cc|CONFEDERATION|#color
   Club Name|City
   Club Name|City
   #L|Next League|...
   ...
 Lines starting with #L define the current league. Other non-empty,
 non-# lines are "Club|City". Team ids are "<cc>-<slug(name)>" to
 guarantee uniqueness across the dataset.

 Run from repo root:
   powershell -ExecutionPolicy Bypass -File tools/build-batch.ps1 -In data/_input.txt
 Then: merge-batch.ps1, then generate-pages.ps1.
================================================================
#>
param([string]$In = 'data/_input.txt', [string]$Out = 'data/_batch.json')
$ErrorActionPreference = 'Stop'
$root = (Get-Location).Path
$inPath  = if ([IO.Path]::IsPathRooted($In))  { $In }  else { Join-Path $root $In }
$outPath = if ([IO.Path]::IsPathRooted($Out)) { $Out } else { Join-Path $root $Out }

function Get-Slug([string]$s) {
  if (-not $s) { return '' }
  $s = $s.Replace([string][char]0x00DF, 'ss')
  $s = $s.Replace([string][char]0x00F8, 'o').Replace([string][char]0x00D8, 'o')
  $s = $s.Replace([string][char]0x0111, 'd').Replace([string][char]0x0110, 'd')
  $s = $s.Replace([string][char]0x0142, 'l').Replace([string][char]0x0141, 'l')
  $norm = $s.Normalize([Text.NormalizationForm]::FormD)
  $sb = New-Object System.Text.StringBuilder
  foreach ($ch in $norm.ToCharArray()) {
    if ([Globalization.CharUnicodeInfo]::GetUnicodeCategory($ch) -ne [Globalization.UnicodeCategory]::NonSpacingMark) {
      [void]$sb.Append($ch)
    }
  }
  $out = $sb.ToString().ToLowerInvariant()
  return (($out -replace '[^a-z0-9]+', '-').Trim('-'))
}
function Esc-Json([string]$s) { if ($null -eq $s) { return '' } return $s.Replace('\', '\\').Replace('"', '\"') }

$lines = [IO.File]::ReadAllLines($inPath, [Text.Encoding]::UTF8)
$leagues = @()
$teams = @()
$seen = @{}
$curL = $null; $curCountry = ''; $curCc = ''; $curConf = ''; $curColor = ''
foreach ($line in $lines) {
  $t = $line.Trim()
  if (-not $t) { continue }
  if ($t.StartsWith('#L|')) {
    $p = $t.Substring(3).Split('|')
    $curL = $p[0].Trim(); $curCountry = $p[1].Trim(); $curCc = $p[2].Trim()
    $curConf = $p[3].Trim(); $curColor = if ($p.Count -ge 5 -and $p[4].Trim()) { $p[4].Trim() } else { '#444' }
    $leagues += [pscustomobject]@{ name = $curL; country = $curCountry; cc = $curCc; conf = $curConf }
    continue
  }
  if ($t.StartsWith('#')) { continue }
  $parts = $t.Split('|')
  $name = $parts[0].Trim()
  $city = if ($parts.Count -ge 2) { $parts[1].Trim() } else { '' }
  if (-not $name -or -not $curL) { continue }
  $id = "$($curCc.ToLowerInvariant())-$(Get-Slug $name)"
  if ($seen.ContainsKey($id)) { continue }
  $seen[$id] = $true
  $teams += [pscustomobject]@{ id = $id; name = $name; league = $curL; country = $curCountry; cc = $curCc; conf = $curConf; color = $curColor; city = $city }
}

$q = [char]34; $nl = [char]10
$sb = New-Object System.Text.StringBuilder
[void]$sb.Append('{' + $nl + '  ' + $q + 'leagues' + $q + ': [' + $nl)
$lfrags = @()
foreach ($l in $leagues) {
  $lfrags += '    {' + $q + 'name' + $q + ': ' + $q + (Esc-Json $l.name) + $q + ', ' + $q + 'country' + $q + ': ' + $q + (Esc-Json $l.country) + $q + ', ' + $q + 'country_code' + $q + ': ' + $q + $l.cc + $q + ', ' + $q + 'confederation' + $q + ': ' + $q + $l.conf + $q + ', ' + $q + 'tier' + $q + ': 1}'
}
[void]$sb.Append(($lfrags -join (',' + $nl)) + $nl + '  ],' + $nl + '  ' + $q + 'teams' + $q + ': [' + $nl)
$tfrags = @()
foreach ($t in $teams) {
  $tfrags += '    {' + $q + 'id' + $q + ': ' + $q + $t.id + $q + ', ' + $q + 'name' + $q + ': ' + $q + (Esc-Json $t.name) + $q + ', ' + $q + 'short_name' + $q + ': ' + $q + (Esc-Json $t.name) + $q + ', ' + $q + 'league' + $q + ': ' + $q + (Esc-Json $t.league) + $q + ', ' + $q + 'country' + $q + ': ' + $q + (Esc-Json $t.country) + $q + ', ' + $q + 'color' + $q + ': ' + $q + $t.color + $q + ', ' + $q + 'city' + $q + ': ' + $q + (Esc-Json $t.city) + $q + ', ' + $q + 'confederation' + $q + ': ' + $q + $t.conf + $q + ', ' + $q + 'country_code' + $q + ': ' + $q + $t.cc + $q + '}'
}
[void]$sb.Append(($tfrags -join (',' + $nl)) + $nl + '  ]' + $nl + '}' + $nl)

$utf8 = New-Object System.Text.UTF8Encoding($false)
[IO.File]::WriteAllText($outPath, $sb.ToString(), $utf8)
Write-Host "Built $outPath : $($leagues.Count) leagues, $($teams.Count) teams." -ForegroundColor Green
