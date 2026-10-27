-- Spielzeit je Spieler seit dem letzten Zurücksetzen der Highscore-Liste (JJE_blocks und JJE_mahjong)
-- Einmal komplett im Supabase SQL Editor ausführen. Bestehende Highscores bleiben erhalten (Spielzeit startet bei 0).
-- Beim Zurücksetzen der Liste (select reset_scores(); bzw. select reset_scores_mah();) wird die Spielzeit mit gelöscht.

-- ===== jemrix_scores =====
alter table public.jemrix_scores add column if not exists play_seconds integer not null default 0 check (play_seconds >= 0);

create or replace function public.get_scores()
returns json
language sql
security definer
set search_path = public, pg_temp
as $$
  select json_build_object(
    'ok', true,
    'epoch', (select epoch from jemrix_meta where id = 1),
    'players', coalesce((select json_agg(json_build_object('name', name, 'score', score, 'secs', play_seconds) order by score desc)
                         from (select name, score, play_seconds from jemrix_scores where score > 0 order by score desc limit 50) t), '[]'::json)
  );
$$;

-- Ergebnisse eintragen: pro Name bleibt der beste Wert; die Spielzeit (secs) wird aufaddiert.
-- Einträge mit score 0 tragen nur Spielzeit nach (z. B. verlorenes Level).
create or replace function public.submit_scores(p_code text, p_entries json)
returns json
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  e json;
  v_name text;
  v_score integer;
  v_secs integer;
  v_num numeric;
  v_min integer;
begin
  if p_code is distinct from (select family_code from jemrix_meta where id = 1) then
    return json_build_object('ok', false, 'error', 'Falscher Familien-Code');
  end if;
  if json_typeof(p_entries) <> 'array' or json_array_length(p_entries) > 50 then
    return json_build_object('ok', false, 'error', 'Ungültige Daten');
  end if;
  for e in select * from json_array_elements(p_entries) loop
    if json_typeof(e) <> 'object' then continue; end if;
    v_name := regexp_replace(normalize(coalesce(e->>'name', ''), NFKC), '[\u0000-\u001F\u007F\u00AD\u200B-\u200F\u202A-\u202E\u2060-\u2064\uFEFF]', '', 'g');
    v_name := btrim(left(btrim(regexp_replace(v_name, '\s+', ' ', 'g')), 20));
    begin
      v_num := (e->>'score')::numeric;
    exception when others then
      v_num := 0;
    end;
    if v_num is null or v_num = 'NaN'::numeric or v_num < 0 then v_num := 0; end if;
    v_score := least(round(v_num), 250000)::integer;
    begin
      v_num := (e->>'secs')::numeric;
    exception when others then
      v_num := 0;
    end;
    if v_num is null or v_num = 'NaN'::numeric or v_num < 0 then v_num := 0; end if;
    v_secs := least(round(v_num), 14400)::integer;   -- höchstens 4 Stunden pro Meldung
    -- nur lateinische Buchstaben: keine Doppelgänger wie „Еmma“ mit kyrillischem E, kein HTML
    if (v_score <= 0 and v_secs <= 0) or not coalesce(v_name ~ '^[A-Za-zÀ-ÖØ-öø-ÿ][A-Za-zÀ-ÖØ-öø-ÿ'' .-]{1,19}$', false) then continue; end if;
    if not exists (select 1 from jemrix_scores where name_key = lower(v_name)) then
      if (select count(*) from jemrix_scores) >= 40 then
        -- Liste voll: den schwächsten Eintrag ersetzen, statt neue Namen für immer auszusperren
        if v_score <= 0 then continue; end if;
        select min(score) into v_min from jemrix_scores;
        if v_score <= v_min then continue; end if;
        delete from jemrix_scores where name_key = (select name_key from jemrix_scores order by score asc, updated_at asc limit 1);
      end if;
    end if;
    insert into jemrix_scores (name_key, name, score, play_seconds)
    values (lower(v_name), v_name, v_score, v_secs)
    on conflict (name_key) do update
      set score = greatest(jemrix_scores.score, excluded.score),
          play_seconds = least(jemrix_scores.play_seconds + excluded.play_seconds, 2000000000),
          name = case when excluded.score > jemrix_scores.score then excluded.name else jemrix_scores.name end,
          updated_at = now();
  end loop;
  return get_scores();
end;
$$;

revoke all on function public.get_scores() from public, authenticated;
revoke all on function public.submit_scores(text, json) from public, authenticated;
grant execute on function public.get_scores() to anon;
grant execute on function public.submit_scores(text, json) to anon;

-- ===== jenmah_scores =====
alter table public.jenmah_scores add column if not exists play_seconds integer not null default 0 check (play_seconds >= 0);

create or replace function public.get_scores_mah()
returns json
language sql
security definer
set search_path = public, pg_temp
as $$
  select json_build_object(
    'ok', true,
    'epoch', (select epoch from jenmah_meta where id = 1),
    'players', coalesce((select json_agg(json_build_object('name', name, 'score', score, 'secs', play_seconds) order by score desc)
                         from (select name, score, play_seconds from jenmah_scores where score > 0 order by score desc limit 50) t), '[]'::json)
  );
$$;

-- Ergebnisse eintragen: pro Name bleibt der beste Wert; die Spielzeit (secs) wird aufaddiert.
-- Einträge mit score 0 tragen nur Spielzeit nach (z. B. verlorenes Level).
create or replace function public.submit_scores_mah(p_code text, p_entries json)
returns json
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  e json;
  v_name text;
  v_score integer;
  v_secs integer;
  v_num numeric;
  v_min integer;
begin
  if p_code is distinct from (select family_code from jemrix_meta where id = 1) then
    return json_build_object('ok', false, 'error', 'Falscher Familien-Code');
  end if;
  if json_typeof(p_entries) <> 'array' or json_array_length(p_entries) > 50 then
    return json_build_object('ok', false, 'error', 'Ungültige Daten');
  end if;
  for e in select * from json_array_elements(p_entries) loop
    if json_typeof(e) <> 'object' then continue; end if;
    v_name := regexp_replace(normalize(coalesce(e->>'name', ''), NFKC), '[\u0000-\u001F\u007F\u00AD\u200B-\u200F\u202A-\u202E\u2060-\u2064\uFEFF]', '', 'g');
    v_name := btrim(left(btrim(regexp_replace(v_name, '\s+', ' ', 'g')), 20));
    begin
      v_num := (e->>'score')::numeric;
    exception when others then
      v_num := 0;
    end;
    if v_num is null or v_num = 'NaN'::numeric or v_num < 0 then v_num := 0; end if;
    v_score := least(round(v_num), 250000)::integer;
    begin
      v_num := (e->>'secs')::numeric;
    exception when others then
      v_num := 0;
    end;
    if v_num is null or v_num = 'NaN'::numeric or v_num < 0 then v_num := 0; end if;
    v_secs := least(round(v_num), 14400)::integer;   -- höchstens 4 Stunden pro Meldung
    -- nur lateinische Buchstaben: keine Doppelgänger wie „Еmma“ mit kyrillischem E, kein HTML
    if (v_score <= 0 and v_secs <= 0) or not coalesce(v_name ~ '^[A-Za-zÀ-ÖØ-öø-ÿ][A-Za-zÀ-ÖØ-öø-ÿ'' .-]{1,19}$', false) then continue; end if;
    if not exists (select 1 from jenmah_scores where name_key = lower(v_name)) then
      if (select count(*) from jenmah_scores) >= 40 then
        -- Liste voll: den schwächsten Eintrag ersetzen, statt neue Namen für immer auszusperren
        if v_score <= 0 then continue; end if;
        select min(score) into v_min from jenmah_scores;
        if v_score <= v_min then continue; end if;
        delete from jenmah_scores where name_key = (select name_key from jenmah_scores order by score asc, updated_at asc limit 1);
      end if;
    end if;
    insert into jenmah_scores (name_key, name, score, play_seconds)
    values (lower(v_name), v_name, v_score, v_secs)
    on conflict (name_key) do update
      set score = greatest(jenmah_scores.score, excluded.score),
          play_seconds = least(jenmah_scores.play_seconds + excluded.play_seconds, 2000000000),
          name = case when excluded.score > jenmah_scores.score then excluded.name else jenmah_scores.name end,
          updated_at = now();
  end loop;
  return get_scores_mah();
end;
$$;

revoke all on function public.get_scores_mah() from public, authenticated;
revoke all on function public.submit_scores_mah(text, json) from public, authenticated;
grant execute on function public.get_scores_mah() to anon;
grant execute on function public.submit_scores_mah(text, json) to anon;
