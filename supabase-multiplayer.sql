-- Jemrix · Mehrspieler (2 oder 3 Spieler gegeneinander, jeder auf seinem iPhone)
-- Einmalig nach supabase-setup.sql ausführen. Direkter Tabellenzugriff bleibt gesperrt,
-- das Spiel nutzt nur die mp_*-Funktionen (mit Familien-Code).

create table if not exists public.jemrix_rooms (
  id          uuid primary key default gen_random_uuid(),
  created_at  timestamptz not null default now(),
  size        integer not null check (size between 2 and 3),
  seed        integer not null,
  host        text not null,
  host_device text not null,
  status      text not null default 'open' check (status in ('open','playing','done','closed')),
  starts_at   timestamptz,
  finished_at timestamptz,
  rematch     uuid
);
create index if not exists jemrix_rooms_status on public.jemrix_rooms (status, created_at);

create table if not exists public.jemrix_room_players (
  room_id    uuid not null references public.jemrix_rooms(id) on delete cascade,
  device     text not null,
  name_key   text not null,
  name       text not null,
  joined_at  timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  state      jsonb not null default '{}'::jsonb,
  score      integer not null default 0,
  done       boolean not null default false,
  primary key (room_id, device),
  unique (room_id, name_key)
);

create table if not exists public.jemrix_wins (
  name_key   text primary key,
  name       text not null,
  wins       integer not null default 0,
  updated_at timestamptz not null default now()
);

alter table public.jemrix_rooms        enable row level security;
alter table public.jemrix_room_players enable row level security;
alter table public.jemrix_wins         enable row level security;
revoke all on public.jemrix_rooms        from anon, authenticated;
revoke all on public.jemrix_room_players from anon, authenticated;
revoke all on public.jemrix_wins         from anon, authenticated;

-- Hilfsfunktionen (nicht von außen aufrufbar)
create or replace function public.mp_clean_name(p text)
returns text language sql immutable set search_path = public, pg_temp as $$
  select btrim(left(btrim(regexp_replace(regexp_replace(coalesce(p, ''), '[\u0000-\u001F\u007F­​-‏‪-‮⁠-⁤﻿]', '', 'g'), '\s+', ' ', 'g')), 20));
$$;

create or replace function public.mp_code_ok(p_code text)
returns boolean language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(p_code = (select family_code from jemrix_meta where id = 1), false);
$$;

create or replace function public.mp_wins_json()
returns json language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(json_agg(json_build_object('name', name, 'wins', wins) order by wins desc, name), '[]'::json)
  from (select name, wins from jemrix_wins where wins > 0 order by wins desc limit 20) t;
$$;

-- Aufräumen (höchstens alle 5 s, nie blockierend): offene Spiele verfallen nach 2 Minuten, Wartende ohne
-- Lebenszeichen (45 s) fliegen raus, laufende Spiele ohne Lebenszeichen werden abgeschlossen (Sieg wird vergeben).
alter table public.jemrix_meta add column if not exists mp_cleaned_at timestamptz;
create or replace function public.mp_cleanup()
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare v uuid;
begin
  if not pg_try_advisory_xact_lock(471100) then return; end if;
  if (select mp_cleaned_at from jemrix_meta where id = 1) > now() - interval '5 seconds' then return; end if;
  update jemrix_meta set mp_cleaned_at = now() where id = 1;
  -- Räume immer zuerst sperren (gleiche Reihenfolge wie mp_sync), belegte überspringen
  for v in select id from jemrix_rooms where status = 'open' order by id for update skip locked loop
    if (select created_at from jemrix_rooms where id = v) < now() - interval '2 minutes'
       or not exists (select 1 from jemrix_room_players p join jemrix_rooms r on r.id = p.room_id
                      where p.room_id = v and p.device = r.host_device and p.updated_at > now() - interval '45 seconds') then
      update jemrix_rooms set status = 'closed' where id = v;
    else
      delete from jemrix_room_players p using jemrix_rooms r
       where r.id = v and p.room_id = v and p.device <> r.host_device and p.updated_at < now() - interval '45 seconds';
    end if;
  end loop;
  for v in select id from jemrix_rooms where status = 'playing' and starts_at < now() - interval '45 seconds' order by id for update skip locked loop
    perform mp_finalize(v);
  end loop;
  update jemrix_rooms set status = 'closed' where status = 'playing' and starts_at < now() - interval '2 hours';
  delete from jemrix_rooms where created_at < now() - interval '2 days';
end;
$$;

-- Spiel abschließen, wenn alle fertig sind (wer 45 s nichts sendet, gilt als fertig). Sieger bekommt einen Sieg.
create or replace function public.mp_finalize(p_room uuid)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare r jemrix_rooms; v_max integer;
begin
  select * into r from jemrix_rooms where id = p_room;
  if r.status <> 'playing' or r.starts_at > now() then return; end if;
  if exists (select 1 from jemrix_room_players where room_id = p_room and not done
             and updated_at > greatest(now() - interval '45 seconds', r.starts_at - interval '45 seconds')) then
    return;
  end if;
  update jemrix_rooms set status = 'done', finished_at = now() where id = p_room and status = 'playing';
  if not found then return; end if;
  select max(score) into v_max from jemrix_room_players where room_id = p_room;
  if coalesce(v_max, 0) > 0 then
    insert into jemrix_wins (name_key, name, wins)
      select name_key, name, 1 from jemrix_room_players where room_id = p_room and score = v_max
    on conflict (name_key) do update set wins = jemrix_wins.wins + 1, name = excluded.name, updated_at = now();
  end if;
end;
$$;

create or replace function public.mp_room_json(p_room uuid, p_device text)
returns json language sql stable security definer set search_path = public, pg_temp as $$
  select json_build_object(
    'ok', true,
    'now', floor(extract(epoch from clock_timestamp()) * 1000),
    'room', (select json_build_object('id', id, 'size', size, 'seed', seed, 'host', host, 'status', status,
                                      'starts_at', floor(extract(epoch from starts_at) * 1000), 'rematch', rematch)
             from jemrix_rooms where id = p_room),
    'me', exists (select 1 from jemrix_room_players where room_id = p_room and device = p_device),
    'players', coalesce((select json_agg(json_build_object(
                  'name', name, 'me', device = p_device, 'score', score, 'done', done, 'state', state,
                  'age', floor(extract(epoch from (now() - updated_at)))) order by joined_at)
                from jemrix_room_players where room_id = p_room), '[]'::json),
    'wins', mp_wins_json()
  );
$$;

-- Offene Spiele (für „Jens wartet – mitspielen?“) und Siegerliste
create or replace function public.mp_lobby(p_code text)
returns json language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if not mp_code_ok(p_code) then return json_build_object('ok', false, 'error', 'Falscher Familien-Code'); end if;
  perform mp_cleanup();
  return json_build_object('ok', true,
    'rooms', coalesce((select json_agg(json_build_object('id', r.id, 'size', r.size, 'host', r.host,
                 'players', (select coalesce(json_agg(p.name order by p.joined_at), '[]'::json) from jemrix_room_players p where p.room_id = r.id))
               order by r.created_at desc)
             from jemrix_rooms r where r.status = 'open'), '[]'::json),
    'wins', mp_wins_json());
end;
$$;

create or replace function public.mp_join(p_code text, p_room uuid, p_device text, p_name text)
returns json language plpgsql security definer set search_path = public, pg_temp as $$
declare r jemrix_rooms; v_name text := mp_clean_name(p_name); v_n integer;
begin
  if not mp_code_ok(p_code) then return json_build_object('ok', false, 'error', 'Falscher Familien-Code'); end if;
  if char_length(v_name) < 2 or char_length(coalesce(p_device, '')) not between 8 and 64 then
    return json_build_object('ok', false, 'error', 'Bitte mindestens 2 Buchstaben eingeben.');
  end if;
  perform mp_cleanup();
  select * into r from jemrix_rooms where id = p_room for update;
  if not found or r.status <> 'open' then return json_build_object('ok', false, 'error', 'Dieses Spiel gibt es nicht mehr.'); end if;
  if exists (select 1 from jemrix_room_players where room_id = p_room and name_key = lower(v_name) and device <> p_device) then
    return json_build_object('ok', false, 'error', (select name from jemrix_room_players where room_id = p_room and name_key = lower(v_name)) || ' spielt schon mit.');
  end if;
  if exists (select 1 from jemrix_room_players where room_id = p_room and device = p_device) then
    update jemrix_room_players set name = v_name, name_key = lower(v_name), updated_at = now() where room_id = p_room and device = p_device;
    update jemrix_rooms set host = v_name where id = p_room and host_device = p_device;
  else
    if (select count(*) from jemrix_room_players where room_id = p_room) >= r.size then
      return json_build_object('ok', false, 'error', 'Das Spiel ist schon voll.');
    end if;
    -- in anderen offenen Spielen abmelden
    delete from jemrix_room_players p using jemrix_rooms o where p.room_id = o.id and o.status = 'open' and p.device = p_device and o.id <> p_room;
    update jemrix_rooms set status = 'closed' where status = 'open' and host_device = p_device and id <> p_room;
    insert into jemrix_room_players (room_id, device, name_key, name) values (p_room, p_device, lower(v_name), v_name);
  end if;
  select count(*) into v_n from jemrix_room_players where room_id = p_room;
  if v_n >= r.size then
    update jemrix_rooms set status = 'playing', starts_at = now() + interval '4 seconds' where id = p_room;
  end if;
  return mp_room_json(p_room, p_device);
end;
$$;

create or replace function public.mp_create(p_code text, p_device text, p_name text, p_size integer)
returns json language plpgsql security definer set search_path = public, pg_temp as $$
declare v_id uuid; v_name text := mp_clean_name(p_name);
begin
  if not mp_code_ok(p_code) then return json_build_object('ok', false, 'error', 'Falscher Familien-Code'); end if;
  if p_size is null or p_size not between 2 and 3 or char_length(v_name) < 2 or char_length(coalesce(p_device, '')) not between 8 and 64 then
    return json_build_object('ok', false, 'error', 'Ungültige Daten');
  end if;
  perform mp_cleanup();
  if (select count(*) from jemrix_rooms where status = 'open' and host_device <> p_device) >= 5 then
    return json_build_object('ok', false, 'error', 'Gerade sind zu viele Spiele offen.');
  end if;
  delete from jemrix_room_players p using jemrix_rooms o where p.room_id = o.id and o.status = 'open' and p.device = p_device;
  update jemrix_rooms set status = 'closed' where status = 'open' and host_device = p_device;
  insert into jemrix_rooms (size, seed, host, host_device)
    values (p_size, floor(random() * 2147483646)::integer + 1, v_name, p_device) returning id into v_id;
  insert into jemrix_room_players (room_id, device, name_key, name) values (v_id, p_device, lower(v_name), v_name);
  return mp_room_json(v_id, p_device);
end;
$$;

-- Lebenszeichen + eigener Spielstand; liefert den Stand aller Mitspieler.
-- p_state: {"g": "64 Zeichen Feld", "s": Punkte, "m": Turbo-Faktor, "d": fertig}
create or replace function public.mp_sync(p_code text, p_room uuid, p_device text, p_state json)
returns json language plpgsql security definer set search_path = public, pg_temp as $$
declare r jemrix_rooms; v_g text; v_s integer; v_m integer; v_d boolean; v_num numeric;
begin
  if not mp_code_ok(p_code) then return json_build_object('ok', false, 'error', 'Falscher Familien-Code'); end if;
  select * into r from jemrix_rooms where id = p_room for update;
  if not found then return json_build_object('ok', false, 'error', 'Dieses Spiel gibt es nicht mehr.'); end if;
  if not exists (select 1 from jemrix_room_players where room_id = p_room and device = p_device) then
    return json_build_object('ok', false, 'gone', true, 'error', 'Du bist nicht mehr dabei.');
  end if;
  if p_state is not null and json_typeof(p_state) = 'object' and r.status = 'playing' then
    v_g := left(regexp_replace(coalesce(p_state->>'g', ''), '[^.1-7]', '', 'g'), 64);
    begin v_num := (p_state->>'s')::numeric; exception when others then v_num := 0; end;
    if v_num is null or v_num = 'NaN'::numeric or v_num < 0 then v_num := 0; end if;
    v_s := least(round(v_num), 250000)::integer;
    begin v_m := least(greatest(coalesce((p_state->>'m')::integer, 1), 1), 9); exception when others then v_m := 1; end;
    v_d := coalesce((p_state->>'d') = 'true', false);
    update jemrix_room_players
       set state = json_build_object('g', v_g, 's', v_s, 'm', v_m, 'd', done or v_d)::jsonb,
           score = greatest(score, v_s), done = done or v_d, updated_at = now()
     where room_id = p_room and device = p_device and not done;
  else
    update jemrix_room_players set updated_at = now() where room_id = p_room and device = p_device and not done;
  end if;
  perform mp_finalize(p_room);
  return mp_room_json(p_room, p_device);
end;
$$;

-- Wartebereich verlassen bzw. aufgeben
create or replace function public.mp_leave(p_code text, p_room uuid, p_device text)
returns json language plpgsql security definer set search_path = public, pg_temp as $$
declare r jemrix_rooms;
begin
  if not mp_code_ok(p_code) then return json_build_object('ok', false, 'error', 'Falscher Familien-Code'); end if;
  select * into r from jemrix_rooms where id = p_room for update;
  if not found then return json_build_object('ok', true); end if;
  if r.status = 'open' then
    delete from jemrix_room_players where room_id = p_room and device = p_device;
    if r.host_device = p_device then update jemrix_rooms set status = 'closed' where id = p_room; end if;
  elsif r.status = 'playing' then
    update jemrix_room_players set done = true, state = jsonb_set(state, '{d}', 'true'::jsonb), updated_at = now()
     where room_id = p_room and device = p_device;
    perform mp_finalize(p_room);
  end if;
  return json_build_object('ok', true);
end;
$$;

-- Revanche: der Erste eröffnet ein neues Spiel mit gleicher Spielerzahl, die anderen treten bei
create or replace function public.mp_rematch(p_code text, p_room uuid, p_device text)
returns json language plpgsql security definer set search_path = public, pg_temp as $$
declare r jemrix_rooms; v_name text; v_new uuid;
begin
  if not mp_code_ok(p_code) then return json_build_object('ok', false, 'error', 'Falscher Familien-Code'); end if;
  select * into r from jemrix_rooms where id = p_room for update;
  if not found or r.status <> 'done' then return json_build_object('ok', false, 'error', 'Revanche ist noch nicht möglich.'); end if;
  select name into v_name from jemrix_room_players where room_id = p_room and device = p_device;
  if v_name is null then return json_build_object('ok', false, 'error', 'Du warst nicht dabei.'); end if;
  if r.rematch is not null and exists (select 1 from jemrix_rooms where id = r.rematch and status = 'open') then
    return mp_join(p_code, r.rematch, p_device, v_name);
  end if;
  if r.rematch is not null and exists (select 1 from jemrix_rooms where id = r.rematch and status in ('playing','done')) then
    return json_build_object('ok', false, 'error', 'Die Revanche läuft schon ohne dich.');
  end if;
  delete from jemrix_room_players p using jemrix_rooms o where p.room_id = o.id and o.status = 'open' and p.device = p_device;
  update jemrix_rooms set status = 'closed' where status = 'open' and host_device = p_device;
  insert into jemrix_rooms (size, seed, host, host_device)
    values (r.size, floor(random() * 2147483646)::integer + 1, v_name, p_device) returning id into v_new;
  insert into jemrix_room_players (room_id, device, name_key, name) values (v_new, p_device, lower(v_name), v_name);
  update jemrix_rooms set rematch = v_new where id = p_room;
  return mp_room_json(v_new, p_device);
end;
$$;

revoke all on function public.mp_clean_name(text), public.mp_code_ok(text), public.mp_wins_json(), public.mp_cleanup(),
  public.mp_finalize(uuid), public.mp_room_json(uuid, text) from public, anon, authenticated;
revoke all on function public.mp_lobby(text), public.mp_join(text, uuid, text, text), public.mp_create(text, text, text, integer),
  public.mp_sync(text, uuid, text, json), public.mp_leave(text, uuid, text), public.mp_rematch(text, uuid, text) from public, authenticated;
grant execute on function public.mp_lobby(text), public.mp_join(text, uuid, text, text), public.mp_create(text, text, text, integer),
  public.mp_sync(text, uuid, text, json), public.mp_leave(text, uuid, text), public.mp_rematch(text, uuid, text) to anon;

-- Siege zurücksetzen (nur im SQL Editor):  delete from jemrix_wins;
