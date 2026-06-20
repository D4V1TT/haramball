/* ============================================================
 * Haramball — application logic
 * ============================================================ */
import { api } from './api.js';

// ---------- DOM helpers ----------
const $  = (id) => document.getElementById(id);
const $$ = (sel, root = document) => Array.from(root.querySelectorAll(sel));

function fmtNum(n) {
  if (n == null) return '—';
  return Number(n).toLocaleString();
}

function getInitials(name) {
  if (!name) return '?';
  const parts = String(name).split(/\s+/).filter(Boolean);
  if (parts.length === 1) return parts[0].slice(0, 2).toUpperCase();
  return (parts[0][0] + parts[1][0]).toUpperCase();
}

function showToast(msg, ms = 2400) {
  const t = $('toast');
  t.textContent = msg;
  t.classList.add('show');
  clearTimeout(showToast._t);
  showToast._t = setTimeout(() => t.classList.remove('show'), ms);
}

function escapeHtml(s) {
  if (s == null) return '';
  return String(s)
    .replace(/&/g, '&amp;').replace(/</g, '&lt;')
    .replace(/>/g, '&gt;').replace(/"/g, '&quot;').replace(/'/g, '&#39;');
}

// ---------- Analytics ----------
// Fires custom events to Cloudflare Web Analytics.
// `cfBeacon` is exposed by the Cloudflare beacon script in index.html.
// We also log to console so events show in dev tools during local testing.
function track(eventName, props = {}) {
  try {
    if (typeof window !== 'undefined' && window.cfBeacon && typeof window.cfBeacon.track === 'function') {
      window.cfBeacon.track(eventName, props);
    }
    // Cloudflare's modern API: window.__cfBeacon._
    // Fallback: dispatch a custom DOM event that the beacon listens for.
    if (typeof window !== 'undefined' && window.dispatchEvent) {
      window.dispatchEvent(new CustomEvent('cf-analytics-event', {
        detail: { name: eventName, props }
      }));
    }
  } catch (e) {
    // Never break the app for analytics failures
  }
  // Also log to console so we can see events fire during testing
  if (typeof console !== 'undefined') {
    console.log('[analytics]', eventName, props);
  }
}

// ---------- Application state ----------
const state = {
  mode: 'clubs',              // 'clubs' | 'countries' (homepage defaults to clubs)
  teams: [],
  countries: [],
  leagues: [],
  reasons: [],
  votedToday: { voted: false },         // club vote status (today)
  countryVotedToday: { voted: false },  // country vote status (today, independent)
  selectedTeam: null,
  selectedIsCountry: false,
  selectedReason: null,
  filterConf: 'all',
  filterLeague: 'all',
  searchQuery: '',
  lbPeriod: 'week',
  renderLimit: 0,   // how many cards are currently shown (grows via "Load more")
};

// How many cards to render at once. Smaller first paint on phones.
const PAGE_SIZE = (typeof window !== 'undefined' && window.innerWidth <= 640) ? 60 : 120;

// ---------- Mode helpers ----------
const isCountries = () => state.mode === 'countries';
// The list of votable items for the current mode.
const currentItems = () => isCountries() ? state.countries : state.teams;
// The vote-status object for the current mode.
const currentVoted = () => isCountries() ? state.countryVotedToday : state.votedToday;
// Secondary line for a card/row: league+country for clubs, confederation for countries.
function itemMeta(item) {
  if (isCountries()) return item.confederation || '';
  return [item.league, item.country].filter(Boolean).join(' · ');
}

// ---------- View routing ----------
function switchView(view) {
  $$('.nav-btn').forEach(b => b.classList.toggle('active', b.dataset.view === view));
  $$('.view').forEach(s => s.classList.add('hidden'));
  const target = $(`view-${view}`);
  if (target) target.classList.remove('hidden');
  if (view === 'leaderboard') loadLeaderboard();
  // Keep the address bar in sync with the active view, otherwise a stale
  // #leaderboard (e.g. arriving from another page) sticks on every view.
  const targetHash = view === 'vote' ? '' : `#${view}`;
  if (window.location.hash !== targetHash) {
    history.replaceState(null, '', window.location.pathname + window.location.search + targetHash);
  }
  track('view_switched', { view });
  window.scrollTo({ top: 0, behavior: 'smooth' });
}
window.switchView = switchView; // exposed for the logo onclick handler

// ---------- Mode switching (Clubs <-> Countries) ----------
async function switchMode(mode) {
  if (mode !== 'clubs' && mode !== 'countries') return;
  if (mode === state.mode) return;
  state.mode = mode;

  // Reflect on every mode toggle (there's one in the hero and one on the board).
  $$('.mode-btn').forEach(b => {
    const on = b.dataset.mode === mode;
    b.classList.toggle('active', on);
    b.setAttribute('aria-selected', on ? 'true' : 'false');
  });

  // Countries have no leagues — hide the league filter, reset it.
  const leagueFilter = $('league-filter');
  if (leagueFilter) leagueFilter.classList.toggle('hidden', isCountries());
  state.filterLeague = 'all';
  if (leagueFilter) leagueFilter.value = 'all';

  // Reset the search when switching modes (a club query rarely matches countries).
  state.searchQuery = '';
  const searchInput = $('search');
  if (searchInput) {
    searchInput.value = '';
    searchInput.placeholder = isCountries()
      ? 'Search any country to vote against…'
      : 'Search any team to vote against…';
  }
  const sc = $('search-clear');
  if (sc) sc.classList.add('hidden');

  // Ensure country data is present (lazy: may still be loading at first toggle).
  if (isCountries() && state.countries.length === 0) {
    try { state.countries = await api.getCountries(); } catch { state.countries = []; }
  }

  track('mode_switched', { mode });

  // Re-render everything that depends on mode.
  renderVoteStatus();
  resetAndRenderTeams();
  renderRandomHints();
  renderQuickVote();
  loadTopPreview();
  loadGlobalStats();   // hero stats are per-mode (own vote/this-week/listed counts)
  // If the leaderboard view is currently visible, reload it too.
  if (!$('view-leaderboard').classList.contains('hidden')) loadLeaderboard();
}
window.switchMode = switchMode;

// ---------- Stats / hero ----------
async function loadGlobalStats() {
  try {
    const lbl = $('stat-teams-lbl');
    if (isCountries()) {
      const s = await api.getCountryGlobalStats();
      $('stat-votes').textContent = fmtNum(s.total_votes);
      $('stat-week').textContent  = fmtNum(s.votes_this_week);
      $('stat-teams').textContent = fmtNum(s.active_countries);
      if (lbl) lbl.textContent = 'Countries listed';
    } else {
      const s = await api.getGlobalStats();
      $('stat-votes').textContent = fmtNum(s.total_votes);
      $('stat-week').textContent  = fmtNum(s.votes_this_week);
      $('stat-teams').textContent = fmtNum(s.active_teams);
      if (lbl) lbl.textContent = 'Teams listed';
      $('about-team-count').textContent = fmtNum(s.active_teams);
    }
  } catch (e) {
    console.error('stats failed', e);
  }
}

// ---------- Top voted this week preview ----------
async function loadTopPreview() {
  const wrap = $('top-preview');
  const list = $('top-preview-list');
  if (!wrap || !list) return;  // Elements might not exist in older HTML — skip gracefully
  try {
    const rows = isCountries()
      ? await api.getCountryLeaderboard({ period: 'week', limit: 3 })
      : await api.getLeaderboard({ period: 'week', limit: 3 });
    if (!rows || rows.length === 0) {
      wrap.classList.add('hidden');
      return;
    }
    list.innerHTML = rows.map(r => {
      const rank = Number(r.rank);
      let rankCls = '';
      if (rank === 1) rankCls = 'gold';
      else if (rank === 2) rankCls = 'silver';
      else if (rank === 3) rankCls = 'bronze';
      const rid   = isCountries() ? r.country_id    : r.team_id;
      const rname = isCountries() ? r.country_name  : r.team_name;
      const rcol  = isCountries() ? r.country_color : r.team_color;
      const meta = isCountries()
        ? (r.confederation || '')
        : [r.league_name, r.country_name].filter(Boolean).join(' · ');
      return `<div class="tp-row" data-team="${escapeHtml(rid)}">
        <div class="tp-rank ${rankCls}">${rank}</div>
        <div class="tp-badge" style="background:${escapeHtml(rcol || '#444')}">${escapeHtml(getInitials(rname))}</div>
        <div class="tp-info">
          <div class="tp-name">${escapeHtml(rname)}</div>
          <div class="tp-meta">${escapeHtml(meta)}</div>
        </div>
        <div>
          <div class="tp-votes">${fmtNum(r.vote_count)}</div>
          <div class="tp-votes-lbl">votes</div>
        </div>
      </div>`;
    }).join('');

    // Click a top row to open the vote modal for that team
    const canVote = !currentVoted().voted;
    $$('.tp-row', list).forEach(row => {
      if (!canVote) row.classList.add('disabled');
      row.addEventListener('click', () => {
        if (row.classList.contains('disabled')) return;
        track('top_preview_clicked', { team_id: row.dataset.team });
        openVoteModal(row.dataset.team);
      });
    });

    wrap.classList.remove('hidden');
  } catch (e) {
    console.error('top preview failed', e);
    wrap.classList.add('hidden');
  }
}

// ---------- Voting status ----------
async function refreshVotedToday() {
  // Club and country votes are independent (one of each per day).
  const [club, country] = await Promise.allSettled([
    api.hasVotedToday(),
    api.hasVotedCountryToday(),
  ]);
  state.votedToday        = club.status === 'fulfilled'    ? club.value    : { voted: false };
  state.countryVotedToday = country.status === 'fulfilled' ? country.value : { voted: false };
  renderVoteStatus();
}

function renderVoteStatus() {
  const el = $('vote-status');
  const text = $('vote-status-text');
  const voted = currentVoted();
  const noun = isCountries() ? 'country' : 'team';
  if (voted.voted) {
    const id = isCountries() ? voted.country_id : voted.team_id;
    const item = currentItems().find(t => t.id === id);
    el.classList.add('voted');
    text.textContent = item
      ? `You voted ${item.name} today. Come back tomorrow.`
      : `You've voted today. Come back tomorrow.`;
  } else {
    el.classList.remove('voted');
    text.textContent = `You can vote once per day. Pick your haramball ${noun} below.`;
  }
}

// ---------- Teams grid ----------
function filteredTeams() {
  const q = state.searchQuery.toLowerCase().trim();
  return currentItems().filter(t => {
    if (state.filterConf !== 'all' && t.confederation !== state.filterConf) return false;
    // League filter only applies to clubs.
    if (!isCountries() && state.filterLeague !== 'all' && t.league !== state.filterLeague) return false;
    if (q) {
      const hay = isCountries()
        ? `${t.name} ${t.code || ''} ${t.confederation || ''}`.toLowerCase()
        : `${t.name} ${t.short_name || ''} ${t.league || ''} ${t.country || ''} ${t.city || ''}`.toLowerCase();
      if (!hay.includes(q)) return false;
    }
    return true;
  });
}

function renderTeams() {
  const grid = $('teams-grid');
  const empty = $('teams-empty');
  const meta = $('teams-meta');
  const list = filteredTeams();
  const voted = currentVoted();
  const canVote = !voted.voted;
  const myLastId = (isCountries() ? voted.country_id : voted.team_id) || null;
  const noun = isCountries() ? 'countries' : 'teams';
  const total = currentItems().length;

  meta.textContent = `${list.length} of ${total} ${noun}`;

  const moreBtn = $('teams-more');

  if (list.length === 0) {
    grid.innerHTML = '';
    if (moreBtn) moreBtn.classList.add('hidden');
    empty.classList.remove('hidden');
    return;
  }
  empty.classList.add('hidden');

  // Render incrementally: only the first `renderLimit` cards are in the DOM,
  // keeping first paint cheap even with thousands of teams. "Load more" grows it.
  // EXCEPTION: when the user is actively searching, show ALL matches — a search
  // result must never be hidden behind "Load more" (the whole point is to find it).
  if (state.renderLimit <= 0) state.renderLimit = PAGE_SIZE;
  const searching = state.searchQuery.trim().length > 0;
  const shown = searching ? list.length : Math.min(state.renderLimit, list.length);
  const capped = list.slice(0, shown);
  grid.innerHTML = capped.map(t => {
    const isMyVote = !canVote && t.id === myLastId;
    const cls = ['team-card'];
    if (!canVote) cls.push('disabled');
    if (isMyVote) cls.push('voted');
    const meta = isMyVote
      ? `${escapeHtml(isCountries() ? (t.confederation || '') : (t.league || ''))} · Your vote`
      : escapeHtml(itemMeta(t));
    return `<button class="${cls.join(' ')}" data-team="${escapeHtml(t.id)}" role="listitem"${!canVote ? ' disabled' : ''}>
      <span class="team-badge" style="background:${escapeHtml(t.color || '#444')}">${escapeHtml(getInitials(t.name))}</span>
      <span class="team-info">
        <span class="team-name">${escapeHtml(t.name)}</span>
        <span class="team-meta">${meta}</span>
      </span>
    </button>`;
  }).join('');

  // Toggle / label the "Load more" button.
  if (moreBtn) {
    const remaining = list.length - shown;
    if (remaining > 0) {
      moreBtn.textContent = `Load ${Math.min(PAGE_SIZE, remaining)} more (${remaining} left)`;
      moreBtn.classList.remove('hidden');
    } else {
      moreBtn.classList.add('hidden');
    }
  }
  if (shown < list.length) {
    meta.textContent = `Showing ${shown} of ${list.length} matching ${noun} (${total} total)`;
  }
  // Note: click handler is attached once during init() using event delegation.
  // See bindGridClickHandler() — we don't re-attach handlers on every render.
}

// Reset pagination to the first page, then render. Use this whenever the
// result set changes (search, filters, mode); plain renderTeams() preserves
// the current "Load more" position (e.g. after casting a vote).
function resetAndRenderTeams() {
  state.renderLimit = PAGE_SIZE;
  renderTeams();
}

// Attached ONCE during init - one click handler for the whole grid (event delegation)
// This avoids re-attaching 240 listeners on every render, fixing the INP performance issue.
function bindGridClickHandler() {
  const grid = $('teams-grid');
  grid.addEventListener('click', (e) => {
    const card = e.target.closest('.team-card');
    if (!card) return;
    if (card.classList.contains('disabled')) return;
    openVoteModal(card.dataset.team);
  });
}

// ---------- League filter (depends on confederation choice) ----------
function rebuildLeagueFilter() {
  const sel = $('league-filter');
  const current = sel.value;
  const conf = state.filterConf;
  const leagues = (conf === 'all' ? state.leagues : state.leagues.filter(l => l.confederation === conf))
    .slice()
    .sort((a, b) => (a.name || '').localeCompare(b.name || ''));
  sel.innerHTML = `<option value="all">All leagues</option>` + leagues.map(l =>
    `<option value="${escapeHtml(l.name)}">${escapeHtml(l.name)} — ${escapeHtml(l.country)}</option>`
  ).join('');
  // Preserve previous selection if still valid
  sel.value = leagues.some(l => l.name === current) ? current : 'all';
  state.filterLeague = sel.value;
}

// ---------- Vote modal ----------
function openVoteModal(teamId) {
  const team = currentItems().find(t => t.id === teamId);
  if (!team) return;
  state.selectedTeam = team;
  state.selectedIsCountry = isCountries();
  state.selectedReason = null;

  track('vote_modal_opened', {
    mode: state.mode,
    team_id: team.id,
    league: team.league,
    confederation: team.confederation
  });

  $('modal-badge').textContent = getInitials(team.name);
  $('modal-badge').style.background = team.color || '#444';
  $('modal-team-name').textContent = team.name;
  $('modal-team-meta').textContent = itemMeta(team);

  // Render reason buttons
  const grid = $('reasons-grid');
  grid.innerHTML = state.reasons.map(r =>
    `<button class="reason-btn" data-reason="${escapeHtml(r.code)}" type="button" role="radio" aria-checked="false">${escapeHtml(r.label)}</button>`
  ).join('');
  $$('.reason-btn', grid).forEach(b => {
    b.addEventListener('click', () => {
      const wasSelected = b.classList.contains('selected');
      // Always clear other selections first
      $$('.reason-btn', grid).forEach(x => { x.classList.remove('selected'); x.setAttribute('aria-checked', 'false'); });
      if (wasSelected) {
        // Clicking the already-selected reason deselects it
        state.selectedReason = null;
      } else {
        b.classList.add('selected');
        b.setAttribute('aria-checked', 'true');
        state.selectedReason = b.dataset.reason;
      }
    });
  });

  $('comment').value = '';
  $('char-count').textContent = '0';
  // Vote button is always enabled — reason is optional
  $('vote-submit').disabled = false;
  $('vote-submit').textContent = 'Cast vote';
  $('modal-error').classList.add('hidden');
  // Ensure we show the form (not a leftover success panel from a prior vote).
  $('vote-form').classList.remove('hidden');
  $('vote-success').classList.add('hidden');

  const m = $('vote-modal');
  m.classList.remove('hidden');
  m.setAttribute('aria-hidden', 'false');
  setTimeout(() => $('comment').focus({ preventScroll: true }), 50);
}

function closeVoteModal() {
  const m = $('vote-modal');
  m.classList.add('hidden');
  m.setAttribute('aria-hidden', 'true');
  state.selectedTeam = null;
  state.selectedReason = null;
}

async function submitVote() {
  if (!state.selectedTeam) return;
  const btn = $('vote-submit');
  const errEl = $('modal-error');
  errEl.classList.add('hidden');
  btn.disabled = true; btn.textContent = 'Casting…';
  const hasComment = ($('comment').value || '').trim().length > 0;
  const asCountry = state.selectedIsCountry;
  try {
    if (asCountry) {
      await api.castCountryVote({
        country_id: state.selectedTeam.id,
        reason_tag: state.selectedReason,
        comment:    $('comment').value,
      });
    } else {
      await api.castVote({
        team_id:    state.selectedTeam.id,
        reason_tag: state.selectedReason,  // can be null — reason is optional
        comment:    $('comment').value,
      });
    }
    track('vote_cast', {
      mode: asCountry ? 'countries' : 'clubs',
      team_id: state.selectedTeam.id,
      league: state.selectedTeam.league,
      confederation: state.selectedTeam.confederation,
      reason: state.selectedReason || 'none',
      has_comment: hasComment
    });
    // Swap the modal into the "verdict filed" share/follow state.
    showVoteSuccess(state.selectedTeam, state.selectedReason);
    await Promise.all([refreshVotedToday(), loadGlobalStats(), loadTopPreview()]);
    renderTeams();
  } catch (e) {
    let msg = e.message || 'Could not cast vote.';
    let errorType = 'unknown';
    if (e.code === 'P0001' || /already voted/i.test(msg)) {
      msg = 'You\'ve already voted today. Come back tomorrow.';
      errorType = 'already_voted';
    } else if (/network/i.test(msg) || /fetch/i.test(msg)) {
      errorType = 'network';
    }
    track('vote_failed', { error_type: errorType, team_id: state.selectedTeam.id });
    errEl.textContent = msg;
    errEl.classList.remove('hidden');
    btn.disabled = false; btn.textContent = 'Cast vote';
  }
}

// ---------- Post-vote share / follow ----------
const SITE_URL = 'https://haramball.com';

function reasonLabelFor(code) {
  if (!code) return '';
  const r = state.reasons.find(x => x.code === code);
  return r ? r.label : '';
}
function shareUrlFor(team, isCountry) {
  return `${SITE_URL}/${isCountry ? 'country' : 'team'}/${team.id}`;
}
function ordinal(n) {
  n = Number(n);
  if (!Number.isFinite(n)) return '';
  const s = ['th', 'st', 'nd', 'rd'], v = n % 100;
  return n + (s[(v - 20) % 10] || s[v] || s[0]);
}
// Live all-time rank for the verdict card. Returns { rank, total } or null.
async function fetchVerdictRank(team, isCountry) {
  try {
    const s = isCountry ? await api.getCountryStats(team.id) : await api.getTeamStats(team.id);
    if (s && s.rank_all) {
      return { rank: Number(s.rank_all), total: Number(s.total_ranked || s.total_teams_ranked || 0) };
    }
  } catch { /* ignore */ }
  return null;
}

// ---- canvas helpers ----
function rrect(x, cx, cy, w, h, r) {
  if (x.roundRect) { x.beginPath(); x.roundRect(cx, cy, w, h, r); return; }
  x.beginPath();
  x.moveTo(cx + r, cy);
  x.arcTo(cx + w, cy, cx + w, cy + h, r);
  x.arcTo(cx + w, cy + h, cx, cy + h, r);
  x.arcTo(cx, cy + h, cx, cy, r);
  x.arcTo(cx, cy, cx + w, cy, r);
  x.closePath();
}
// The haramball ball mark (matches the site logo, simplified).
function drawBallMark(x, cx, cy, r) {
  x.save();
  x.beginPath(); x.arc(cx, cy, r, 0, Math.PI * 2); x.fillStyle = '#d63031'; x.fill();
  const bw = r * 0.22, bh = r * 1.24;
  x.fillStyle = '#fff';
  x.fillRect(cx - r * 0.52 - bw / 2, cy - bh / 2, bw, bh);
  x.fillRect(cx + r * 0.52 - bw / 2, cy - bh / 2, bw, bh);
  x.beginPath(); x.arc(cx, cy, r * 0.28, 0, Math.PI * 2); x.fillStyle = '#fff'; x.fill();
  x.beginPath(); x.arc(cx, cy, r * 0.28, 0, Math.PI * 2);
  x.strokeStyle = '#0a0a0a'; x.lineWidth = r * 0.03; x.stroke();
  x.restore();
}

// Draw a polished 1200x630 verdict card and return a PNG blob.
function buildVerdictCard(team, reasonLabel, rank) {
  return new Promise(resolve => {
    const W = 1200, H = 630;
    const accent = team.color || '#d63031';
    const c = document.createElement('canvas');
    c.width = W; c.height = H;
    const x = c.getContext('2d');

    // Background: near-black with a soft team-colour glow top-right.
    x.fillStyle = '#0c0c0c'; x.fillRect(0, 0, W, H);
    const g = x.createRadialGradient(W - 180, 120, 40, W - 180, 120, 720);
    g.addColorStop(0, accent + '33'); g.addColorStop(1, 'transparent');
    x.fillStyle = g; x.fillRect(0, 0, W, H);
    // Left accent stripe + bottom rule.
    x.fillStyle = accent; x.fillRect(0, 0, 14, H);
    x.fillStyle = '#1c1c1c'; x.fillRect(70, H - 96, W - 140, 2);

    // Header: ball mark + wordmark.
    drawBallMark(x, 92, 84, 26);
    x.textBaseline = 'middle'; x.textAlign = 'left';
    x.fillStyle = '#e8e8e8'; x.font = '800 30px Arial, sans-serif';
    if ('letterSpacing' in x) x.letterSpacing = '3px';
    x.fillText('THE HARAMBALL COURT', 132, 86);
    if ('letterSpacing' in x) x.letterSpacing = '0px';

    // Team badge (circle with initials).
    const bcx = 150, bcy = 320, br = 84;
    x.beginPath(); x.arc(bcx, bcy, br, 0, Math.PI * 2); x.fillStyle = accent; x.fill();
    x.lineWidth = 3; x.strokeStyle = 'rgba(255,255,255,0.18)'; x.stroke();
    x.fillStyle = '#fff'; x.textAlign = 'center'; x.font = '800 58px Arial, sans-serif';
    x.fillText(getInitials(team.name), bcx, bcy + 2);

    // Right-hand text block (name wraps to <=2 lines), vertically centred.
    x.textAlign = 'left';
    const bx = 270, maxW = W - bx - 70;
    const name = String(team.name).toUpperCase();
    let size = name.length > 18 ? 70 : 86;
    x.font = `800 ${size}px Arial, sans-serif`;
    const words = name.split(' ');
    let line = '', lines = [];
    for (const w of words) {
      const t = line ? line + ' ' + w : w;
      if (x.measureText(t).width > maxW && line) { lines.push(line); line = w; } else line = t;
    }
    if (line) lines.push(line);
    lines = lines.slice(0, 2);
    const rankText = (rank && rank.rank)
      ? `${ordinal(rank.rank)} worst${rank.total ? ' of ' + rank.total.toLocaleString() : ''}`
      : '';
    const nameLH = size * 1.04;
    const blockH = lines.length * nameLH + 14 + 46 + (rankText ? 40 : 0) + (reasonLabel ? 52 : 0);
    let y = 200 + (270 - blockH) / 2; if (y < 170) y = 170;

    x.fillStyle = '#ffffff';
    x.textBaseline = 'top';
    for (const ln of lines) { x.fillText(ln, bx, y); y += nameLH; }

    y += 14;
    x.fillStyle = accent === '#d63031' ? '#ff5a5b' : '#d63031';
    x.font = '800 38px Arial, sans-serif';
    x.fillText('GUILTY OF HARAMBALL', bx, y);
    y += 46;

    if (rankText) {
      x.fillStyle = '#f1c40f';
      x.font = '800 30px Arial, sans-serif';
      x.fillText('🔥 ' + rankText.toUpperCase(), bx, y);
      y += 40;
    }

    if (reasonLabel) {
      const label = reasonLabel.toUpperCase();
      x.font = '700 26px Arial, sans-serif';
      const tw = x.measureText(label).width;
      rrect(x, bx, y, tw + 36, 44, 22);
      x.fillStyle = 'rgba(255,255,255,0.08)'; x.fill();
      x.lineWidth = 1.5; x.strokeStyle = 'rgba(255,255,255,0.18)'; x.stroke();
      x.fillStyle = '#f1c40f'; x.textBaseline = 'middle';
      x.fillText(label, bx + 18, y + 24);
      x.textBaseline = 'top';
    }

    // Tilted "GUILTY" stamp, top-right.
    x.save();
    x.translate(1000, 150); x.rotate(-13 * Math.PI / 180);
    x.lineWidth = 5; x.strokeStyle = 'rgba(214,48,49,0.85)';
    rrect(x, -140, -60, 280, 120, 14); x.stroke();
    x.fillStyle = 'rgba(214,48,49,0.92)';
    x.textAlign = 'center'; x.textBaseline = 'middle';
    x.font = '900 60px Arial, sans-serif'; x.fillText('GUILTY', 0, -10);
    x.font = '700 20px Arial, sans-serif'; if ('letterSpacing' in x) x.letterSpacing = '2px';
    x.fillText('VERDICT FILED', 0, 34);
    if ('letterSpacing' in x) x.letterSpacing = '0px';
    x.restore();

    // Footer watermark.
    x.textAlign = 'left'; x.textBaseline = 'middle';
    x.fillStyle = '#8a8a8a'; x.font = '700 26px Arial, sans-serif';
    x.fillText('haramball.com', 70, H - 56);
    const wmW = x.measureText('haramball.com').width;  // measure with the bold font
    x.fillStyle = '#5a5a5a'; x.font = '400 24px Arial, sans-serif';
    x.fillText('  ·  vote the worst football of the week', 70 + wmW, H - 56);

    c.toBlob(b => resolve(b), 'image/png');
  });
}

async function shareVerdict(team, reasonLabel, isCountry) {
  const rank = await fetchVerdictRank(team, isCountry);
  const rankPhrase = (rank && rank.rank) ? ` Currently ${ordinal(rank.rank)} worst${rank.total ? ' of ' + rank.total.toLocaleString() : ''}.` : '';
  const text = `I filed against ${team.name} at the haramball court${reasonLabel ? '. ' + reasonLabel : ''}.${rankPhrase} Vote at haramball.com`;
  track('share_verdict', { team_id: team.id, mode: isCountry ? 'countries' : 'clubs', rank: rank ? rank.rank : null });
  let blob;
  try { blob = await buildVerdictCard(team, reasonLabel, rank); } catch { blob = null; }
  const file = blob ? new File([blob], `haramball-${team.id}.png`, { type: 'image/png' }) : null;
  try {
    if (file && navigator.canShare && navigator.canShare({ files: [file] })) {
      await navigator.share({ files: [file], text, title: 'Haramball verdict' });
      return;
    }
    if (navigator.share) { await navigator.share({ text, url: shareUrlFor(team, isCountry) }); return; }
  } catch (e) { if (e && e.name === 'AbortError') return; }
  // Fallback: download the image + copy the caption.
  if (blob) {
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url; a.download = `haramball-${team.id}.png`;
    document.body.appendChild(a); a.click(); a.remove();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
  }
  try { await navigator.clipboard.writeText(text); showToast('Verdict image saved + caption copied'); }
  catch { showToast('Verdict image saved'); }
}

async function recruitWitness(team, isCountry) {
  const url = shareUrlFor(team, isCountry);
  const text = `The haramball court has ${team.name} on the docket. File your verdict:`;
  track('recruit_witness', { team_id: team.id, mode: isCountry ? 'countries' : 'clubs' });
  try {
    if (navigator.share) { await navigator.share({ title: 'Haramball', text, url }); return; }
  } catch (e) { if (e && e.name === 'AbortError') return; }
  try { await navigator.clipboard.writeText(`${text} ${url}`); showToast('Link copied — send it to a friend who hates them'); }
  catch { showToast(url); }
}

function showVoteSuccess(team, reasonCode) {
  const isCountry = state.selectedIsCountry;
  const reasonLabel = reasonLabelFor(reasonCode);
  $('vote-form').classList.add('hidden');
  const panel = $('vote-success');
  panel.classList.remove('hidden');
  $('vote-success-title').textContent = `Verdict filed against ${team.name}.`;
  $('vote-success-sub').textContent = reasonLabel
    ? `Logged: ${reasonLabel}. Spread the word.`
    : 'One vote per day — come back tomorrow. Spread the word.';
  $('share-verdict').onclick = () => shareVerdict(team, reasonLabel, isCountry);
  $('share-witness').onclick = () => recruitWitness(team, isCountry);
}

// ---------- Leaderboard ----------
async function loadLeaderboard() {
  const list = $('lb-list');
  const loading = $('lb-loading');
  const empty = $('lb-empty');

  list.innerHTML = '';
  empty.classList.add('hidden');
  loading.classList.remove('hidden');

  try {
    const rows = isCountries()
      ? await api.getCountryLeaderboard({ period: state.lbPeriod, limit: 50 })
      : await api.getLeaderboard({ period: state.lbPeriod, limit: 50 });
    loading.classList.add('hidden');

    if (!rows || rows.length === 0) {
      empty.classList.remove('hidden');
      return;
    }

    list.innerHTML = rows.map(r => {
      const rank = Number(r.rank);
      let rankCls = '';
      if (rank === 1) rankCls = 'gold';
      else if (rank === 2) rankCls = 'silver';
      else if (rank === 3) rankCls = 'bronze';
      // Country rows use country_* fields; club rows use team_*/league_name.
      const teamName  = isCountries() ? r.country_name  : r.team_name;
      const teamColor = isCountries() ? r.country_color : r.team_color;
      const meta = isCountries()
        ? (r.confederation || '')
        : [r.league_name, r.country_name].filter(Boolean).join(' · ');
      const reason = r.top_reason_label
        ? `<div class="lb-reason">${escapeHtml(r.top_reason_label)}</div>`
        : '';
      return `<div class="lb-row">
        <div class="lb-rank ${rankCls}">${rank}</div>
        <div class="lb-team-badge" style="background:${escapeHtml(teamColor || '#444')}">${escapeHtml(getInitials(teamName))}</div>
        <div class="lb-team-info">
          <div class="lb-team-name">${escapeHtml(teamName)}</div>
          <div class="lb-team-meta">${escapeHtml(meta)}</div>
          ${reason}
        </div>
        <div class="lb-vote-block">
          <div class="lb-votes">${fmtNum(r.vote_count)}</div>
          <div class="lb-votes-lbl">votes</div>
        </div>
      </div>`;
    }).join('');
  } catch (e) {
    loading.classList.add('hidden');
    list.innerHTML = `<div class="lb-empty">Could not load leaderboard. ${escapeHtml(e.message || '')}</div>`;
    console.error('leaderboard failed', e);
  }
}

// ---------- About counts ----------
function renderAboutCounts() {
  $('about-team-count').textContent   = fmtNum(state.teams.length);
  $('about-league-count').textContent = fmtNum(state.leagues.length);
}

// Pick 3 random teams from the loaded set and turn them into "Try:" chips below the search.
// Different teams every page load - keeps the homepage feeling alive and surfaces variety.
function renderRandomHints() {
  const container = $('hero-search-hints');
  const items = currentItems();
  if (!container || !items || items.length === 0) return;

  // Pick 3 distinct random items. Skip very short names (often acronyms users don't know).
  const pool = items.filter(t => t.name && t.name.length >= 4);
  if (pool.length < 3) return;
  const picks = [];
  const usedIds = new Set();
  let safety = 0;
  while (picks.length < 3 && safety < 50) {
    const t = pool[Math.floor(Math.random() * pool.length)];
    if (!usedIds.has(t.id)) {
      usedIds.add(t.id);
      picks.push(t);
    }
    safety++;
  }

  // Render the chips. Keep the existing "Try:" label, replace the rest.
  const label = '<span class="hero-hint-label">Try:</span>';
  const chips = picks.map(t =>
    `<button class="hero-hint" type="button" data-hint="${escapeHtml(t.name)}">${escapeHtml(t.name)}</button>`
  ).join('');
  container.innerHTML = label + chips;
}

// Render quick-vote cards from the LIVE overall leaderboard (all-time top teams).
// Tapping a card opens the existing vote modal — same flow as searching for a team.
//
// NOTE (design decision): these cards show the current top-voted teams. This creates
// a mild feedback loop — easy-to-tap leaders may accrue more votes simply for being
// the default buttons, which can entrench the leaderboard order. Chosen deliberately
// to keep the cards always-current and zero-maintenance. If the leaderboard ever feels
// "stuck", consider excluding rank #1 or mixing in canonical teams.
async function renderQuickVote() {
  const grid = $('quick-vote-grid');
  const wrap = $('quick-vote');
  if (!grid || !wrap) return;

  let rows = [];
  try {
    rows = isCountries()
      ? await api.getCountryLeaderboard({ period: 'all', limit: 5 })
      : await api.getLeaderboard({ period: 'all', limit: 5 });
  } catch (e) {
    rows = [];
  }

  // Top picks = the top five from the all-time leaderboard.
  const picks = (Array.isArray(rows) ? rows : []).slice(0, 5).map(r => ({
    id:    isCountries() ? r.country_id    : r.team_id,
    name:  isCountries() ? r.country_name  : r.team_name,
    color: isCountries() ? r.country_color : r.team_color,
  }));

  // Nothing voted yet in this mode — hide the row rather than show an empty one.
  if (picks.length === 0) { wrap.style.display = 'none'; return; }

  wrap.style.display = '';
  grid.innerHTML = picks.map(p => `
    <button class="qv-card" type="button" data-team="${escapeHtml(p.id)}" aria-label="Vote against ${escapeHtml(p.name)}">
      <span class="qv-badge" style="background:${escapeHtml(p.color || '#444')}">${escapeHtml(getInitials(p.name))}</span>
      <span class="qv-info">
        <span class="qv-name">${escapeHtml(p.name)}</span>
        <span class="qv-action">Vote ⚖</span>
      </span>
    </button>`).join('');

  // Event delegation: tapping a card opens the vote modal for that team.
  grid.querySelectorAll('.qv-card').forEach(card => {
    card.addEventListener('click', () => {
      track('quick_vote_clicked', { team_id: card.dataset.team });
      openVoteModal(card.dataset.team);
    });
  });
}

// ---------- Bootstrap ----------
async function init() {
  // Wire UI events first so the page is responsive even before data loads
  $$('.nav-btn').forEach(b => {
    // Only attach the view-switching handler to buttons, not anchor links
    if (b.tagName === 'BUTTON') {
      b.addEventListener('click', () => switchView(b.dataset.view));
    }
  });
  // Mode toggles (Clubs / Countries) — there may be more than one on the page.
  $$('.mode-btn').forEach(b => b.addEventListener('click', () => switchMode(b.dataset.mode)));

  $$('.lb-tab').forEach(t => t.addEventListener('click', () => {
    $$('.lb-tab').forEach(x => x.classList.remove('active'));
    t.classList.add('active');
    state.lbPeriod = t.dataset.period;
    loadLeaderboard();
  }));

  // Debounce search: wait 120ms after typing stops before re-rendering.
  // Without this, every keystroke triggers a full 240-card grid render,
  // which was the main cause of poor INP (interaction latency).
  let searchTimer = null;
  const searchInput = $('search');
  const searchClear = $('search-clear');  // optional - might not exist in older HTML
  // Magnifying glass icon - selector covers both naming variants
  const searchIcon = document.querySelector('.hero-search-icon, .search-icon');

  // Smooth-scroll the teams grid into view. Used by Enter key, icon click, hint chips.
  function scrollToTeams() {
    const grid = $('teams-grid');
    if (!grid) return;
    const offset = grid.getBoundingClientRect().top + window.pageYOffset - 80;
    window.scrollTo({ top: offset, behavior: 'smooth' });
  }

  if (searchInput) {
    searchInput.addEventListener('input', e => {
      const val = e.target.value;
      if (searchClear) searchClear.classList.toggle('hidden', !val);
      if (searchTimer) clearTimeout(searchTimer);
      searchTimer = setTimeout(() => {
        state.searchQuery = val;
        resetAndRenderTeams();
      }, 120);
    });
    // Pressing Enter: commit search immediately and jump to results
    searchInput.addEventListener('keydown', e => {
      if (e.key === 'Enter') {
        e.preventDefault();
        if (searchTimer) clearTimeout(searchTimer);
        state.searchQuery = searchInput.value;
        resetAndRenderTeams();
        searchInput.blur();  // close mobile keyboard
        scrollToTeams();
      }
    });
  }
  // Magnifying-glass icon: clicking it acts like Enter
  if (searchIcon) {
    searchIcon.style.pointerEvents = 'auto';
    searchIcon.style.cursor = 'pointer';
    searchIcon.addEventListener('click', () => {
      if (!searchInput) return;
      if (searchTimer) clearTimeout(searchTimer);
      state.searchQuery = searchInput.value;
      resetAndRenderTeams();
      searchInput.blur();
      scrollToTeams();
    });
  }
  if (searchClear) {
    searchClear.addEventListener('click', () => {
      searchInput.value = '';
      state.searchQuery = '';
      searchClear.classList.add('hidden');
      searchInput.focus();
      resetAndRenderTeams();
    });
  }
  // Hint chips: event delegation on container so it works for dynamically-inserted chips too
  const hintsContainer = $('hero-search-hints');
  if (hintsContainer) {
    hintsContainer.addEventListener('click', (e) => {
      const btn = e.target.closest('.hero-hint');
      if (!btn) return;
      const val = btn.dataset.hint;
      $('search').value = val;
      state.searchQuery = val;
      const sc = $('search-clear');
      if (sc) sc.classList.remove('hidden');
      $('search').focus();
      resetAndRenderTeams();
      scrollToTeams();
    });
  }
  $('conf-filter').addEventListener('change', e => {
    state.filterConf = e.target.value;
    rebuildLeagueFilter();
    resetAndRenderTeams();
  });
  $('league-filter').addEventListener('change', e => {
    state.filterLeague = e.target.value;
    resetAndRenderTeams();
  });

  // "Load more" grows the visible page.
  const moreBtn = $('teams-more');
  if (moreBtn) moreBtn.addEventListener('click', () => {
    state.renderLimit += PAGE_SIZE;
    renderTeams();
    moreBtn.focus();
  });

  $('modal-close').addEventListener('click', closeVoteModal);
  $('vote-modal').addEventListener('click', e => {
    if (e.target.id === 'vote-modal') closeVoteModal();
  });
  document.addEventListener('keydown', e => {
    if (e.key === 'Escape' && !$('vote-modal').classList.contains('hidden')) closeVoteModal();
  });
  $('comment').addEventListener('input', e => {
    $('char-count').textContent = e.target.value.length;
  });
  $('vote-submit').addEventListener('click', submitVote);
  $('vote-success-done').addEventListener('click', closeVoteModal);

  // Load reference data in parallel. Countries are part of the critical path
  // because the homepage defaults to Countries mode (so they must be ready
  // before the first render). getCountries degrades to [] if the table is unseeded.
  try {
    const [teams, leagues, reasons, countries] = await Promise.all([
      api.getTeams(), api.getLeagues(), api.getReasonTags(),
      api.getCountries().catch(() => [])
    ]);
    state.teams = teams;
    state.leagues = leagues;
    state.reasons = reasons;
    state.countries = countries;
  } catch (e) {
    console.error('failed to load reference data', e);
    $('teams-empty').textContent = 'Could not load teams. Check your connection or Supabase config (env.js).';
    $('teams-empty').classList.remove('hidden');
    return;
  }

  // Apply the default mode's UI (Countries): hide the league filter and set the
  // country search placeholder. switchMode() handles this on later toggles.
  if (isCountries()) {
    const lf = $('league-filter'); if (lf) lf.classList.add('hidden');
    if (searchInput) searchInput.placeholder = 'Search any country to vote against…';
  }

  rebuildLeagueFilter();
  renderAboutCounts();
  renderRandomHints();  // Pick 3 random teams for the "Try:" chips
  renderQuickVote();    // Live overall leaderboard as instant-vote cards (async, fire-and-forget)
  bindGridClickHandler();  // Attach grid click handler ONCE (event delegation)
  // Wire the "See full leaderboard" link in the top preview
  const tpLink = $('top-preview-link');
  if (tpLink) tpLink.addEventListener('click', () => switchView('leaderboard'));

  // Honor URL hash on load (e.g. /#leaderboard from other pages routes to that view).
  // Also re-honor on hashchange so in-page navigation works.
  const hashToView = h => {
    const v = (h || '').replace(/^#/, '').trim();
    return ['vote', 'leaderboard', 'about'].includes(v) ? v : null;
  };
  const applyHashView = () => {
    const v = hashToView(window.location.hash);
    if (v) switchView(v);
  };
  applyHashView();
  window.addEventListener('hashchange', applyHashView);

  await Promise.all([refreshVotedToday(), loadGlobalStats(), loadTopPreview()]);
  renderTeams();

  // Deep-link from a detail page:
  //   /?vote=<team_id>     opens the club vote modal
  //   /?cvote=<country_id> switches to Countries and opens the country vote modal
  // (the "Vote against …" buttons on team/league/country pages).
  try {
    const params = new URLSearchParams(window.location.search);
    const clubId = params.get('vote');
    const countryId = params.get('cvote');
    if (clubId || countryId) {
      // Clean the URL so a refresh / share doesn't re-trigger the modal.
      history.replaceState(null, '', window.location.pathname + window.location.hash);
      if (countryId) {
        await switchMode('countries');
        const c = state.countries.find(t => t.id === countryId);
        if (c && !state.countryVotedToday.voted) openVoteModal(countryId);
        else if (c) showToast('You already voted on a country today. Come back tomorrow.');
      } else {
        await switchMode('clubs');   // homepage defaults to Countries — flip to Clubs for a club link
        const team = state.teams.find(t => t.id === clubId);
        if (team && !state.votedToday.voted) openVoteModal(clubId);
        else if (team) showToast('You already voted today. Come back tomorrow.');
      }
    }
  } catch (e) { /* non-fatal */ }
}

init();
