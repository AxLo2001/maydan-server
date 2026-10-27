-- Maydan Al Hayy: real push notifications (Firebase Cloud Messaging). Safe to run again.
-- Phones register their push token; whenever an event row is written (cells taken, friend joined, season medal)
-- the database sends pg_notify('maydan_push', ...) and the server forwards it to the player's phones.

create table if not exists public.push_tokens (
  token text primary key,
  user_id uuid not null references auth.users on delete cascade,
  platform text not null default 'android',
  updated_at timestamptz not null default now()
);
create index if not exists push_tokens_user on public.push_tokens (user_id);
alter table public.push_tokens enable row level security;

create or replace function public.save_push_token(p_token text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  if p_token is null or length(p_token) < 20 or length(p_token) > 4096 then raise exception 'bad token'; end if;
  insert into public.push_tokens (token, user_id, updated_at) values (p_token, auth.uid(), now())
  on conflict (token) do update set user_id = excluded.user_id, updated_at = now();   -- a phone that changes account moves with it
end $$;

create or replace function public.delete_push_token(p_token text) returns void
language sql security definer set search_path = '' as $$
  delete from public.push_tokens where token = p_token and user_id = auth.uid()
$$;

create or replace function public.events_push() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  perform pg_notify('maydan_push', json_build_object('user_id', new.user_id, 'kind', new.kind, 'amount', new.amount,
    'actor', (select name from public.profiles where id = new.actor))::text);
  return new;
end $$;
drop trigger if exists events_push on public.events;
create trigger events_push after insert on public.events for each row execute function public.events_push();

revoke all on function public.save_push_token(text), public.delete_push_token(text), public.events_push() from public, anon;
grant execute on function public.save_push_token(text), public.delete_push_token(text) to authenticated;

-- used by the server's own database user to find a player's phones and drop dead tokens
create or replace function public.push_targets(p_user uuid) returns setof text
language sql stable security definer set search_path = '' as $$
  select token from public.push_tokens where user_id = p_user order by updated_at desc limit 5
$$;
create or replace function public.push_drop(p_token text) returns void
language sql security definer set search_path = '' as $$ delete from public.push_tokens where token = p_token $$;
revoke all on function public.push_targets(uuid), public.push_drop(text) from public, anon, authenticated;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'maydan') then
    grant execute on function public.push_targets(uuid), public.push_drop(text) to maydan;
  end if;
end $$;
