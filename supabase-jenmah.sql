-- jenMah · eigene Highscore-Liste (getrennt von Jemrix)
-- Einmal komplett im Supabase SQL Editor ausführen. Jemrix-Highscores bleiben unverändert.
-- Familien-Code: derselbe wie bei Jemrix (Tabelle jemrix_meta).

create table if not exists public.jenmah_scores (
  name_key   text primary key,
  name       text not null,
  score      integer not null check (score between 0 and 10000000),
  updated_at timestamptz not null default now()
);
create table if not exists public.jenmah_meta (
  id    integer primary key default 1 check (id = 1),
  epoch integer not null default 1
);
insert into public.jenmah_meta (id, epoch) values (1, 1) on conflict (id) do nothing;

alter table public.jenmah_scores enable row level security;
alter table public.jenmah_meta   enable row level security;
revoke all on public.jenmah_scores from anon, authenticated;
revoke all on public.jenmah_meta   from anon, authenticated;

create or replace function public.get_scores_mah()
returns json
language sql
security definer
set search_path = public, pg_temp
as $$
  select json_build_object(
    'ok', true,
    'epoch', (select epoch from jenmah_meta where id = 1),
    'players', coalesce((select json_agg(json_build_object('name', name, 'score', score) order by score desc)
                         from (select name, score from jenmah_scores order by score desc limit 50) t), '[]'::json)
  );
$$;

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
    v_score := least(round(v_num), 250000)::integer;   -- realistisch erreichbares Maximum
    -- nur lateinische Buchstaben: keine Doppelgänger wie „Еmma“ mit kyrillischem E, kein HTML
    if v_score <= 0 or not coalesce(v_name ~ '^[A-Za-zÀ-ÖØ-öø-ÿ][A-Za-zÀ-ÖØ-öø-ÿ'' .-]{1,19}$', false) then continue; end if;
    if not exists (select 1 from jenmah_scores where name_key = lower(v_name))
       and (select count(*) from jenmah_scores) >= 40 then
      -- Liste voll: den schwächsten Eintrag ersetzen, statt neue Namen für immer auszusperren
      select min(score) into v_min from jenmah_scores;
      if v_score <= v_min then continue; end if;
      delete from jenmah_scores where name_key = (select name_key from jenmah_scores order by score asc, updated_at asc limit 1);
    end if;
    insert into jenmah_scores (name_key, name, score)
    values (lower(v_name), v_name, v_score)
    on conflict (name_key) do update
      set score = greatest(jenmah_scores.score, excluded.score),
          name = case when excluded.score > jenmah_scores.score then excluded.name else jenmah_scores.name end,
          updated_at = now();
  end loop;
  return get_scores_mah();
end;
$$;

-- Liste zurücksetzen (nur hier im SQL Editor):   select reset_scores_mah();
create or replace function public.reset_scores_mah()
returns void
language sql
security definer
set search_path = public, pg_temp
as $$
  delete from jenmah_scores;
  update jenmah_meta set epoch = epoch + 1 where id = 1;
$$;

revoke all on function public.reset_scores_mah() from anon, authenticated, public;
revoke all on function public.get_scores_mah() from public, authenticated;
revoke all on function public.submit_scores_mah(text, json) from public, authenticated;
grant execute on function public.get_scores_mah() to anon;
grant execute on function public.submit_scores_mah(text, json) to anon;
