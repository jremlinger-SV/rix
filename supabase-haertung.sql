-- JJE · Absicherung der Highscore-Listen (27.10.2026)
-- Einmal komplett im Supabase SQL Editor ausführen. Bestehende Highscores und Spielzeiten bleiben erhalten.
-- Baut auf supabase-spielzeit.sql auf. Danach ist dies der aktuelle Stand aller Listen-Funktionen.

-- 1) Mehrspieler-Reste entfernen (das Spiel nutzt sie nicht mehr)
drop function if exists public.mp_lobby(text), public.mp_join(text, uuid, text, text, text),
  public.mp_create(text, text, text, integer, text), public.mp_sync(text, uuid, text, json),
  public.mp_leave(text, uuid, text), public.mp_rematch(text, uuid, text, text),
  public.mp_room_json(uuid, text), public.mp_finalize(uuid), public.mp_cleanup(),
  public.mp_wins_json(), public.mp_code_ok(text), public.mp_clean_name(text), public.jemrix_name_ok(text);
drop table if exists public.jemrix_room_players, public.jemrix_rooms, public.jemrix_wins;
alter table public.jemrix_meta drop column if exists mp_cleaned_at;

-- 2) Hilfsdaten: Zeitpunkt des letzten Zurücksetzens, Aufrufbremse, bereits verbuchte Meldungen, neue Namen pro Tag
alter table public.jemrix_meta  add column if not exists reset_at timestamptz not null default now();
alter table public.jenmah_meta  add column if not exists reset_at timestamptz not null default now();
alter table public.jemrix_meta  add column if not exists rl_start timestamptz not null default now();
alter table public.jemrix_meta  add column if not exists rl_count integer not null default 0;
alter table public.jemrix_scores add column if not exists created_at timestamptz not null default now();
alter table public.jenmah_scores add column if not exists created_at timestamptz not null default now();
update public.jemrix_scores set created_at = '2000-01-01' where created_at > now() - interval '1 minute';
update public.jenmah_scores set created_at = '2000-01-01' where created_at > now() - interval '1 minute';

create table if not exists public.jje_seen (id text primary key, at timestamptz not null default now());
alter table public.jje_seen enable row level security;
revoke all on public.jje_seen from anon, authenticated;

-- 3) Prüfung vor jeder Meldung: Familien-Code (Fehler statt stiller Ablehnung, damit das Spiel seine Warteschlange behält)
--    und höchstens 60 Meldungen pro Minute für beide Spiele zusammen
create or replace function public.jje_guard(p_code text)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare m jemrix_meta;
begin
  select * into m from jemrix_meta where id = 1 for update;
  if p_code is distinct from m.family_code then
    raise exception 'Falscher Familien-Code' using errcode = '28000';
  end if;
  if m.rl_start < now() - interval '1 minute' then
    update jemrix_meta set rl_start = now(), rl_count = 1 where id = 1;
  elsif m.rl_count >= 60 then
    raise exception 'Zu viele Anfragen' using errcode = '53400';
  else
    update jemrix_meta set rl_count = rl_count + 1 where id = 1;
  end if;
  delete from jje_seen where at < now() - interval '60 days';
end $$;
revoke all on function public.jje_guard(text) from public, anon, authenticated;

-- 4) Gemeinsamer Eintrag für beide Listen
--    · pro Name bleibt der beste Wert, Spielzeit wird aufaddiert – jede Meldung (id) aber nur einmal
--    · höchstens 5 neue Namen pro Tag und Liste (Schutz gegen Spam-Namen), höchstens 40 Namen
--    · Grenzen: JJE_blocks 250000, JJE_mahjong Level 5000, Spielzeit 4 Std pro Meldung
create or replace function public.jje_submit(p_mah boolean, p_entries json)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare
  tbl text := case when p_mah then 'jenmah_scores' else 'jemrix_scores' end;
  e json; v_name text; v_key text; v_id text; v_num numeric; v_score integer; v_secs integer;
  v_exists boolean; v_cnt integer; v_new integer; v_min integer; v_rows integer;
begin
  if json_typeof(p_entries) is distinct from 'array' or json_array_length(p_entries) > 50 then
    raise exception 'Ungültige Daten' using errcode = '22023';
  end if;
  for e in select * from json_array_elements(p_entries) loop
    if json_typeof(e) <> 'object' then continue; end if;
    v_name := left(coalesce(e->>'name', ''), 60);
    v_name := regexp_replace(normalize(v_name, NFKC), '[\u0001-\u001F\u007F­​-‏‪-‮⁠-⁤﻿]', '', 'g');
    v_name := btrim(left(btrim(regexp_replace(v_name, '\s+', ' ', 'g')), 20));
    v_key := lower(v_name);
    -- nur lateinische Buchstaben: keine Doppelgänger wie „Еmma“ mit kyrillischem E, kein HTML
    if not coalesce(v_name ~ '^[A-Za-zÀ-ÖØ-öø-ÿ][A-Za-zÀ-ÖØ-öø-ÿ'' .-]{1,19}$', false) then continue; end if;
    begin v_num := (e->>'score')::numeric; exception when others then v_num := 0; end;
    if v_num is null or v_num = 'NaN'::numeric or v_num < 0 then v_num := 0; end if;
    v_score := least(round(v_num), case when p_mah then 5000 else 250000 end)::integer;
    begin v_num := (e->>'secs')::numeric; exception when others then v_num := 0; end;
    if v_num is null or v_num = 'NaN'::numeric or v_num < 0 then v_num := 0; end if;
    v_secs := least(round(v_num), 14400)::integer;
    -- dieselbe Meldung (z. B. erneut gesendet nach Funkloch) zählt ihre Spielzeit nur einmal
    v_id := left(coalesce(e->>'id', ''), 64);
    if v_secs > 0 and v_id <> '' then
      insert into jje_seen (id) values ((case when p_mah then 'm:' else 'b:' end) || v_id) on conflict do nothing;
      get diagnostics v_rows = row_count;
      if v_rows = 0 then v_secs := 0; end if;
    end if;
    if v_score <= 0 and v_secs <= 0 then continue; end if;
    execute format('select exists(select 1 from %I where name_key = $1)', tbl) into v_exists using v_key;
    if not v_exists then
      if v_score <= 0 then continue; end if;   -- neue Namen nur mit Ergebnis
      execute format('select count(*), count(*) filter (where created_at > now() - interval ''1 day'') from %I', tbl) into v_cnt, v_new;
      if v_new >= 5 then continue; end if;
      if v_cnt >= 40 then
        execute format('select min(score) from %I', tbl) into v_min;
        if v_score <= v_min then continue; end if;
        execute format('delete from %1$I where name_key = (select name_key from %1$I order by score asc, updated_at asc limit 1)', tbl);
      end if;
    end if;
    execute format($q$insert into %1$I (name_key, name, score, play_seconds) values ($1, $2, $3, $4)
      on conflict (name_key) do update
        set score = greatest(%1$I.score, excluded.score),
            play_seconds = least(%1$I.play_seconds + excluded.play_seconds, 2000000000),
            name = case when excluded.score > %1$I.score then excluded.name else %1$I.name end,
            updated_at = now()$q$, tbl)
      using v_key, v_name, v_score, v_secs;
  end loop;
end $$;
revoke all on function public.jje_submit(boolean, json) from public, anon, authenticated;

-- 5) Lesen (mit Zeitpunkt des letzten Zurücksetzens) und Eintragen
create or replace function public.get_scores()
returns json language sql security definer set search_path = public, pg_temp as $$
  select json_build_object(
    'ok', true,
    'epoch', (select epoch from jemrix_meta where id = 1),
    'reset', (select (extract(epoch from reset_at) * 1000)::bigint from jemrix_meta where id = 1),
    'players', coalesce((select json_agg(json_build_object('name', name, 'score', score, 'secs', play_seconds) order by score desc)
                         from (select name, score, play_seconds from jemrix_scores where score > 0 order by score desc limit 50) t), '[]'::json));
$$;
create or replace function public.get_scores_mah()
returns json language sql security definer set search_path = public, pg_temp as $$
  select json_build_object(
    'ok', true,
    'epoch', (select epoch from jenmah_meta where id = 1),
    'reset', (select (extract(epoch from reset_at) * 1000)::bigint from jenmah_meta where id = 1),
    'players', coalesce((select json_agg(json_build_object('name', name, 'score', score, 'secs', play_seconds) order by score desc)
                         from (select name, score, play_seconds from jenmah_scores where score > 0 order by score desc limit 50) t), '[]'::json));
$$;
create or replace function public.submit_scores(p_code text, p_entries json)
returns json language plpgsql security definer set search_path = public, pg_temp as $$
begin perform jje_guard(p_code); perform jje_submit(false, p_entries); return get_scores(); end $$;
create or replace function public.submit_scores_mah(p_code text, p_entries json)
returns json language plpgsql security definer set search_path = public, pg_temp as $$
begin perform jje_guard(p_code); perform jje_submit(true, p_entries); return get_scores_mah(); end $$;

-- 6) Zurücksetzen (nur hier im SQL Editor):  select reset_scores();  bzw.  select reset_scores_mah();
create or replace function public.reset_scores()
returns void language sql security definer set search_path = public, pg_temp as $$
  delete from jemrix_scores;
  update jemrix_meta set epoch = epoch + 1, reset_at = now() where id = 1;
$$;
create or replace function public.reset_scores_mah()
returns void language sql security definer set search_path = public, pg_temp as $$
  delete from jenmah_scores;
  update jenmah_meta set epoch = epoch + 1, reset_at = now() where id = 1;
$$;

revoke all on function public.reset_scores(), public.reset_scores_mah() from public, anon, authenticated;
revoke all on function public.submit_scores(text, json), public.submit_scores_mah(text, json),
  public.get_scores(), public.get_scores_mah() from public, authenticated;
grant execute on function public.submit_scores(text, json), public.submit_scores_mah(text, json),
  public.get_scores(), public.get_scores_mah() to anon;
