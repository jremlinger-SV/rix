-- JJE · Highscores aller Spiele JEDEN FREITAG um 0:00 Uhr (deutsche Zeit) zurücksetzen – ersetzt den Monats-Reset
-- Einmalig im Supabase-Projekt ausführen: SQL Editor → New query → alles einfügen → Run.
-- Setzt außerdem JETZT einmal alle 8 Listen zurück (Blocks, Mahjong, Tetris, Arki, Snake, Maze, Solitaire, Chess).
-- Der Mahjong-Level-Fortschritt bleibt erhalten (liegt auf den iPhones, nicht in der Liste).
-- Die Apps merken den Reset an der erhöhten „epoch“ und leeren dann auch ihre Listen auf den iPhones.

create extension if not exists pg_cron;

-- alle Listen auf einmal zurücksetzen (auch für manuelle Resets: select public.jje_reset_all();)
create or replace function public.jje_reset_all()
returns void language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform reset_scores();        -- JJE_blocks
  perform reset_scores_mah();    -- JJE_mahjong
  perform reset_scores_tet();    -- JJE_tetris
  perform reset_scores_ark();    -- JJE_arki
  perform reset_scores_snk();    -- JJE_snake
  perform reset_scores_maz();    -- JJE_maze
  perform reset_scores_sol();    -- JJE_solitaire
  perform reset_scores_sch();    -- JJE_chess
end $$;
revoke all on function public.jje_reset_all() from public, anon, authenticated;

-- läuft stündlich zur vollen Stunde; setzt nur zurück, wenn es in Berlin Freitag, 0 Uhr ist (Sommer-/Winterzeit automatisch)
-- die Log-Tabelle des Monats-Resets wird weiterverwendet, Schlüssel z. B. 'W2026-47' (nie doppelt in einer Woche)
create or replace function public.jje_weekly_reset()
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare
  b timestamp := now() at time zone 'Europe/Berlin';
  k text := 'W' || to_char(b, 'IYYY-IW');
begin
  if extract(isodow from b) <> 5 or extract(hour from b) <> 0 then return; end if;
  if exists (select 1 from jje_monthly_reset_log where month = k) then return; end if;
  insert into jje_monthly_reset_log (month) values (k);
  perform jje_reset_all();
end $$;
revoke all on function public.jje_weekly_reset() from public, anon, authenticated;

-- Zeitplan umstellen: Monats-Reset aus, Wochen-Reset an (pg_cron rechnet in UTC, daher jede volle Stunde prüfen)
select cron.unschedule(jobid) from cron.job where jobname in ('jje-monatsreset', 'jje-wochenreset');
select cron.schedule('jje-wochenreset', '0 * * * *', 'select public.jje_weekly_reset()');

-- jetzt einmal alles zurücksetzen
select public.jje_reset_all();

-- Kontrolle: Job anzeigen
select jobname, schedule, command, active from cron.job where jobname like 'jje-%';
