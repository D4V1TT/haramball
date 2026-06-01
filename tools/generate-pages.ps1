<#
================================================================
 Haramball -- static SEO page generator
----------------------------------------------------------------
 Reads data/teams-all.json + data/leagues.json and emits:
   frontend/team/<id>.html        (one per club, ~963)
   frontend/league/<slug>.html     (one per league, ~82)
   frontend/sitemap.xml            (home + article + all pages)
 Also fills the "Browse by league" block in frontend/index.html
 between the LEAGUE-INDEX:START / END markers.

 The site stays pure-static: re-run this only when team data
 changes. No build step is wired into deployment.

 Usage (from repo root):
   powershell -ExecutionPolicy Bypass -File tools/generate-pages.ps1
================================================================
#>
[CmdletBinding()]
param(
  [string]$Root
)
if (-not $Root) {
  if ($PSScriptRoot) { $Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path }
  else { $Root = (Get-Location).Path }
}

$ErrorActionPreference = 'Stop'
$SITE      = 'https://haramball.com'
$dataDir   = Join-Path $Root 'data'
$frontend  = Join-Path $Root 'frontend'
$teamDir   = Join-Path $frontend 'team'
$leagueDir = Join-Path $frontend 'league'
$today     = (Get-Date).ToString('yyyy-MM-dd')

# UTF-8 without BOM for all output.
$utf8 = New-Object System.Text.UTF8Encoding($false)
function Read-Json($path) {
  $text = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
  return $text | ConvertFrom-Json
}
function Write-File($path, $content) {
  [System.IO.File]::WriteAllText($path, $content, $utf8)
}

function Esc-Html([string]$s) {
  if ($null -eq $s) { return '' }
  return $s.Replace('&','&amp;').Replace('<','&lt;').Replace('>','&gt;').Replace('"','&quot;').Replace("'",'&#39;')
}
function Esc-Json([string]$s) {
  if ($null -eq $s) { return '' }
  return $s.Replace('\','\\').Replace('"','\"').Replace("`r",'').Replace("`n",' ')
}
function Get-Slug([string]$s) {
  if (-not $s) { return '' }
  # Map chars that FormD does not decompose. Source kept ASCII for PS 5.1 ANSI loading.
  $s = $s.Replace([string][char]0x00DF, 'ss')
  $s = $s.Replace([string][char]0x00F8, 'o')
  $s = $s.Replace([string][char]0x00D8, 'o')
  $s = $s.Replace([string][char]0x0111, 'd')
  $s = $s.Replace([string][char]0x0110, 'd')
  $s = $s.Replace([string][char]0x0142, 'l')
  $s = $s.Replace([string][char]0x0141, 'l')
  $norm = $s.Normalize([Text.NormalizationForm]::FormD)
  $sb = New-Object System.Text.StringBuilder
  foreach ($ch in $norm.ToCharArray()) {
    if ([Globalization.CharUnicodeInfo]::GetUnicodeCategory($ch) -ne [Globalization.UnicodeCategory]::NonSpacingMark) {
      [void]$sb.Append($ch)
    }
  }
  $out = $sb.ToString().ToLowerInvariant()
  $out = ($out -replace '[^a-z0-9]+','-').Trim('-')
  return $out
}
function Get-Initials([string]$name) {
  if (-not $name) { return '?' }
  $parts = @($name -split '\s+' | Where-Object { $_ })
  if ($parts.Count -eq 1) { return $parts[0].Substring(0, [Math]::Min(2,$parts[0].Length)).ToUpperInvariant() }
  return ($parts[0].Substring(0,1) + $parts[1].Substring(0,1)).ToUpperInvariant()
}

# ---------- Load data ----------
Write-Host "Reading data..." -ForegroundColor Cyan
$teamsDoc   = Read-Json (Join-Path $dataDir 'teams-all.json')
$teams      = $teamsDoc.teams
$leaguesRaw = $teamsDoc.leagues

# League metadata lookup by name
$leagueMeta = @{}
foreach ($l in $leaguesRaw) { $leagueMeta[$l.name] = $l }

# Countries (national teams)
$countriesDoc = Read-Json (Join-Path $dataDir 'countries.json')
$countries    = $countriesDoc.countries
$confNames = @{
  'UEFA' = 'Europe (UEFA)'; 'CONMEBOL' = 'South America (CONMEBOL)';
  'CONCACAF' = 'North &amp; Central America (CONCACAF)'; 'CAF' = 'Africa (CAF)';
  'AFC' = 'Asia (AFC)'; 'OFC' = 'Oceania (OFC)'
}

# Group teams by league name
$byLeague = @{}
foreach ($t in $teams) {
  if (-not $byLeague.ContainsKey($t.league)) { $byLeague[$t.league] = New-Object System.Collections.ArrayList }
  [void]$byLeague[$t.league].Add($t)
}

# Slug maps
$leagueSlug = @{}
foreach ($name in $byLeague.Keys) { $leagueSlug[$name] = Get-Slug $name }

# Shared HTML fragments ------------------------------------------------
$LOGO_SVG = @'
<svg class="logo-mark" viewBox="0 0 200 200" width="32" height="32" aria-hidden="true"><circle cx="100" cy="100" r="96" fill="#d63031"/><rect x="48" y="38" width="22" height="124" fill="#fff" rx="2"/><rect x="130" y="38" width="22" height="124" fill="#fff" rx="2"/><circle cx="100" cy="100" r="28" fill="#fff"/><circle cx="100" cy="100" r="28" fill="none" stroke="#0a0a0a" stroke-width="2.5"/><polygon points="100,90.5 109.04,97.07 105.58,107.71 94.42,107.71 90.96,97.07" fill="#0a0a0a"/></svg>
'@

$HEADER = @"
<header class="header"><div class="header-inner">
<a class="logo" href="/" aria-label="Haramball home">$LOGO_SVG<span class="logo-text">haram<span>ball</span></span></a>
<nav class="nav" aria-label="Primary">
<a class="nav-btn" href="/">Vote</a>
<a class="nav-btn" href="/#leaderboard">Leaderboards</a>
<a class="nav-btn" href="/what-is-haramball">What is Haramball</a>
</nav></div></header>
"@

$FOOTER = @"
<footer class="footer">
<div class="footer-socials" aria-label="Follow Haramball on social media">
<a href="https://www.tiktok.com/@haramball.com" target="_blank" rel="noopener" aria-label="TikTok"><svg viewBox="0 0 24 24" width="22" height="22" fill="currentColor" aria-hidden="true"><path d="M19.589 6.686a4.793 4.793 0 0 1-3.77-4.245V2h-3.445v13.672a2.896 2.896 0 0 1-5.201 1.743l-.002-.001.002.001a2.895 2.895 0 0 1 3.183-4.51v-3.5a6.329 6.329 0 0 0-5.394 10.692 6.33 6.33 0 0 0 10.857-4.424V8.687a8.182 8.182 0 0 0 4.773 1.526V6.79a4.831 4.831 0 0 1-1.003-.104z"/></svg></a>
<a href="https://www.instagram.com/haramball11/" target="_blank" rel="noopener" aria-label="Instagram"><svg viewBox="0 0 24 24" width="22" height="22" fill="currentColor" aria-hidden="true"><path d="M12 2.163c3.204 0 3.584.012 4.85.07 3.252.148 4.771 1.691 4.919 4.919.058 1.265.069 1.645.069 4.849 0 3.205-.012 3.584-.069 4.849-.149 3.225-1.664 4.771-4.919 4.919-1.266.058-1.644.07-4.85.07-3.204 0-3.584-.012-4.849-.07-3.26-.149-4.771-1.699-4.919-4.92-.058-1.265-.07-1.644-.07-4.849 0-3.204.013-3.583.07-4.849.149-3.227 1.664-4.771 4.919-4.919 1.266-.057 1.645-.069 4.849-.069zm0-2.163c-3.259 0-3.667.014-4.947.072-4.358.2-6.78 2.618-6.98 6.98-.059 1.281-.073 1.689-.073 4.948 0 3.259.014 3.668.072 4.948.2 4.358 2.618 6.78 6.98 6.98 1.281.058 1.689.072 4.948.072 3.259 0 3.668-.014 4.948-.072 4.354-.2 6.782-2.618 6.979-6.98.059-1.28.073-1.689.073-4.948 0-3.259-.014-3.667-.072-4.947-.196-4.354-2.617-6.78-6.979-6.98-1.281-.059-1.69-.073-4.949-.073zm0 5.838c-3.403 0-6.162 2.759-6.162 6.162s2.759 6.163 6.162 6.163 6.162-2.759 6.162-6.163c0-3.403-2.759-6.162-6.162-6.162zm0 10.162c-2.209 0-4-1.79-4-4 0-2.209 1.791-4 4-4s4 1.791 4 4c0 2.21-1.791 4-4 4zm6.406-11.845c-.796 0-1.441.645-1.441 1.44s.645 1.44 1.441 1.44c.795 0 1.439-.645 1.439-1.44s-.644-1.44-1.439-1.44z"/></svg></a>
<a href="https://x.com/haramball11" target="_blank" rel="noopener" aria-label="X (Twitter)"><svg viewBox="0 0 24 24" width="22" height="22" fill="currentColor" aria-hidden="true"><path d="M18.244 2.25h3.308l-7.227 8.26 8.502 11.24H16.17l-5.214-6.817L4.99 21.75H1.68l7.73-8.835L1.254 2.25H8.08l4.713 6.231zm-1.161 17.52h1.833L7.084 4.126H5.117z"/></svg></a>
<a href="https://www.youtube.com/channel/UCnhH-qAcvuU97o4dQVmhz3A" target="_blank" rel="noopener" aria-label="YouTube"><svg viewBox="0 0 24 24" width="22" height="22" fill="currentColor" aria-hidden="true"><path d="M23.498 6.186a3.016 3.016 0 0 0-2.122-2.136C19.505 3.545 12 3.545 12 3.545s-7.505 0-9.377.505A3.017 3.017 0 0 0 .502 6.186C0 8.07 0 12 0 12s0 3.93.502 5.814a3.016 3.016 0 0 0 2.122 2.136c1.871.505 9.376.505 9.376.505s7.505 0 9.377-.505a3.015 3.015 0 0 0 2.122-2.136C24 15.93 24 12 24 12s0-3.93-.502-5.814zM9.545 15.568V8.432L15.818 12l-6.273 3.568z"/></svg></a>
</div>
<p>haramball.com &middot; Vote the worst football of the week</p>
<p class="footer-fine">Not affiliated with any club, league, or federation. For entertainment only.</p>
</footer>
"@

$CF = @"
<script defer src='https://static.cloudflareinsights.com/beacon.min.js' data-cf-beacon='{"token": "e73dff5b5ce54a71905c7f411a12dfab"}'></script>
"@

# ---------- Generate TEAM pages ----------
if (-not (Test-Path $teamDir)) { New-Item -ItemType Directory -Path $teamDir | Out-Null }
Write-Host "Generating $($teams.Count) team pages..." -ForegroundColor Cyan
$teamCount = 0
foreach ($t in $teams) {
  $id        = $t.id
  $name      = $t.name
  $nameH     = Esc-Html $name
  $nameJ     = Esc-Json $name
  $league    = $t.league
  $leagueH   = Esc-Html $league
  $lslug     = $leagueSlug[$league]
  $country   = Esc-Html $t.country
  $conf      = Esc-Html $t.confederation
  $city      = if ($t.city) { Esc-Html $t.city } else { '' }
  $founded   = if ($t.founded) { [string]$t.founded } else { '' }
  $color     = if ($t.color) { $t.color } else { '#444' }
  $initials  = Esc-Html (Get-Initials $name)
  $url       = "$SITE/team/$id"

  $foundedTxt = if ($founded) { " &middot; Founded $founded" } else { '' }
  $cityTxt    = if ($city) { "$city, " } else { '' }
  $title   = "Is $nameH playing Haramball? Vote &amp; rank | Haramball"
  $desc    = "Is $nameH guilty of haramball &mdash; time-wasting, parking the bus, anti-football? See live vote totals, the worst-football leaderboard rank, fan reasons and comments. Cast your verdict."

  # Sibling clubs in the same league (internal links)
  $siblings = $byLeague[$league] | Where-Object { $_.id -ne $id } | Select-Object -First 14
  $sibHtml = ($siblings | ForEach-Object {
    $sc = if ($_.color) { $_.color } else { '#444' }
    "<a href=""/team/$($_.id)""><span class=""ti-badge"" style=""background:$sc"">$(Esc-Html (Get-Initials $_.name))</span><span class=""ti-name"">$(Esc-Html $_.name)</span></a>"
  }) -join "`n"

  $page = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8" />
<meta name="viewport" content="width=device-width, initial-scale=1.0" />
<title>$title</title>
<meta name="description" content="$desc" />
<link rel="canonical" href="$url" />
<meta name="theme-color" content="#0a0a0a" />
<meta name="robots" content="index, follow, max-image-preview:large" />
<meta property="og:site_name" content="Haramball" />
<meta property="og:title" content="Is $nameH playing Haramball?" />
<meta property="og:description" content="Vote on whether $nameH is serving the worst football of the week." />
<meta property="og:type" content="website" />
<meta property="og:url" content="$url" />
<meta property="og:image" content="$SITE/og-image.png" />
<meta name="twitter:card" content="summary_large_image" />
<meta name="twitter:site" content="@haramball11" />
<meta name="twitter:title" content="Is $nameH playing Haramball?" />
<meta name="twitter:image" content="$SITE/og-image.png" />
<link rel="icon" type="image/svg+xml" href="/logo.svg" />
<link rel="alternate icon" href="/favicon.ico" />
<link rel="preconnect" href="https://wolleqnvaonerzsomzvd.supabase.co" crossorigin />
<script type="application/ld+json">
{"@context":"https://schema.org","@type":"BreadcrumbList","itemListElement":[
{"@type":"ListItem","position":1,"name":"Haramball","item":"$SITE/"},
{"@type":"ListItem","position":2,"name":"$(Esc-Json $league)","item":"$SITE/league/$lslug"},
{"@type":"ListItem","position":3,"name":"$nameJ","item":"$url"}]}
</script>
<script type="application/ld+json">
{"@context":"https://schema.org","@type":"SportsTeam","name":"$nameJ","sport":"Association football","memberOf":{"@type":"SportsOrganization","name":"$(Esc-Json $league)"},"url":"$url"}
</script>
<script type="application/ld+json">
{"@context":"https://schema.org","@type":"FAQPage","mainEntity":[
{"@type":"Question","name":"Is $nameJ playing haramball?","acceptedAnswer":{"@type":"Answer","text":"Haramball fans vote on whether $nameJ is serving cynical, time-wasting, anti-entertainment football. See the live vote tally and leaderboard rank on this page."}},
{"@type":"Question","name":"What is haramball?","acceptedAnswer":{"@type":"Answer","text":"Haramball is the worst football of the week: time-wasting, parking the bus, diving and anti-football tactics. Fans vote for the teams most guilty of it."}}]}
</script>
<link rel="stylesheet" href="/styles.css" />
<link rel="stylesheet" href="/page.css" />
<script>window.HARAMBALL_TEAM = { id: "$(Esc-Json $id)", name: "$nameJ" };</script>
<script src="/env.js"></script>
</head>
<body data-team-id="$(Esc-Html $id)" data-team-name="$nameH">
$HEADER
<main>
<article class="detail-page">
<nav class="crumbs" aria-label="Breadcrumb">
<a href="/">Haramball</a><span class="sep">/</span>
<a href="/league/$lslug">$leagueH</a><span class="sep">/</span>
<span>$nameH</span>
</nav>

<div class="detail-hero">
<span class="detail-badge" style="background:$color">$initials</span>
<div>
<h1>Is <span class="accent">$nameH</span> playing haramball?</h1>
<p class="detail-sub">$cityTxt$leagueH &middot; $country$foundedTxt</p>
</div>
</div>

<p class="detail-lede">$nameH play in the <strong>$leagueH</strong> ($country). The haramball court is open: vote on whether they are serving the worst football of the week &mdash; cynical time-wasting, parking the bus, or pure anti-football &mdash; and see how they rank against $($teams.Count - 1)+ other clubs worldwide.</p>

<div class="t-stats" id="t-stats">
<div class="t-stat"><div class="num" id="t-votes-all">&mdash;</div><div class="lbl">All-time votes</div></div>
<div class="t-stat"><div class="num" id="t-votes-week">&mdash;</div><div class="lbl">This week</div></div>
<div class="t-stat"><div class="num" id="t-rank-all">&mdash;</div><div class="lbl">Worst rank</div></div>
</div>
<p class="t-rank-line" id="t-rank-line">Loading the verdict&hellip;</p>

<div class="detail-cta">
<h2>Convict $nameH</h2>
<p>One vote per day. Pick a reason &mdash; time-wasting, diving, parking the bus &mdash; or just cast your verdict.</p>
<a class="btn-vote" data-vote-link href="/?vote=$(Esc-Html $id)">Vote against $nameH &#9878;</a>
</div>

<section class="detail-section">
<h2>Why fans convict $nameH</h2>
<div id="t-reasons"><p class="t-empty">Loading reasons&hellip;</p></div>
</section>

<section class="detail-section">
<h2>What fans are saying</h2>
<div id="t-comments"><p class="t-empty">Loading comments&hellip;</p></div>
</section>

<section class="detail-section">
<h2>Other clubs in $leagueH</h2>
<div class="team-index">
$sibHtml
</div>
<p style="margin-top:14px"><a href="/league/$lslug" class="t-empty" style="color:var(--accent)">See the full $leagueH haramball board &rarr;</a></p>
</section>
</article>
</main>
$FOOTER
$CF
<script type="module" src="/team.js"></script>
</body>
</html>
"@

  Write-File (Join-Path $teamDir "$id.html") $page
  $teamCount++
}
Write-Host "  -> $teamCount team pages written." -ForegroundColor Green

# ---------- Generate LEAGUE pages ----------
if (-not (Test-Path $leagueDir)) { New-Item -ItemType Directory -Path $leagueDir | Out-Null }
Write-Host "Generating $($byLeague.Keys.Count) league pages..." -ForegroundColor Cyan
$leagueCount = 0
foreach ($lname in $byLeague.Keys) {
  $slug    = $leagueSlug[$lname]
  $meta    = $leagueMeta[$lname]
  $lnameH  = Esc-Html $lname
  $lnameJ  = Esc-Json $lname
  $lcountry= if ($meta) { Esc-Html $meta.country } else { '' }
  $lconf   = if ($meta) { Esc-Html $meta.confederation } else { '' }
  $clubs   = $byLeague[$lname] | Sort-Object name
  $n       = $clubs.Count
  $url     = "$SITE/league/$slug"

  $title = "Worst football in the $lnameH &mdash; Haramball leaderboard"
  $desc  = "Vote on the worst football in the $lnameH ($lcountry). Live haramball leaderboard of all $n clubs &mdash; who is parking the bus, time-wasting and serving anti-football right now?"

  $teamItems = ($clubs | ForEach-Object {
    $c = if ($_.color) { $_.color } else { '#444' }
    "<a href=""/team/$($_.id)""><span class=""ti-badge"" style=""background:$c"">$(Esc-Html (Get-Initials $_.name))</span><span class=""ti-name"">$(Esc-Html $_.name)</span></a>"
  }) -join "`n"

  $ldItems = ($clubs | ForEach-Object {
    "{""@type"":""ListItem"",""position"":$($clubs.IndexOf($_)+1),""name"":""$(Esc-Json $_.name)"",""item"":""$SITE/team/$($_.id)""}"
  }) -join ","

  $page = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8" />
<meta name="viewport" content="width=device-width, initial-scale=1.0" />
<title>$title</title>
<meta name="description" content="$desc" />
<link rel="canonical" href="$url" />
<meta name="theme-color" content="#0a0a0a" />
<meta name="robots" content="index, follow, max-image-preview:large" />
<meta property="og:site_name" content="Haramball" />
<meta property="og:title" content="$title" />
<meta property="og:description" content="$desc" />
<meta property="og:type" content="website" />
<meta property="og:url" content="$url" />
<meta property="og:image" content="$SITE/og-image.png" />
<meta name="twitter:card" content="summary_large_image" />
<meta name="twitter:site" content="@haramball11" />
<link rel="icon" type="image/svg+xml" href="/logo.svg" />
<link rel="alternate icon" href="/favicon.ico" />
<link rel="preconnect" href="https://wolleqnvaonerzsomzvd.supabase.co" crossorigin />
<script type="application/ld+json">
{"@context":"https://schema.org","@type":"BreadcrumbList","itemListElement":[
{"@type":"ListItem","position":1,"name":"Haramball","item":"$SITE/"},
{"@type":"ListItem","position":2,"name":"$lnameJ","item":"$url"}]}
</script>
<script type="application/ld+json">
{"@context":"https://schema.org","@type":"ItemList","name":"$lnameJ clubs","itemListElement":[$ldItems]}
</script>
<link rel="stylesheet" href="/styles.css" />
<link rel="stylesheet" href="/page.css" />
<script>window.HARAMBALL_LEAGUE = { name: "$lnameJ" };</script>
<script src="/env.js"></script>
</head>
<body data-league-name="$lnameH">
$HEADER
<main>
<article class="detail-page">
<nav class="crumbs" aria-label="Breadcrumb">
<a href="/">Haramball</a><span class="sep">/</span><span>$lnameH</span>
</nav>

<div class="detail-hero">
<div>
<h1>Worst football in the <span class="accent">$lnameH</span></h1>
<p class="detail-sub">$lcountry &middot; $lconf &middot; $n clubs</p>
</div>
</div>

<p class="detail-lede">Which $lnameH club is serving haramball right now? Vote on the worst football in $lcountry's top flight &mdash; time-wasting, parking the bus, diving and anti-football &mdash; and watch the live leaderboard below.</p>

<section class="detail-section lg-board-section">
<h2>Worst in the $lnameH this week</h2>
<div class="lg-board" id="lg-board"><p class="t-empty">Loading this week's board&hellip;</p></div>
</section>

<section class="detail-section">
<h2>All $n clubs</h2>
<div class="team-index">
$teamItems
</div>
</section>
</article>
</main>
$FOOTER
$CF
<script type="module" src="/league.js"></script>
</body>
</html>
"@

  Write-File (Join-Path $leagueDir "$slug.html") $page
  $leagueCount++
}
Write-Host "  -> $leagueCount league pages written." -ForegroundColor Green

# ---------- Generate COUNTRY pages ----------
$countryDir = Join-Path $frontend 'country'
if (-not (Test-Path $countryDir)) { New-Item -ItemType Directory -Path $countryDir | Out-Null }
Write-Host "Generating $($countries.Count) country pages..." -ForegroundColor Cyan
$countryCount = 0
foreach ($c in $countries) {
  $id      = $c.id
  $name    = $c.name
  $nameH   = Esc-Html $name
  $nameJ   = Esc-Json $name
  $conf    = $c.confederation
  $confH   = if ($confNames.ContainsKey($conf)) { $confNames[$conf] } else { Esc-Html $conf }
  $color   = if ($c.color) { $c.color } else { '#444' }
  $initials= Esc-Html (Get-Initials $name)
  $url     = "$SITE/country/$id"

  $title = "Is $nameH playing Haramball? Vote &amp; rank | Haramball"
  $desc  = "Is the $nameH national team guilty of haramball &mdash; time-wasting, parking the bus, anti-football? Vote and see the worst-football leaderboard rank, fan reasons and comments."

  # A few other nations from the same confederation (internal links)
  $peers = $countries | Where-Object { $_.confederation -eq $conf -and $_.id -ne $id } | Get-Random -Count ([Math]::Min(12, ($countries | Where-Object { $_.confederation -eq $conf -and $_.id -ne $id }).Count))
  $peerHtml = ($peers | ForEach-Object {
    $pc = if ($_.color) { $_.color } else { '#444' }
    "<a href=""/country/$($_.id)""><span class=""ti-badge"" style=""background:$pc"">$(Esc-Html (Get-Initials $_.name))</span><span class=""ti-name"">$(Esc-Html $_.name)</span></a>"
  }) -join "`n"

  $page = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8" />
<meta name="viewport" content="width=device-width, initial-scale=1.0" />
<title>$title</title>
<meta name="description" content="$desc" />
<link rel="canonical" href="$url" />
<meta name="theme-color" content="#0a0a0a" />
<meta name="robots" content="index, follow, max-image-preview:large" />
<meta property="og:site_name" content="Haramball" />
<meta property="og:title" content="Is $nameH playing Haramball?" />
<meta property="og:description" content="Vote on whether the $nameH national team is serving the worst football." />
<meta property="og:type" content="website" />
<meta property="og:url" content="$url" />
<meta property="og:image" content="$SITE/og-image.png" />
<meta name="twitter:card" content="summary_large_image" />
<meta name="twitter:site" content="@haramball11" />
<meta name="twitter:title" content="Is $nameH playing Haramball?" />
<meta name="twitter:image" content="$SITE/og-image.png" />
<link rel="icon" type="image/svg+xml" href="/logo.svg" />
<link rel="alternate icon" href="/favicon.ico" />
<link rel="preconnect" href="https://wolleqnvaonerzsomzvd.supabase.co" crossorigin />
<script type="application/ld+json">
{"@context":"https://schema.org","@type":"BreadcrumbList","itemListElement":[
{"@type":"ListItem","position":1,"name":"Haramball","item":"$SITE/"},
{"@type":"ListItem","position":2,"name":"Countries","item":"$SITE/#countries"},
{"@type":"ListItem","position":3,"name":"$nameJ","item":"$url"}]}
</script>
<script type="application/ld+json">
{"@context":"https://schema.org","@type":"SportsTeam","name":"$nameJ national football team","sport":"Association football","url":"$url"}
</script>
<script type="application/ld+json">
{"@context":"https://schema.org","@type":"FAQPage","mainEntity":[
{"@type":"Question","name":"Is the $nameJ national team playing haramball?","acceptedAnswer":{"@type":"Answer","text":"Haramball fans vote on whether $nameJ is serving cynical, time-wasting, anti-entertainment football. See the live vote tally and leaderboard rank on this page."}},
{"@type":"Question","name":"What is haramball?","acceptedAnswer":{"@type":"Answer","text":"Haramball is the worst football: time-wasting, parking the bus, diving and anti-football tactics. Fans vote for the teams most guilty of it."}}]}
</script>
<link rel="stylesheet" href="/styles.css" />
<link rel="stylesheet" href="/page.css" />
<script>window.HARAMBALL_COUNTRY = { id: "$(Esc-Json $id)", name: "$nameJ" };</script>
<script src="/env.js"></script>
</head>
<body data-country-id="$(Esc-Html $id)" data-country-name="$nameH">
$HEADER
<main>
<article class="detail-page">
<nav class="crumbs" aria-label="Breadcrumb">
<a href="/">Haramball</a><span class="sep">/</span>
<a href="/#countries">Countries</a><span class="sep">/</span>
<span>$nameH</span>
</nav>

<div class="detail-hero">
<span class="detail-badge" style="background:$color">$initials</span>
<div>
<h1>Is <span class="accent">$nameH</span> playing haramball?</h1>
<p class="detail-sub">$confH</p>
</div>
</div>

<p class="detail-lede">The haramball court is open on <strong>$nameH</strong>. Vote on whether the national team is serving the worst football &mdash; cynical time-wasting, parking the bus, or pure anti-football &mdash; and see how they rank against every other FIFA nation.</p>

<div class="t-stats" id="t-stats">
<div class="t-stat"><div class="num" id="t-votes-all">&mdash;</div><div class="lbl">All-time votes</div></div>
<div class="t-stat"><div class="num" id="t-votes-week">&mdash;</div><div class="lbl">This week</div></div>
<div class="t-stat"><div class="num" id="t-rank-all">&mdash;</div><div class="lbl">Worst rank</div></div>
</div>
<p class="t-rank-line" id="t-rank-line">Loading the verdict&hellip;</p>

<div class="detail-cta">
<h2>Convict $nameH</h2>
<p>One country vote per day. Pick a reason &mdash; time-wasting, diving, parking the bus &mdash; or just cast your verdict.</p>
<a class="btn-vote" data-vote-link href="/?cvote=$(Esc-Html $id)">Vote against $nameH &#9878;</a>
</div>

<section class="detail-section">
<h2>Why fans convict $nameH</h2>
<div id="t-reasons"><p class="t-empty">Loading reasons&hellip;</p></div>
</section>

<section class="detail-section">
<h2>What fans are saying</h2>
<div id="t-comments"><p class="t-empty">Loading comments&hellip;</p></div>
</section>

<section class="detail-section">
<h2>Other nations in $confH</h2>
<div class="team-index">
$peerHtml
</div>
</section>
</article>
</main>
$FOOTER
$CF
<script type="module" src="/country.js"></script>
</body>
</html>
"@

  Write-File (Join-Path $countryDir "$id.html") $page
  $countryCount++
}
Write-Host "  -> $countryCount country pages written." -ForegroundColor Green

# ---------- Emit country import SQL ----------
Write-Host "Writing backend/05-import-countries.sql..." -ForegroundColor Cyan
$sqlDir = Join-Path $Root 'backend'
$csb = New-Object System.Text.StringBuilder
[void]$csb.AppendLine('-- ============================================================')
[void]$csb.AppendLine('-- HARAMBALL.COM - national team seed (GENERATED by tools/generate-pages.ps1)')
[void]$csb.AppendLine('-- Run AFTER 04-countries.sql. Idempotent upsert.')
[void]$csb.AppendLine('-- ============================================================')
[void]$csb.AppendLine('insert into public.national_teams (id, name, confederation, code, color) values')
$rows = @()
foreach ($c in $countries) {
  $nm = $c.name.Replace("'", "''")
  $cd = if ($c.code) { $c.code.Replace("'","''") } else { '' }
  $co = if ($c.color) { $c.color } else { '#444' }
  $rows += "  ('$($c.id)', '$nm', '$($c.confederation)', '$cd', '$co')"
}
[void]$csb.AppendLine(($rows -join ",`n"))
[void]$csb.AppendLine('on conflict (id) do update set')
[void]$csb.AppendLine('  name = excluded.name, confederation = excluded.confederation,')
[void]$csb.AppendLine('  code = excluded.code, color = excluded.color, active = true;')
Write-File (Join-Path $sqlDir '05-import-countries.sql') $csb.ToString()
Write-Host "  -> 05-import-countries.sql with $($countries.Count) rows." -ForegroundColor Green

# ---------- Emit club import SQL (single source: teams-all.json) ----------
# Additive + idempotent. Countries use "do nothing" so the existing
# hand-seeded country rows (incl. the GB/home-nations quirk) are untouched.
Write-Host "Writing backend/06-import-clubs.sql..." -ForegroundColor Cyan
function Esc-Sql([string]$s) { if ($null -eq $s) { return '' } return $s.Replace("'", "''") }

$tsb = New-Object System.Text.StringBuilder
[void]$tsb.AppendLine('-- ============================================================')
[void]$tsb.AppendLine('-- HARAMBALL.COM - club seed (GENERATED by tools/generate-pages.ps1)')
[void]$tsb.AppendLine('-- Source of truth: data/teams-all.json. Run AFTER 01-schema.sql.')
[void]$tsb.AppendLine('-- Idempotent. Supersedes the hand-written 02-import-teams.sql.')
[void]$tsb.AppendLine('-- ============================================================')
[void]$tsb.AppendLine('')

# Countries (distinct by code; first name wins). do-nothing avoids clobbering existing rows.
[void]$tsb.AppendLine('insert into public.countries (code, name, confederation) values')
$seenCodes = @{}
$cRows = @()
foreach ($l in $leaguesRaw) {
  if (-not $seenCodes.ContainsKey($l.country_code)) {
    $seenCodes[$l.country_code] = $true
    $cRows += "  ('$(Esc-Sql $l.country_code)', '$(Esc-Sql $l.country)', '$(Esc-Sql $l.confederation)')"
  }
}
[void]$tsb.AppendLine(($cRows -join ",`n"))
[void]$tsb.AppendLine('on conflict (code) do nothing;')
[void]$tsb.AppendLine('')

# Leagues
[void]$tsb.AppendLine('insert into public.leagues (name, country_code, confederation, tier) values')
$lRows = @()
foreach ($l in $leaguesRaw) {
  $tier = if ($l.tier) { [int]$l.tier } else { 1 }
  $lRows += "  ('$(Esc-Sql $l.name)', '$(Esc-Sql $l.country_code)', '$(Esc-Sql $l.confederation)', $tier)"
}
[void]$tsb.AppendLine(($lRows -join ",`n"))
[void]$tsb.AppendLine('on conflict (name, country_code) do update set tier = excluded.tier, confederation = excluded.confederation;')
[void]$tsb.AppendLine('')

# Teams (mapped to league_id via (league name, country_code))
[void]$tsb.AppendLine('with input(id, name, short_name, league_name, country_code, color, city) as (')
[void]$tsb.AppendLine('  values')
$tRows = @()
foreach ($t in $teams) {
  $sn = if ($t.short_name) { Esc-Sql $t.short_name } else { Esc-Sql $t.name }
  $cl = if ($t.color) { Esc-Sql $t.color } else { '#444' }
  $ci = if ($t.city) { "'$(Esc-Sql $t.city)'" } else { 'null' }
  $tRows += "    ('$(Esc-Sql $t.id)', '$(Esc-Sql $t.name)', '$sn', '$(Esc-Sql $t.league)', '$(Esc-Sql $t.country_code)', '$cl', $ci)"
}
[void]$tsb.AppendLine(($tRows -join ",`n"))
[void]$tsb.AppendLine(')')
[void]$tsb.AppendLine('insert into public.teams (id, league_id, name, short_name, color, city, active)')
[void]$tsb.AppendLine('select i.id, l.id, i.name, i.short_name, i.color, i.city, true')
[void]$tsb.AppendLine('from input i')
[void]$tsb.AppendLine('join public.leagues l on l.name = i.league_name and l.country_code = i.country_code')
[void]$tsb.AppendLine('on conflict (id) do update set')
[void]$tsb.AppendLine('  league_id = excluded.league_id, name = excluded.name, short_name = excluded.short_name,')
[void]$tsb.AppendLine('  color = excluded.color, city = excluded.city, active = true, updated_at = now();')
[void]$tsb.AppendLine('')

# Deactivate any club no longer in teams-all.json (e.g. old variants replaced
# during a league refresh). Non-destructive: getTeams() filters active=true,
# and votes/FKs are preserved. teams-all.json is the single source of truth.
[void]$tsb.AppendLine('-- Retire clubs that are no longer in the dataset (prevents duplicates from earlier imports).')
[void]$tsb.AppendLine('update public.teams set active = false, updated_at = now() where id not in (')
$idList = @()
foreach ($t in $teams) { $idList += "'$(Esc-Sql $t.id)'" }
# Emit ~12 ids per line for readability.
$chunk = @()
for ($k = 0; $k -lt $idList.Count; $k++) {
  $chunk += $idList[$k]
  if ($chunk.Count -eq 12 -or $k -eq ($idList.Count - 1)) {
    $sep = if ($k -eq ($idList.Count - 1)) { '' } else { ',' }
    [void]$tsb.AppendLine('  ' + ($chunk -join ', ') + $sep)
    $chunk = @()
  }
}
[void]$tsb.AppendLine(');')
Write-File (Join-Path $sqlDir '06-import-clubs.sql') $tsb.ToString()
Write-Host "  -> 06-import-clubs.sql ($($leaguesRaw.Count) leagues, $($teams.Count) teams)." -ForegroundColor Green

# ---------- Sitemap ----------
Write-Host "Writing sitemap.xml..." -ForegroundColor Cyan
$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine('<?xml version="1.0" encoding="UTF-8"?>')
[void]$sb.AppendLine('<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">')
[void]$sb.AppendLine("  <url><loc>$SITE/</loc><lastmod>$today</lastmod><changefreq>daily</changefreq><priority>1.0</priority></url>")
[void]$sb.AppendLine("  <url><loc>$SITE/what-is-haramball</loc><lastmod>$today</lastmod><changefreq>monthly</changefreq><priority>0.8</priority></url>")
foreach ($lname in ($byLeague.Keys | Sort-Object)) {
  [void]$sb.AppendLine("  <url><loc>$SITE/league/$($leagueSlug[$lname])</loc><lastmod>$today</lastmod><changefreq>daily</changefreq><priority>0.7</priority></url>")
}
foreach ($t in ($teams | Sort-Object id)) {
  [void]$sb.AppendLine("  <url><loc>$SITE/team/$($t.id)</loc><lastmod>$today</lastmod><changefreq>weekly</changefreq><priority>0.6</priority></url>")
}
foreach ($c in ($countries | Sort-Object id)) {
  [void]$sb.AppendLine("  <url><loc>$SITE/country/$($c.id)</loc><lastmod>$today</lastmod><changefreq>weekly</changefreq><priority>0.6</priority></url>")
}
[void]$sb.AppendLine('</urlset>')
Write-File (Join-Path $frontend 'sitemap.xml') $sb.ToString()
Write-Host "  -> sitemap.xml with $(2 + $byLeague.Keys.Count + $teams.Count + $countries.Count) URLs." -ForegroundColor Green

# ---------- Inject "Browse by league" into index.html ----------
$indexPath = Join-Path $frontend 'index.html'
$indexHtml = [System.IO.File]::ReadAllText($indexPath, [System.Text.Encoding]::UTF8)
$startMark = '<!-- LEAGUE-INDEX:START -->'
$endMark   = '<!-- LEAGUE-INDEX:END -->'
if ($indexHtml.Contains($startMark) -and $indexHtml.Contains($endMark)) {
  $links = ($byLeague.Keys | Sort-Object | ForEach-Object {
    $m = $leagueMeta[$_]
    $ctry = if ($m) { Esc-Html $m.country } else { '' }
    "<li><a href=""/league/$($leagueSlug[$_])""><span>$(Esc-Html $_)</span> <span class=""li-country"">$ctry</span></a></li>"
  }) -join "`n"
  $inner = "`n<ul class=""league-index"">`n$links`n</ul>`n"
  $iStart = $indexHtml.IndexOf($startMark)
  $iEnd   = $indexHtml.IndexOf($endMark)
  $pre    = $indexHtml.Substring(0, $iStart + $startMark.Length)
  $post   = $indexHtml.Substring($iEnd)
  $indexHtml = $pre + $inner + $post
  Write-File $indexPath $indexHtml
  Write-Host "  -> index.html league index updated." -ForegroundColor Green
} else {
  Write-Host "  ! LEAGUE-INDEX markers not found in index.html -- skipped." -ForegroundColor Yellow
}

# ---------- Inject "Browse by country" into index.html ----------
$cStart = '<!-- COUNTRY-INDEX:START -->'
$cEnd   = '<!-- COUNTRY-INDEX:END -->'
$indexHtml = [System.IO.File]::ReadAllText($indexPath, [System.Text.Encoding]::UTF8)
if ($indexHtml.Contains($cStart) -and $indexHtml.Contains($cEnd)) {
  $clinks = ($countries | Sort-Object name | ForEach-Object {
    "<li><a href=""/country/$($_.id)""><span>$(Esc-Html $_.name)</span> <span class=""li-country"">$(Esc-Html $_.confederation)</span></a></li>"
  }) -join "`n"
  $cinner = "`n<ul class=""league-index"">`n$clinks`n</ul>`n"
  $ci1 = $indexHtml.IndexOf($cStart)
  $ci2 = $indexHtml.IndexOf($cEnd)
  $cpre = $indexHtml.Substring(0, $ci1 + $cStart.Length)
  $cpost = $indexHtml.Substring($ci2)
  $indexHtml = $cpre + $cinner + $cpost
  Write-File $indexPath $indexHtml
  Write-Host "  -> index.html country index updated." -ForegroundColor Green
}

Write-Host "`nDone. Team: $teamCount, League: $leagueCount, Country: $countryCount." -ForegroundColor Cyan
