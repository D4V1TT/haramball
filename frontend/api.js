/* ============================================================
 * Haramball API layer
 * ------------------------------------------------------------
 * Frontend talks ONLY to this object. To swap backends, replace
 * the implementation here without touching the rest of the app.
 *
 * Public methods:
 *   api.getTeams()            -> Team[]
 *   api.getLeagues()          -> League[]
 *   api.getReasonTags()       -> ReasonTag[]
 *   api.getGlobalStats()      -> { total_votes, votes_today, ... }
 *   api.getLeaderboard(opts)  -> LeaderboardRow[]
 *   api.getTeamReasons(id, period)   -> ReasonBreakdown[]
 *   api.getTeamComments(id, limit)   -> Comment[]
 *   api.hasVotedToday()              -> { voted, team_id?, ... }
 *   api.castVote({ team_id, reason_tag, comment }) -> Vote
 * ============================================================ */

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

// ---------- Configuration ----------
// Set these in env.js (a small file with just window.HARAMBALL_CONFIG = {...}).
// Keeps secrets out of source control while staying static-host friendly.
const cfg = (typeof window !== 'undefined' && window.HARAMBALL_CONFIG) || {};
const SUPABASE_URL      = cfg.SUPABASE_URL      || '';
const SUPABASE_ANON_KEY = cfg.SUPABASE_ANON_KEY || '';

if (!SUPABASE_URL || !SUPABASE_ANON_KEY) {
  console.warn('[haramball] Supabase config missing. Set window.HARAMBALL_CONFIG in env.js');
}

const supabase = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
  auth: { persistSession: false },
});

// ---------- Voter identity ----------
// Each browser gets a UUID stored in a long-lived cookie + localStorage.
// This is NOT authentication — it's a soft identifier so we can enforce
// 1 vote/day per device. Determined attackers can clear it; we accept that.
const VOTER_KEY = 'haramball_voter_id';

function uuidv4() {
  // crypto.randomUUID() is widely available in 2026 browsers
  if (typeof crypto !== 'undefined' && crypto.randomUUID) return crypto.randomUUID();
  // Fallback
  return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, c => {
    const r = Math.random() * 16 | 0;
    const v = c === 'x' ? r : (r & 0x3 | 0x8);
    return v.toString(16);
  });
}

function getVoterId() {
  let id = null;
  try { id = localStorage.getItem(VOTER_KEY); } catch {}
  if (!id) {
    // Try cookie
    const m = document.cookie.match(new RegExp('(?:^|;\\s*)' + VOTER_KEY + '=([^;]+)'));
    if (m) id = decodeURIComponent(m[1]);
  }
  if (!id) {
    id = uuidv4();
  }
  // Persist in both places for redundancy
  try { localStorage.setItem(VOTER_KEY, id); } catch {}
  try {
    const oneYear = 60 * 60 * 24 * 365;
    document.cookie = `${VOTER_KEY}=${encodeURIComponent(id)}; max-age=${oneYear}; path=/; samesite=lax`;
  } catch {}
  return id;
}

// ---------- Internal helpers ----------
function err(msg, code) {
  const e = new Error(msg);
  if (code) e.code = code;
  return e;
}

async function rpc(name, args = {}) {
  const { data, error } = await supabase.rpc(name, args);
  if (error) {
    // Surface PostgREST errors with their PostgreSQL codes
    const e = err(error.message || 'API error', error.code);
    e.details = error.details;
    e.hint    = error.hint;
    throw e;
  }
  return data;
}

// ---------- Cache for reference data ----------
const cache = {
  teams: null,
  leagues: null,
  reasons: null,
  countries: null,
};

// ---------- Public API ----------
export const api = {
  // Reference data — loaded once per session, then cached.
  async getTeams() {
    if (cache.teams) return cache.teams;
    const { data, error } = await supabase
      .from('teams')
      .select('id, name, short_name, color, city, league_id, leagues!inner(name, confederation, country_code, countries!inner(name))')
      .eq('active', true)
      .order('name');
    if (error) throw err(error.message, error.code);
    // Flatten the join shape into something simple
    cache.teams = (data || []).map(t => ({
      id: t.id,
      name: t.name,
      short_name: t.short_name,
      color: t.color,
      city: t.city,
      league: t.leagues?.name,
      country: t.leagues?.countries?.name,
      country_code: t.leagues?.country_code,
      confederation: t.leagues?.confederation,
    }));
    return cache.teams;
  },

  async getLeagues() {
    if (cache.leagues) return cache.leagues;
    const { data, error } = await supabase
      .from('leagues')
      .select('id, name, confederation, country_code, countries!inner(name)')
      .order('name');
    if (error) throw err(error.message, error.code);
    cache.leagues = (data || []).map(l => ({
      id: l.id,
      name: l.name,
      confederation: l.confederation,
      country_code: l.country_code,
      country: l.countries?.name,
    }));
    return cache.leagues;
  },

  async getReasonTags() {
    if (cache.reasons) return cache.reasons;
    const { data, error } = await supabase
      .from('reason_tags')
      .select('code, label, display_order')
      .eq('active', true)
      .order('display_order');
    if (error) throw err(error.message, error.code);
    cache.reasons = data || [];
    return cache.reasons;
  },

  async getGlobalStats() {
    const data = await rpc('global_stats');
    return data?.[0] || { total_votes: 0, votes_today: 0, votes_this_week: 0, active_teams: 0, unique_voters: 0 };
  },

  async getLeaderboard({ period = 'week', limit = 50, confederation = null, league = null } = {}) {
    return await rpc('leaderboard', {
      p_period: period,
      p_limit: limit,
      p_confederation: confederation,
      p_league: league,
    }) || [];
  },

  async getTeamReasons(team_id, period = 'all') {
    return await rpc('team_reason_breakdown', { p_team_id: team_id, p_period: period }) || [];
  },

  // Per-team vote totals + rank (used by the team detail pages).
  // Returns null if the team has no row yet (no votes) or the RPC is unavailable,
  // so callers can degrade gracefully.
  async getTeamStats(team_id) {
    try {
      const data = await rpc('team_stats', { p_team_id: team_id });
      return (data && data.length > 0) ? data[0] : null;
    } catch (e) {
      console.warn('[haramball] team_stats unavailable', e?.message || e);
      return null;
    }
  },

  async getTeamComments(team_id, limit = 25) {
    return await rpc('team_recent_comments', { p_team_id: team_id, p_limit: limit }) || [];
  },

  async hasVotedToday() {
    const data = await rpc('has_voted_today', { p_voter_id: getVoterId() });
    if (data && data.length > 0) return { voted: true, ...data[0] };
    return { voted: false };
  },

  async castVote({ team_id, reason_tag = null, comment = null }) {
    if (!team_id) throw err('team_id required', '22023');
    const trimmed = (comment || '').trim().slice(0, 100) || null;
    return await rpc('cast_vote', {
      p_voter_id:   getVoterId(),
      p_team_id:    team_id,
      p_reason_tag: reason_tag,
      p_comment:    trimmed,
      p_user_agent: (navigator.userAgent || '').slice(0, 200),
      p_ip_country: null, // could be enriched server-side later
    });
  },

  // ===================== COUNTRIES (national teams) =====================
  // Parallel contest for the World Cup. Mirrors the club methods above.
  async getCountries() {
    if (cache.countries) return cache.countries;
    const { data, error } = await supabase
      .from('national_teams')
      .select('id, name, confederation, code, color')
      .eq('active', true)
      .order('name');
    if (error) throw err(error.message, error.code);
    cache.countries = data || [];
    return cache.countries;
  },

  async getCountryLeaderboard({ period = 'week', limit = 50, confederation = null } = {}) {
    return await rpc('country_leaderboard', {
      p_period: period, p_limit: limit, p_confederation: confederation,
    }) || [];
  },

  async getCountryReasons(country_id, period = 'all') {
    return await rpc('country_reason_breakdown', { p_country_id: country_id, p_period: period }) || [];
  },

  async getCountryComments(country_id, limit = 25) {
    return await rpc('country_recent_comments', { p_country_id: country_id, p_limit: limit }) || [];
  },

  async getCountryStats(country_id) {
    try {
      const data = await rpc('country_stats', { p_country_id: country_id });
      return (data && data.length > 0) ? data[0] : null;
    } catch (e) {
      console.warn('[haramball] country_stats unavailable', e?.message || e);
      return null;
    }
  },

  async getCountryGlobalStats() {
    const data = await rpc('country_global_stats');
    return data?.[0] || { total_votes: 0, votes_today: 0, votes_this_week: 0, active_countries: 0 };
  },

  async hasVotedCountryToday() {
    const data = await rpc('has_voted_country_today', { p_voter_id: getVoterId() });
    if (data && data.length > 0) return { voted: true, ...data[0] };
    return { voted: false };
  },

  async castCountryVote({ country_id, reason_tag = null, comment = null }) {
    if (!country_id) throw err('country_id required', '22023');
    const trimmed = (comment || '').trim().slice(0, 100) || null;
    return await rpc('cast_country_vote', {
      p_voter_id:   getVoterId(),
      p_country_id: country_id,
      p_reason_tag: reason_tag,
      p_comment:    trimmed,
      p_user_agent: (navigator.userAgent || '').slice(0, 200),
      p_ip_country: null,
    });
  },

  // Utility: clear cached reference data (e.g. after a manual update)
  _clearCache() { cache.teams = null; cache.leagues = null; cache.reasons = null; cache.countries = null; },

  // Expose voter id for debug, never for trust.
  _voterId() { return getVoterId(); },
};

export default api;
