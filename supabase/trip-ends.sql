-- Anonymous trip ends for route planning, as deployed in Supabase project gautrain-s5-live.
-- With "Help plan new routes" switched on in the app (off by default), a phone shares where its commute starts
-- (first mile) and ends (last mile). The phone snaps each point to a ~500 m grid before sending it and never sends
-- place names. Each phone has one row per trip end under a random id, updated in place, so there is no movement
-- history. Switching sharing off deletes the phone's rows. Only the project owner can read the data or the analysis.

create table if not exists public.s5_trip_ends (
  device uuid not null,            -- random id made on the phone, not linked to a person
  role text not null check (role in ('first_mile', 'last_mile')),
  lat numeric(7, 3) not null,      -- ~500 m grid
  lon numeric(7, 3) not null,
  usual_time time,                 -- when the morning journey usually starts, to the nearest 15 min
  updated_at timestamptz not null default now(),
  primary key (device, role)
);
alter table public.s5_trip_ends enable row level security;  -- no policies: only the functions below touch it

-- Snap to the ~500 m grid (0.005°), so a shared point is an area, not an address.
create or replace function public.s5_snap(v float8)
returns numeric language sql immutable as $$ select round((round(v / 0.005) * 0.005)::numeric, 3) $$;

create or replace function public.s5_share_trip_end(p_device uuid, p_role text, p_lat float8, p_lon float8, p_usual text default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare u time;
begin
  if p_role not in ('first_mile', 'last_mile') then raise exception 'role must be first_mile or last_mile'; end if;
  if p_lat not between -26.9 and -25.1 or p_lon not between 27.3 and 29.1 then raise exception 'point is outside Gauteng'; end if;
  -- A cheap brake on abuse: the app writes a couple of rows when settings change, never hundreds a minute.
  if (select count(*) from public.s5_trip_ends where updated_at > now() - interval '1 minute') > 120 then
    raise exception 'too many updates, try again shortly';
  end if;
  if p_usual ~ '^\d\d:\d\d$' then
    u := make_time(split_part(p_usual, ':', 1)::int, (split_part(p_usual, ':', 2)::int / 15) * 15, 0);
  end if;
  insert into public.s5_trip_ends as t (device, role, lat, lon, usual_time, updated_at)
    values (p_device, p_role, public.s5_snap(p_lat), public.s5_snap(p_lon), u, now())
  on conflict (device, role) do update
    set lat = excluded.lat, lon = excluded.lon, usual_time = excluded.usual_time, updated_at = now();
end $$;

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
revoke all on function public.s5_share_trip_end(uuid, text, float8, float8, text), public.s5_forget_trip_ends(uuid, text)
  from public;
grant execute on function public.s5_share_trip_end(uuid, text, float8, float8, text), public.s5_forget_trip_ends(uuid, text)
  to anon, authenticated;
