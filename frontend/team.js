/* ============================================================
 * Haramball — team detail page hydration
 * ------------------------------------------------------------
 * The team page (frontend/team/<id>.html) is fully rendered as
 * static HTML for SEO. This module layers LIVE data on top:
 * current rank, vote totals, reason breakdown, recent comments.
 *
 * Everything here is progressive enhancement — if the API is
 * unavailable the statically-rendered page still stands on its own.
 * ============================================================ */
import { api } from './api.js';

const $ = (id) => document.getElementById(id);
function setText(id, txt) { const el = $(id); if (el) el.textContent = txt; }

function fmtNum(n) {
  if (n == null) return '—';
  return Number(n).toLocaleString();
}
function escapeHtml(s) {
  if (s == null) return '';
  return String(s)
    .replace(/&/g, '&amp;').replace(/</g, '&lt;')
    .replace(/>/g, '&gt;').replace(/"/g, '&quot;').replace(/'/g, '&#39;');
}
function ordinal(n) {
  n = Number(n);
  if (!Number.isFinite(n)) return '—';
  const s = ['th', 'st', 'nd', 'rd'], v = n % 100;
  return n + (s[(v - 20) % 10] || s[v] || s[0]);
}
function timeAgo(iso) {
  const then = new Date(iso).getTime();
  if (!Number.isFinite(then)) return '';
  const secs = Math.max(1, Math.floor((Date.now() - then) / 1000));
  const units = [[31536000, 'y'], [2592000, 'mo'], [604800, 'w'], [86400, 'd'], [3600, 'h'], [60, 'm']];
  for (const [s, label] of units) {
    if (secs >= s) return `${Math.floor(secs / s)}${label} ago`;
  }
  return `${secs}s ago`;
}

const TEAM = window.HARAMBALL_TEAM || {};
const teamId = TEAM.id || document.body.getAttribute('data-team-id');
const teamName = TEAM.name || document.body.getAttribute('data-team-name') || 'this team';

async function hydrateStats() {
  const stats = await api.getTeamStats(teamId);
  const box = $('t-stats');
  if (!stats) {
    // No votes yet — invite the user to be first.
    if (box) box.classList.add('t-stats--empty');
    setText('t-votes-all', '0');
    setText('t-rank-all', '—');
    setText('t-votes-week', '0');
    setText('t-rank-line', `No verdicts filed yet. Be the first to convict ${teamName}.`);
    return;
  }
  setText('t-votes-all', fmtNum(stats.vote_count_all));
  setText('t-votes-week', fmtNum(stats.votes_week));
  setText('t-votes-month', fmtNum(stats.votes_month));
  setText('t-rank-all', stats.rank_all ? ordinal(stats.rank_all) : '—');

  const rankLine = $('t-rank-line');
  if (rankLine) {
    if (stats.rank_all && stats.total_teams_ranked) {
      rankLine.textContent =
        `Currently ${ordinal(stats.rank_all)} worst out of ${fmtNum(stats.total_teams_ranked)} convicted clubs, all-time.`;
    } else {
      rankLine.textContent = `No verdicts filed yet. Be the first to convict ${teamName}.`;
    }
  }
}

async function hydrateReasons() {
  const wrap = $('t-reasons');
  if (!wrap) return;
  let rows;
  try { rows = await api.getTeamReasons(teamId, 'all'); } catch { rows = []; }
  if (!rows || rows.length === 0) {
    wrap.innerHTML = `<p class="t-empty">No reasons logged yet. Cast the first verdict and tell us why.</p>`;
    return;
  }
  wrap.innerHTML = rows.map(r => {
    const pct = Math.max(2, Math.round(Number(r.percentage) || 0));
    return `<div class="t-reason-row">
      <div class="t-reason-head">
        <span class="t-reason-label">${escapeHtml(r.reason_label || 'No reason given')}</span>
        <span class="t-reason-count">${fmtNum(r.vote_count)}</span>
      </div>
      <div class="t-reason-bar"><span style="width:${pct}%"></span></div>
    </div>`;
  }).join('');
}

async function hydrateComments() {
  const wrap = $('t-comments');
  if (!wrap) return;
  let rows;
  try { rows = await api.getTeamComments(teamId, 12); } catch { rows = []; }
  if (!rows || rows.length === 0) {
    wrap.innerHTML = `<p class="t-empty">No comments yet. Add the first one when you vote.</p>`;
    return;
  }
  wrap.innerHTML = rows.map(r => `
    <div class="t-comment">
      <p class="t-comment-text">“${escapeHtml(r.comment)}”</p>
      <div class="t-comment-meta">
        ${r.reason_label ? `<span class="t-comment-reason">${escapeHtml(r.reason_label)}</span>` : ''}
        <span class="t-comment-time">${escapeHtml(timeAgo(r.voted_at))}</span>
      </div>
    </div>`).join('');
}

function wireVoteButton() {
  // The vote flow lives on the homepage. Sending ?vote=<id> there opens the
  // vote modal for this team automatically (handled in app.js).
  document.querySelectorAll('[data-vote-link]').forEach(a => {
    a.setAttribute('href', `/?vote=${encodeURIComponent(teamId)}`);
  });
}

function init() {
  if (!teamId) return;
  wireVoteButton();
  // Fire all three in parallel; each handles its own failure.
  hydrateStats();
  hydrateReasons();
  hydrateComments();
}

init();
