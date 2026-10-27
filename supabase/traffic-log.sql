-- Live TomTom traffic, logged every 5 minutes on weekdays while the S5 runs, so the backtest (backtest.sql) can score
-- the app's live-traffic adjustment against what buses really did.
--
-- It asks the s5-traffic Edge Function, exactly as the app does, so the TomTom key stays an Edge Function secret and
-- the function's 2-minute cache is shared with the app. Each answer costs at most 2 TomTom requests (one route per
-- direction): at most ~410 a weekday from 05:00 to 22:00. Only driving times per stretch are stored. Kept 30 days.
create table if not exists public.s5_traffic_log (
  at timestamptz primary key,       -- when TomTom answered
  to_sandton int[] not null,        -- live driving seconds for each stretch between S5 stops
  to_montecasino int[] not null
);
alter table public.s5_traffic_log enable row level security;
revoke all on public.s5_traffic_log from anon, authenticated;

create or replace function public.s5_traffic_log_tick() returns void
language plpgsql security definer set search_path = public, extensions as $$
declare
  -- the site's public (publishable) key, as in index.html; the Edge Function asks for one
  k text := 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImdrenV1d29obGRxYnNuem1oZG14Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTI2OTA0MzcsImV4cCI6MjEwODI2NjQzN30.L5Ze3IO4dp6psKOC_KBCA7ScT5hj7J0ej9rLLsnOc8k';
  r extensions.http_response; b jsonb;
begin
  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT', '20');
  r := extensions.http(('GET', 'https://gkzuuwohldqbsnzmhdmx.supabase.co/functions/v1/s5-traffic',
         array[extensions.http_header('apikey', k), extensions.http_header('Authorization', 'Bearer ' || k)], null, null)::extensions.http_request);
  if r.status <> 200 then return; end if;
  b := r.content::jsonb;
  if jsonb_typeof(b -> 'toSandton' -> 'live') <> 'array' or jsonb_typeof(b -> 'toMontecasino' -> 'live') <> 'array' then return; end if;
  insert into public.s5_traffic_log (at, to_sandton, to_montecasino)
  values (to_timestamp(coalesce((b ->> 'at')::float8, extract(epoch from now()) * 1000) / 1000),
          array(select (x #>> '{}')::int from jsonb_array_elements(b -> 'toSandton' -> 'live') x),
          array(select (x #>> '{}')::int from jsonb_array_elements(b -> 'toMontecasino' -> 'live') x))
  on conflict (at) do nothing;
end $$;
revoke all on function public.s5_traffic_log_tick() from public, anon, authenticated;
select cron.schedule('s5-traffic-log', '*/5 3-19 * * 1-5', 'select public.s5_traffic_log_tick()');  -- 05:00-21:55 SAST
