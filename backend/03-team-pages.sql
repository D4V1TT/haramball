-- ============================================================
-- HARAMBALL.COM — team detail page support
-- Run AFTER 01-schema.sql. Idempotent (CREATE OR REPLACE).
-- ------------------------------------------------------------
-- Adds team_stats(): per-team vote totals across periods plus
-- the team's current rank on the all-time and weekly boards.
-- Used by the per-team SEO pages (frontend/team/<id>.html) to
-- hydrate live numbers on top of the statically-rendered HTML.
-- ============================================================

create or replace function public.team_stats (p_team_id text)
returns table (
  team_id          text,
  team_name        text,
  vote_count_all   bigint,
  votes_week       bigint,
  votes_month      bigint,
  votes_year       bigint,
  votes_today      bigint,
  rank_all         bigint,
  rank_week        bigint,
  total_teams_ranked bigint
)
language sql
stable
security definer
set search_path = public
as $$
  with bounds as (
    select
      date_trunc('week',  now() at time zone 'utc') as week_start,
      date_trunc('month', now() at time zone 'utc') as month_start,
      date_trunc('year',  now() at time zone 'utc') as year_start,
      date_trunc('day',   now() at time zone 'utc') as day_start
  ),
  -- all-time totals per team, for ranking
  all_counts as (
    select team_id, count(*)::bigint as c
    from public.votes
    group by team_id
  ),
  week_counts as (
    select team_id, count(*)::bigint as c
    from public.votes, bounds
    where voted_at >= bounds.week_start
    group by team_id
  ),
  ranked_all as (
    select team_id, c, rank() over (order by c desc) as rnk from all_counts
  ),
  ranked_week as (
    select team_id, c, rank() over (order by c desc) as rnk from week_counts
  ),
  this_team as (
    select
      t.id   as team_id,
      t.name as team_name,
      coalesce((select c from all_counts  where team_id = t.id), 0) as vote_count_all,
      coalesce((select count(*) from public.votes, bounds where votes.team_id = t.id and voted_at >= bounds.week_start),  0)::bigint as votes_week,
      coalesce((select count(*) from public.votes, bounds where votes.team_id = t.id and voted_at >= bounds.month_start), 0)::bigint as votes_month,
      coalesce((select count(*) from public.votes, bounds where votes.team_id = t.id and voted_at >= bounds.year_start),  0)::bigint as votes_year,
      coalesce((select count(*) from public.votes, bounds where votes.team_id = t.id and voted_at >= bounds.day_start),   0)::bigint as votes_today,
      (select rnk from ranked_all  where team_id = t.id) as rank_all,
      (select rnk from ranked_week where team_id = t.id) as rank_week,
      (select count(*) from all_counts) as total_teams_ranked
    from public.teams t
    where t.id = p_team_id and t.active
  )
  select
    team_id, team_name, vote_count_all, votes_week, votes_month,
    votes_year, votes_today, rank_all, rank_week, total_teams_ranked
  from this_team;
$$;
revoke all on function public.team_stats(text) from public;
grant  execute on function public.team_stats(text) to anon, authenticated;

-- ============================================================
-- DONE. Re-run safely anytime. No data migration required.
-- ============================================================
