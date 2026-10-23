-- Anonymous trip ends for route planning, as deployed in Supabase project gautrain-s5-live.
-- With "Help plan new routes" switched on in the app (off by default), a phone shares where its commute starts
-- (first mile) and ends (last mile). The phone snaps each point to a ~500 m grid before sending it and never sends
-- place names. Each phone has one row per trip end under a random id, updated in place, so there is no movement
-- history. Switching sharing off deletes the phone's rows; rows not refreshed for 12 months are deleted. Sharing
-- needs consent on the app's consent screen (recorded as consent_version). Only the project owner can read the data
-- or the analysis. See PRIVACY.md.

create table if not exists public.s5_trip_ends (
  device uuid not null,            -- random id made on the phone, not linked to a person
  role text not null check (role in ('first_mile', 'last_mile')),
  lat numeric(7, 3) not null,      -- ~500 m grid
  lon numeric(7, 3) not null,
  usual_time time,                 -- when the morning journey usually starts, to the nearest 15 min
  updated_at timestamptz not null default now(),
  consent_version text,            -- date of the privacy notice the person agreed to
  primary key (device, role)
);
alter table public.s5_trip_ends enable row level security;  -- no policies: only the functions below touch it

-- Snap to the ~500 m grid (0.005°), so a shared point is an area, not an address.
create or replace function public.s5_snap(v float8)
returns numeric language sql immutable as $$ select round((round(v / 0.005) * 0.005)::numeric, 3) $$;

-- Shares one trip end. Only with consent to the current privacy notice: p_consent is the notice's date (PRIVACY.md),
-- and the app sends it only after the person agrees on its consent screen. Change both together.
create or replace function public.s5_share_trip_end(p_device uuid, p_role text, p_lat float8, p_lon float8, p_usual text, p_consent text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare u time;
begin
  if p_consent is distinct from '2026-10-23' then raise exception 'consent to the current privacy notice is required'; end if;
  if p_role not in ('first_mile', 'last_mile') then raise exception 'role must be first_mile or last_mile'; end if;
  if p_lat not between -26.9 and -25.1 or p_lon not between 27.3 and 29.1 then raise exception 'point is outside Gauteng'; end if;
  -- A cheap brake on abuse: the app writes a couple of rows when settings change, never hundreds a minute.
  if (select count(*) from public.s5_trip_ends where updated_at > now() - interval '1 minute') > 120 then
    raise exception 'too many updates, try again shortly';
  end if;
  if p_usual ~ '^\d\d:\d\d$' then
    u := make_time(split_part(p_usual, ':', 1)::int, (split_part(p_usual, ':', 2)::int / 15) * 15, 0);
  end if;
  insert into public.s5_trip_ends as t (device, role, lat, lon, usual_time, updated_at, consent_version)
    values (p_device, p_role, public.s5_snap(p_lat), public.s5_snap(p_lon), u, now(), p_consent)
  on conflict (device, role) do update
    set lat = excluded.lat, lon = excluded.lon, usual_time = excluded.usual_time, updated_at = now(), consent_version = excluded.consent_version;
end $$;

-- The first version, without consent, now refuses, so an older copy of the app can't share without agreeing.
create or replace function public.s5_share_trip_end(p_device uuid, p_role text, p_lat float8, p_lon float8, p_usual text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  raise exception 'consent to the current privacy notice is required: please reload the app';
end $$;

-- Retention: entries not refreshed for 12 months are deleted (the app refreshes them monthly while it is used).
create or replace function public.s5_trip_ends_retention()
returns void language sql security definer set search_path = public as $$
  delete from public.s5_trip_ends where updated_at < now() - interval '12 months'
$$;
select cron.schedule('s5-trip-ends-retention', '17 2 * * 0', 'select public.s5_trip_ends_retention()');  -- Sundays 04:17 SAST

-- Delete one trip end (p_role) or all of a phone's trip ends (p_role null).
create or replace function public.s5_forget_trip_ends(p_device uuid, p_role text default null)
returns void
language sql
security definer
set search_path = public
as $$ delete from public.s5_trip_ends where device = p_device and (p_role is null or role = p_role) $$;

-- Every S5 stop, both directions, for distance-to-service in the analysis.
create or replace function public.s5_stops()
returns table (lat float8, lon float8) language sql immutable as $$
  select * from (values
    (-26.02467, 28.01143), (-26.02813, 28.00963), (-26.03346, 28.01029), (-26.04185, 28.01514), (-26.04338, 28.0168),
    (-26.04839, 28.02081), (-26.05209, 28.02137), (-26.06134, 28.02386), (-26.07572, 28.02687), (-26.07411, 28.03452),
    (-26.07773, 28.0484), (-26.08025, 28.0496), (-26.08638, 28.04777), (-26.08809, 28.04718), (-26.09487, 28.052),
    (-26.09998, 28.05028), (-26.10431, 28.05094), (-26.10807, 28.05673), (-26.10409, 28.05345), (-26.1016, 28.05076),
    (-26.09356, 28.05116), (-26.08561, 28.04922), (-26.07972, 28.04936), (-26.07495, 28.03125), (-26.07584, 28.0276),
    (-26.0645, 28.02444), (-26.0598, 28.02331), (-26.05276, 28.02132), (-26.04458, 28.01799), (-26.04165, 28.0148),
    (-26.0321, 28.00966)) s(lat, lon)
$$;

-- Demand by ~500 m cell: how many phones start or end their commute there, when they set off, and how far the
-- cell is from the nearest S5 stop. Cells with many phones and no stop within walking distance are where a new
-- route, an extra stop or a feeder service would help most.
create or replace view public.s5_demand_cells with (security_invoker = true) as
select e.role, e.lat, e.lon,
  count(*) as phones,
  min(e.usual_time) as earliest_start,
  max(e.usual_time) as latest_start,
  round((select min(public.s5_dist_m(e.lat::float8, e.lon::float8, s.lat, s.lon)) from public.s5_stops() s)::numeric / 1000, 2) as nearest_s5_stop_km,
  max(e.updated_at) as last_update
from public.s5_trip_ends e
group by e.role, e.lat, e.lon;

revoke all on public.s5_trip_ends, public.s5_demand_cells from anon, authenticated;
revoke all on function public.s5_share_trip_end(uuid, text, float8, float8, text, text), public.s5_forget_trip_ends(uuid, text)
  from public;
grant execute on function public.s5_share_trip_end(uuid, text, float8, float8, text, text), public.s5_forget_trip_ends(uuid, text)
  to anon, authenticated;
revoke all on function public.s5_trip_ends_retention() from public, anon, authenticated;

-- Where and when the S5 should grow, from the shared trip ends (and the departure log). Owner-only.
-- Zones are ~2 km squares; zones with fewer than p_min_phones phones are left out, so no single person shows.
--   kind = 'coverage': demand by zone, how far it is from the S5, and what kind of expansion would serve it.
--   kind = 'service':  demand by departure hour against the S5 departures in that hour and how reliably they ran.
create or replace function public.s5_expansion_report(p_min_phones int default 3)
returns table (kind text, zone text, phones bigint, first_mile bigint, last_mile bigint, nearest_s5_stop_km numeric,
               detail text, suggestion text)
language sql stable
security definer
set search_path = public
as $$
  with z as (
    select round(lat / 0.02) * 0.02 as zlat, round(lon / 0.02) * 0.02 as zlon, role, device, usual_time, lat, lon
    from public.s5_trip_ends
  ), zones as (
    select zlat, zlon, count(distinct device) as phones,
      count(*) filter (where role = 'first_mile') as first_mile, count(*) filter (where role = 'last_mile') as last_mile,
      avg(lat)::float8 as clat, avg(lon)::float8 as clon
    from z group by zlat, zlon
  ), coverage as (
    select 'coverage'::text as kind, to_char(zlat, 'FM990.00') || ', ' || to_char(zlon, 'FM990.00') as zone, phones, first_mile, last_mile,
      round((select min(public.s5_dist_m(clat, clon, s.lat, s.lon)) from public.s5_stops() s)::numeric / 1000, 1) as km,
      -- compass direction from Montecasino, to group zones into corridors a new route could follow
      (array['north', 'north-east', 'east', 'south-east', 'south', 'south-west', 'west', 'north-west'])[
        (round(((degrees(atan2(clon - 28.0114, clat - -26.02466)) + 360)::numeric % 360) / 45)::int % 8) + 1] as dir
    from zones where phones >= p_min_phones
  ), hours as (
    select extract(hour from usual_time)::int as h, count(distinct device) as phones
    from public.s5_trip_ends where role = 'first_mile' and usual_time is not null group by 1
  ), runs as (
    select extract(hour from scheduled)::int as h, count(*) as logged,
      count(*) filter (where status = 'did not run') as missed, round(avg(late_min) filter (where status <> 'did not run'), 1) as late
    from public.s5_departure_history where dir = 'toSandton' and scheduled is not null
      and day > (now() at time zone 'Africa/Johannesburg')::date - 30 group by 1
  ), service as (
    select 'service'::text, lpad(h::text, 2, '0') || ':00–' || lpad(h::text, 2, '0') || ':59', hours.phones, hours.phones, 0::bigint, null::numeric,
      -- people usually set off from home ~15 min before their S5, so look at the S5 departures in that hour
      (select count(*) from unnest(public.s5_monte_timetable()) t where t / 60 = h) || ' S5 departures from Montecasino' ||
        coalesce('; last 30 days: ' || r.missed || ' of ' || r.logged || ' did not run, ' || coalesce(r.late, 0) || ' min late on average', ''),
      case
        when (select count(*) from unnest(public.s5_monte_timetable()) t where t / 60 = h) = 0 then 'add service: no S5 leaves in this hour'
        when r.logged >= 10 and r.missed::numeric / r.logged >= 0.1 then 'reliability first: 1 in ' || round(r.logged::numeric / greatest(r.missed, 1)) || ' runs missing'
        when (select count(*) from unnest(public.s5_monte_timetable()) t where t / 60 = h) <= 3 then 'more frequent service: only every 20 min'
        else 'served: a bus every 10 min'
      end
    from hours left join runs r using (h) where hours.phones >= p_min_phones
  )
  select kind, zone, phones, first_mile, last_mile, km,
    km || ' km from the nearest S5 stop, ' || dir || ' of Montecasino',
    case when km <= 0.6 then 'served: within walking distance of an S5 stop'
         when km <= 2 then 'extra S5 stop or a short detour'
         else 'feeder or new route heading ' || dir || ' from Montecasino' end
  from coverage
  union all
  select * from service
  order by 1, 3 desc, 6 desc nulls last
$$;
revoke all on function public.s5_expansion_report(int) from public, anon, authenticated;
