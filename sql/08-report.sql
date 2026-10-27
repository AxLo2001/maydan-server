-- Maydan Al Hayy: the weekly report (last 7 days compared with the 7 days before). Safe to run again.
create or replace function public.weekly_report() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare uid uuid := auth.uid(); d date := public.riyadh_today(); r jsonb;
begin
  if uid is null then raise exception 'not signed in'; end if;
  with w as (
    select day, km + indoor_km as km, steps, kcal, secs, new_cells, steals, pts from public.workouts
    where user_id = uid and day > d - 14 and day <= d
  ), cur as (select * from w where day > d - 7), prev as (select * from w where day <= d - 7),
  agg as (
    select 'cur' as k, coalesce(sum(km), 0) km, coalesce(sum(steps), 0) steps, coalesce(sum(kcal), 0) kcal, count(*) workouts,
           count(distinct day) active_days, coalesce(sum(secs), 0) secs, coalesce(sum(new_cells), 0) cells, coalesce(sum(steals), 0) steals from cur
    union all
    select 'prev', coalesce(sum(km), 0), coalesce(sum(steps), 0), coalesce(sum(kcal), 0), count(*), count(distinct day), coalesce(sum(secs), 0),
           coalesce(sum(new_cells), 0), coalesce(sum(steals), 0) from prev
  )
  select jsonb_build_object(
    'from', d - 6, 'to', d,
    'cur',  (select to_jsonb(a) - 'k' from agg a where k = 'cur'),
    'prev', (select to_jsonb(a) - 'k' from agg a where k = 'prev'),
    'pts', (select coalesce(sum(amount), 0) from public.points where user_id = uid and (created_at at time zone 'Asia/Riyadh')::date > d - 7),
    'days', (select jsonb_agg(jsonb_build_object('d', g::date, 'km', coalesce((select sum(km) from cur where day = g::date), 0)) order by g)
             from generate_series(d - 6, d, interval '1 day') g),
    'best', (select jsonb_build_object('d', day, 'km', s) from (select day, sum(km) s from cur group by day order by s desc limit 1) b),
    'streak', public.streak_for(uid),
    'name', (select name from public.profiles where id = uid)
  ) into r;
  return r;
end $$;
revoke all on function public.weekly_report() from public, anon;
grant execute on function public.weekly_report() to authenticated;
