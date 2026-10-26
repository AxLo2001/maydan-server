-- Table rights for signed-in users. Row level security in 02-schema.sql decides which rows they see.
grant usage on schema public to anon, authenticated;
grant select on public.profiles, public.workouts, public.points, public.cells to authenticated;
grant update (name) on public.profiles to authenticated;
