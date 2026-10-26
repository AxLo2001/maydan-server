-- ميدان الحي: قاعدة البيانات
-- تُشغَّل مرة واحدة في Supabase: SQL Editor ثم New query ثم الصق هذا الملف كامل ثم Run.
-- آمنة لإعادة التشغيل.

-- ============ الجداول ============

create table if not exists public.profiles (
  id uuid primary key references auth.users on delete cascade,
  name text not null check (char_length(name) between 2 and 20),
  created_at timestamptz not null default now()
);

create table if not exists public.workouts (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users on delete cascade,
  client_id text not null,
  started_at timestamptz not null,
  day date not null,
  mode text not null check (mode in ('walk', 'run')),
  km numeric(7,3) not null check (km >= 0 and km <= 100),
  secs integer not null check (secs >= 0 and secs <= 86400),
  pts integer not null default 0,
  new_cells integer not null default 0,
  steals integer not null default 0,
  created_at timestamptz not null default now(),
  unique (user_id, client_id)
);
create index if not exists workouts_user_day on public.workouts (user_id, day);

-- كل النقاط (تمارين، مهمات، صندوق المكافأة) في دفتر واحد. السبب فريد لكل مستخدم فما تنحسب مرتين.
create table if not exists public.points (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users on delete cascade,
  amount integer not null,
  reason text not null,
  created_at timestamptz not null default now(),
  unique (user_id, reason)
);
create index if not exists points_created on public.points (created_at);

-- خلايا الحي (شبكة H3 العالمية، دقة 11، حوالي 25 م للضلع)
create table if not exists public.cells (
  cell text primary key,
  owner uuid not null references auth.users on delete cascade,
  lat double precision not null,
  lng double precision not null,
  taken_at timestamptz not null default now()
);
create index if not exists cells_latlng on public.cells (lat, lng);
create index if not exists cells_owner on public.cells (owner);

-- ============ الحماية ============

alter table public.profiles enable row level security;
alter table public.workouts enable row level security;
alter table public.points enable row level security;
alter table public.cells enable row level security;

drop policy if exists "profiles: signed-in users read" on public.profiles;
create policy "profiles: signed-in users read" on public.profiles for select to authenticated using (true);
drop policy if exists "profiles: update own name" on public.profiles;
create policy "profiles: update own name" on public.profiles for update to authenticated
  using (id = (select auth.uid())) with check (id = (select auth.uid()));

drop policy if exists "workouts: read own" on public.workouts;
create policy "workouts: read own" on public.workouts for select to authenticated using (user_id = (select auth.uid()));
drop policy if exists "points: read own" on public.points;
create policy "points: read own" on public.points for select to authenticated using (user_id = (select auth.uid()));
drop policy if exists "cells: signed-in users read" on public.cells;
create policy "cells: signed-in users read" on public.cells for select to authenticated using (true);
-- لا توجد سياسات كتابة على workouts و points و cells: الكتابة فقط عبر الدوال تحت، عشان النقاط تنحسب في الخادم.

-- ============ إنشاء الملف الشخصي عند التسجيل ============

create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = '' as $$
declare n text;
begin
  n := left(coalesce(nullif(trim(new.raw_user_meta_data->>'name'), ''), 'عداء'), 20);
  if char_length(n) < 2 then n := 'عداء'; end if;
  insert into public.profiles (id, name) values (new.id, n) on conflict (id) do nothing;
  return new;
end $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- ============ أدوات الوقت (توقيت الرياض، الأسبوع يبدأ الأحد) ============

create or replace function public.riyadh_today() returns date
language sql stable set search_path = '' as $$ select (now() at time zone 'Asia/Riyadh')::date $$;

create or replace function public.week_start() returns timestamptz
language sql stable set search_path = '' as $$
  select ((public.riyadh_today() - extract(dow from public.riyadh_today())::int)::timestamp at time zone 'Asia/Riyadh')
$$;

create or replace function public.streak_for(uid uuid) returns integer
language plpgsql stable set search_path = '' as $$
declare d date := public.riyadh_today(); n integer := 0;
begin
  if not exists (select 1 from public.workouts where user_id = uid and day = d group by day having sum(km) >= 0.5) then
    d := d - 1;
  end if;
  while exists (select 1 from public.workouts where user_id = uid and day = d group by day having sum(km) >= 0.5) loop
    n := n + 1; d := d - 1;
  end loop;
  return n;
end $$;

-- ============ تسجيل تمرين (الخادم يحسب النقاط ويحتل الخلايا) ============

create or replace function public.log_workout(p jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := auth.uid();
  v_client text := p->>'client_id';
  v_mode text := coalesce(p->>'mode', 'walk');
  v_secs integer := greatest(0, least(86400, coalesce((p->>'secs')::numeric, 0)::integer));
  v_km numeric := greatest(0, least(100, coalesce((p->>'km')::numeric, 0)));
  v_start timestamptz := coalesce((p->>'started_at')::timestamptz, now());
  v_streak integer; v_mult numeric; v_base integer; v_pts integer;
  v_new integer := 0; v_steal integer := 0; v_max_cells integer;
  c jsonb; prev uuid; existing public.workouts;
begin
  if uid is null then raise exception 'not signed in'; end if;
  if v_client is null or v_mode not in ('walk', 'run') then raise exception 'bad workout'; end if;

  select * into existing from public.workouts where user_id = uid and client_id = v_client;
  if found then
    return jsonb_build_object('pts', existing.pts, 'new_cells', existing.new_cells, 'steals', existing.steals, 'duplicate', true);
  end if;

  -- أسرع من 25 كم/س متوسط = غير منطقي للمشي أو الجري: نقص المسافة على هذا الحد
  if v_secs > 0 and v_km * 1000 / v_secs > 7 then v_km := round(v_secs * 7 / 1000.0, 3); end if;
  if v_secs = 0 then v_km := 0; end if;

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
    end if;
  end loop;

  v_pts := v_base + v_new * 5 + v_steal * 8;

  insert into public.workouts (user_id, client_id, started_at, day, mode, km, secs, pts, new_cells, steals)
  values (uid, v_client, v_start, (v_start at time zone 'Asia/Riyadh')::date, v_mode, v_km, v_secs, v_pts, v_new, v_steal);

  if v_pts > 0 then
    insert into public.points (user_id, amount, reason) values (uid, v_pts, 'workout:' || v_client);
  end if;

  return jsonb_build_object('pts', v_pts, 'base', v_base, 'new_cells', v_new, 'steals', v_steal, 'mult', v_mult, 'km', v_km);
end $$;

-- ============ المهمات اليومية وصندوق المكافأة ============

create or replace function public.claim(p_id text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := auth.uid(); d date := public.riyadh_today();
  t_km numeric; t_new integer; t_steal integer; amt integer; ok boolean;
begin
  if uid is null then raise exception 'not signed in'; end if;
  select coalesce(sum(km), 0), coalesce(sum(new_cells), 0), coalesce(sum(steals), 0)
    into t_km, t_new, t_steal from public.workouts where user_id = uid and day = d;
  if p_id = 'km' then ok := t_km >= 2; amt := 40;
  elsif p_id = 'cells' then ok := t_new >= 5; amt := 30;
  elsif p_id = 'steal' then ok := t_steal >= 1; amt := 50;
  elsif p_id = 'box' then ok := true; amt := 20 + floor(random() * 41)::integer;
  else raise exception 'unknown'; end if;
  if not ok then return jsonb_build_object('ok', false); end if;
  insert into public.points (user_id, amount, reason) values (uid, amt, p_id || ':' || d)
    on conflict (user_id, reason) do nothing;
  if not found then return jsonb_build_object('ok', false, 'already', true); end if;
  return jsonb_build_object('ok', true, 'amount', amt);
end $$;

-- ============ الدوري الأسبوعي ============

create or replace function public.weekly_board() returns table (rank bigint, name text, pts bigint, is_me boolean)
language sql stable security definer set search_path = '' as $$
  with w as (
    select user_id, sum(amount) as pts from public.points where created_at >= public.week_start() group by user_id
  ), all_rows as (
    select pr.id, pr.name, coalesce(w.pts, 0) as pts
    from public.profiles pr left join w on w.user_id = pr.id
    where w.pts > 0 or pr.id = auth.uid()
  )
  select rank() over (order by pts desc), name, pts, id = auth.uid()
  from all_rows order by pts desc, name limit 100
$$;

-- ============ إحصائياتي ============

create or replace function public.my_stats() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare uid uuid := auth.uid(); d date := public.riyadh_today(); r jsonb;
begin
  if uid is null then raise exception 'not signed in'; end if;
  select jsonb_build_object(
    'name', (select name from public.profiles where id = uid),
    'today', (select jsonb_build_object('km', coalesce(sum(km), 0), 'new_cells', coalesce(sum(new_cells), 0), 'steals', coalesce(sum(steals), 0))
              from public.workouts where user_id = uid and day = d),
    'today_pts', (select coalesce(sum(amount), 0) from public.points where user_id = uid
                  and (created_at at time zone 'Asia/Riyadh')::date = d),
    'week_pts', (select coalesce(sum(amount), 0) from public.points where user_id = uid and created_at >= public.week_start()),
    'streak', public.streak_for(uid),
    'total_km', (select coalesce(sum(km), 0) from public.workouts where user_id = uid),
    'workouts', (select count(*) from public.workouts where user_id = uid),
    'cells', (select count(*) from public.cells where owner = uid),
    'claimed', (select coalesce(jsonb_agg(split_part(reason, ':', 1)), '[]'::jsonb) from public.points
                where user_id = uid and reason like '%:' || d::text and reason not like 'workout:%'),
    'week_ends', public.week_start() + interval '7 days',
    'week_days', (select jsonb_agg(jsonb_build_object('d', g::date, 'km', coalesce(
                    (select sum(km) from public.workouts where user_id = uid and day = g::date), 0)) order by g)
                  from generate_series((public.week_start() at time zone 'Asia/Riyadh')::date,
                                       (public.week_start() at time zone 'Asia/Riyadh')::date + 6, interval '1 day') g),
    'week_km', (select coalesce(sum(km), 0) from public.workouts where user_id = uid
                and day >= (public.week_start() at time zone 'Asia/Riyadh')::date)
  ) into r;
  return r;
end $$;

-- ============ خلايا الخريطة في المنطقة الظاهرة ============

create or replace function public.cells_in_view(s float8, w float8, n float8, e float8)
returns table (cell text, mine boolean, owner_name text)
language sql stable security definer set search_path = '' as $$
  select c.cell, c.owner = auth.uid(), p.name
  from public.cells c join public.profiles p on p.id = c.owner
  where c.lat between s and n and c.lng between w and e
  limit 3000
$$;

-- ============ حذف الحساب (شرط من Google Play) ============

create or replace function public.delete_my_account() returns void
language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  delete from auth.users where id = auth.uid();
end $$;

-- ============ الصلاحيات ============

revoke all on function public.log_workout(jsonb), public.claim(text), public.weekly_board(), public.my_stats(),
  public.cells_in_view(float8, float8, float8, float8), public.delete_my_account(), public.streak_for(uuid)
  from public, anon;
grant execute on function public.log_workout(jsonb), public.claim(text), public.weekly_board(), public.my_stats(),
  public.cells_in_view(float8, float8, float8, float8), public.delete_my_account()
  to authenticated;
