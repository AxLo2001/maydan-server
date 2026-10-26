-- Maydan Al Hayy: invites, activity events and badge stats. Safe to run again.

-- ============ steps and calories per workout ============
alter table public.workouts add column if not exists steps integer not null default 0;
alter table public.workouts add column if not exists kcal integer not null default 0;

-- ============ invite codes ============
alter table public.profiles add column if not exists invite_code text;
alter table public.profiles add column if not exists invited_by uuid references auth.users on delete set null;
alter table public.profiles add column if not exists invite_rewarded boolean not null default false;
create unique index if not exists profiles_invite_code on public.profiles (invite_code);

create or replace function public.new_invite_code() returns text
language plpgsql volatile set search_path = '' as $$
declare a text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; c text; i int;
begin
  loop
    c := '';
    for i in 1..6 loop c := c || substr(a, 1 + floor(random() * length(a))::int, 1); end loop;
    exit when not exists (select 1 from public.profiles where invite_code = c);
  end loop;
  return c;
end $$;

create or replace function public.profiles_set_code() returns trigger
language plpgsql set search_path = '' as $$
begin
  if new.invite_code is null then new.invite_code := public.new_invite_code(); end if;
  return new;
end $$;
drop trigger if exists profiles_code on public.profiles;
create trigger profiles_code before insert on public.profiles for each row execute function public.profiles_set_code();
update public.profiles set invite_code = public.new_invite_code() where invite_code is null;

-- ============ activity events (someone took your cells, a friend joined) ============
create table if not exists public.events (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users on delete cascade,
  kind text not null,
  actor uuid references auth.users on delete set null,
  amount integer not null default 0,
  seen boolean not null default false,
  created_at timestamptz not null default now()
);
create index if not exists events_user_unseen on public.events (user_id) where not seen;
alter table public.events enable row level security;
drop policy if exists "events: read own" on public.events;
create policy "events: read own" on public.events for select to authenticated using (user_id = (select auth.uid()));

-- ============ log_workout: also records who lost cells and rewards invites ============
create or replace function public.log_workout(p jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := auth.uid();
  v_client text := p->>'client_id';
  v_mode text := coalesce(p->>'mode', 'walk');
  v_secs integer := greatest(0, least(86400, coalesce((p->>'secs')::numeric, 0)::integer));
  v_km numeric := greatest(0, least(100, coalesce((p->>'km')::numeric, 0)));
  v_start timestamptz := coalesce((p->>'started_at')::timestamptz, now());
  v_steps integer := greatest(0, coalesce((p->>'steps')::numeric, 0)::integer);
  v_kcal integer := greatest(0, coalesce((p->>'kcal')::numeric, 0)::integer);
  v_streak integer; v_mult numeric; v_base integer; v_pts integer;
  v_new integer := 0; v_steal integer := 0; v_max_cells integer;
  v_victims jsonb := '{}'::jsonb; v_key text; v_inviter uuid; v_bonus integer := 0;
  c jsonb; prev uuid; existing public.workouts;
begin
  if uid is null then raise exception 'not signed in'; end if;
  if v_client is null or v_mode not in ('walk', 'run') then raise exception 'bad workout'; end if;

  select * into existing from public.workouts where user_id = uid and client_id = v_client;
  if found then
    return jsonb_build_object('pts', existing.pts, 'new_cells', existing.new_cells, 'steals', existing.steals, 'duplicate', true);
  end if;

  if v_secs > 0 and v_km * 1000 / v_secs > 7 then v_km := round(v_secs * 7 / 1000.0, 3); end if;
  if v_secs = 0 then v_km := 0; end if;
  v_steps := least(v_steps, v_secs * 4);                      -- nobody takes more than 4 steps a second
  v_kcal := least(v_kcal, ceil(v_km * 200)::integer, 5000);

  v_streak := public.streak_for(uid);
  v_mult := 1 + least(v_streak, 10) * 0.05;
  v_base := round(v_km * (case when v_mode = 'run' then 15 else 10 end) * v_mult);

  v_max_cells := greatest(10, ceil(v_km * 60)::integer);
  for c in select * from jsonb_array_elements(coalesce(p->'cells', '[]'::jsonb)) limit v_max_cells loop
    select owner into prev from public.cells where cell = c->>'c' for update;
    if not found then
      insert into public.cells (cell, owner, lat, lng) values (c->>'c', uid, (c->>'lat')::float8, (c->>'lng')::float8)
        on conflict (cell) do nothing;
      v_new := v_new + 1;
    elsif prev <> uid then
      update public.cells set owner = uid, taken_at = now() where cell = c->>'c';
      v_steal := v_steal + 1;
      v_victims := jsonb_set(v_victims, array[prev::text], to_jsonb(coalesce((v_victims->>prev::text)::int, 0) + 1));
    end if;
  end loop;

  v_pts := v_base + v_new * 5 + v_steal * 8;

  insert into public.workouts (user_id, client_id, started_at, day, mode, km, secs, pts, new_cells, steals, steps, kcal)
  values (uid, v_client, v_start, (v_start at time zone 'Asia/Riyadh')::date, v_mode, v_km, v_secs, v_pts, v_new, v_steal, v_steps, v_kcal);
  if v_pts > 0 then
    insert into public.points (user_id, amount, reason) values (uid, v_pts, 'workout:' || v_client);
  end if;

  for v_key in select jsonb_object_keys(v_victims) loop
    insert into public.events (user_id, kind, actor, amount) values (v_key::uuid, 'stolen', uid, (v_victims->>v_key)::int);
  end loop;

  -- invite reward: once the invited player has walked or run 1 km in total, both get 100 points
  select invited_by into v_inviter from public.profiles where id = uid and not invite_rewarded and invited_by is not null;
  if v_inviter is not null and (select coalesce(sum(km), 0) from public.workouts where user_id = uid) >= 1 then
    update public.profiles set invite_rewarded = true where id = uid;
    insert into public.points (user_id, amount, reason) values (uid, 100, 'invited:' || uid) on conflict do nothing;
    insert into public.points (user_id, amount, reason) values (v_inviter, 100, 'invite:' || uid) on conflict do nothing;
    insert into public.events (user_id, kind, actor, amount) values (v_inviter, 'invite_joined', uid, 100);
    v_bonus := 100;
  end if;

  return jsonb_build_object('pts', v_pts, 'base', v_base, 'new_cells', v_new, 'steals', v_steal, 'mult', v_mult, 'km', v_km, 'invite_bonus', v_bonus);
end $$;

-- ============ use an invite code (after signing up) ============
create or replace function public.redeem_invite(p_code text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid(); v_inviter uuid; v_name text;
begin
  if uid is null then raise exception 'not signed in'; end if;
  select id, name into v_inviter, v_name from public.profiles where invite_code = upper(trim(p_code));
  if v_inviter is null then return jsonb_build_object('ok', false, 'reason', 'unknown'); end if;
  if v_inviter = uid then return jsonb_build_object('ok', false, 'reason', 'self'); end if;
  update public.profiles set invited_by = v_inviter where id = uid and invited_by is null;
  if not found then return jsonb_build_object('ok', false, 'reason', 'already'); end if;
  return jsonb_build_object('ok', true, 'inviter', v_name);
end $$;

-- ============ unseen activity (and mark it seen) ============
create or replace function public.my_events() returns table (kind text, actor_name text, amount integer, created_at timestamptz)
language plpgsql security definer set search_path = '' as $$
begin
  return query
    with e as (
      update public.events ev set seen = true
      where ev.id in (select id from public.events where user_id = auth.uid() and not seen order by id desc limit 20)
      returning ev.kind, ev.actor, ev.amount, ev.created_at
    )
    select e.kind, coalesce(p.name, 'لاعب'), e.amount, e.created_at
    from e left join public.profiles p on p.id = e.actor
    order by e.created_at desc;
end $$;

-- ============ my_stats with everything the badges need ============
create or replace function public.best_streak_for(uid uuid) returns integer
language sql stable set search_path = '' as $$
  with d as (select day from public.workouts where user_id = uid group by day having sum(km) >= 0.5),
       g as (select day, day - (row_number() over (order by day))::int as grp from d)
  select coalesce(max(n), 0)::int from (select count(*) as n from g group by grp) x
$$;

create or replace function public.my_stats() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare uid uuid := auth.uid(); d date := public.riyadh_today(); ws date; r jsonb;
begin
  if uid is null then raise exception 'not signed in'; end if;
  ws := (public.week_start() at time zone 'Asia/Riyadh')::date;
  select jsonb_build_object(
    'name', (select name from public.profiles where id = uid),
    'invite_code', (select invite_code from public.profiles where id = uid),
    'today', (select jsonb_build_object('km', coalesce(sum(km), 0), 'new_cells', coalesce(sum(new_cells), 0), 'steals', coalesce(sum(steals), 0), 'steps', coalesce(sum(steps), 0), 'kcal', coalesce(sum(kcal), 0))
              from public.workouts where user_id = uid and day = d),
    'today_pts', (select coalesce(sum(amount), 0) from public.points where user_id = uid and (created_at at time zone 'Asia/Riyadh')::date = d),
    'week_pts', (select coalesce(sum(amount), 0) from public.points where user_id = uid and created_at >= public.week_start()),
    'streak', public.streak_for(uid),
    'best_streak', public.best_streak_for(uid),
    'total_km', (select coalesce(sum(km), 0) from public.workouts where user_id = uid),
    'total_steps', (select coalesce(sum(steps), 0) from public.workouts where user_id = uid),
    'total_kcal', (select coalesce(sum(kcal), 0) from public.workouts where user_id = uid),
    'most_steps', (select coalesce(max(steps), 0) from public.workouts where user_id = uid),
    'longest_km', (select coalesce(max(km), 0) from public.workouts where user_id = uid),
    'workouts', (select count(*) from public.workouts where user_id = uid),
    'runs', (select count(*) from public.workouts where user_id = uid and mode = 'run'),
    'early', (select count(*) from public.workouts where user_id = uid and extract(hour from started_at at time zone 'Asia/Riyadh') < 7),
    'night', (select count(*) from public.workouts where user_id = uid and extract(hour from started_at at time zone 'Asia/Riyadh') >= 21),
    'steals_total', (select coalesce(sum(steals), 0) from public.workouts where user_id = uid),
    'cells', (select count(*) from public.cells where owner = uid),
    'invites', (select count(*) from public.profiles where invited_by = uid and invite_rewarded),
    'claimed', (select coalesce(jsonb_agg(split_part(reason, ':', 1)), '[]'::jsonb) from public.points
                where user_id = uid and reason like '%:' || d::text and reason not like 'workout:%'),
    'week_ends', public.week_start() + interval '7 days',
    'week_days', (select jsonb_agg(jsonb_build_object('d', g::date, 'km', coalesce(
                    (select sum(km) from public.workouts where user_id = uid and day = g::date), 0)) order by g)
                  from generate_series(ws, ws + 6, interval '1 day') g),
    'week_km', (select coalesce(sum(km), 0) from public.workouts where user_id = uid and day >= ws)
  ) into r;
  return r;
end $$;

revoke all on function public.redeem_invite(text), public.my_events(), public.best_streak_for(uuid), public.new_invite_code() from public, anon;
grant execute on function public.redeem_invite(text), public.my_events(), public.log_workout(jsonb), public.my_stats() to authenticated;
grant select on public.events to authenticated;
