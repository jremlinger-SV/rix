-- JJE_snake · eigene Highscore-Liste, getrennt nach Schwierigkeit (Leicht, Mittel, Schwer)
-- Einmal komplett im Supabase SQL Editor ausführen. Die Listen von JJE_blocks, JJE_mahjong, JJE_tetris und JJE_arki bleiben unverändert.
-- Baut auf supabase-haertung.sql auf (nutzt Familien-Code-Prüfung jje_guard und jje_seen).

create table if not exists public.jjesnk_scores (
  mode         text not null check (mode in ('leicht','mittel','schwer')),
  name_key     text not null,
  name         text not null,
  score        integer not null default 0 check (score between 0 and 10000000),
  play_seconds integer not null default 0 check (play_seconds >= 0),
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  primary key (mode, name_key)
);
create table if not exists public.jjesnk_meta (
  id       integer primary key default 1 check (id = 1),
  epoch    integer not null default 1,
  reset_at timestamptz not null default now()
);
insert into public.jjesnk_meta (id, epoch) values (1, 1) on conflict (id) do nothing;

alter table public.jjesnk_scores enable row level security;
alter table public.jjesnk_meta   enable row level security;
revoke all on public.jjesnk_scores from anon, authenticated;
revoke all on public.jjesnk_meta   from anon, authenticated;

-- Lesen: je Schwierigkeit die besten 50
create or replace function public.get_scores_snk()
returns json language sql security definer set search_path = public, pg_temp as $$
  select json_build_object(
    'ok', true,
    'epoch', (select epoch from jjesnk_meta where id = 1),
    'reset', (select (extract(epoch from reset_at) * 1000)::bigint from jjesnk_meta where id = 1),
    'players', coalesce((select json_agg(json_build_object('mode', mode, 'name', name, 'score', score, 'secs', play_seconds) order by mode, score desc)
                         from (select mode, name, score, play_seconds,
                                      row_number() over (partition by mode order by score desc) as rn
                               from jjesnk_scores where score > 0) t where rn <= 50), '[]'::json));
$$;

-- Eintragen: pro Name und Schwierigkeit bleibt der beste Wert, Spielzeit wird aufaddiert (jede Meldung nur einmal)
-- höchstens 5 neue Namen pro Tag und Schwierigkeit, höchstens 40 Namen je Schwierigkeit, Punkte bis 9.999.999
create or replace function public.jje_submit_snk(p_entries json)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare
  e json; v_mode text; v_name text; v_key text; v_id text; v_num numeric; v_score integer; v_secs integer;
  v_cnt integer; v_new integer; v_min integer; v_rows integer;
begin
  if json_typeof(p_entries) is distinct from 'array' or json_array_length(p_entries) > 50 then
    raise exception 'Ungültige Daten' using errcode = '22023';
  end if;
  for e in select * from json_array_elements(p_entries) loop
    if json_typeof(e) <> 'object' then continue; end if;
    v_mode := e->>'mode';
    if v_mode is null or v_mode not in ('leicht','mittel','schwer') then continue; end if;
    v_name := left(coalesce(e->>'name', ''), 60);
    v_name := regexp_replace(normalize(v_name, NFKC), '[\u0001-\u001F\u007F­​-‏‪-‮⁠-⁤﻿]', '', 'g');
    v_name := btrim(left(btrim(regexp_replace(v_name, '\s+', ' ', 'g')), 20));
    v_key := lower(v_name);
    if not coalesce(v_name ~ '^[A-Za-zÀ-ÖØ-öø-ÿ][A-Za-zÀ-ÖØ-öø-ÿ'' .-]{1,19}$', false) then continue; end if;
    begin v_num := (e->>'score')::numeric; exception when others then v_num := 0; end;
    if v_num is null or v_num = 'NaN'::numeric or v_num < 0 then v_num := 0; end if;
    v_score := least(round(v_num), 9999999)::integer;
    begin v_num := (e->>'secs')::numeric; exception when others then v_num := 0; end;
    if v_num is null or v_num = 'NaN'::numeric or v_num < 0 then v_num := 0; end if;
    v_secs := least(round(v_num), 14400)::integer;
    v_id := left(coalesce(e->>'id', ''), 64);
    if v_secs > 0 and v_id <> '' then
      insert into jje_seen (id) values ('n:' || v_id) on conflict do nothing;
      get diagnostics v_rows = row_count;
      if v_rows = 0 then v_secs := 0; end if;
    end if;
    if v_score <= 0 and v_secs <= 0 then continue; end if;
    if not exists (select 1 from jjesnk_scores where mode = v_mode and name_key = v_key) then
      if v_score <= 0 then continue; end if;   -- neue Namen nur mit Ergebnis
      select count(*), count(*) filter (where created_at > now() - interval '1 day') into v_cnt, v_new from jjesnk_scores where mode = v_mode;
      if v_new >= 5 then continue; end if;
      if v_cnt >= 40 then
        select min(score) into v_min from jjesnk_scores where mode = v_mode;
        if v_score <= v_min then continue; end if;
        delete from jjesnk_scores where mode = v_mode and name_key =
          (select name_key from jjesnk_scores where mode = v_mode order by score asc, updated_at asc limit 1);
      end if;
    end if;
    insert into jjesnk_scores (mode, name_key, name, score, play_seconds) values (v_mode, v_key, v_name, v_score, v_secs)
    on conflict (mode, name_key) do update
      set score = greatest(jjesnk_scores.score, excluded.score),
          play_seconds = least(jjesnk_scores.play_seconds + excluded.play_seconds, 2000000000),
          name = case when excluded.score > jjesnk_scores.score then excluded.name else jjesnk_scores.name end,
          updated_at = now();
  end loop;
end $$;
revoke all on function public.jje_submit_snk(json) from public, anon, authenticated;

create or replace function public.submit_scores_snk(p_code text, p_entries json)
returns json language plpgsql security definer set search_path = public, pg_temp as $$
begin perform jje_guard(p_code); perform jje_submit_snk(p_entries); return get_scores_snk(); end $$;

-- Liste zurücksetzen (nur hier im SQL Editor):  select reset_scores_snk();
create or replace function public.reset_scores_snk()
returns void language sql security definer set search_path = public, pg_temp as $$
  delete from jjesnk_scores;
  update jjesnk_meta set epoch = epoch + 1, reset_at = now() where id = 1;
$$;

revoke all on function public.reset_scores_snk() from public, anon, authenticated;
revoke all on function public.get_scores_snk(), public.submit_scores_snk(text, json) from public, authenticated;
grant execute on function public.get_scores_snk(), public.submit_scores_snk(text, json) to anon;

-- Monats-Reset (supabase-monatsreset.sql) um JJE_snake erweitern: am 1. jedes Monats um 0:01 Uhr auch diese Liste leeren
create or replace function public.jje_monthly_reset()
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare
  b timestamp := now() at time zone 'Europe/Berlin';
  m text := to_char(b, 'YYYY-MM');
begin
  if extract(day from b) <> 1 or extract(hour from b) <> 0 then return; end if;
  if exists (select 1 from jje_monthly_reset_log where month = m) then return; end if;
  insert into jje_monthly_reset_log (month) values (m);
  perform reset_scores();
  perform reset_scores_mah();
  perform reset_scores_tet();
  perform reset_scores_ark();
  perform reset_scores_snk();
end $$;
revoke all on function public.jje_monthly_reset() from public, anon, authenticated;
