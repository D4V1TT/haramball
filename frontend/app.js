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
  teams: [],
  leagues: [],
  reasons: [],
  votedToday: { voted: false },
  selectedTeam: null,
  selectedReason: null,
  filterConf: 'all',
  filterLeague: 'all',
  searchQuery: '',
  lbPeriod: 'week',
};

// ---------- View routing ----------
function switchView(view) {
  $$('.nav-btn').forEach(b => b.classList.toggle('active', b.dataset.view === view));
  $$('.view').forEach(s => s.classList.add('hidden'));
  const target = $(`view-${view}`);
  if (target) target.classList.remove('hidden');
  if (view === 'leaderboard') loadLeaderboard();
  track('view_switched', { view });
  window.scrollTo({ top: 0, behavior: 'smooth' });
}
window.switchView = switchView; // exposed for the logo onclick handler

// ---------- Stats / hero ----------
async function loadGlobalStats() {
  try {
    const s = await api.getGlobalStats();
    $('stat-votes').textContent = fmtNum(s.total_votes);
    $('stat-week').textContent  = fmtNum(s.votes_this_week);
    $('stat-teams').textContent = fmtNum(s.active_teams);
    $('about-team-count').textContent = fmtNum(s.active_teams);
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
    const rows = await api.getLeaderboard({ period: 'week', limit: 3 });
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
      const meta = [r.league_name, r.country_name].filter(Boolean).join(' · ');
      return `<div class="tp-row" data-team="${escapeHtml(r.team_id)}">
        <div class="tp-rank ${rankCls}">${rank}</div>
        <div class="tp-badge" style="background:${escapeHtml(r.team_color || '#444')}">${escapeHtml(getInitials(r.team_name))}</div>
        <div class="tp-info">
          <div class="tp-name">${escapeHtml(r.team_name)}</div>
          <div class="tp-meta">${escapeHtml(meta)}</div>
        </div>
        <div>
          <div class="tp-votes">${fmtNum(r.vote_count)}</div>
          <div class="tp-votes-lbl">votes</div>
        </div>
      </div>`;
    }).join('');

    // Click a top row to open the vote modal for that team
    const canVote = !state.votedToday.voted;
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
  try {
    state.votedToday = await api.hasVotedToday();
  } catch (e) {
    console.error('voted-today failed', e);
    state.votedToday = { voted: false };
  }
  renderVoteStatus();
}

function renderVoteStatus() {
  const el = $('vote-status');
  const text = $('vote-status-text');
  if (state.votedToday.voted) {
    const team = state.teams.find(t => t.id === state.votedToday.team_id);
    el.classList.add('voted');
    text.textContent = team
      ? `You voted ${team.name} today. Come back tomorrow.`
      : `You've voted today. Come back tomorrow.`;
  } else {
    el.classList.remove('voted');
    text.textContent = 'You can vote once per day. Pick your haramball team below.';
  }
}

// ---------- Teams grid ----------
function filteredTeams() {
  const q = state.searchQuery.toLowerCase().trim();
  return state.teams.filter(t => {
    if (state.filterConf   !== 'all' && t.confederation !== state.filterConf) return false;
    if (state.filterLeague !== 'all' && t.league        !== state.filterLeague) return false;
    if (q) {
      const hay = `${t.name} ${t.short_name || ''} ${t.league || ''} ${t.country || ''} ${t.city || ''}`.toLowerCase();
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
  const canVote = !state.votedToday.voted;
  const myLastTeam = state.votedToday.team_id || null;

  meta.textContent = `${list.length} of ${state.teams.length} teams`;

  if (list.length === 0) {
    grid.innerHTML = '';
    empty.classList.remove('hidden');
    return;
  }
  empty.classList.add('hidden');

  // Cap render to 240 cards per pass to keep DOM cheap on mobile
  const capped = list.slice(0, 240);
  grid.innerHTML = capped.map(t => {
    const isMyVote = !canVote && t.id === myLastTeam;
    const cls = ['team-card'];
    if (!canVote) cls.push('disabled');
    if (isMyVote) cls.push('voted');
    const meta = isMyVote
      ? `${escapeHtml(t.league || '')} · Your vote`
      : escapeHtml([t.league, t.country].filter(Boolean).join(' · '));
    return `<button class="${cls.join(' ')}" data-team="${escapeHtml(t.id)}" role="listitem"${!canVote ? ' disabled' : ''}>
      <span class="team-badge" style="background:${escapeHtml(t.color || '#444')}">${escapeHtml(getInitials(t.name))}</span>
      <span class="team-info">
        <span class="team-name">${escapeHtml(t.name)}</span>
        <span class="team-meta">${meta}</span>
      </span>
    </button>`;
  }).join('');

  if (capped.length < list.length) {
    meta.textContent = `Showing 240 of ${list.length} matching teams (${state.teams.length} total). Refine your search.`;
  }
  // Note: click handler is attached once during init() using event delegation.
  // See bindGridClickHandler() — we don't re-attach handlers on every render.
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
  const team = state.teams.find(t => t.id === teamId);
  if (!team) return;
  state.selectedTeam = team;
  state.selectedReason = null;

  track('vote_modal_opened', {
    team_id: team.id,
    league: team.league,
    confederation: team.confederation
  });

  $('modal-badge').textContent = getInitials(team.name);
  $('modal-badge').style.background = team.color || '#444';
  $('modal-team-name').textContent = team.name;
  $('modal-team-meta').textContent = [team.league, team.country].filter(Boolean).join(' · ');

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
  $('modal-error').classList.add('hidden');

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
  try {
    await api.castVote({
      team_id:    state.selectedTeam.id,
      reason_tag: state.selectedReason,  // can be null — reason is optional
      comment:    $('comment').value,
    });
    track('vote_cast', {
      team_id: state.selectedTeam.id,
      league: state.selectedTeam.league,
      confederation: state.selectedTeam.confederation,
      reason: state.selectedReason || 'none',
      has_comment: hasComment
    });
    closeVoteModal();
    showToast(`Vote registered for ${state.selectedTeam.name}`);
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

// ---------- Leaderboard ----------
async function loadLeaderboard() {
  const list = $('lb-list');
  const loading = $('lb-loading');
  const empty = $('lb-empty');

  list.innerHTML = '';
  empty.classList.add('hidden');
  loading.classList.remove('hidden');

  try {
    const rows = await api.getLeaderboard({ period: state.lbPeriod, limit: 50 });
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
      const meta = [r.league_name, r.country_name].filter(Boolean).join(' · ');
      const reason = r.top_reason_label
        ? `<div class="lb-reason">${escapeHtml(r.top_reason_label)}</div>`
        : '';
      return `<div class="lb-row">
        <div class="lb-rank ${rankCls}">${rank}</div>
        <div class="lb-team-badge" style="background:${escapeHtml(r.team_color || '#444')}">${escapeHtml(getInitials(r.team_name))}</div>
        <div class="lb-team-info">
          <div class="lb-team-name">${escapeHtml(r.team_name)}</div>
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
  if (!container || !state.teams || state.teams.length === 0) return;

  // Pick 3 distinct random teams. Bias slightly toward bigger leagues so they're recognizable.
  // We pick from the full pool but skip teams with very short names (often acronyms users don't know).
  const pool = state.teams.filter(t => t.name && t.name.length >= 4);
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

// ---------- Bootstrap ----------
async function init() {
  // Wire UI events first so the page is responsive even before data loads
  $$('.nav-btn').forEach(b => b.addEventListener('click', () => switchView(b.dataset.view)));
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
        renderTeams();
      }, 120);
    });
    // Pressing Enter: commit search immediately and jump to results
    searchInput.addEventListener('keydown', e => {
      if (e.key === 'Enter') {
        e.preventDefault();
        if (searchTimer) clearTimeout(searchTimer);
        state.searchQuery = searchInput.value;
        renderTeams();
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
      renderTeams();
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
      renderTeams();
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
      renderTeams();
      scrollToTeams();
    });
  }
  $('conf-filter').addEventListener('change', e => {
    state.filterConf = e.target.value;
    rebuildLeagueFilter();
    renderTeams();
  });
  $('league-filter').addEventListener('change', e => {
    state.filterLeague = e.target.value;
    renderTeams();
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

  // Load reference data + voted-today + stats in parallel.
  try {
    const [teams, leagues, reasons] = await Promise.all([
      api.getTeams(), api.getLeagues(), api.getReasonTags()
    ]);
    state.teams = teams;
    state.leagues = leagues;
    state.reasons = reasons;
  } catch (e) {
    console.error('failed to load reference data', e);
    $('teams-empty').textContent = 'Could not load teams. Check your connection or Supabase config (env.js).';
    $('teams-empty').classList.remove('hidden');
    return;
  }

  rebuildLeagueFilter();
  renderAboutCounts();
  renderRandomHints();  // Pick 3 random teams for the "Try:" chips
  bindGridClickHandler();  // Attach grid click handler ONCE (event delegation)
  // Wire the "See full leaderboard" link in the top preview
  const tpLink = $('top-preview-link');
  if (tpLink) tpLink.addEventListener('click', () => switchView('leaderboard'));
  await Promise.all([refreshVotedToday(), loadGlobalStats(), loadTopPreview()]);
  renderTeams();
}

init();
