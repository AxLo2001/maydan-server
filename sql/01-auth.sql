-- Maydan Al Hayy server: accounts layer (replaces the hosted auth service).
-- Safe to run again.
create extension if not exists pgcrypto;

do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then create role anon nologin; end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then create role authenticated nologin; end if;
end $$;

create schema if not exists auth;

create table if not exists auth.users (
  id uuid primary key default gen_random_uuid(),
  email text not null,
  password_hash text not null,
  raw_user_meta_data jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  last_sign_in_at timestamptz
);
create unique index if not exists users_email_lower on auth.users (lower(email));

create table if not exists auth.refresh_tokens (
  token_hash text primary key,
  user_id uuid not null references auth.users on delete cascade,
  expires_at timestamptz not null,
  created_at timestamptz not null default now()
);
create index if not exists refresh_tokens_user on auth.refresh_tokens (user_id);

-- the signed-in user for this request (set by the server inside each transaction)
create or replace function auth.uid() returns uuid language sql stable as $$
  select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid
$$;

grant usage on schema auth to anon, authenticated;
grant execute on function auth.uid() to anon, authenticated;

-- account functions, called only by the server's own database user
create or replace function auth.sign_up(p_email text, p_password text, p_name text) returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_id uuid;
begin
  if exists (select 1 from auth.users where lower(email) = lower(trim(p_email))) then
    raise exception 'User already registered';
  end if;
  insert into auth.users (email, password_hash, raw_user_meta_data, last_sign_in_at)
  values (lower(trim(p_email)), public.crypt(p_password, public.gen_salt('bf', 10)), jsonb_build_object('name', p_name), now())
  returning id into v_id;
  return v_id;
end $$;

create or replace function auth.sign_in(p_email text, p_password text) returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_id uuid; v_hash text;
begin
  select id, password_hash into v_id, v_hash from auth.users where lower(email) = lower(trim(p_email));
  if v_id is null or public.crypt(p_password, v_hash) <> v_hash then
    raise exception 'Invalid login credentials';
  end if;
  update auth.users set last_sign_in_at = now() where id = v_id;
  return v_id;
end $$;

create or replace function auth.set_password(p_email text, p_password text) returns boolean
language plpgsql security definer set search_path = '' as $$
begin
  update auth.users set password_hash = public.crypt(p_password, public.gen_salt('bf', 10)) where lower(email) = lower(trim(p_email));
  if not found then return false; end if;
  delete from auth.refresh_tokens where user_id = (select id from auth.users where lower(email) = lower(trim(p_email)));
  return true;
end $$;

revoke all on function auth.sign_up(text, text, text), auth.sign_in(text, text), auth.set_password(text, text) from public, anon, authenticated;
