-- Backup relays for the S5 Bus Tracker, as deployed in Supabase project gautrain-s5-live.
-- The app calls these through the REST API (/rest/v1/rpc/...) when the Edge Functions are unavailable.
-- Needs the "http" extension. s5_traffic reads the TomTom key from Vault, stored as "tomtom_api_key".

create table if not exists public.s5_bus_cache (id int primary key, at timestamptz not null, body jsonb not null);
alter table public.s5_bus_cache enable row level security;  -- no policies: only the functions below use it
create table if not exists public.s5_traffic_cache (id int primary key, at timestamptz not null, body jsonb not null);
alter table public.s5_traffic_cache enable row level security;

create or replace function public.s5_buses()
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
-- Gautrain's bus positions for the fixed Fourways–Sandton box, cached for 5 seconds.
declare
  c public.s5_bus_cache;
  r extensions.http_response;
begin
  select * into c from public.s5_bus_cache where id = 1;
  if found and c.at > now() - interval '5 seconds' then return c.body; end if;
  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT', '8');
  r := extensions.http(('POST', 'https://api.gautrain.co.za/transport-api/api/0/busses/location', null,
        'application/json', '{"east":"28.1","south":"-26.15","north":"-25.97","west":"27.94"}')::extensions.http_request);
  if r.status <> 200 then
    if found then return c.body; end if;
    raise exception 'Gautrain feed answered HTTP %', r.status;
  end if;
  insert into public.s5_bus_cache (id, at, body) values (1, now(), r.content::jsonb)
    on conflict (id) do update set at = excluded.at, body = excluded.body;
  return r.content::jsonb;
end $$;

create or replace function public.s5_traffic()
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
-- TomTom live driving time for every stretch between S5 stops, both directions. Cached for 2 minutes.
declare
  c public.s5_traffic_cache;
  k text;
  paths jsonb := jsonb_build_object(
    'toSandton', '-26.02467,28.01143:-26.02813,28.00963:-26.03346,28.01029:-26.04185,28.01514:-26.04338,28.0168:-26.04839,28.02081:-26.05209,28.02137:-26.06134,28.02386:-26.07572,28.02687:-26.07411,28.03452:-26.07773,28.0484:-26.08025,28.0496:-26.08638,28.04777:-26.08809,28.04718:-26.09487,28.052:-26.09998,28.05028:-26.10431,28.05094:-26.10807,28.05673',
    'toMontecasino', '-26.10807,28.05673:-26.10409,28.05345:-26.1016,28.05076:-26.09993,28.05015:-26.09356,28.05116:-26.08678,28.04687:-26.08561,28.04922:-26.07972,28.04936:-26.0775,28.04828:-26.07495,28.03125:-26.07584,28.0276:-26.0645,28.02444:-26.0598,28.02331:-26.05276,28.02132:-26.04458,28.01799:-26.04165,28.0148:-26.0321,28.00966:-26.02467,28.01143');
  dir text;
  r extensions.http_response;
  out jsonb := '{}'::jsonb;
begin
  select * into c from public.s5_traffic_cache where id = 1;
  if found and c.at > now() - interval '2 minutes' then return c.body; end if;
  select decrypted_secret into k from vault.decrypted_secrets where name = 'tomtom_api_key' limit 1;
  if k is null or k = '' then raise exception 'No TomTom key in Vault (name it tomtom_api_key)'; end if;
  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT', '10');
  foreach dir in array array['toSandton', 'toMontecasino'] loop
    r := extensions.http_get('https://api.tomtom.com/routing/1/calculateRoute/' || (paths->>dir) ||
      '/json?traffic=true&routeType=fastest&computeTravelTimeFor=all&key=' || k);
    if r.status <> 200 then
      if found then return c.body; end if;
      raise exception 'TomTom answered HTTP %', r.status;
    end if;
    out := out || jsonb_build_object(dir, jsonb_build_object('live',
      (select jsonb_agg((l->'summary'->>'travelTimeInSeconds')::int order by n)
         from jsonb_array_elements(r.content::jsonb->'routes'->0->'legs') with ordinality t(l, n))));
  end loop;
  out := out || jsonb_build_object('at', floor(extract(epoch from now()) * 1000)::bigint, 'source', 'TomTom live traffic');
  insert into public.s5_traffic_cache (id, at, body) values (1, now(), out)
    on conflict (id) do update set at = excluded.at, body = excluded.body;
  return out;
end $$;

revoke all on function public.s5_buses() from public;
revoke all on function public.s5_traffic() from public;
grant execute on function public.s5_buses() to anon, authenticated;
grant execute on function public.s5_traffic() to anon, authenticated;
