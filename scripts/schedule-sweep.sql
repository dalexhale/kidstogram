-- kidstogram — schedule the hourly sweep (launch plan Phase 7.2).
--
-- NOT a migration: it embeds the service role key, so it is run by hand
-- in the Supabase SQL editor and never committed with the key filled in.
-- The key ends up inside cron.job, which only the postgres role can read.
--
-- Afterwards:
--   select * from cron.job;                                          -- is it scheduled?
--   select * from cron.job_run_details order by start_time desc limit 10;   -- did it run?
--
-- Phase 7.3 — run it once by hand and watch a file actually vanish from
-- the bucket: run just the inner select net.http_post(...) on its own.
-- The sweep also logs its counts to the edge function logs on every run.

create extension if not exists pg_cron;
create extension if not exists pg_net;   -- net.http_post; missing from the plan's 1.4 list

select cron.schedule(
  'sweep-expired',
  '0 * * * *',                           -- on the hour, every hour
  $$
  select net.http_post(
    url     := 'https://pzfnmjkylfuppxyrrmdy.supabase.co/functions/v1/sweep',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || ''
    ),
    body    := '{}'::jsonb
  );
  $$
);

-- undo:  select cron.unschedule('sweep-expired');
