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
<a href="https://www.tiktok.com/@haramball.com" target="_blank" rel="noopener" aria-label="TikTok">TikTok</a>
<a href="https://www.instagram.com/haramball11/" target="_blank" rel="noopener" aria-label="Instagram">Instagram</a>
<a href="https://x.com/haramball11" target="_blank" rel="noopener" aria-label="X">X</a>
<a href="https://www.youtube.com/channel/UCnhH-qAcvuU97o4dQVmhz3A" target="_blank" rel="noopener" aria-label="YouTube">YouTube</a>
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

  $title = "Is $nameH playing Haramball at the World Cup? Vote | Haramball"
  $desc  = "Is $nameH guilty of haramball &mdash; time-wasting, parking the bus, anti-football? Vote and see the World Cup worst-football leaderboard, fan reasons and comments."

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
<meta property="og:description" content="Vote on whether $nameH is serving the worst football at the World Cup." />
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
{"@type":"Question","name":"Is $nameJ playing haramball at the World Cup?","acceptedAnswer":{"@type":"Answer","text":"Haramball fans vote on whether $nameJ is serving cynical, time-wasting, anti-entertainment football. See the live vote tally and leaderboard rank on this page."}},
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

<p class="detail-lede">With the World Cup coming, the haramball court is open on <strong>$nameH</strong>. Vote on whether the national team is serving the worst football &mdash; cynical time-wasting, parking the bus, or pure anti-football &mdash; and see how they rank against every other FIFA nation.</p>

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
