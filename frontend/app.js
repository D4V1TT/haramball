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

// ---------- State management ----------
const state = {
  teams: [],       // Raw lookup reference
  leagues: [],     // League reference maps
  reasons: [],     // Reason tags collection
  leaderboard: [], // Current selected view array
  quickTeams: [],  // Trending instant vote cards raw array
  votedToday: null, // { voted: true/false, team_id: ... }
  selectedPeriod: 'week',
  searchQuery: '',
  selectedReasonTag: null,
  activeModalTeamId: null
};

// ---------- Render logic ----------
function renderLeaderboard() {
  const grid = $('teams-grid');
  const empty = $('teams-empty');
  grid.innerHTML = '';

  const filtered = state.leaderboard.filter(item => {
    const team = state.teams.find(t => t.id === item.team_id);
    if (!team) return false;
    if (!state.searchQuery) return true;
    return team.name.toLowerCase().includes(state.searchQuery.toLowerCase());
  });

  if (filtered.length === 0) {
    empty.classList.remove('hidden');
    return;
  }
  empty.classList.add('hidden');

  grid.innerHTML = filtered.map((item, index) => {
    const team = state.teams.find(t => t.id === item.team_id);
    const league = state.leagues.find(l => l.id === team.league_id);
    const rank = index + 1;
    const isHigh = item.vote_count > 10;

    return `
      <div class="team-card" data-team-id="${team.id}">
        <div class="team-info">
          <div class="badge-placeholder">${getInitials(team.name)}</div>
          <div>
            <div class="team-name">${rank}. ${escapeHtml(team.name.toLowerCase())}</div>
            <div class="team-league">${league ? escapeHtml(league.name.toLowerCase()) : ''}</div>
          </div>
        </div>
        <div class="vote-badge ${isHigh ? 'high' : ''}">
          ${fmtNum(item.vote_count)} verdicts
        </div>
      </div>
    `;
  }).join('');
}

function renderRandomHints() {
  const container = $('hints-container');
  if (!container || state.teams.length === 0) return;

  const shuffled = [...state.teams].sort(() => 0.5 - Math.random());
  const selected = shuffled.slice(0, 3);

  container.innerHTML = selected.map(t => 
    `<span class="hint-chip" data-name="${escapeHtml(t.name)}">${escapeHtml(t.name.toLowerCase())}</span>`
  ).join(',');

  $$('.hint-chip', container).forEach(chip => {
    chip.addEventListener('click', () => {
      const name = chip.getAttribute('data-name');
      $('search').value = name;
      state.searchQuery = name;
      renderLeaderboard();
    });
  });
}

// Dynamically retrieve top teams for interactive instant voting cards
function renderQuickVote() {
  const container = $('quick-vote-container');
  if (!container || !state.quickTeams || state.quickTeams.length === 0) {
    if (container) container.parentElement.classList.add('hidden');
    return;
  }
  container.parentElement.classList.remove('hidden');

  container.innerHTML = state.quickTeams.map(item => {
    const team = state.teams.find(t => t.id === item.team_id);
    const displayName = team ? team.name.toLowerCase() : item.team_id;
    return `
      <button class="quick-vote-chip" data-team-id="${item.team_id}" type="button">
        <span>${escapeHtml(displayName)}</span>
        <span class="chip-count">(${item.vote_count})</span>
      </button>
    `;
  }).join('');

  $$('.quick-vote-chip', container).forEach(btn => {
    btn.addEventListener('click', () => {
      const teamId = btn.getAttribute('data-team-id');
      openVoteModal(teamId);
    });
  });
}

// ---------- Modal handlers ----------
function openVoteModal(teamId) {
  if (state.votedToday && state.votedToday.voted) {
    showToast(`court closed. you already issued a verdict today.`);
    return;
  }

  const team = state.teams.find(t => t.id === teamId);
  if (!team) return;

  state.activeModalTeamId = teamId;
  state.selectedReasonTag = null;

  $('modal-badge').textContent = getInitials(team.name);
  $('modal-team-name').textContent = team.name.toLowerCase();
  
  const league = state.leagues.find(l => l.id === team.league_id);
  $('modal-team-meta').textContent = league ? league.name.toLowerCase() : '';

  const reasonsGrid = $('reasons-grid');
  reasonsGrid.innerHTML = state.reasons.map(r => `
    <button class="reason-btn" data-tag="${r.tag}" type="button">
      ${escapeHtml(r.label.toLowerCase())}
    </button>
  `).join('');

  $$('.reason-btn', reasonsGrid).forEach(btn => {
    btn.addEventListener('click', () => {
      $$('.reason-btn', reasonsGrid).forEach(b => b.classList.remove('selected'));
      btn.classList.add('selected');
      state.selectedReasonTag = btn.getAttribute('data-tag');
    });
  });

  $('comment').value = '';
  $('char-count').textContent = '0';
  $('modal-error').classList.add('hidden');
  $('vote-modal').classList.remove('hidden');
}

function closeVoteModal() {
  $('vote-modal').classList.add('hidden');
  state.activeModalTeamId = null;
  state.selectedReasonTag = null;
}

async function submitVote() {
  const errDiv = $('modal-error');
  errDiv.classList.add('hidden');

  if (!state.activeModalTeamId) return;

  try {
    await api.castVote({
      team_id: state.activeModalTeamId,
      reason_tag: state.selectedReasonTag,
      comment: $('comment').value
    });

    state.votedToday = { voted: true, team_id: state.activeModalTeamId };
    showToast('verdict officially filed to the archive.');
    closeVoteModal();
    
    // Refresh lists
    const ld = await api.getLeaderboard({ period: state.selectedPeriod });
    state.leaderboard = ld;
    renderLeaderboard();
  } catch (e) {
    errDiv.textContent = (e.message || 'failed to register verdict').toLowerCase();
    errDiv.classList.remove('hidden');
  }
}

// ---------- Init & Event Listeners ----------
document.addEventListener('DOMContentLoaded', async () => {
  // Bind tab toggles
  $$('.tab').forEach(tab => {
    tab.addEventListener('click', async () => {
      $$('.tab').forEach(t => t.classList.remove('active'));
      tab.classList.add('active');
      state.selectedPeriod = tab.getAttribute('data-period');
      
      try {
        state.leaderboard = await api.getLeaderboard({ period: state.selectedPeriod });
        renderLeaderboard();
      } catch (e) {
        console.error(e);
      }
    });
  });

  // Bind lookup inputs
  $('search').addEventListener('input', (e) => {
    state.searchQuery = e.target.value;
    renderLeaderboard();
  });

  // Modal lifecycle hooks
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

  // Load backend context records in parallel
  try {
    const [teams, leagues, reasons, votedToday, weeklyLeaderboard] = await Promise.all([
      api.getTeams(), 
      api.getLeagues(), 
      api.getReasonTags(),
      api.hasVotedToday(),
      api.getLeaderboard({ period: 'week', limit: 3 }) // Fetch current top 3 culprits
    ]);

    state.teams = teams;
    state.leagues = leagues;
    state.reasons = reasons;
    state.votedToday = votedToday;
    state.quickTeams = weeklyLeaderboard;

    // Load active layout list
    state.leaderboard = await api.getLeaderboard({ period: state.selectedPeriod });
  } catch (e) {
    console.error('failed to load operational dataset maps', e);
    $('teams-empty').textContent = 'could not pull data ledger rows. verify active supabase routing parameters.';
    $('teams-empty').classList.remove('hidden');
    return;
  }

  // Bind click handlers to primary elements via row delegates
  $('teams-grid').addEventListener('click', e => {
    const card = e.target.closest('.team-card');
    if (card) {
      const teamId = card.getAttribute('data-team-id');
      openVoteModal(teamId);
    }
  });

  renderRandomHints();
  renderQuickVote();
  renderLeaderboard();
});