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

// ---------- Fan comments (standalone, rate-limited) ----------
const TARGET_TYPE = 'club';

const CMT_PAGE = 20;
let cmtOffset = 0;

function commentHtml(r) {
  return `<div class="cmt-item">
      <p class="cmt-item-body">${escapeHtml(r.body)}</p>
      <div class="cmt-item-time">${escapeHtml(timeAgo(r.created_at))}</div>
    </div>`;
}

// Render the first page (also used to reset after posting a new comment).
async function renderComments() {
  const list = $('cmt-list'), more = $('cmt-more');
  if (!list) return;
  cmtOffset = 0;
  let rows;
  try { rows = await api.getComments(TARGET_TYPE, teamId, CMT_PAGE, 0); } catch { rows = []; }
  if (!rows || rows.length === 0) {
    list.innerHTML = `<p class="t-empty">No comments yet. Be the first to make the case against ${escapeHtml(teamName)}.</p>`;
    if (more) more.classList.add('hidden');
    return;
  }
  list.innerHTML = rows.map(commentHtml).join('');
  cmtOffset = rows.length;
  if (more) more.classList.toggle('hidden', rows.length < CMT_PAGE);
}

// Append the next page.
async function loadMoreComments() {
  const list = $('cmt-list'), more = $('cmt-more');
  if (!list || !more) return;
  more.disabled = true; more.textContent = 'Loading…';
  let rows;
  try { rows = await api.getComments(TARGET_TYPE, teamId, CMT_PAGE, cmtOffset); } catch { rows = []; }
  if (rows && rows.length) {
    list.insertAdjacentHTML('beforeend', rows.map(commentHtml).join(''));
    cmtOffset += rows.length;
  }
  more.disabled = false; more.textContent = 'Load more comments';
  if (!rows || rows.length < CMT_PAGE) more.classList.add('hidden');
}

function friendlyCmtError(e) {
  const m = (e && e.message) || '';
  if (/too fast|wait/i.test(m)) return 'Posting too fast — wait a second and try again.';
  if (/link/i.test(m)) return 'Links are not allowed in comments.';
  if (/long/i.test(m)) return 'Comment is too long (max 280 characters).';
  if (/empty/i.test(m)) return 'Write something first.';
  return 'Could not post your comment. Please try again.';
}

function wireCommentForm() {
  const form = $('cmt-form'), input = $('cmt-input'), count = $('cmt-charcount'),
        submit = $('cmt-submit'), errEl = $('cmt-error'), more = $('cmt-more');
  if (more) more.addEventListener('click', loadMoreComments);
  if (!form || !input) return;
  const showErr = (msg) => { if (errEl) { errEl.textContent = msg; errEl.classList.remove('hidden'); } };
  input.addEventListener('input', () => { if (count) count.textContent = input.value.length; });
  form.addEventListener('submit', async (e) => {
    e.preventDefault();
    if (errEl) errEl.classList.add('hidden');
    const body = input.value.trim();
    if (!body) return;
    if (/(https?:\/\/|www\.)/i.test(body)) { showErr('Links are not allowed in comments.'); return; }
    submit.disabled = true; submit.textContent = 'Posting…';
    try {
      await api.postComment({ target_type: TARGET_TYPE, target_id: teamId, body });
      input.value = ''; if (count) count.textContent = '0';
      await renderComments();
    } catch (err) {
      showErr(friendlyCmtError(err));
    } finally {
      submit.disabled = false; submit.textContent = 'Post comment';
    }
  });
}

function wireVoteButton() {
  // The vote flow lives on the homepage. Sending ?vote=<id> there opens the
  // vote modal for this team automatically (handled in app.js).
  document.querySelectorAll('[data-vote-link]').forEach(a => {
    a.setAttribute('href', `/?vote=${encodeURIComponent(teamId)}`);
  });
}

// "Recruit a witness" — Web Share API with clipboard fallback.
function wireShareButton() {
  const url = location.href;
  const text = `The haramball court has ${teamName} on the docket. File your verdict:`;
  document.querySelectorAll('[data-share-link]').forEach(btn => {
    btn.addEventListener('click', async () => {
      try {
        if (navigator.share) { await navigator.share({ title: 'Haramball', text, url }); return; }
      } catch (e) { if (e && e.name === 'AbortError') return; }
      try {
        await navigator.clipboard.writeText(`${text} ${url}`);
        btn.textContent = '✓ Link copied — send it';
        setTimeout(() => { btn.innerHTML = '📣 Recruit a witness'; }, 2500);
      } catch { /* no-op */ }
    });
  });
}

function init() {
  if (!teamId) return;
  wireVoteButton();
  wireShareButton();
  wireCommentForm();
  // Fire in parallel; each handles its own failure.
  hydrateStats();
  hydrateReasons();
  renderComments();
}

init();
