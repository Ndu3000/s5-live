-- Learning real S5 travel times for better arrival estimates, as deployed in Supabase project gautrain-s5-live.
-- 1. Each night, from the departure log's bus GPS, when every trip passed every stop (s5_stop_passages).
--    This is Gautrain's bus data, not anyone's personal information.
-- 2. s5_segment_profile(): the median minutes for each stretch between stops, by direction and half hour, over the
--    last 30 days, wherever at least 3 trips on 2+ days were seen. The app uses it in place of typical car traffic.
-- 3. Optional, with consent: rides confirmed with "I'm on a bus" (s5_rides), only the bus, the departure, and the
--    stop and time where the ride was confirmed and where it ended. No location track, not linked to anyone.
-- Needs departure-log.sql.

-- Timetable stops for each direction, in order (the same points as the app and the s5-traffic relay).
create or replace function public.s5_route_stops(p_dir text)
returns table (idx int, lat float8, lon float8) language sql immutable as $$
  select v.idx, v.lat, v.lon from (values
    ('toSandton', 0, -26.02467, 28.01143), ('toSandton', 1, -26.02813, 28.00963), ('toSandton', 2, -26.03346, 28.01029), ('toSandton', 3, -26.04185, 28.01514),
    ('toSandton', 4, -26.04338, 28.0168), ('toSandton', 5, -26.04839, 28.02081), ('toSandton', 6, -26.05209, 28.02137), ('toSandton', 7, -26.06134, 28.02386),
    ('toSandton', 8, -26.07572, 28.02687), ('toSandton', 9, -26.07411, 28.03452), ('toSandton', 10, -26.07773, 28.0484), ('toSandton', 11, -26.08025, 28.0496),
    ('toSandton', 12, -26.08638, 28.04777), ('toSandton', 13, -26.08809, 28.04718), ('toSandton', 14, -26.09487, 28.052), ('toSandton', 15, -26.09998, 28.05028),
    ('toSandton', 16, -26.10431, 28.05094), ('toSandton', 17, -26.10807, 28.05673),
    ('toMontecasino', 0, -26.10807, 28.05673), ('toMontecasino', 1, -26.10409, 28.05345), ('toMontecasino', 2, -26.1016, 28.05076), ('toMontecasino', 3, -26.09993, 28.05015),
    ('toMontecasino', 4, -26.09356, 28.05116), ('toMontecasino', 5, -26.08678, 28.04687), ('toMontecasino', 6, -26.08561, 28.04922), ('toMontecasino', 7, -26.07972, 28.04936),
    ('toMontecasino', 8, -26.0775, 28.04828), ('toMontecasino', 9, -26.07495, 28.03125), ('toMontecasino', 10, -26.07584, 28.0276), ('toMontecasino', 11, -26.0645, 28.02444),
    ('toMontecasino', 12, -26.0598, 28.02331), ('toMontecasino', 13, -26.05276, 28.02132), ('toMontecasino', 14, -26.04458, 28.01799), ('toMontecasino', 15, -26.04165, 28.0148),
    ('toMontecasino', 16, -26.0321, 28.00966), ('toMontecasino', 17, -26.02467, 28.01143)) v(dir, idx, lat, lon)
  where v.dir = p_dir order by v.idx
$$;

create table if not exists public.s5_stop_passages (
  day date not null,
  dir text not null,
  scheduled time not null,       -- the trip's timetabled departure from its first stop
  bus_id text not null,
  stop_idx int not null,
  passed_at timestamptz not null, -- when the bus reached the stop (left it, for the first stop)
  primary key (day, dir, scheduled, stop_idx)
);
alter table public.s5_stop_passages enable row level security;

-- When bus p_bus reached each stop of p_dir between p_from and p_to. Buses report about every 30 s, so at speed a
-- stop usually falls between two reports: take the pair of consecutive reports whose straight line passes closest to
-- the stop (within 80 m) and interpolate the time along it. A bus that waited at the stop counts from its arrival.
create or replace function public.s5_trip_passages(p_bus text, p_dir text, p_from timestamptz, p_to timestamptz)
returns table (stop_idx int, passed_at timestamptz)
language sql stable security definer set search_path = public as $$
  with f as (
    select l.fix_at, l.seen_at, l.lat, l.lon,
      lead(l.fix_at) over w as nfix, lead(l.lat) over w as nlat, lead(l.lon) over w as nlon
    from public.s5_pos_log l
    where l.bus_id = p_bus and l.fix_at between p_from - interval '2 minutes' and p_to
    window w as (order by l.fix_at)
  ), g as (
    -- metres east / north of the stop (a local flat projection is plenty over a few hundred metres)
    select s.idx, f.fix_at, f.seen_at, f.nfix,
      (f.lon - s.lon) * 100060 as ax, (f.lat - s.lat) * 110540 as ay,
      (coalesce(f.nlon, f.lon) - s.lon) * 100060 as ux, (coalesce(f.nlat, f.lat) - s.lat) * 110540 as uy
    from public.s5_route_stops(p_dir) s cross join f
  ), h as (
    select g.*, greatest(0, least(1, case when (ux - ax) ^ 2 + (uy - ay) ^ 2 > 0
      then -(ax * (ux - ax) + ay * (uy - ay)) / ((ux - ax) ^ 2 + (uy - ay) ^ 2) else 0 end)) as t
    from g
  ), k as (
    select idx, fix_at, seen_at, nfix, t, sqrt((ax + t * (ux - ax)) ^ 2 + (ay + t * (uy - ay)) ^ 2) as d, sqrt(ax ^ 2 + ay ^ 2) as da
    from h
  )
  select distinct on (idx) idx,
    case when da < 40 or nfix is null then fix_at else seen_at + (nfix - seen_at) * t end
  from k where d < 80 and fix_at <= p_to
  order by idx, d, fix_at
$$;

-- Record every completed trip of day d, both directions.
create or replace function public.s5_record_passages(d date)
returns int
language plpgsql security definer set search_path = public as $$
declare r record; dep timestamptz; arr timestamptz; last int; n int := 0; tz text := 'Africa/Johannesburg';
begin
  delete from public.s5_stop_passages where day = d;
  for r in
    select 'toSandton' as dir, x.scheduled, x.bus_id, x.departed, x.sandton as arrived from public.s5_departure_report(d) x
      where x.scheduled is not null and x.departed is not null and x.sandton is not null
    union all
    select 'toMontecasino', y.scheduled, y.bus_id, y.departed, y.monte from public.s5_sandton_report(d) y
      where y.scheduled is not null and y.departed is not null and y.monte is not null
  loop
    dep := (d + r.departed) at time zone tz; arr := (d + r.arrived) at time zone tz;
    continue when arr <= dep or arr - dep > interval '2 hours';
    last := (select max(idx) from public.s5_route_stops(r.dir));
    insert into public.s5_stop_passages values (d, r.dir, r.scheduled, r.bus_id, 0, dep), (d, r.dir, r.scheduled, r.bus_id, last, arr)
      on conflict do nothing;
    insert into public.s5_stop_passages
      select d, r.dir, r.scheduled, r.bus_id, p.stop_idx, p.passed_at
      from public.s5_trip_passages(r.bus_id, r.dir, dep, arr) p
      where p.stop_idx > 0 and p.stop_idx < last
    on conflict do nothing;
    n := n + 1;
  end loop;
  return n;
end $$;

-- {"toSandton": {"450": {"0": 9.4, "1": 3.1, ...}, ...}, "toMontecasino": {...}}: median minutes for stretch
-- k → k+1, by the half hour (minutes after midnight) the bus reached stop k. Only where at least 3 trips on at least
-- 2 different days were seen, so one unusual day can't set it.
create or replace function public.s5_segment_profile(days int default 30)
returns jsonb
language sql stable security definer set search_path = public as $$
  with seg as (
    select a.dir, a.stop_idx as leg,
      (floor(extract(epoch from (a.passed_at at time zone 'Africa/Johannesburg')::time) / 1800) * 30)::int as bucket,
      extract(epoch from b.passed_at - a.passed_at) / 60 as mins
    from public.s5_stop_passages a
    join public.s5_stop_passages b on b.day = a.day and b.dir = a.dir and b.scheduled = a.scheduled and b.stop_idx = a.stop_idx + 1
    where a.day > (now() at time zone 'Africa/Johannesburg')::date - least(greatest(days, 1), 90)
  ), agg as (
    select dir, bucket, leg, percentile_cont(0.5) within group (order by mins) as med
    from seg where mins > 0 and mins < 30
    group by dir, bucket, leg having count(*) >= 3 and count(distinct day) >= 2
  )
  select coalesce(jsonb_object_agg(dir, buckets), '{}') from (
    select dir, jsonb_object_agg(bucket::text, legs) as buckets from (
      select dir, bucket, jsonb_object_agg(leg::text, round(med::numeric, 2)) as legs from agg group by dir, bucket) x
    group by dir) y
$$;

-- Rides confirmed with "I'm on a bus", shared only with consent. Not linked to a phone or person.
create table if not exists public.s5_rides (
  id uuid primary key default gen_random_uuid(),
  shared_at timestamptz not null default now(),
  consent_version text not null,
  dir text not null check (dir in ('toSandton', 'toMontecasino')),
  scheduled time,                  -- the departure the app matched the bus to, if any
  bus_id text not null,
  how text not null check (how in ('gps', 'picked')),
  board_stop int not null,         -- where the ride was confirmed
  board_at timestamptz not null,
  end_stop int not null,           -- where it ended
  end_at timestamptz not null,
  ended text not null check (ended in ('last stop', 'got off', 'tapped'))
);
alter table public.s5_rides enable row level security;

create or replace function public.s5_share_ride(p_consent text, p_dir text, p_scheduled text, p_bus text, p_how text,
  p_board_stop int, p_board_at timestamptz, p_end_stop int, p_end_at timestamptz, p_ended text)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if p_consent is distinct from 'rides-2026-10-26' then raise exception 'consent to share rides is required'; end if;
  if p_board_at > now() + interval '5 minutes' or p_end_at < p_board_at or p_end_at - p_board_at > interval '3 hours' or p_end_at < now() - interval '1 day' then
    raise exception 'ride times look wrong';
  end if;
  if (select count(*) from public.s5_rides where shared_at > now() - interval '1 minute') > 60 then raise exception 'too many rides, try again shortly'; end if;
  insert into public.s5_rides (consent_version, dir, scheduled, bus_id, how, board_stop, board_at, end_stop, end_at, ended)
  values (p_consent, p_dir, case when p_scheduled ~ '^\d\d:\d\d$' then p_scheduled::time end, left(p_bus, 12), p_how,
          p_board_stop, p_board_at, p_end_stop, p_end_at, p_ended);
end $$;

create or replace function public.s5_rides_retention()
returns void language sql security definer set search_path = public as $$
  delete from public.s5_rides where shared_at < now() - interval '12 months'
$$;

-- The nightly departure job also records the day's stop passages; rides older than 12 months go weekly.
create or replace function public.s5_eta_nightly()
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public.s5_record_passages((now() at time zone 'Africa/Johannesburg')::date);
end $$;
select cron.schedule('s5-eta-nightly', '45 20 * * 1-5', 'select public.s5_eta_nightly()');      -- 22:45 SAST
select cron.schedule('s5-rides-retention', '27 2 * * 0', 'select public.s5_rides_retention()'); -- Sundays 04:27 SAST

revoke all on function public.s5_trip_passages(text, text, timestamptz, timestamptz), public.s5_record_passages(date),
  public.s5_rides_retention(), public.s5_eta_nightly() from public, anon, authenticated;
revoke all on function public.s5_share_ride(text, text, text, text, text, int, timestamptz, int, timestamptz, text) from public;
grant execute on function public.s5_share_ride(text, text, text, text, text, int, timestamptz, int, timestamptz, text) to anon, authenticated;
grant execute on function public.s5_segment_profile(int) to anon, authenticated;

-- Table access: the app reaches data only through the functions above (security definer). Tables have row-level
-- security and no public table permissions; _osm_s5 is the route geometry imported while building the app.
alter table public._osm_s5 enable row level security;
revoke all on public._osm_s5, public.s5_bus_cache, public.s5_traffic_cache, public.s5_departure_history, public.s5_log_beat,
  public.s5_pos_log, public.s5_stop_passages, public.s5_rides from anon, authenticated;
