-- ============================================================
-- HARAMBALL.COM — Supabase schema
-- Run these statements in order in the Supabase SQL Editor.
-- ============================================================
-- This script is idempotent (safe to re-run): it uses IF NOT
-- EXISTS / CREATE OR REPLACE wherever possible.
-- ============================================================

-- ---------- 1. EXTENSIONS ----------
create extension if not exists pgcrypto;     -- gen_random_uuid()


-- ---------- 2. TABLES ----------

-- Reference: confederations
create table if not exists public.confederations (
  code        text primary key,        -- 'UEFA', 'CONMEBOL', etc.
  name        text not null
);

-- Reference: countries
create table if not exists public.countries (
  code              text primary key,  -- ISO 3166-1 alpha-2
  name              text not null,
  confederation     text not null references public.confederations(code)
);

-- Reference: leagues
create table if not exists public.leagues (
  id                uuid primary key default gen_random_uuid(),
  name              text not null,
  country_code      text not null references public.countries(code),
  confederation     text not null references public.confederations(code),
  tier              integer not null default 1,
  created_at        timestamptz not null default now(),
  unique (name, country_code)
);
create index if not exists idx_leagues_country on public.leagues(country_code);

-- Teams
create table if not exists public.teams (
  id                text primary key,        -- our slug, e.g. "man-utd"
  league_id         uuid not null references public.leagues(id) on delete restrict,
  name              text not null,
  short_name        text not null,
  city              text,
  color             text,                    -- hex like '#A6192E'
  founded           integer,
  active            boolean not null default true,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);
create index if not exists idx_teams_league   on public.teams(league_id);
create index if not exists idx_teams_active   on public.teams(active);
create index if not exists idx_teams_name_lower on public.teams (lower(name));

-- Voter sessions: one row per anonymous voter (cookie-based id)
-- Used to enforce 1 vote/day and to detect abuse.
create table if not exists public.voter_sessions (
  voter_id          uuid primary key,         -- generated client-side, stored in cookie + sent with each vote
  first_seen_at     timestamptz not null default now(),
  last_seen_at      timestamptz not null default now(),
  ip_country        text,
  user_agent        text,
  total_votes       integer not null default 0
);

-- Reason tags (preset list, editable later)
create table if not exists public.reason_tags (
  code              text primary key,         -- 'time-wasting', 'parking-bus', etc.
  label             text not null,
  display_order     integer not null default 0,
  active            boolean not null default true
);

-- Votes (the core table)
create table if not exists public.votes (
  id                uuid primary key default gen_random_uuid(),
  team_id           text not null references public.teams(id) on delete cascade,
  voter_id          uuid not null references public.voter_sessions(voter_id) on delete cascade,
  reason_tag        text references public.reason_tags(code),
  comment           text,                     -- optional, max 100 chars (CHECK below)
  voted_at          timestamptz not null default now(),
  ip_country        text,
  -- the day the vote counts for, in UTC. used to enforce 1 vote/day.
  vote_day          date generated always as ((voted_at at time zone 'utc')::date) stored,
  constraint comment_length check (comment is null or char_length(comment) <= 100),
  constraint unique_vote_per_day unique (voter_id, vote_day)
);
create index if not exists idx_votes_team           on public.votes(team_id);
create index if not exists idx_votes_voted_at       on public.votes(voted_at desc);
create index if not exists idx_votes_team_voted_at  on public.votes(team_id, voted_at desc);
create index if not exists idx_votes_vote_day       on public.votes(vote_day);
create index if not exists idx_votes_reason         on public.votes(reason_tag) where reason_tag is not null;


-- ---------- 3. SEED CONFEDERATIONS & REASON TAGS ----------
insert into public.confederations (code, name) values
  ('UEFA',      'Union of European Football Associations'),
  ('CONMEBOL',  'South American Football Confederation'),
  ('CONCACAF',  'Confederation of North, Central American and Caribbean Association Football'),
  ('AFC',       'Asian Football Confederation'),
  ('CAF',       'Confederation of African Football'),
  ('OFC',       'Oceania Football Confederation')
on conflict (code) do update set name = excluded.name;

insert into public.reason_tags (code, label, display_order) values
  ('time-wasting',    'Time-wasting',                 1),
  ('parking-bus',     'Parking the bus',              2),
  ('diving',          'Diving and complaining',       3),
  ('boring-poss',     'Boring possession, no goals',  4),
  ('anti-football',   'Anti-football tactics',        5),
  ('no-attack',       'No attacking intent',          6),
  ('cynical-fouls',   'Cynical fouling',              7),
  ('long-balls',      'Just long balls',              8),
  ('referee-ball',    'Playing the referee',          9),
  ('other',           'Other',                       99)
on conflict (code) do update set label = excluded.label, display_order = excluded.display_order;


-- ---------- 4. ROW LEVEL SECURITY ----------
alter table public.confederations    enable row level security;
alter table public.countries         enable row level security;
alter table public.leagues           enable row level security;
alter table public.teams             enable row level security;
alter table public.voter_sessions    enable row level security;
alter table public.reason_tags       enable row level security;
alter table public.votes             enable row level security;

-- Public read access on reference data (anon role)
drop policy if exists "read confederations" on public.confederations;
create policy "read confederations" on public.confederations for select using (true);

drop policy if exists "read countries" on public.countries;
create policy "read countries" on public.countries for select using (true);

drop policy if exists "read leagues" on public.leagues;
create policy "read leagues" on public.leagues for select using (true);

drop policy if exists "read teams" on public.teams;
create policy "read teams" on public.teams for select using (true);

drop policy if exists "read reasons" on public.reason_tags;
create policy "read reasons" on public.reason_tags for select using (true);

-- Votes: anyone can read aggregated views (we'll use a SECURITY DEFINER
-- function for inserts and a view for reads).
drop policy if exists "read votes" on public.votes;
create policy "read votes" on public.votes for select using (true);

-- voter_sessions: service-role only (we never expose voter_id lookups
-- to the anon role; the cast_vote function manages this internally).
-- No SELECT/INSERT/UPDATE policies for anon = anon is fully blocked here.


-- ---------- 5. CORE RPC FUNCTIONS ----------

-- Cast a vote. Called by the frontend (anon role) via supabase.rpc().
-- Enforces 1 vote per voter_id per UTC day.
-- Returns the vote row on success, or raises an error.
create or replace function public.cast_vote (
  p_voter_id      uuid,
  p_team_id       text,
  p_reason_tag    text default null,
  p_comment       text default null,
  p_user_agent    text default null,
  p_ip_country    text default null
) returns public.votes
language plpgsql
security definer
set search_path = public
as $$
declare
  v_vote   public.votes;
begin
  -- Validate inputs
  if p_voter_id is null then
    raise exception 'voter_id is required' using errcode = '22023';
  end if;
  if p_team_id is null then
    raise exception 'team_id is required' using errcode = '22023';
  end if;
  if p_comment is not null and char_length(p_comment) > 100 then
    raise exception 'comment too long (max 100 chars)' using errcode = '22023';
  end if;

  -- Validate team exists and is active
  if not exists (select 1 from public.teams where id = p_team_id and active) then
    raise exception 'unknown or inactive team: %', p_team_id using errcode = '23503';
  end if;

  -- Validate reason tag if provided
  if p_reason_tag is not null and not exists (
    select 1 from public.reason_tags where code = p_reason_tag and active
  ) then
    raise exception 'unknown reason tag: %', p_reason_tag using errcode = '23503';
  end if;

  -- Upsert voter session
  insert into public.voter_sessions (voter_id, ip_country, user_agent, total_votes)
  values (p_voter_id, p_ip_country, p_user_agent, 1)
  on conflict (voter_id) do update
    set last_seen_at = now(),
        total_votes  = public.voter_sessions.total_votes + 1,
        ip_country   = coalesce(excluded.ip_country, public.voter_sessions.ip_country),
        user_agent   = coalesce(excluded.user_agent, public.voter_sessions.user_agent);

  -- Insert vote (the unique constraint blocks duplicates per day)
  insert into public.votes (team_id, voter_id, reason_tag, comment, ip_country)
  values (p_team_id, p_voter_id, p_reason_tag, nullif(trim(p_comment), ''), p_ip_country)
  returning * into v_vote;

  return v_vote;
exception
  when unique_violation then
    raise exception 'already voted today' using errcode = 'P0001', hint = 'one vote per day per voter';
end;
$$;
revoke all on function public.cast_vote(uuid, text, text, text, text, text) from public;
grant  execute on function public.cast_vote(uuid, text, text, text, text, text) to anon, authenticated;

-- Has the voter voted today?
create or replace function public.has_voted_today (p_voter_id uuid)
returns table (voted boolean, team_id text, reason_tag text, comment text, voted_at timestamptz)
language sql
security definer
set search_path = public
stable
as $$
  select true,
         v.team_id,
         v.reason_tag,
         v.comment,
         v.voted_at
  from public.votes v
  where v.voter_id = p_voter_id
    and v.vote_day = (now() at time zone 'utc')::date
  limit 1;
$$;
revoke all on function public.has_voted_today(uuid) from public;
grant  execute on function public.has_voted_today(uuid) to anon, authenticated;


-- ---------- 6. LEADERBOARD VIEWS & FUNCTIONS ----------

-- Cleaned read-model: votes joined with team / league / country (no PII).
create or replace view public.votes_public as
select
  v.id,
  v.team_id,
  t.name        as team_name,
  t.short_name  as team_short_name,
  t.color       as team_color,
  t.city        as team_city,
  l.name        as league_name,
  c.name        as country_name,
  c.code        as country_code,
  l.confederation,
  v.reason_tag,
  rt.label      as reason_label,
  v.comment,
  v.voted_at,
  v.vote_day
from public.votes v
join public.teams t       on t.id = v.team_id
join public.leagues l     on l.id = t.league_id
join public.countries c   on c.code = l.country_code
left join public.reason_tags rt on rt.code = v.reason_tag;

grant select on public.votes_public to anon, authenticated;

-- Leaderboard for a given period.
-- p_period: 'day' | 'week' | 'month' | 'year' | 'all'
create or replace function public.leaderboard (
  p_period      text default 'week',
  p_limit       integer default 50,
  p_confederation text default null,
  p_league      text default null
)
returns table (
  rank          bigint,
  team_id       text,
  team_name     text,
  team_short_name text,
  team_color    text,
  league_name   text,
  country_name  text,
  country_code  text,
  confederation text,
  vote_count    bigint,
  top_reason    text,
  top_reason_label text
)
language sql
stable
security definer
set search_path = public
as $$
  with bounds as (
    select
      case p_period
        when 'day'   then date_trunc('day',   now() at time zone 'utc')
        when 'week'  then date_trunc('week',  now() at time zone 'utc')
        when 'month' then date_trunc('month', now() at time zone 'utc')
        when 'year'  then date_trunc('year',  now() at time zone 'utc')
        else timestamptz '1970-01-01'
      end as start_at
  ),
  scoped_votes as (
    select v.team_id, v.reason_tag
    from public.votes v
    join public.teams t       on t.id = v.team_id
    join public.leagues l     on l.id = t.league_id
    where v.voted_at >= (select start_at from bounds)
      and (p_confederation is null or l.confederation = p_confederation)
      and (p_league       is null or l.name          = p_league)
  ),
  team_counts as (
    select team_id, count(*)::bigint as vote_count
    from scoped_votes
    group by team_id
  ),
  team_top_reason as (
    select distinct on (team_id)
      team_id,
      reason_tag,
      count(*) over (partition by team_id, reason_tag) as reason_count
    from scoped_votes
    where reason_tag is not null
    order by team_id, reason_count desc
  )
  select
    rank() over (order by tc.vote_count desc) as rank,
    t.id,
    t.name,
    t.short_name,
    t.color,
    l.name,
    c.name,
    c.code,
    l.confederation,
    tc.vote_count,
    tr.reason_tag,
    rt.label
  from team_counts tc
  join public.teams t      on t.id = tc.team_id
  join public.leagues l    on l.id = t.league_id
  join public.countries c  on c.code = l.country_code
  left join team_top_reason tr on tr.team_id = tc.team_id
  left join public.reason_tags rt on rt.code = tr.reason_tag
  order by tc.vote_count desc
  limit p_limit;
$$;
revoke all on function public.leaderboard(text, integer, text, text) from public;
grant  execute on function public.leaderboard(text, integer, text, text) to anon, authenticated;

-- Reason breakdown for a single team (for team detail pages).
create or replace function public.team_reason_breakdown (
  p_team_id text,
  p_period  text default 'all'
)
returns table (
  reason_tag    text,
  reason_label  text,
  vote_count    bigint,
  percentage    numeric
)
language sql
stable
security definer
set search_path = public
as $$
  with bounds as (
    select
      case p_period
        when 'day'   then date_trunc('day',   now() at time zone 'utc')
        when 'week'  then date_trunc('week',  now() at time zone 'utc')
        when 'month' then date_trunc('month', now() at time zone 'utc')
        when 'year'  then date_trunc('year',  now() at time zone 'utc')
        else timestamptz '1970-01-01'
      end as start_at
  ),
  v as (
    select reason_tag from public.votes
    where team_id = p_team_id
      and voted_at >= (select start_at from bounds)
  ),
  total as (select count(*) as n from v)
  select
    coalesce(v.reason_tag, 'unspecified'),
    coalesce(rt.label, 'No reason given'),
    count(*)::bigint,
    round( (count(*)::numeric / nullif((select n from total), 0)) * 100, 1)
  from v
  left join public.reason_tags rt on rt.code = v.reason_tag
  group by v.reason_tag, rt.label
  order by count(*) desc;
$$;
revoke all on function public.team_reason_breakdown(text, text) from public;
grant  execute on function public.team_reason_breakdown(text, text) to anon, authenticated;

-- Recent comments for a team (latest 50, max).
create or replace function public.team_recent_comments (
  p_team_id text,
  p_limit   integer default 25
)
returns table (
  comment       text,
  reason_tag    text,
  reason_label  text,
  voted_at      timestamptz,
  ip_country    text
)
language sql
stable
security definer
set search_path = public
as $$
  select v.comment, v.reason_tag, rt.label, v.voted_at, v.ip_country
  from public.votes v
  left join public.reason_tags rt on rt.code = v.reason_tag
  where v.team_id = p_team_id
    and v.comment is not null
    and char_length(v.comment) > 0
  order by v.voted_at desc
  limit least(coalesce(p_limit, 25), 50);
$$;
revoke all on function public.team_recent_comments(text, integer) from public;
grant  execute on function public.team_recent_comments(text, integer) to anon, authenticated;

-- Global stats for the homepage hero.
create or replace function public.global_stats ()
returns table (
  total_votes     bigint,
  votes_today     bigint,
  votes_this_week bigint,
  active_teams    bigint,
  unique_voters   bigint
)
language sql
stable
security definer
set search_path = public
as $$
  select
    (select count(*) from public.votes),
    (select count(*) from public.votes where vote_day = (now() at time zone 'utc')::date),
    (select count(*) from public.votes where voted_at >= date_trunc('week', now() at time zone 'utc')),
    (select count(*) from public.teams where active),
    (select count(*) from public.voter_sessions);
$$;
revoke all on function public.global_stats() from public;
grant  execute on function public.global_stats() to anon, authenticated;


-- ============================================================
-- DONE. Next step: run import-teams.sql to populate teams.
-- ============================================================
