-- Departure log for the S5 from Montecasino, as deployed in Supabase project gautrain-s5-live.
-- Every 30 seconds on weekdays (05:00–22:20 SAST) pg_cron saves the GPS fixes of buses near the S5,
-- and s5_departure_report(day) works out, for every timetabled departure from Montecasino, whether a bus
-- actually left, when, and when it reached Sandton Station; and, for that bus, when it got to Montecasino and
-- which departure from Sandton brought it there, so a missed slot shows whether a bus was waiting or none had
-- come yet. The same is kept for departures from Sandton Station (s5_sandton_report). Slots while Gautrain's feed
-- was quiet are 'no data' (s5_log_beat). Each night the reports are kept in s5_departure_history and fixes older
-- than 30 days are deleted.
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

-- One row per tick that brought new GPS fixes. Gaps here mean Gautrain's feed went quiet, so the log saw nothing.
create table if not exists public.s5_log_beat (at timestamptz primary key, fixes int not null);
alter table public.s5_log_beat enable row level security;

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
alter table public.s5_departure_history
  add column if not exists monte_arrived_at timestamptz,  -- the bus's trip before: reached Montecasino
  add column if not exists waited_min numeric,
  add column if not exists sandton_left_at timestamptz,   -- ...after leaving Sandton Station
  add column if not exists sandton_slot time,             -- as this timetabled departure from Sandton
  add column if not exists sandton_late_min numeric,
  add column if not exists dir text not null default 'toSandton';  -- toMontecasino: departures from Sandton Station
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
  v jsonb; lat float8; lon float8; fix timestamptz; id text; n int := 0; fresh int := 0;
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
    fresh := fresh + 1;
    if found and public.s5_dist_m(last.lat, last.lon, lat, lon) < 20 and fix - last.seen_at < interval '10 minutes' then
      update public.s5_pos_log set seen_at = fix where bus_id = id and fix_at = last.fix_at;
    else
      insert into public.s5_pos_log values (id, fix, fix, lat, lon, round(nullif(v ->> 'heading', '')::numeric)::int)
        on conflict do nothing;
      n := n + 1;
    end if;
  end loop;
  if fresh > 0 then insert into public.s5_log_beat values (now(), fresh) on conflict do nothing; end if;
  return n;
end $$;

-- Weekday departures from Sandton Station towards Montecasino, minutes after midnight.
create or replace function public.s5_sandton_timetable()
returns int[] language sql immutable as $$
  select array[368,378,388,398,408,418,428,438,448,458,468,478,488,498,508,518,528,538,548,568,588,608,628,648,668,
    688,708,728,748,768,788,808,828,848,868,888,908,918,928,938,948,958,968,978,988,998,1008,1018,1028,1038,1048,1058,
    1068,1078,1088,1098,1108,1118,1128,1138,1158,1178,1198,1218,1238]
$$;

create or replace function public.s5_day_min(d date, t timestamptz)
returns numeric language sql immutable as $$
  select extract(epoch from (t at time zone 'Africa/Johannesburg') - d::timestamp) / 60
$$;

create or replace function public.s5_hm(t timestamptz)
returns text language sql immutable as $$ select to_char(t at time zone 'Africa/Johannesburg', 'HH24:MI') $$;

-- Did the log get fresh GPS all the way from a to b, never quiet for more than 5 minutes?
create or replace function public.s5_covered(a timestamptz, b timestamptz)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.s5_log_beat where at between a - interval '5 minutes' and a)
     and exists (select 1 from public.s5_log_beat where at between b and b + interval '5 minutes')
     and not exists (select 1 from (select at, lead(at) over (order by at) as nx from public.s5_log_beat
                                    where at between a - interval '5 minutes' and b + interval '5 minutes') g
                     where g.nx - g.at > interval '5 minutes')
$$;

-- Could the log see a departure at time t (and up to 15 min late)? If not, its slot is 'no data', not 'did not run'.
create or replace function public.s5_logged(t timestamptz)
returns boolean language sql stable security definer set search_path = public as $$
  select public.s5_covered(t, t + interval '15 minutes')
$$;

-- The timetable slot a departure at minute m belongs to: the nearest free one, leaving early counting
-- 2.5 times as far as leaving late, from 6 min early to 20 min late. Null if none.
create or replace function public.s5_slot_match(m numeric, slots int[], taken jsonb default '{}')
returns int language plpgsql immutable as $$
declare i int; best int; best_cost numeric; c numeric;
begin
  for i in 1 .. array_length(slots, 1) loop
    continue when taken ? i::text;
    c := m - slots[i];
    continue when c < -6 or c > 20;
    c := case when c >= 0 then c else -c * 2.5 end;
    if best is null or c < best_cost then best := i; best_cost := c; end if;
  end loop;
  return best;
end $$;

-- Every bus that left Montecasino Terminal towards Sandton on a day, when it reached Sandton Station,
-- and the trip before: when it got to Montecasino and when it left Sandton for it (null if it didn't come from Sandton).
drop function if exists public.s5_departure_report(date);
drop function if exists public.s5_monte_departures(date);
create function public.s5_monte_departures(d date)
returns table (bus_id text, departed_at timestamptz, sandton_at timestamptz, monte_arrived_at timestamptz, sandton_left_at timestamptz)
language sql stable
security definer
set search_path = public
as $$
  with p as (
    select l.bus_id, l.fix_at, l.seen_at, l.lat,
      public.s5_dist_m(l.lat, l.lon, -26.02466, 28.0114) as dm,
      public.s5_dist_m(l.lat, l.lon, -26.10801, 28.05673) < 150 as at_sandton
    from public.s5_pos_log l
    where l.fix_at >= (d::timestamp + interval '4 hours') at time zone 'Africa/Johannesburg'
      and l.fix_at < (d::timestamp + interval '24 hours') at time zone 'Africa/Johannesburg'
  ), q as (
    select p.*, p.dm < 150 as at_monte, lag(p.dm < 150) over w as was_monte,
      lag(p.seen_at) over w as prev_seen, lead(p.fix_at) over w as next_fix
    from p window w as (partition by p.bus_id order by p.fix_at)
  ), dep as (
    -- Last seen parked at the terminal, then the first fix outside it: it left halfway between.
    select q.bus_id, q.prev_seen + (q.fix_at - q.prev_seen) / 2 as departed_at, q.fix_at as out_at
    from q where q.was_monte and not q.at_monte
      and q.fix_at - q.prev_seen <= interval '5 minutes'  -- across a feed gap its time is unknown
      -- Count it only if it went down William Nicol before coming back to the terminal.
      and exists (select 1 from p s where s.bus_id = q.bus_id and s.lat < -26.035
                    and s.fix_at between q.fix_at and q.fix_at + interval '25 minutes'
                    and not exists (select 1 from p m where m.bus_id = q.bus_id and m.dm < 150
                                      and m.fix_at > q.fix_at and m.fix_at < s.fix_at))
  ), stay as (
    -- Its time at the terminal began after it was last well away (400 m) or last missing from the feed for 5 min.
    select dep.*,
      (select max(a.fix_at) from q a where a.bus_id = dep.bus_id and a.fix_at < dep.out_at and a.dm > 400) as away_at,
      (select max(g.fix_at) from q g where g.bus_id = dep.bus_id and g.fix_at < dep.out_at
         and g.fix_at - g.prev_seen > interval '5 minutes') as gap_at
    from dep
  ), arr as (
    select stay.*,
      (select case when i.prev_seen is null or i.fix_at - i.prev_seen > interval '5 minutes' then i.fix_at
                   else i.prev_seen + (i.fix_at - i.prev_seen) / 2 end
       from q i where i.bus_id = stay.bus_id and i.at_monte and i.fix_at < stay.out_at
         and (stay.away_at is null or i.fix_at > stay.away_at) and (stay.gap_at is null or i.fix_at >= stay.gap_at)
       order by i.fix_at limit 1) as monte_arrived_at
    from stay
  )
  select a.bus_id, a.departed_at,
    (select min(s.fix_at) from p s where s.bus_id = a.bus_id and s.at_sandton
       and s.fix_at between a.out_at and a.out_at + interval '100 minutes'),
    a.monte_arrived_at,
    -- Last seen at Sandton Station on the way: it left halfway to its next fix. Only when it came straight from there.
    (select s.seen_at + (coalesce(s.next_fix, s.seen_at) - s.seen_at) / 2 from q s
     where s.bus_id = a.bus_id and s.at_sandton and s.fix_at < a.monte_arrived_at
       and s.fix_at > a.monte_arrived_at - interval '100 minutes' and (a.gap_at is null or s.fix_at >= a.gap_at)
       and coalesce(s.next_fix, s.seen_at) - s.seen_at <= interval '5 minutes'
     order by s.fix_at desc limit 1)
  from arr a
  order by 2
$$;

-- For every timetabled departure from Montecasino on a day: did a bus leave, how late, when it reached Sandton,
-- and the bus's trip before (when it reached Montecasino, how long it waited, which Sandton departure it was).
-- A slot that did not run says why: a bus was waiting there but left later, or no bus had arrived yet.
create function public.s5_departure_report(d date)
returns table (scheduled time, status text, bus_id text, departed time, late_min numeric, sandton time, trip_min numeric,
               monte_arrived time, waited_min numeric, left_sandton time, sandton_slot time, sandton_late_min numeric, note text)
language plpgsql stable
security definer
set search_path = public
as $$
declare
  slots int[] := public.s5_monte_timetable();
  inslots int[] := public.s5_sandton_timetable();
  sast text := 'Africa/Johannesburg';
  deps jsonb := '[]'; got jsonb := '{}'; lst jsonb := '[]';
  r jsonb; x jsonb; y jsonb; dep record; i int; j int; ts timestamptz; why text;
  now_min numeric := public.s5_day_min(d, now());
  any_dep boolean := false;
begin
  for dep in select * from public.s5_monte_departures(d) loop
    any_dep := true;
    i := public.s5_slot_match(public.s5_day_min(d, dep.departed_at), slots, got);
    x := jsonb_build_object('bus', dep.bus_id, 'dep', dep.departed_at, 'arr', dep.sandton_at,
                            'marr', dep.monte_arrived_at, 'sleft', dep.sandton_left_at, 'slot', i);
    deps := deps || jsonb_build_array(x);
    if i is not null then got := got || jsonb_build_object(i::text, x); end if;
  end loop;
  for i in 1 .. array_length(slots, 1) loop
    lst := lst || jsonb_build_array(jsonb_build_object('slot', i, 'x', got -> i::text));
  end loop;
  for x in select e from jsonb_array_elements(deps) e where e -> 'slot' = 'null' loop
    lst := lst || jsonb_build_array(jsonb_build_object('slot', null, 'x', x));
  end loop;

  for r in select e from jsonb_array_elements(lst) e loop
    i := (r ->> 'slot')::int; x := r -> 'x'; if x = 'null' then x := null; end if;
    scheduled := case when i is null then null else make_time(slots[i] / 60, slots[i] % 60, 0) end;
    ts := (d + scheduled) at time zone sast;
    bus_id := null; departed := null; late_min := null; sandton := null; trip_min := null; monte_arrived := null;
    waited_min := null; left_sandton := null; sandton_slot := null; sandton_late_min := null; note := null;
    if x is not null then
      bus_id := x ->> 'bus';
      departed := ((x ->> 'dep')::timestamptz at time zone sast)::time(0);
      late_min := round((extract(epoch from departed - scheduled) / 60)::numeric, 1);
      status := case when i is null then 'extra departure' when late_min < -1 then 'left early'
                     when late_min > 3 then 'left late' else 'on time' end;
      sandton := ((x ->> 'arr')::timestamptz at time zone sast)::time(0);
      trip_min := round((extract(epoch from (x ->> 'arr')::timestamptz - (x ->> 'dep')::timestamptz) / 60)::numeric, 1);
      monte_arrived := ((x ->> 'marr')::timestamptz at time zone sast)::time(0);
      waited_min := round((extract(epoch from (x ->> 'dep')::timestamptz - (x ->> 'marr')::timestamptz) / 60)::numeric, 1);
      left_sandton := ((x ->> 'sleft')::timestamptz at time zone sast)::time(0);
      if x ->> 'sleft' is not null then
        j := public.s5_slot_match(public.s5_day_min(d, (x ->> 'sleft')::timestamptz), inslots);
        if j is not null then
          sandton_slot := make_time(inslots[j] / 60, inslots[j] % 60, 0);
          sandton_late_min := round((extract(epoch from left_sandton - sandton_slot) / 60)::numeric, 1);
        end if;
      end if;
      if x ->> 'arr' is null then
        note := case when now_min < public.s5_day_min(d, (x ->> 'dep')::timestamptz) + 100 then 'on the way'
                     else 'not seen arriving at Sandton' end;
      end if;
      if late_min > 3 and (x ->> 'marr')::timestamptz > ts then
        note := concat_ws('; ', note, 'the bus only reached Montecasino at ' || public.s5_hm((x ->> 'marr')::timestamptz));
      end if;
      if x ->> 'marr' is null then
        note := concat_ws('; ', note, 'already at Montecasino when the log starts');
      elsif x ->> 'sleft' is null and not public.s5_covered((x ->> 'marr')::timestamptz - interval '45 minutes', (x ->> 'marr')::timestamptz) then
        note := concat_ws('; ', note, 'the log could not see where it came from');
      elsif x ->> 'sleft' is null then
        note := concat_ws('; ', note, 'came to Montecasino from elsewhere, not on an S5 from Sandton');
      end if;
    elsif now_min < slots[i] + 15 then status := 'not yet';
    elsif not any_dep or not public.s5_logged(ts) then status := 'no data';
    else
      status := 'did not run';
      -- Was a bus waiting at the terminal at that time?
      select e into y from jsonb_array_elements(deps) e
        where (e ->> 'marr')::timestamptz <= ts and (e ->> 'dep')::timestamptz > ts
        order by (e ->> 'dep')::timestamptz limit 1;
      if y is not null then
        note := format('bus %s was at Montecasino from %s but only left at %s', y ->> 'bus',
                       public.s5_hm((y ->> 'marr')::timestamptz), public.s5_hm((y ->> 'dep')::timestamptz))
          || coalesce(' as the ' || to_char(make_time(slots[(y ->> 'slot')::int] / 60, slots[(y ->> 'slot')::int] % 60, 0), 'HH24:MI'), '');
      else
        select e into y from jsonb_array_elements(deps) e
          where (e ->> 'dep')::timestamptz > ts order by (e ->> 'dep')::timestamptz limit 1;
        if y is null then note := 'no bus left Montecasino after this';
        elsif y ->> 'marr' is null then
          note := format('the next bus, %s, left at %s; when it reached Montecasino is not in the log',
                         y ->> 'bus', public.s5_hm((y ->> 'dep')::timestamptz));
        elsif y ->> 'sleft' is null and not public.s5_covered((y ->> 'marr')::timestamptz - interval '45 minutes', (y ->> 'marr')::timestamptz) then
          note := format('no bus at the terminal: the next bus, %s, arrived at %s and left at %s',
                         y ->> 'bus', public.s5_hm((y ->> 'marr')::timestamptz), public.s5_hm((y ->> 'dep')::timestamptz));
        elsif y ->> 'sleft' is null then
          note := format('no bus at the terminal: the next bus, %s, arrived at %s from elsewhere (not an S5 from Sandton) and left at %s',
                         y ->> 'bus', public.s5_hm((y ->> 'marr')::timestamptz), public.s5_hm((y ->> 'dep')::timestamptz));
        else
          j := public.s5_slot_match(public.s5_day_min(d, (y ->> 'sleft')::timestamptz), inslots);
          why := case when j is null then '' else format(' (the %s from Sandton, %s min late)',
                   to_char(make_time(inslots[j] / 60, inslots[j] % 60, 0), 'HH24:MI'),
                   round(public.s5_day_min(d, (y ->> 'sleft')::timestamptz) - inslots[j])) end;
          note := format('no bus at the terminal: the next bus, %s, only arrived at %s; it left Sandton at %s%s',
                         y ->> 'bus', public.s5_hm((y ->> 'marr')::timestamptz), public.s5_hm((y ->> 'sleft')::timestamptz), why);
        end if;
      end if;
    end if;
    return next;
  end loop;
end $$;

-- Every S5 trip that reached Montecasino Terminal on a day, and when that bus left Sandton Station for it.
create or replace function public.s5_monte_arrivals(d date)
returns table (bus_id text, sandton_left_at timestamptz, monte_arrived_at timestamptz)
language sql stable
security definer
set search_path = public
as $$
  with p as (
    select l.bus_id, l.fix_at, l.seen_at, l.lat,
      public.s5_dist_m(l.lat, l.lon, -26.02466, 28.0114) as dm,
      public.s5_dist_m(l.lat, l.lon, -26.10801, 28.05673) < 150 as at_sandton
    from public.s5_pos_log l
    where l.fix_at >= (d::timestamp + interval '4 hours') at time zone 'Africa/Johannesburg'
      and l.fix_at < (d::timestamp + interval '24 hours') at time zone 'Africa/Johannesburg'
  ), q as (
    select p.*, p.dm < 150 as at_monte, lag(p.dm < 150) over w as was_monte,
      lag(p.seen_at) over w as prev_seen, lead(p.fix_at) over w as next_fix
    from p window w as (partition by p.bus_id order by p.fix_at)
  ), arr as (
    -- Into the terminal from well down William Nicol, without stopping at the terminal on the way.
    select q.bus_id, q.fix_at as in_at,
      case when q.fix_at - q.prev_seen > interval '5 minutes' then q.fix_at
           else q.prev_seen + (q.fix_at - q.prev_seen) / 2 end as monte_arrived_at
    from q where q.at_monte and not q.was_monte
      and exists (select 1 from p s where s.bus_id = q.bus_id and s.lat < -26.035
                    and s.fix_at between q.fix_at - interval '25 minutes' and q.fix_at
                    and not exists (select 1 from p m where m.bus_id = q.bus_id and m.dm < 150
                                      and m.fix_at > s.fix_at and m.fix_at < q.fix_at))
  )
  select a.bus_id,
    -- Last seen at Sandton Station before that, with no stop at the terminal in between: it left halfway to its next fix.
    (select s.seen_at + (coalesce(s.next_fix, s.seen_at) - s.seen_at) / 2 from q s
     where s.bus_id = a.bus_id and s.at_sandton and s.fix_at < a.in_at and s.fix_at > a.in_at - interval '100 minutes'
       and coalesce(s.next_fix, s.seen_at) - s.seen_at <= interval '5 minutes'
       and not exists (select 1 from p m where m.bus_id = a.bus_id and m.dm < 150 and m.fix_at > s.fix_at and m.fix_at < a.in_at)
     order by s.fix_at desc limit 1),
    a.monte_arrived_at
  from arr a
  order by 3
$$;

-- For every timetabled departure from Sandton Station to Montecasino on a day: did a bus leave, how late,
-- and when it reached Montecasino. A trip only shows once the bus reaches Montecasino.
create or replace function public.s5_sandton_report(d date)
returns table (scheduled time, status text, bus_id text, departed time, late_min numeric, monte time, trip_min numeric, note text)
language plpgsql stable
security definer
set search_path = public
as $$
declare
  slots int[] := public.s5_sandton_timetable();
  sast text := 'Africa/Johannesburg';
  got jsonb := '{}'; extra jsonb := '[]'; x jsonb; a record; i int; ts timestamptz; any_trip boolean := false;
  now_min numeric := public.s5_day_min(d, now());
begin
  for a in select * from public.s5_monte_arrivals(d) where sandton_left_at is not null order by sandton_left_at loop
    any_trip := true;
    i := public.s5_slot_match(public.s5_day_min(d, a.sandton_left_at), slots, got);
    x := jsonb_build_object('bus', a.bus_id, 'dep', a.sandton_left_at, 'arr', a.monte_arrived_at);
    if i is null then extra := extra || jsonb_build_array(x); else got := got || jsonb_build_object(i::text, x); end if;
  end loop;
  for i in 1 .. array_length(slots, 1) loop
    scheduled := make_time(slots[i] / 60, slots[i] % 60, 0);
    ts := (d + scheduled) at time zone sast;
    bus_id := null; departed := null; late_min := null; monte := null; trip_min := null; note := null;
    x := got -> i::text;
    if x is not null then
      bus_id := x ->> 'bus';
      departed := ((x ->> 'dep')::timestamptz at time zone sast)::time(0);
      late_min := round((extract(epoch from departed - scheduled) / 60)::numeric, 1);
      status := case when late_min < -1 then 'left early' when late_min > 3 then 'left late' else 'on time' end;
      monte := ((x ->> 'arr')::timestamptz at time zone sast)::time(0);
      trip_min := round((extract(epoch from (x ->> 'arr')::timestamptz - (x ->> 'dep')::timestamptz) / 60)::numeric, 1);
    elsif now_min < slots[i] + 100 then status := 'not yet';
    elsif not any_trip or not public.s5_logged(ts) then status := 'no data';
    else status := 'did not run'; note := 'no bus left Sandton Station for Montecasino near this time';
    end if;
    return next;
  end loop;
  for x in select e from jsonb_array_elements(extra) e loop
    scheduled := null; status := 'extra departure'; bus_id := x ->> 'bus'; late_min := null; note := null;
    departed := ((x ->> 'dep')::timestamptz at time zone sast)::time(0);
    monte := ((x ->> 'arr')::timestamptz at time zone sast)::time(0);
    trip_min := round((extract(epoch from (x ->> 'arr')::timestamptz - (x ->> 'dep')::timestamptz) / 60)::numeric, 1);
    return next;
  end loop;
end $$;

-- How each timetabled departure has done over the last few weekdays, for the app's timetable and warnings:
-- {"toSandton": {"09:17": {"n": days logged, "ran": days it ran, "late": median minutes late}}, "toMontecasino": {...}}
create or replace function public.s5_reliability(days int default 30)
returns jsonb
language sql stable
security definer
set search_path = public
as $$
  with h as (
    select dir, to_char(scheduled, 'HH24:MI') as t, status, late_min from public.s5_departure_history
    where scheduled is not null and status in ('on time', 'left late', 'left early', 'did not run')
      and day > (now() at time zone 'Africa/Johannesburg')::date - least(greatest(days, 1), 90)
  ), s as (
    select dir, t, count(*) as n, count(*) filter (where status <> 'did not run') as ran,
      percentile_cont(0.5) within group (order by late_min) filter (where status <> 'did not run') as late
    from h group by dir, t
  )
  select coalesce(jsonb_object_agg(dir, slots), '{}') from (
    select dir, jsonb_object_agg(t, jsonb_build_object('n', n, 'ran', ran, 'late', round(late::numeric, 1))) as slots
    from s group by dir) x
$$;

create or replace function public.s5_departure_nightly()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare d date := (now() at time zone 'Africa/Johannesburg')::date;
begin
  delete from public.s5_departure_history where day = d;
  insert into public.s5_departure_history (dir, day, scheduled, status, bus_id, departed_at, late_min, sandton_at, trip_min,
      monte_arrived_at, waited_min, sandton_left_at, sandton_slot, sandton_late_min, note)
    select 'toSandton', d, r.scheduled, r.status, r.bus_id, (d + r.departed) at time zone 'Africa/Johannesburg', r.late_min,
      (d + r.sandton) at time zone 'Africa/Johannesburg', r.trip_min, (d + r.monte_arrived) at time zone 'Africa/Johannesburg',
      r.waited_min, (d + r.left_sandton) at time zone 'Africa/Johannesburg', r.sandton_slot, r.sandton_late_min, r.note
    from public.s5_departure_report(d) r
    where r.status <> 'no data';
  insert into public.s5_departure_history (dir, day, scheduled, status, bus_id, departed_at, late_min, monte_arrived_at, trip_min, note)
    select 'toMontecasino', d, r.scheduled, r.status, r.bus_id, (d + r.departed) at time zone 'Africa/Johannesburg', r.late_min,
      (d + r.monte) at time zone 'Africa/Johannesburg', r.trip_min, r.note
    from public.s5_sandton_report(d) r
    where r.status not in ('no data', 'not yet');
  delete from public.s5_pos_log where fix_at < now() - interval '30 days';
  delete from public.s5_log_beat where at < now() - interval '30 days';
end $$;

-- Only pg_cron and the project owner call these; the app reads the per-departure summary.
revoke all on function public.s5_log_tick(), public.s5_monte_departures(date), public.s5_departure_report(date),
  public.s5_monte_arrivals(date), public.s5_sandton_report(date), public.s5_logged(timestamptz),
  public.s5_covered(timestamptz, timestamptz),
  public.s5_departure_nightly() from public, anon, authenticated;
grant execute on function public.s5_reliability(int) to anon, authenticated;

select cron.schedule('s5-log-tick', '30 seconds', 'select public.s5_log_tick()');
select cron.schedule('s5-departure-nightly', '30 20 * * 1-5', 'select public.s5_departure_nightly()');  -- 22:30 SAST
