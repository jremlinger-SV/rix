-- Jemrix · gemeinsame Highscore-Liste
-- Einmalig im Supabase-Projekt ausführen: SQL Editor → New query → alles einfügen → Run.
-- Der Familien-Code unten muss mit "familyCode" in config.js übereinstimmen.

create table if not exists public.jemrix_scores (
  name_key   text primary key,               -- Name in Kleinbuchstaben (eindeutig)
  name       text not null,                  -- Name, wie er angezeigt wird
  score      integer not null check (score between 0 and 10000000),
  updated_at timestamptz not null default now()
);

create table if not exists public.jemrix_meta (
  id    integer primary key default 1 check (id = 1),
  epoch integer not null default 1,
  family_code text not null
);
insert into public.jemrix_meta (id, epoch, family_code)
values (1, 1, 'remlinger-familie')
on conflict (id) do nothing;

-- Direkter Zugriff auf die Tabellen ist gesperrt; das Spiel nutzt nur die beiden Funktionen unten.
alter table public.jemrix_scores enable row level security;
alter table public.jemrix_meta   enable row level security;
revoke all on public.jemrix_scores from anon, authenticated;
revoke all on public.jemrix_meta   from anon, authenticated;

-- Liste lesen: {"epoch": 1, "players": [{"name": "...", "score": 123}, ...]}
create or replace function public.get_scores()
returns json
language sql
security definer
set search_path = public
as $$
  select json_build_object(
    'ok', true,
    'epoch', (select epoch from jemrix_meta where id = 1),
    'players', coalesce((select json_agg(json_build_object('name', name, 'score', score) order by score desc)
                         from (select name, score from jemrix_scores order by score desc limit 50) t), '[]'::json)
  );
$$;

-- Ergebnisse eintragen: behält pro Name immer nur den besten Wert.
-- Schutz: unsichtbare Zeichen entfernt, nur lateinische Buchstaben, Werte gekappt, höchstens 40 Namen (schwächster fliegt raus).
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
    v_name := regexp_replace(normalize(coalesce(e->>'name', ''), NFKC), '[\u0000-\u001F\u007F­​-‏‪-‮⁠-⁤﻿]', '', 'g');
    v_name := btrim(left(btrim(regexp_replace(v_name, '\s+', ' ', 'g')), 20));
    begin
      v_num := (e->>'score')::numeric;
    exception when others then
      v_num := 0;
    end;
    if v_num is null or v_num = 'NaN'::numeric or v_num < 0 then v_num := 0; end if;
    v_score := least(round(v_num), 250000)::integer;   -- realistisch erreichbares Maximum
    -- nur lateinische Buchstaben: keine Doppelgänger wie „Еmma“ mit kyrillischem E, kein HTML
    if v_score <= 0 or not coalesce(v_name ~ '^[A-Za-zÀ-ÖØ-öø-ÿ][A-Za-zÀ-ÖØ-öø-ÿ'' .-]{1,19}$', false) then continue; end if;
    if not exists (select 1 from jemrix_scores where name_key = lower(v_name))
       and (select count(*) from jemrix_scores) >= 40 then
      -- Liste voll: den schwächsten Eintrag ersetzen, statt neue Namen für immer auszusperren
      select min(score) into v_min from jemrix_scores;
      if v_score <= v_min then continue; end if;
      delete from jemrix_scores where name_key = (select name_key from jemrix_scores order by score asc, updated_at asc limit 1);
    end if;
    insert into jemrix_scores (name_key, name, score)
    values (lower(v_name), v_name, v_score)
    on conflict (name_key) do update
      set score = greatest(jemrix_scores.score, excluded.score),
          name = case when excluded.score > jemrix_scores.score then excluded.name else jemrix_scores.name end,
          updated_at = now();
  end loop;
  return get_scores();
end;
$$;

-- Liste zurücksetzen (nur hier im SQL Editor ausführen, nicht aus dem Spiel erreichbar):
create or replace function public.reset_scores()
returns void
language sql
security definer
set search_path = public
as $$
  delete from jemrix_scores;
  update jemrix_meta set epoch = epoch + 1 where id = 1;
$$;
revoke all on function public.reset_scores() from anon, authenticated, public;

grant execute on function public.get_scores() to anon;
grant execute on function public.submit_scores(text, json) to anon;

-- Zum Zurücksetzen später einfach ausführen:   select reset_scores();
