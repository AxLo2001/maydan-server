-- Maydan Al Hayy: guest play (no account) and Google sign-in. Safe to run again.
alter table auth.users add column if not exists is_guest boolean not null default false;
alter table auth.users add column if not exists google_sub text;
create unique index if not exists users_google_sub on auth.users (google_sub) where google_sub is not null;

-- a guest: a real account with a hidden random login, so everything works the same (league, cells, invites)
create or replace function auth.guest(p_name text) returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_id uuid;
begin
  insert into auth.users (email, password_hash, raw_user_meta_data, last_sign_in_at, is_guest)
  values ('guest-' || gen_random_uuid() || '@guest.invalid', public.crypt(encode(public.gen_random_bytes(24), 'base64'), public.gen_salt('bf', 6)),
          jsonb_build_object('name', p_name), now(), true)
  returning id into v_id;
  return v_id;
end $$;

-- sign in with Google (the server already checked Google's signature on the token).
-- Same Google account -> same player. A verified email that already has an account gets linked to it.
create or replace function auth.google(p_sub text, p_email text, p_name text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_id uuid;
begin
  select id into v_id from auth.users where google_sub = p_sub;
  if v_id is not null then
    update auth.users set last_sign_in_at = now() where id = v_id;
    return jsonb_build_object('id', v_id, 'created', false);
  end if;
  select id into v_id from auth.users where lower(email) = lower(p_email) and not is_guest;
  if v_id is not null then
    update auth.users set google_sub = p_sub, last_sign_in_at = now() where id = v_id;
    return jsonb_build_object('id', v_id, 'created', false);
  end if;
  insert into auth.users (email, password_hash, raw_user_meta_data, last_sign_in_at, google_sub)
  values (lower(p_email), public.crypt(encode(public.gen_random_bytes(24), 'base64'), public.gen_salt('bf', 6)),
          jsonb_build_object('name', p_name), now(), p_sub)
  returning id into v_id;
  return jsonb_build_object('id', v_id, 'created', true);
end $$;

-- a guest keeps everything and becomes a normal account (email + password)
create or replace function auth.upgrade_email(p_uid uuid, p_email text, p_password text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not exists (select 1 from auth.users where id = p_uid and is_guest) then raise exception 'not a guest'; end if;
  if exists (select 1 from auth.users where lower(email) = lower(trim(p_email)) and id <> p_uid) then raise exception 'User already registered'; end if;
  update auth.users set email = lower(trim(p_email)), password_hash = public.crypt(p_password, public.gen_salt('bf', 10)), is_guest = false
  where id = p_uid;
end $$;

-- a guest keeps everything and links a Google account
create or replace function auth.upgrade_google(p_uid uuid, p_sub text, p_email text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not exists (select 1 from auth.users where id = p_uid and is_guest) then raise exception 'not a guest'; end if;
  if exists (select 1 from auth.users where (google_sub = p_sub or lower(email) = lower(p_email)) and id <> p_uid) then raise exception 'google_taken'; end if;
  update auth.users set email = lower(p_email), google_sub = p_sub, is_guest = false where id = p_uid;
end $$;

revoke all on function auth.guest(text), auth.google(text, text, text), auth.upgrade_email(uuid, text, text), auth.upgrade_google(uuid, text, text) from public, anon, authenticated;

-- remove guests who never trained and have been away for 30 days (called by the server every few hours)
create or replace function auth.cleanup_guests() returns integer
language plpgsql security definer set search_path = '' as $$
declare n integer;
begin
  delete from auth.users u where u.is_guest and coalesce(u.last_sign_in_at, u.created_at) < now() - interval '30 days'
    and not exists (select 1 from public.workouts w where w.user_id = u.id)
    and not exists (select 1 from auth.refresh_tokens t where t.user_id = u.id and t.expires_at > now());
  get diagnostics n = row_count;
  return n;
end $$;
revoke all on function auth.cleanup_guests() from public, anon, authenticated;
