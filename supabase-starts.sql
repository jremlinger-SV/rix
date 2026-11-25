-- Jemrix · Spielstarts zählen (familienweit, alle Spiele)
-- Einmal komplett im Supabase SQL Editor ausführen. Highscore-Listen bleiben unverändert, der Wochen-Reset betrifft die Zählung nicht.
-- Baut auf supabase-haertung.sql auf (nutzt Familien-Code-Prüfung jje_guard und jje_seen).

create table if not exists public.jje_plays (
  game   text primary key check (game in ('blocks','mah','tet','ark','snk','maz','sol','sch','jmp')),
  starts bigint not null default 0 check (starts >= 0),
  updated_at timestamptz not null default now()
);
alter table public.jje_plays enable row level security;
revoke all on public.jje_plays from anon, authenticated;

-- Lesen: Starts je Spiel
create or replace function public.get_plays()
returns json language sql security definer set search_path = public, pg_temp as $$
  select json_build_object('ok', true,
    'plays', coalesce((select json_object_agg(game, starts) from jje_plays), '{}'::json));
$$;

-- Melden: jede Meldung (id) zählt genau einmal, höchstens 200 je Aufruf
create or replace function public.add_plays(p_code text, p_entries json)
returns json language plpgsql security definer set search_path = public, pg_temp as $$
declare e json; v_game text; v_id text; v_rows integer;
begin
  perform jje_guard(p_code);
  if json_typeof(p_entries) is distinct from 'array' or json_array_length(p_entries) > 200 then
    raise exception 'Ungültige Daten' using errcode = '22023';
  end if;
  for e in select * from json_array_elements(p_entries) loop
    if json_typeof(e) <> 'object' then continue; end if;
    v_game := e->>'g';
    if v_game is null or v_game not in ('blocks','mah','tet','ark','snk','maz','sol','sch','jmp') then continue; end if;
    v_id := left(coalesce(e->>'id', ''), 64);
    if v_id = '' then continue; end if;
    insert into jje_seen (id) values ('p:' || v_id) on conflict do nothing;
    get diagnostics v_rows = row_count;
    if v_rows = 0 then continue; end if;
    insert into jje_plays (game, starts) values (v_game, 1)
      on conflict (game) do update set starts = jje_plays.starts + 1, updated_at = now();
  end loop;
  return get_plays();
end $$;

revoke all on function public.get_plays(), public.add_plays(text, json) from public, authenticated;
grant execute on function public.get_plays(), public.add_plays(text, json) to anon;
