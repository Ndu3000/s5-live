-- Departure log for the S5 from Montecasino, as deployed in Supabase project gautrain-s5-live.
-- Every 30 seconds on weekdays (05:00–22:20 SAST) pg_cron saves the GPS fixes of buses near the S5,
-- and s5_departure_report(day) works out, for every timetabled departure from Montecasino, whether a bus
-- actually left, when, and when it reached Sandton Station. Each night the report is kept in
-- s5_departure_history and fixes older than 30 days are deleted.
-- Needs pg_cron and the backup relay public.s5_buses() from backup-relays.sql.

create extension if not exists pg_cron;

-- One row per stop or movement: a parked bus keeps one row and only seen_at moves on.
create table if not exists public.s5_pos_log (
  bus_id text not null,
  fix_at timestamptz not null,   -- first GPS fix at this spot
  seen_at timestamptz not null,  -- latest GPS fix still at this spot
  lat float8 not null,
  lon float8 not null,
  heading int,
  primary key (bus_id, fix_at)
);
create index if not exists s5_pos_log_fix_at on public.s5_pos_log (fix_at);
alter table public.s5_pos_log enable row level security;  -- no policies: only the functions below use it

create table if not exists public.s5_departure_history (
  day date not null,
  scheduled time,                -- null: a departure that matched no timetable slot
  status text not null,
  bus_id text,
  departed_at timestamptz,
  late_min numeric,
  sandton_at timestamptz,
  trip_min numeric,
  note text
);
create index if not exists s5_departure_history_day on public.s5_departure_history (day);
alter table public.s5_departure_history enable row level security;

-- Weekday departures from Montecasino Terminal, minutes after midnight (same as the app's timetable).
create or replace function public.s5_monte_timetable()
returns int[] language sql immutable as $$
  select array[310,320,330,340,350,360,370,380,390,400,410,417,427,437,447,457,467,477,487,497,507,517,527,537,547,
    557,567,577,587,597,617,637,657,677,697,717,737,757,777,797,817,837,857,877,897,917,937,957,967,977,987,997,1007,
    1017,1027,1037,1047,1057,1067,1077,1087,1097,1107,1117,1127,1137,1147,1157,1167,1177,1187,1207,1227,1247,1267,1287]
$$;

create or replace function public.s5_dist_m(lat1 float8, lon1 float8, lat2 float8, lon2 float8)
returns float8 language sql immutable as $$
  select 2 * 6371000 * asin(sqrt(power(sin(radians(lat2 - lat1) / 2), 2)
    + cos(radians(lat1)) * cos(radians(lat2)) * power(sin(radians(lon2 - lon1) / 2), 2)))
$$;

create or replace function public.s5_log_tick()
returns int
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  t timestamp := now() at time zone 'Africa/Johannesburg';
  v jsonb; lat float8; lon float8; fix timestamptz; id text; n int := 0;
  last public.s5_pos_log;
begin
  if extract(isodow from t) > 5 or t::time not between '05:00' and '22:20' then return 0; end if;
  for v in select * from jsonb_array_elements(public.s5_buses() -> 'Result' -> 'busPositions') loop
    id := v ->> 'busId'; lat := (v ->> 'latitude')::float8; lon := (v ->> 'longitude')::float8;
    -- Only the S5 corridor: Montecasino down William Nicol and Ballyclare to Sandton Station.
    continue when id is null or lat is null or lon is null
      or lat not between -26.115 and -26.018 or lon not between 28.000 and 28.065;
    fix := coalesce(to_timestamp(nullif(v ->> 'lastModified', '')::bigint / 1000.0), now());
    select * into last from public.s5_pos_log where bus_id = id order by fix_at desc limit 1;
    if found and fix <= last.seen_at then continue; end if;  -- no new GPS fix since last time
    if found and public.s5_dist_m(last.lat, last.lon, lat, lon) < 20 and fix - last.seen_at < interval '10 minutes' then
      update public.s5_pos_log set seen_at = fix where bus_id = id and fix_at = last.fix_at;
    else
      insert into public.s5_pos_log values (id, fix, fix, lat, lon, round(nullif(v ->> 'heading', '')::numeric)::int)
        on conflict do nothing;
      n := n + 1;
    end if;
  end loop;
  return n;
end $$;

-- Every bus that left Montecasino Terminal towards Sandton on a day, and when it reached Sandton Station.
create or replace function public.s5_monte_departures(d date)
returns table (bus_id text, departed_at timestamptz, sandton_at timestamptz)
language sql stable
security definer
set search_path = public
as $$
  with p as (
    select l.bus_id, l.fix_at, l.seen_at, l.lat,
      public.s5_dist_m(l.lat, l.lon, -26.02466, 28.0114) < 150 as at_monte,
      public.s5_dist_m(l.lat, l.lon, -26.10801, 28.05673) < 150 as at_sandton
    from public.s5_pos_log l
    where l.fix_at >= (d::timestamp + interval '4 hours') at time zone 'Africa/Johannesburg'
      and l.fix_at < (d::timestamp + interval '24 hours') at time zone 'Africa/Johannesburg'
  ), q as (
    select p.*, lag(at_monte) over w as was_monte, lag(seen_at) over w as left_seen
    from p window w as (partition by p.bus_id order by p.fix_at)
  ), dep as (
    -- Last seen parked at the terminal, then the first fix outside it: it left halfway between.
    select q.bus_id, q.left_seen + (q.fix_at - q.left_seen) / 2 as departed_at, q.fix_at as out_at
    from q where q.was_monte and not q.at_monte
  )
  select dep.bus_id, dep.departed_at,
    (select min(s.fix_at) from p s where s.bus_id = dep.bus_id and s.at_sandton
       and s.fix_at between dep.out_at and dep.out_at + interval '100 minutes')
  from dep
  -- Count it only if it went down William Nicol before coming back to the terminal.
  where exists (select 1 from p s where s.bus_id = dep.bus_id and s.lat < -26.035
                  and s.fix_at between dep.out_at and dep.out_at + interval '25 minutes'
                  and not exists (select 1 from p m where m.bus_id = dep.bus_id and m.at_monte
                                    and m.fix_at > dep.out_at and m.fix_at < s.fix_at))
  order by 2
$$;

-- For every timetabled departure from Montecasino on a day: did a bus leave, how late, and when it reached Sandton.
-- Each actual departure goes to the nearest free slot; leaving early counts 2.5 times as far as leaving late,
-- so a bus leaving at 09:27 is the 09:27, and the 09:17 shows as not run.
create or replace function public.s5_departure_report(d date)
returns table (scheduled time, status text, bus_id text, departed time, late_min numeric,
               sandton time, trip_min numeric, note text)
language plpgsql stable
security definer
set search_path = public
as $$
declare
  slots int[] := public.s5_monte_timetable();
  got jsonb := '{}';   -- slot index -> departure
  extra jsonb := '[]';
  dep record; i int; best int; best_cost numeric; late numeric; cost numeric; any_dep boolean := false;
  now_min numeric := extract(epoch from (now() at time zone 'Africa/Johannesburg') - d::timestamp) / 60;
  sast text := 'Africa/Johannesburg';
begin
  for dep in select * from public.s5_monte_departures(d) loop
    any_dep := true; best := null; best_cost := null;
    late := extract(epoch from (dep.departed_at at time zone sast) - d::timestamp) / 60;
    for i in 1 .. array_length(slots, 1) loop
      continue when got ? i::text;
      cost := late - slots[i];
      continue when cost < -4 or cost > 15;
      cost := case when cost >= 0 then cost else -cost * 2.5 end;
      if best is null or cost < best_cost then best := i; best_cost := cost; end if;
    end loop;
    if best is null then
      extra := extra || jsonb_build_object('bus', dep.bus_id, 'dep', dep.departed_at, 'arr', dep.sandton_at);
    else
      got := got || jsonb_build_object(best::text, jsonb_build_object('bus', dep.bus_id, 'dep', dep.departed_at, 'arr', dep.sandton_at));
    end if;
  end loop;
  for i in 1 .. array_length(slots, 1) loop
    scheduled := make_time(slots[i] / 60, slots[i] % 60, 0);
    bus_id := null; departed := null; late_min := null; sandton := null; trip_min := null; note := null;
    if got ? i::text then
      bus_id := got -> i::text ->> 'bus';
      departed := ((got -> i::text ->> 'dep')::timestamptz at time zone sast)::time(0);
      late_min := round((extract(epoch from departed - scheduled) / 60)::numeric, 1);
      status := case when late_min < -1 then 'left early' when late_min > 3 then 'left late' else 'on time' end;
      if got -> i::text ->> 'arr' is not null then
        sandton := ((got -> i::text ->> 'arr')::timestamptz at time zone sast)::time(0);
        trip_min := round((extract(epoch from (got -> i::text ->> 'arr')::timestamptz - (got -> i::text ->> 'dep')::timestamptz) / 60)::numeric, 1);
      elsif now_min < slots[i] + 100 then note := 'on the way';
      else note := 'not seen arriving at Sandton';
      end if;
    elsif now_min < slots[i] + 15 then status := 'not yet';
    elsif not any_dep then status := 'no data';
    else status := 'did not run';
    end if;
    return next;
  end loop;
  for dep in select * from jsonb_to_recordset(extra) as x(bus text, dep timestamptz, arr timestamptz) loop
    scheduled := null; status := 'extra departure'; bus_id := dep.bus;
    departed := (dep.dep at time zone sast)::time(0); late_min := null;
    sandton := (dep.arr at time zone sast)::time(0);
    trip_min := round((extract(epoch from dep.arr - dep.dep) / 60)::numeric, 1); note := null;
    return next;
  end loop;
end $$;

create or replace function public.s5_departure_nightly()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare d date := (now() at time zone 'Africa/Johannesburg')::date;
begin
  delete from public.s5_departure_history where day = d;
  insert into public.s5_departure_history
    select d, r.scheduled, r.status, r.bus_id,
      case when r.departed is null then null else (d + r.departed) at time zone 'Africa/Johannesburg' end,
      r.late_min,
      case when r.sandton is null then null else (d + r.sandton) at time zone 'Africa/Johannesburg' end,
      r.trip_min, r.note
    from public.s5_departure_report(d) r
    where r.status <> 'no data';
  delete from public.s5_pos_log where fix_at < now() - interval '30 days';
end $$;

-- Only pg_cron and the project owner call these.
revoke all on function public.s5_log_tick(), public.s5_monte_departures(date), public.s5_departure_report(date),
  public.s5_departure_nightly() from public, anon, authenticated;

select cron.schedule('s5-log-tick', '30 seconds', 'select public.s5_log_tick()');
select cron.schedule('s5-departure-nightly', '30 20 * * 1-5', 'select public.s5_departure_nightly()');  -- 22:30 SAST
