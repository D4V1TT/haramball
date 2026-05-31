/* ============================================================
 * Haramball — league page hydration
 * ------------------------------------------------------------
 * The league page (frontend/league/<slug>.html) statically lists
 * every club in the league (great for crawling + internal links).
 * This module layers a LIVE "worst in this league" mini-board on
 * top, using the existing leaderboard RPC with a league filter.
 * Progressive enhancement only.
 * ============================================================ */
import { api } from './api.js';

const $ = (id) => document.getElementById(id);
function fmtNum(n) { return n == null ? '—' : Number(n).toLocaleString(); }
function escapeHtml(s) {
  if (s == null) return '';
  return String(s)
    .replace(/&/g, '&amp;').replace(/</g, '&lt;')
    .replace(/>/g, '&gt;').replace(/"/g, '&quot;').replace(/'/g, '&#39;');
}
function getInitials(name) {
  if (!name) return '?';
  const p = String(name).split(/\s+/).filter(Boolean);
  return (p.length === 1 ? p[0].slice(0, 2) : p[0][0] + p[1][0]).toUpperCase();
}

const LEAGUE = window.HARAMBALL_LEAGUE || {};
const leagueName = LEAGUE.name || document.body.getAttribute('data-league-name');

async function hydrateBoard() {
  const wrap = $('lg-board');
  if (!wrap || !leagueName) return;
  let rows;
  try {
    rows = await api.getLeaderboard({ period: 'week', league: leagueName, limit: 10 });
  } catch {
    wrap.closest('.lg-board-section')?.classList.add('hidden');
    return;
  }
  if (!Array.isArray(rows) || rows.length === 0) {
    wrap.innerHTML = `<p class="t-empty">No votes in this league this week. The docket is clean — for now.</p>`;
    return;
  }
  wrap.innerHTML = rows.map(r => {
    const rank = Number(r.rank);
    const cls = rank === 1 ? 'gold' : rank === 2 ? 'silver' : rank === 3 ? 'bronze' : '';
    return `<a class="lg-board-row" href="/team/${escapeHtml(r.team_id)}">
      <span class="lg-rank ${cls}">${rank}</span>
      <span class="lg-badge" style="background:${escapeHtml(r.team_color || '#444')}">${escapeHtml(getInitials(r.team_name))}</span>
      <span class="lg-name">${escapeHtml(r.team_name)}</span>
      <span class="lg-votes">${fmtNum(r.vote_count)} <small>votes</small></span>
    </a>`;
  }).join('');
}

hydrateBoard();
