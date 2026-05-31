-- ============================================================
-- HARAMBALL.COM — country (national team) voting
-- Run AFTER 01-schema.sql, then run 05-import-countries.sql to seed.
-- Idempotent (IF NOT EXISTS / CREATE OR REPLACE).
-- ------------------------------------------------------------
-- A parallel, independent contest to the club vote:
--   * national_teams  — the ~211 FIFA members
--   * country_votes   — one row per vote (separate 1/day allowance)
-- Reuses the existing reason_tags and voter_sessions tables.
-- ============================================================

-- ---------- TABLES ----------
create table if not exists public.national_teams (
  id            text primary key,        -- slug, e.g. "brazil"
  name          text not null,
  confederation text not null references public.confederations(code),
  code          text,                    -- FIFA 3-letter code
  color         text,                    -- hex
  active        boolean not null default true,
  created_at    timestamptz not null default now()
);
create index if not exists idx_natteams_conf   on public.national_teams(confederation);
create index if not exists idx_natteams_active on public.national_teams(active);
create index if not exists idx_natteams_name_lower on public.national_teams (lower(name));

create table if not exists public.country_votes (
  id          uuid primary key default gen_random_uuid(),
  country_id  text not null references public.national_teams(id) on delete cascade,
  voter_id    uuid not null references public.voter_sessions(voter_id) on delete cascade,
  reason_tag  text references public.reason_tags(code),
  comment     text,
  voted_at    timestamptz not null default now(),
  ip_country  text,
  vote_day    date generated always as ((voted_at at time zone 'utc')::date) stored,
  constraint country_comment_length check (comment is null or char_length(comment) <= 100),
  -- Independent of club votes: a voter may cast one club + one country vote per day.
  constraint unique_country_vote_per_day unique (voter_id, vote_day)
);
create index if not exists idx_cvotes_country         on public.country_votes(country_id);
create index if not exists idx_cvotes_voted_at        on public.country_votes(voted_at desc);
create index if not exists idx_cvotes_vote_day        on public.country_votes(vote_day);
create index if not exists idx_cvotes_reason          on public.country_votes(reason_tag) where reason_tag is not null;

-- ---------- RLS ----------
alter table public.national_teams enable row level security;
alter table public.country_votes  enable row level security;

drop policy if exists "read national_teams" on public.national_teams;
create policy "read national_teams" on public.national_teams for select using (true);

drop policy if exists "read country_votes" on public.country_votes;
create policy "read country_votes" on public.country_votes for select using (true);

-- ---------- EXPLICIT TABLE GRANTS ----------
-- RLS gates which ROWS are visible; these GRANTs give the API roles the
-- table-level privilege to read at all. Writes are NOT granted to anon —
-- they go exclusively through the SECURITY DEFINER cast_country_vote().
grant select on public.national_teams to anon, authenticated;
grant select on public.country_votes  to anon, authenticated;
-- service_role bypasses RLS but make the admin privileges explicit too.
grant select, insert, update, delete on public.national_teams to service_role;
grant select, insert, update, delete on public.country_votes  to service_role;

-- ---------- CAST VOTE ----------
create or replace function public.cast_country_vote (
  p_voter_id    uuid,
  p_country_id  text,
  p_reason_tag  text default null,
  p_comment     text default null,
  p_user_agent  text default null,
  p_ip_country  text default null
) returns public.country_votes
language plpgsql
security definer
set search_path = public
as $$
declare
  v_vote public.country_votes;
begin
  if p_voter_id is null then
    raise exception 'voter_id is required' using errcode = '22023';
  end if;
  if p_country_id is null then
    raise exception 'country_id is required' using errcode = '22023';
  end if;
  if p_comment is not null and char_length(p_comment) > 100 then
    raise exception 'comment too long (max 100 chars)' using errcode = '22023';
  end if;
  if not exists (select 1 from public.national_teams where id = p_country_id and active) then
    raise exception 'unknown or inactive country: %', p_country_id using errcode = '23503';
  end if;
  if p_reason_tag is not null and not exists (
    select 1 from public.reason_tags where code = p_reason_tag and active
  ) then
    raise exception 'unknown reason tag: %', p_reason_tag using errcode = '23503';
  end if;

  insert into public.voter_sessions (voter_id, ip_country, user_agent, total_votes)
  values (p_voter_id, p_ip_country, p_user_agent, 1)
  on conflict (voter_id) do update
    set last_seen_at = now(),
        total_votes  = public.voter_sessions.total_votes + 1,
        ip_country   = coalesce(excluded.ip_country, public.voter_sessions.ip_country),
        user_agent   = coalesce(excluded.user_agent, public.voter_sessions.user_agent);

  insert into public.country_votes (country_id, voter_id, reason_tag, comment, ip_country)
  values (p_country_id, p_voter_id, p_reason_tag, nullif(trim(p_comment), ''), p_ip_country)
  returning * into v_vote;

  return v_vote;
exception
  when unique_violation then
    raise exception 'already voted today' using errcode = 'P0001', hint = 'one country vote per day per voter';
end;
$$;
revoke all on function public.cast_country_vote(uuid, text, text, text, text, text) from public;
grant  execute on function public.cast_country_vote(uuid, text, text, text, text, text) to anon, authenticated;

-- ---------- HAS VOTED TODAY ----------
create or replace function public.has_voted_country_today (p_voter_id uuid)
returns table (voted boolean, country_id text, reason_tag text, comment text, voted_at timestamptz)
language sql security definer set search_path = public stable
as $$
  select true, v.country_id, v.reason_tag, v.comment, v.voted_at
  from public.country_votes v
  where v.voter_id = p_voter_id
    and v.vote_day = (now() at time zone 'utc')::date
  limit 1;
$$;
revoke all on function public.has_voted_country_today(uuid) from public;
grant  execute on function public.has_voted_country_today(uuid) to anon, authenticated;

-- ---------- LEADERBOARD ----------
create or replace function public.country_leaderboard (
  p_period        text default 'week',
  p_limit         integer default 50,
  p_confederation text default null
)
returns table (
  rank bigint, country_id text, country_name text, country_color text,
  confederation text, code text, vote_count bigint,
  top_reason text, top_reason_label text
)
language sql stable security definer set search_path = public
as $$
  with bounds as (
    select case p_period
      when 'day'   then date_trunc('day',   now() at time zone 'utc')
      when 'week'  then date_trunc('week',  now() at time zone 'utc')
      when 'month' then date_trunc('month', now() at time zone 'utc')
      when 'year'  then date_trunc('year',  now() at time zone 'utc')
      else timestamptz '1970-01-01' end as start_at
  ),
  scoped as (
    select v.country_id, v.reason_tag
    from public.country_votes v
    join public.national_teams nt on nt.id = v.country_id
    where v.voted_at >= (select start_at from bounds)
      and (p_confederation is null or nt.confederation = p_confederation)
  ),
  counts as (select country_id, count(*)::bigint vote_count from scoped group by country_id),
  top_reason as (
    select distinct on (country_id) country_id, reason_tag,
      count(*) over (partition by country_id, reason_tag) as rc
    from scoped where reason_tag is not null
    order by country_id, rc desc
  )
  select rank() over (order by c.vote_count desc), nt.id, nt.name, nt.color,
         nt.confederation, nt.code, c.vote_count, tr.reason_tag, rt.label
  from counts c
  join public.national_teams nt on nt.id = c.country_id
  left join top_reason tr on tr.country_id = c.country_id
  left join public.reason_tags rt on rt.code = tr.reason_tag
  order by c.vote_count desc
  limit p_limit;
$$;
revoke all on function public.country_leaderboard(text, integer, text) from public;
grant  execute on function public.country_leaderboard(text, integer, text) to anon, authenticated;

-- ---------- REASON BREAKDOWN ----------
create or replace function public.country_reason_breakdown (p_country_id text, p_period text default 'all')
returns table (reason_tag text, reason_label text, vote_count bigint, percentage numeric)
language sql stable security definer set search_path = public
as $$
  with bounds as (
    select case p_period
      when 'day' then date_trunc('day', now() at time zone 'utc')
      when 'week' then date_trunc('week', now() at time zone 'utc')
      when 'month' then date_trunc('month', now() at time zone 'utc')
      when 'year' then date_trunc('year', now() at time zone 'utc')
      else timestamptz '1970-01-01' end as start_at
  ),
  v as (
    select reason_tag from public.country_votes
    where country_id = p_country_id and voted_at >= (select start_at from bounds)
  ),
  total as (select count(*) n from v)
  select coalesce(v.reason_tag,'unspecified'), coalesce(rt.label,'No reason given'),
         count(*)::bigint, round((count(*)::numeric / nullif((select n from total),0))*100,1)
  from v left join public.reason_tags rt on rt.code = v.reason_tag
  group by v.reason_tag, rt.label order by count(*) desc;
$$;
revoke all on function public.country_reason_breakdown(text, text) from public;
grant  execute on function public.country_reason_breakdown(text, text) to anon, authenticated;

-- ---------- RECENT COMMENTS ----------
create or replace function public.country_recent_comments (p_country_id text, p_limit integer default 25)
returns table (comment text, reason_tag text, reason_label text, voted_at timestamptz, ip_country text)
language sql stable security definer set search_path = public
as $$
  select v.comment, v.reason_tag, rt.label, v.voted_at, v.ip_country
  from public.country_votes v
  left join public.reason_tags rt on rt.code = v.reason_tag
  where v.country_id = p_country_id and v.comment is not null and char_length(v.comment) > 0
  order by v.voted_at desc
  limit least(coalesce(p_limit,25),50);
$$;
revoke all on function public.country_recent_comments(text, integer) from public;
grant  execute on function public.country_recent_comments(text, integer) to anon, authenticated;

-- ---------- PER-COUNTRY STATS (for country detail pages) ----------
create or replace function public.country_stats (p_country_id text)
returns table (
  country_id text, country_name text, vote_count_all bigint,
  votes_week bigint, votes_month bigint, votes_year bigint,
  rank_all bigint, total_ranked bigint
)
language sql stable security definer set search_path = public
as $$
  with bounds as (
    select date_trunc('week', now() at time zone 'utc') wk,
           date_trunc('month', now() at time zone 'utc') mo,
           date_trunc('year', now() at time zone 'utc') yr
  ),
  all_counts as (select country_id, count(*)::bigint c from public.country_votes group by country_id),
  ranked as (select country_id, rank() over (order by c desc) rnk from all_counts)
  select nt.id, nt.name,
    coalesce((select c from all_counts where country_id = nt.id),0),
    coalesce((select count(*) from public.country_votes, bounds where country_votes.country_id = nt.id and voted_at >= bounds.wk),0)::bigint,
    coalesce((select count(*) from public.country_votes, bounds where country_votes.country_id = nt.id and voted_at >= bounds.mo),0)::bigint,
    coalesce((select count(*) from public.country_votes, bounds where country_votes.country_id = nt.id and voted_at >= bounds.yr),0)::bigint,
    (select rnk from ranked where country_id = nt.id),
    (select count(*) from all_counts)
  from public.national_teams nt
  where nt.id = p_country_id and nt.active;
$$;
revoke all on function public.country_stats(text) from public;
grant  execute on function public.country_stats(text) to anon, authenticated;

-- ---------- GLOBAL STATS ----------
create or replace function public.country_global_stats ()
returns table (total_votes bigint, votes_today bigint, votes_this_week bigint, active_countries bigint)
language sql stable security definer set search_path = public
as $$
  select
    (select count(*) from public.country_votes),
    (select count(*) from public.country_votes where vote_day = (now() at time zone 'utc')::date),
    (select count(*) from public.country_votes where voted_at >= date_trunc('week', now() at time zone 'utc')),
    (select count(*) from public.national_teams where active);
$$;
revoke all on function public.country_global_stats() from public;
grant  execute on function public.country_global_stats() to anon, authenticated;

-- ============================================================
-- DONE. Now run 05-import-countries.sql (generated) to seed teams.
-- ============================================================
