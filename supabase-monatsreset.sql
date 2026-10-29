-- JJE · Highscores aller drei Spiele automatisch am 1. jedes Monats um 0:01 Uhr (deutsche Zeit) zurücksetzen
-- Einmalig im Supabase-Projekt ausführen: SQL Editor → New query → alles einfügen → Run.
-- Nutzt die vorhandenen Funktionen reset_scores() (JJE_blocks), reset_scores_mah() (JJE_mahjong) und reset_scores_tet() (JJE_tetris).
-- Die Apps merken den Reset an der erhöhten „epoch“ und leeren dann auch ihre Listen auf den iPhones.

create extension if not exists pg_cron;

-- merkt sich, für welchen Monat schon zurückgesetzt wurde (nie doppelt)
create table if not exists public.jje_monthly_reset_log (
  month text primary key,              -- z. B. '2026-11'
  at    timestamptz not null default now()
);
alter table public.jje_monthly_reset_log enable row level security;
revoke all on public.jje_monthly_reset_log from anon, authenticated;

-- läuft stündlich um xx:01; setzt nur zurück, wenn es in Berlin der 1. des Monats, 0 Uhr ist (Sommer-/Winterzeit automatisch)
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
end $$;
revoke all on function public.jje_monthly_reset() from public, anon, authenticated;

-- Zeitplan (pg_cron rechnet in UTC; Berlin liegt immer volle Stunden daneben, daher Minute 1 jeder Stunde)
select cron.unschedule(jobid) from cron.job where jobname = 'jje-monatsreset';
select cron.schedule('jje-monatsreset', '1 * * * *', 'select public.jje_monthly_reset()');

-- Kontrolle: Job anzeigen
select jobname, schedule, command, active from cron.job where jobname = 'jje-monatsreset';
