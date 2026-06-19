-- ============================================================
-- HARAMBALL.COM — standalone fan comments (clubs + countries)
-- Run AFTER 01-schema.sql and 04-countries.sql. Idempotent.
-- ------------------------------------------------------------
-- Anyone can post a short comment on a team/country page without
-- voting, and as many comments as they like (no daily cap; voting
-- stays 1/day separately). Spam guards: length cap, link block, and
-- a 3s anti-flood cooldown. Public read of "visible" rows.
-- ============================================================

create table if not exists public.comments (
  id           uuid primary key default gen_random_uuid(),
  target_type  text not null check (target_type in ('club','country')),
  target_id    text not null,
  voter_id     uuid not null references public.voter_sessions(voter_id) on delete cascade,
  body         text not null,
  created_at   timestamptz not null default now(),
  ip_country   text,
  status       text not null default 'visible',   -- 'visible' | 'hidden' | 'removed'
  constraint comment_body_len check (char_length(body) between 1 and 280)
);
create index if not exists idx_comments_target    on public.comments(target_type, target_id, created_at desc);
create index if not exists idx_comments_voter_time on public.comments(voter_id, created_at desc);

alter table public.comments enable row level security;
drop policy if exists "read visible comments" on public.comments;
create policy "read visible comments" on public.comments for select using (status = 'visible');

grant select on public.comments to anon, authenticated;
grant select, insert, update, delete on public.comments to service_role;

-- ---------- POST a comment ----------
create or replace function public.post_comment (
  p_voter_id    uuid,
  p_target_type text,
  p_target_id   text,
  p_body        text,
  p_user_agent  text default null,
  p_ip_country  text default null
) returns public.comments
language plpgsql
security definer
set search_path = public
as $$
declare
  v_body  text;
  v_row   public.comments;
begin
  if p_voter_id is null then raise exception 'voter_id is required' using errcode = '22023'; end if;
  if p_target_type not in ('club','country') then raise exception 'invalid target_type' using errcode = '22023'; end if;

  v_body := btrim(coalesce(p_body, ''));
  if char_length(v_body) < 1   then raise exception 'comment is empty' using errcode = '22023'; end if;
  if char_length(v_body) > 280 then raise exception 'comment too long (max 280)' using errcode = '22023'; end if;

  -- Block links / obvious spam.
  if v_body ~* '(https?://|www\.|\.com|\.net|\.io|\.ru|\.xyz|t\.me|bit\.ly|telegram|whatsapp)' then
    raise exception 'links are not allowed in comments' using errcode = '22023';
  end if;

  -- Validate the target exists and is active.
  if p_target_type = 'club' then
    if not exists (select 1 from public.teams where id = p_target_id and active) then
      raise exception 'unknown team: %', p_target_id using errcode = '23503';
    end if;
  else
    if not exists (select 1 from public.national_teams where id = p_target_id and active) then
      raise exception 'unknown country: %', p_target_id using errcode = '23503';
    end if;
  end if;

  -- NO daily cap: users may post as many comments as they like (unlike voting,
  -- which stays 1/day). Keep only a short anti-flood cooldown so an automated
  -- script can't rapid-fire thousands of rows. This never limits a real user.
  if exists (
    select 1 from public.comments
    where voter_id = p_voter_id and created_at >= now() - interval '3 seconds'
  ) then
    raise exception 'posting too fast, please wait a moment' using errcode = 'P0001';
  end if;

  -- Upsert the voter session (comments do not count as votes).
  insert into public.voter_sessions (voter_id, ip_country, user_agent, total_votes)
  values (p_voter_id, p_ip_country, p_user_agent, 0)
  on conflict (voter_id) do update
    set last_seen_at = now(),
        ip_country   = coalesce(excluded.ip_country, public.voter_sessions.ip_country),
        user_agent   = coalesce(excluded.user_agent, public.voter_sessions.user_agent);

  insert into public.comments (target_type, target_id, voter_id, body, ip_country)
  values (p_target_type, p_target_id, p_voter_id, v_body, p_ip_country)
  returning * into v_row;
  return v_row;
end;
$$;
revoke all on function public.post_comment(uuid, text, text, text, text, text) from public;
grant  execute on function public.post_comment(uuid, text, text, text, text, text) to anon, authenticated;

-- ---------- READ comments for a page ----------
create or replace function public.get_comments (
  p_target_type text,
  p_target_id   text,
  p_limit       integer default 30
)
returns table (id uuid, body text, created_at timestamptz, ip_country text)
language sql
stable
security definer
set search_path = public
as $$
  select id, body, created_at, ip_country
  from public.comments
  where target_type = p_target_type and target_id = p_target_id and status = 'visible'
  order by created_at desc
  limit least(coalesce(p_limit, 30), 100);
$$;
revoke all on function public.get_comments(text, text, integer) from public;
grant  execute on function public.get_comments(text, text, integer) to anon, authenticated;

-- ============================================================
-- DONE. To hide a bad comment: update public.comments set status='hidden' where id='…';
-- ============================================================
