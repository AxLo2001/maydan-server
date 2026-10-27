-- Maydan Al Hayy: monthly seasons. Safe to run again.
-- A season is a calendar month (Riyadh time). When a new month starts:
--   the top 10 of the old season get a medal, the top 3 get bonus points (300 / 200 / 100),
--   and the map starts empty again so everyone can capture fresh.

create table if not exists public.seasons (
  id text primary key,                         -- 'YYYY-MM'
  started_at timestamptz not null default now()
);
create table if not exists public.season_awards (
  season text not null,
  user_id uuid not null references auth.users on delete cascade,
  rank integer not null,
  pts integer not null,
  primary key (season, user_id)
);
alter table public.seasons enable row level security;
alter table public.season_awards enable row level security;
drop policy if exists "awards: read all" on public.season_awards;
create policy "awards: read all" on public.season_awards for select to authenticated using (true);

create or replace function public.season_id(d date) returns text language sql immutable as $$ select to_char(d, 'YYYY-MM') $$;
create or replace function public.season_start(id text) returns timestamptz language sql immutable set search_path = '' as $$
  select ((id || '-01')::date)::timestamp at time zone 'Asia/Riyadh'
$$;
create or replace function public.season_end(id text) returns timestamptz language sql immutable set search_path = '' as $$
  select (((id || '-01')::date + interval '1 month')::date)::timestamp at time zone 'Asia/Riyadh'
$$;
create or replace function public.season_name(id text) returns text language sql immutable set search_path = '' as $$
  select 'موسم ' || (array['يناير','فبراير','مارس','أبريل','مايو','يونيو','يوليو','أغسطس','سبتمبر','أكتوبر','نوفمبر','ديسمبر'])[split_part(id, '-', 2)::int]
$$;

-- runs before every workout is saved and every few minutes from the server: closes the old season once
create or replace function public.season_tick() returns void
language plpgsql security definer set search_path = '' as $$
declare cur text := public.season_id(public.riyadh_today()); last text;
begin
  select id into last from public.seasons order by id desc limit 1;
  if last = cur then return; end if;
  perform pg_advisory_xact_lock(424242);
  select id into last from public.seasons order by id desc limit 1;
  if last = cur then return; end if;
  if last is not null then
    insert into public.season_awards (season, user_id, rank, pts)
    select last, user_id, rk, pts from (
      select user_id, sum(amount)::int as pts, rank() over (order by sum(amount) desc) as rk
      from public.points
      where created_at >= public.season_start(last) and created_at < public.season_end(last) and reason not like 'season:%'
      group by user_id
    ) x where rk <= 10 and pts > 0
    on conflict do nothing;
    insert into public.points (user_id, amount, reason)
      select user_id, case rank when 1 then 300 when 2 then 200 else 100 end, 'season:' || last
      from public.season_awards where season = last and rank <= 3
      on conflict do nothing;
    insert into public.events (user_id, kind, amount)
      select user_id, 'season_award', rank from public.season_awards where season = last;
    delete from public.cells;                    -- the map starts again
  end if;
  insert into public.seasons (id) values (cur) on conflict do nothing;
end $$;

-- the season leaderboard (season bonuses from last month do not count here)
create or replace function public.season_board() returns table (rank bigint, name text, pts bigint, is_me boolean)
language sql stable security definer set search_path = '' as $$
  with s as (select public.season_id(public.riyadh_today()) as id),
  w as (
    select user_id, sum(amount) as pts from public.points, s
    where created_at >= public.season_start(s.id) and reason not like 'season:%' group by user_id
  ), all_rows as (
    select pr.id, pr.name, coalesce(w.pts, 0) as pts
    from public.profiles pr left join w on w.user_id = pr.id
    where w.pts > 0 or pr.id = auth.uid()
  )
  select rank() over (order by pts desc), name, pts, id = auth.uid()
  from all_rows order by pts desc, name limit 100
$$;

create or replace function public.season_state(uid uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare sid text := public.season_id(public.riyadh_today()); my integer; rk integer; players integer;
begin
  select coalesce(sum(amount), 0) into my from public.points
    where user_id = uid and created_at >= public.season_start(sid) and reason not like 'season:%';
  select count(*) into players from (select user_id from public.points
    where created_at >= public.season_start(sid) and reason not like 'season:%' group by user_id having sum(amount) > 0) x;
  select count(*) + 1 into rk from (select user_id from public.points
    where created_at >= public.season_start(sid) and reason not like 'season:%' group by user_id having sum(amount) > my) x;
  return jsonb_build_object('id', sid, 'name', public.season_name(sid), 'ends', public.season_end(sid),
    'pts', my, 'rank', case when my > 0 then rk end, 'players', players,
    'awards', (select coalesce(jsonb_agg(jsonb_build_object('season', season, 'name', public.season_name(season), 'rank', rank) order by season desc), '[]'::jsonb)
               from public.season_awards where user_id = uid));
end $$;

revoke all on function public.season_tick(), public.season_state(uuid) from public, anon, authenticated;
grant execute on function public.season_board() to authenticated;
grant select on public.season_awards to authenticated;
select public.season_tick();
