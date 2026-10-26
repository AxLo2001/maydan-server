-- Maydan Al Hayy: a new challenge from the app every day, with its own streak. Safe to run again.
-- Everything is checked on the server from the saved workouts, so the app cannot claim a challenge it did not finish.

-- the challenge for a given day: the same for every player, and it changes at midnight Riyadh time
create or replace function public.challenge_for(d date) returns jsonb
language sql immutable set search_path = '' as $$
  select (array[
    jsonb_build_object('kind', 'km',      'goal', 3,     'reward', 60,  'title', 'امش 3 كيلو اليوم'),
    jsonb_build_object('kind', 'steps',   'goal', 5000,  'reward', 60,  'title', '5,000 خطوة اليوم'),
    jsonb_build_object('kind', 'minutes', 'goal', 30,    'reward', 60,  'title', '30 دقيقة حركة'),
    jsonb_build_object('kind', 'cells',   'goal', 10,    'reward', 70,  'title', 'احتل 10 خلايا جديدة'),
    jsonb_build_object('kind', 'steps',   'goal', 8000,  'reward', 90,  'title', '8,000 خطوة اليوم'),
    jsonb_build_object('kind', 'run_km',  'goal', 2,     'reward', 80,  'title', 'اجر 2 كيلو'),
    jsonb_build_object('kind', 'km',      'goal', 5,     'reward', 100, 'title', 'تحدي الـ 5 كيلو'),
    jsonb_build_object('kind', 'early_km','goal', 1,     'reward', 70,  'title', 'امش كيلو قبل 9 الصبح'),
    jsonb_build_object('kind', 'km',      'goal', 2,     'reward', 50,  'title', 'امش 2 كيلو اليوم'),
    jsonb_build_object('kind', 'minutes', 'goal', 45,    'reward', 80,  'title', '45 دقيقة حركة'),
    jsonb_build_object('kind', 'steps',   'goal', 10000, 'reward', 120, 'title', 'تحدي الـ 10,000 خطوة'),
    jsonb_build_object('kind', 'km',      'goal', 4,     'reward', 80,  'title', 'امش 4 كيلو اليوم')
  ])[1 + ((d - date '2026-01-01') * 5 % 12 + 12) % 12]
$$;

-- how far a player got today towards a challenge kind
create or replace function public.challenge_progress(uid uuid, d date, kind text) returns numeric
language sql stable set search_path = '' as $$
  select coalesce(case kind
    when 'km'       then sum(km)
    when 'steps'    then sum(steps)
    -- only moving minutes count: at most 20 minutes for each kilometre (a slow 3 km/h walk), so standing still earns nothing
    when 'minutes'  then floor(sum(least(secs / 60.0, km * 20)))
    when 'cells'    then sum(new_cells)
    when 'steals'   then sum(steals)
    when 'run_km'   then sum(km) filter (where mode = 'run')
    when 'early_km' then sum(km) filter (where extract(hour from started_at at time zone 'Asia/Riyadh') < 9)
  end, 0)
  from public.workouts where user_id = uid and day = d
$$;

-- days in a row the player finished the daily challenge (today counts once it is claimed)
create or replace function public.challenge_streak(uid uuid) returns integer
language plpgsql stable set search_path = '' as $$
declare d date := public.riyadh_today(); n integer := 0;
begin
  if not exists (select 1 from public.points where user_id = uid and reason = 'challenge:' || d) then d := d - 1; end if;
  while exists (select 1 from public.points where user_id = uid and reason = 'challenge:' || d) loop
    n := n + 1; d := d - 1;
  end loop;
  return n;
end $$;

-- everything the app shows on the challenge card
create or replace function public.challenge_state(uid uuid) returns jsonb
language plpgsql stable set search_path = '' as $$
declare d date := public.riyadh_today(); c jsonb := public.challenge_for(d); prog numeric; claimed boolean; streak integer; bonus integer;
begin
  prog := public.challenge_progress(uid, d, c->>'kind');
  claimed := exists (select 1 from public.points where user_id = uid and reason = 'challenge:' || d);
  streak := public.challenge_streak(uid);
  -- the bonus grows with the streak you would continue (up to +70 after a week)
  bonus := least(case when claimed then greatest(streak - 1, 0) else streak end, 7) * 10;
  return c || jsonb_build_object('progress', prog, 'claimed', claimed, 'streak', streak, 'bonus', bonus,
    'tomorrow', public.challenge_for(d + 1)->>'title', 'ends', (d + 1)::timestamp at time zone 'Asia/Riyadh');
end $$;

-- claim: the old daily quests plus the daily challenge
create or replace function public.claim(p_id text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := auth.uid(); d date := public.riyadh_today();
  t_km numeric; t_new integer; t_steal integer; amt integer; ok boolean; c jsonb; st jsonb;
begin
  if uid is null then raise exception 'not signed in'; end if;
  select coalesce(sum(km), 0), coalesce(sum(new_cells), 0), coalesce(sum(steals), 0)
    into t_km, t_new, t_steal from public.workouts where user_id = uid and day = d;
  if p_id = 'km' then ok := t_km >= 2; amt := 40;
  elsif p_id = 'cells' then ok := t_new >= 5; amt := 30;
  elsif p_id = 'steal' then ok := t_steal >= 1; amt := 50;
  elsif p_id = 'box' then ok := true; amt := 20 + floor(random() * 41)::integer;
  elsif p_id = 'challenge' then
    st := public.challenge_state(uid);
    ok := (st->>'progress')::numeric >= (st->>'goal')::numeric;
    amt := (st->>'reward')::integer + (st->>'bonus')::integer;
  else raise exception 'unknown'; end if;
  if not ok then return jsonb_build_object('ok', false); end if;
  insert into public.points (user_id, amount, reason) values (uid, amt, p_id || ':' || d)
    on conflict (user_id, reason) do nothing;
  if not found then return jsonb_build_object('ok', false, 'already', true); end if;
  if p_id = 'challenge' then
    return jsonb_build_object('ok', true, 'amount', amt, 'streak', public.challenge_streak(uid));
  end if;
  return jsonb_build_object('ok', true, 'amount', amt);
end $$;

revoke all on function public.challenge_progress(uuid, date, text), public.challenge_streak(uuid), public.challenge_state(uuid) from public, anon;
grant execute on function public.claim(text) to authenticated;
