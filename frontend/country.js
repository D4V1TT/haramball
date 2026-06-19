/* ============================================================
 * Haramball — country (national team) detail page hydration
 * Mirrors team.js but uses the country_* RPCs. Progressive
 * enhancement: the static page stands alone if the API is down.
 * ============================================================ */
import { api } from './api.js';

const $ = (id) => document.getElementById(id);
function setText(id, txt) { const el = $(id); if (el) el.textContent = txt; }
function fmtNum(n) { return n == null ? '—' : Number(n).toLocaleString(); }
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
  for (const [s, label] of units) if (secs >= s) return `${Math.floor(secs / s)}${label} ago`;
  return `${secs}s ago`;
}

const C = window.HARAMBALL_COUNTRY || {};
const countryId = C.id || document.body.getAttribute('data-country-id');
const countryName = C.name || document.body.getAttribute('data-country-name') || 'this team';

async function hydrateStats() {
  const stats = await api.getCountryStats(countryId);
  if (!stats) {
    setText('t-votes-all', '0');
    setText('t-votes-week', '0');
    setText('t-rank-all', '—');
    setText('t-rank-line', `No verdicts filed yet. Be the first to convict ${countryName}.`);
    return;
  }
  setText('t-votes-all', fmtNum(stats.vote_count_all));
  setText('t-votes-week', fmtNum(stats.votes_week));
  setText('t-rank-all', stats.rank_all ? ordinal(stats.rank_all) : '—');
  const rankLine = $('t-rank-line');
  if (rankLine) {
    rankLine.textContent = (stats.rank_all && stats.total_ranked)
      ? `Currently ${ordinal(stats.rank_all)} worst out of ${fmtNum(stats.total_ranked)} convicted nations, all-time.`
      : `No verdicts filed yet. Be the first to convict ${countryName}.`;
  }
}

async function hydrateReasons() {
  const wrap = $('t-reasons');
  if (!wrap) return;
  let rows;
  try { rows = await api.getCountryReasons(countryId, 'all'); } catch { rows = []; }
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
const TARGET_TYPE = 'country';

function paintComments(list, rows) {
  if (!rows || rows.length === 0) {
    list.innerHTML = `<p class="t-empty">No comments yet. Be the first to make the case against ${escapeHtml(countryName)}.</p>`;
    return;
  }
  list.innerHTML = rows.map(r => `
    <div class="cmt-item">
      <p class="cmt-item-body">${escapeHtml(r.body)}</p>
      <div class="cmt-item-time">${escapeHtml(timeAgo(r.created_at))}</div>
    </div>`).join('');
}

async function renderComments() {
  const list = $('cmt-list');
  if (!list) return;
  let rows;
  try { rows = await api.getComments(TARGET_TYPE, countryId, 30); } catch { rows = []; }
  paintComments(list, rows);
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
        submit = $('cmt-submit'), errEl = $('cmt-error');
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
      await api.postComment({ target_type: TARGET_TYPE, target_id: countryId, body });
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
  document.querySelectorAll('[data-vote-link]').forEach(a => {
    a.setAttribute('href', `/?cvote=${encodeURIComponent(countryId)}`);
  });
}

// "Recruit a witness" — Web Share API with clipboard fallback.
function wireShareButton() {
  const url = location.href;
  const text = `The haramball court has ${countryName} on the docket. File your verdict:`;
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

if (countryId) {
  wireVoteButton();
  wireShareButton();
  wireCommentForm();
  hydrateStats();
  hydrateReasons();
  renderComments();
}
