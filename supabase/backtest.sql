-- Arrival-time backtest (owner only). Replays every recorded trip in s5_stop_passages: from each stop the trip passed,
-- predict the time to every later stop with several methods, using only what would have been known then, and compare
-- with when the bus really got there. Run: select public.s5_backtest_run(); then select * from public.s5_backtest_summary().
--
-- Methods (minutes for each stretch, summed along the way):
--   timetable  the timetable's minutes
--   tomtom     timetable x TomTom typical traffic for that time of day (the app's fallback)
--   app        the learned median for the stretch and half hour (as s5_segment_profile: 3+ trips on 2+ days), from
--              the OTHER days only, else tomtom. This is what the app does today, without live traffic (not logged).
--   headway    the median time S5 buses took on the stretch in the 40 minutes before the prediction, same day and
--              direction (the buses ahead), else app
--   blend      half headway, half app where the buses ahead were seen, else app
--   live       app with live TomTom traffic, as the app applies it (needs traffic-log.sql)
--   shipped    what the app does now: the buses ahead first, then live, then app
-- It runs every weekday night (s5-backtest-nightly). Needs eta-learning.sql and traffic-log.sql.
--
-- Generated from index.html (RAW offsets, TRAFFIC_R): timetable minutes and TomTom typical-traffic ratios per stretch.
create table if not exists public.s5_bt_legs (dir text, leg int, tt float8, ratio float8[], primary key (dir, leg));
alter table public.s5_bt_legs add column if not exists mean_sec float8;  -- TomTom's daily average seconds (TRAFFIC_MEAN)
alter table public.s5_bt_legs enable row level security;
revoke all on public.s5_bt_legs from anon, authenticated;

insert into public.s5_bt_legs (dir, leg, tt, ratio, mean_sec) values
('toSandton', 0, 1, array[0.9096,1.0974,1.2559,1.0739,0.9448,0.9448,0.98,0.9624,0.9272,0.9038]::float8[], 170.4),
('toSandton', 1, 2, array[0.6,1.133,1.6913,1.4122,0.8867,0.8949,1.1905,1.0509,0.7225,0.6]::float8[], 121.8),
('toSandton', 2, 3, array[0.6438,0.9657,1.3646,1.0077,0.7768,0.8328,1.3016,1.3296,1.0707,0.7068]::float8[], 142.9),
('toSandton', 3, 1, array[0.8128,0.9852,1.1084,1.0345,1.0099,1.0837,1.1823,1.1576,0.936,0.6897]::float8[], 40.6),
('toSandton', 4, 2, array[0.6727,0.9122,1.2429,1.3569,1.0946,1.049,1.0262,1.0034,0.9236,0.7184]::float8[], 87.7),
('toSandton', 5, 1, array[0.7849,0.814,0.9012,0.9884,1.1047,1.1047,1.1337,1.1337,1.1047,0.9302]::float8[], 34.4),
('toSandton', 6, 3, array[0.8534,0.9091,1.0204,1.039,1.0111,1.0297,1.1224,1.1039,1.0111,0.8998]::float8[], 107.8),
('toSandton', 7, 5, array[0.8258,0.9621,1.197,1.1212,0.9697,0.9848,1.0758,1.0379,0.9621,0.8636]::float8[], 132.0),
('toSandton', 8, 2, array[0.7892,0.9921,1.2063,1.071,0.9696,0.9921,1.1161,1.0598,0.9696,0.8343]::float8[], 88.7),
('toSandton', 9, 4, array[0.7057,0.8625,1.3643,1.0873,1.0507,1.1291,1.1762,1.0403,0.8573,0.7266]::float8[], 191.3),
('toSandton', 10, 1, array[0.8636,0.9545,1.3636,1.0455,0.9545,0.9545,1,1,0.9545,0.9091]::float8[], 22.0),
('toSandton', 11, 3, array[0.8862,0.9519,1.105,1.0394,0.9628,0.9737,1.0832,1.0722,1.0066,0.919]::float8[], 91.4),
('toSandton', 12, 1, array[0.9365,1.0033,1.0033,1.0033,1.0033,1.0033,1.0368,1.0368,1.0033,0.9699]::float8[], 29.9),
('toSandton', 13, 3, array[0.8153,1.1868,1.5686,1.0836,0.8669,0.8875,0.9391,0.9288,0.8875,0.8359]::float8[], 96.9),
('toSandton', 14, 2, array[0.8499,0.9562,1.1421,1.0491,0.9429,0.9562,1.1687,1.1023,0.9695,0.8632]::float8[], 75.3),
('toSandton', 15, 2, array[0.7909,0.9227,1.116,1.0193,0.949,0.9666,1.1775,1.1775,1.0369,0.8436]::float8[], 113.8),
('toSandton', 16, 4, array[0.7743,1.0028,1.2453,1.0308,0.8862,0.9235,1.1987,1.1427,0.9888,0.8069]::float8[], 214.4),
('toMontecasino', 0, 2, array[0.7405,0.8038,0.9937,1.0316,0.962,1.0063,1.2089,1.2658,1.1266,0.8608]::float8[], 158.0),
('toMontecasino', 1, 1, array[0.8703,0.9059,1.048,1.048,0.9236,0.9591,1.2078,1.1545,0.9947,0.8881]::float8[], 56.3),
('toMontecasino', 2, 1, array[0.7783,0.8491,1.0849,1.1085,0.9198,0.9434,1.2264,1.2028,1.0613,0.8255]::float8[], 42.4),
('toMontecasino', 3, 3, array[0.8837,0.9186,1,1.0233,1,1.0116,1.1744,1.0814,0.9884,0.9186]::float8[], 86.0),
('toMontecasino', 4, 2, array[0.8188,0.911,1.085,1.0645,0.9621,1.0133,1.2078,1.1054,0.9826,0.8495]::float8[], 97.7),
('toMontecasino', 5, 1, array[0.9653,0.9653,1.0039,1.0039,1.0039,1.0039,1.0425,1.0425,1.0039,0.9653]::float8[], 25.9),
('toMontecasino', 6, 3, array[0.8222,0.9069,1.2213,1.052,0.9311,0.9794,1.0883,1.0883,1.0157,0.8948]::float8[], 82.7),
('toMontecasino', 7, 1, array[0.8205,0.8718,1.4359,1.0769,0.9231,0.9744,1.0256,1.0256,0.9744,0.8718]::float8[], 19.5),
('toMontecasino', 8, 5, array[0.838,0.8883,1.0168,1.0168,0.9777,1.0279,1.2346,1.1453,0.9888,0.8659]::float8[], 179.0),
('toMontecasino', 9, 1, array[0.7479,0.7906,0.9188,0.9615,0.9402,1.0043,1.4316,1.3248,1.047,0.8333]::float8[], 46.8),
('toMontecasino', 10, 4, array[0.8621,0.9267,0.977,0.977,0.9914,1.0345,1.1566,1.1351,1.0345,0.9052]::float8[], 139.2),
('toMontecasino', 11, 2, array[0.8443,0.863,0.9381,1.0131,1.1257,1.1632,1.1257,1.0507,0.9756,0.9006]::float8[], 53.3),
('toMontecasino', 12, 2, array[0.8424,0.8785,1.0108,1.0469,1.0469,1.059,1.1312,1.0951,0.9988,0.8905]::float8[], 83.1),
('toMontecasino', 13, 3, array[0.6987,0.7773,0.9083,0.9083,0.8908,0.9782,1.6943,1.4061,1.0131,0.7249]::float8[], 114.5),
('toMontecasino', 14, 2, array[0.6,0.7921,0.9406,0.7921,0.6683,0.7921,2,1.7946,1.0396,0.6]::float8[], 80.8),
('toMontecasino', 15, 3, array[0.6,0.7708,0.8993,0.8171,0.7708,0.9096,1.9733,1.6393,1.038,0.6]::float8[], 194.6),
('toMontecasino', 16, 4, array[0.7775,0.8789,0.9465,0.9634,1.0423,1.1155,1.1437,1.1268,1.0873,0.9183]::float8[], 177.5)
  on conflict (dir, leg) do update set tt = excluded.tt, ratio = excluded.ratio, mean_sec = excluded.mean_sec;
-- the times of day (minutes) the ratios were sampled at
create or replace function public.s5_bt_at() returns int[] language sql immutable as $$ select array[330,390,450,510,630,780,990,1050,1110,1230] $$;

-- TomTom typical ratio at minute-of-day m, interpolated between the sampled times (as tomTomTypical in the app).
create or replace function public.s5_bt_ratio(r float8[], m float8) returns float8 language plpgsql immutable as $$
declare h int[] := public.s5_bt_at(); s int;
begin
  m := ((m::numeric % 1440) + 1440) % 1440;
  if m <= h[1] then return r[1]; end if;
  for s in 1 .. array_length(h, 1) - 1 loop
    if m < h[s + 1] then return r[s] + (m - h[s]) / (h[s + 1] - h[s]) * (r[s + 1] - r[s]); end if;
  end loop;
  return r[array_length(h, 1)];
end $$;

create table if not exists public.s5_backtest (
  day date, dir text, scheduled time, origin int, target int, origin_at timestamptz,
  actual float8,                                   -- minutes the bus really took from origin to target
  timetable float8, tomtom float8, app float8, headway float8, blend float8,
  learned_legs int, headway_legs int, legs int,    -- how many stretches had a learned median / buses ahead
  run_at timestamptz default now(),
  primary key (day, dir, scheduled, origin, target)
);
alter table public.s5_backtest enable row level security;
revoke all on public.s5_backtest from anon, authenticated;
-- live      app, with live TomTom traffic as the app applies it (from s5_traffic_log, the snapshot the app would have had)
-- shipped   what the app does now: the buses ahead (one bus far out of line ignored), fading out 30-75 min ahead, then live
alter table public.s5_backtest add column if not exists live float8, add column if not exists shipped float8,
  add column if not exists live_legs int;

-- Replay the trips of every day from p_since (all days if null).
create or replace function public.s5_backtest_run() returns int
language plpgsql security definer set search_path = public as $$ begin return public.s5_backtest_run_since(null); end $$;

create or replace function public.s5_backtest_run_since(p_since date) returns int
language plpgsql security definer set search_path = public as $$
declare
  tz text := 'Africa/Johannesburg'; dd record; tr record; n int := 0;
  learned jsonb; hw jsonb; p timestamptz[]; last int; i int; j int; t0 timestamptz; m0 float8;
  c_tt float8; c_tom float8; c_app float8; c_hw float8; c_bl float8; c_live float8; c_sh float8; nl int; nh int; nlive int;
  lg record; lv float8; hv float8; tomv float8; appv float8; snap int[]; r float8; w float8; tr2 float8; a2 float8;
  livev float8; road2 float8; hn int; ha float8; shv float8;
begin
  create temp table if not exists bt_seg on commit drop as
    select a.day, a.dir, a.scheduled, a.stop_idx as leg, b.passed_at as ended_at,
      (floor(extract(epoch from (a.passed_at at time zone tz)::time) / 1800) * 30)::int as bucket,
      extract(epoch from b.passed_at - a.passed_at) / 60 as mins
    from s5_stop_passages a
    join s5_stop_passages b on b.day = a.day and b.dir = a.dir and b.scheduled = a.scheduled and b.stop_idx = a.stop_idx + 1
    where extract(epoch from b.passed_at - a.passed_at) between 1 and 1800;
  for dd in select distinct day, dir from s5_stop_passages where p_since is null or day >= p_since order by 1, 2 loop
    -- learned medians from the other days only
    select coalesce(jsonb_object_agg(bucket || ':' || leg, med), '{}') into learned from (
      select bucket, leg, percentile_cont(0.5) within group (order by mins) as med from bt_seg
      where dir = dd.dir and day <> dd.day group by bucket, leg having count(*) >= 3 and count(distinct day) >= 2) x;
    last := (select max(leg) + 1 from s5_bt_legs where dir = dd.dir);
    for tr in select scheduled, bus_id from s5_stop_passages where day = dd.day and dir = dd.dir and stop_idx = 0 loop
      p := array_fill(null::timestamptz, array[last + 1], array[0]);
      for lg in select stop_idx, passed_at from s5_stop_passages where day = dd.day and dir = dd.dir and scheduled = tr.scheduled loop
        p[lg.stop_idx] := lg.passed_at;
      end loop;
      for i in 0 .. last - 1 loop
        continue when p[i] is null;
        t0 := p[i]; m0 := extract(epoch from (t0 at time zone tz)::time) / 60;
        select coalesce(jsonb_object_agg(leg, jsonb_build_array(med, cnt)), '{}') into hw from (
          select leg, percentile_cont(0.5) within group (order by mins) as med, count(*) as cnt from bt_seg
          where day = dd.day and dir = dd.dir and scheduled <> tr.scheduled and ended_at <= t0 and ended_at > t0 - interval '40 minutes'
          group by leg) h;
        -- the live TomTom snapshot the app would have had (it uses one up to 8 minutes old)
        snap := (select case when dd.dir = 'toSandton' then to_sandton else to_montecasino end from s5_traffic_log
                 where at <= t0 and at > t0 - interval '8 minutes' order by at desc limit 1);
        c_tt := 0; c_tom := 0; c_app := 0; c_hw := 0; c_bl := 0; c_live := 0; c_sh := 0; nl := 0; nh := 0; nlive := 0;
        for j in i .. last - 1 loop
          select * into lg from s5_bt_legs where dir = dd.dir and leg = j;
          tomv := lg.tt * public.s5_bt_ratio(lg.ratio, m0 + c_tom);
          lv := (learned ->> ((floor((m0 + c_app) / 30) * 30)::int || ':' || j))::float8;
          appv := coalesce(lv, lg.tt * public.s5_bt_ratio(lg.ratio, m0 + c_app));
          hv := (hw -> j::text ->> 0)::float8; hn := (hw -> j::text ->> 1)::int;
          -- live: typical x (live / TomTom typical), full for the next 15 min, fading out by 60 (roadRatio in the app)
          tr2 := public.s5_bt_ratio(lg.ratio, m0 + c_live);
          a2 := coalesce((learned ->> ((floor((m0 + c_live) / 30) * 30)::int || ':' || j))::float8, lg.tt * tr2);
          if snap is not null and lg.mean_sec > 0 then
            r := least(3, greatest(0.5, snap[j + 1] / lg.mean_sec));
            w := case when c_live <= 15 then 1 when c_live >= 60 then 0 else 1 - (c_live - 15) / 45 end;
            livev := a2 * (w * r / tr2 + 1 - w);
          else livev := a2; end if;
          -- shipped: the buses ahead first (trafficRatio + aheadRatio in the app), then the same live as above
          tr2 := public.s5_bt_ratio(lg.ratio, m0 + c_sh);
          a2 := coalesce((learned ->> ((floor((m0 + c_sh) / 30) * 30)::int || ':' || j))::float8, lg.tt * tr2);
          if snap is not null and lg.mean_sec > 0 then
            w := case when c_sh <= 15 then 1 when c_sh >= 60 then 0 else 1 - (c_sh - 15) / 45 end;
            road2 := a2 * (w * least(3, greatest(0.5, snap[j + 1] / lg.mean_sec)) / tr2 + 1 - w);
          else road2 := a2; end if;
          ha := case when hv is null or (hn < 2 and hv > 3 * greatest(0.5, lg.tt) + 6) then null
                     else least(15, greatest(0.2, hv / greatest(0.5, lg.tt))) * lg.tt end;
          w := case when c_sh <= 30 then 1 when c_sh >= 75 then 0 else 1 - (c_sh - 30) / 45 end;
          shv := case when ha is null then road2 else w * ha + (1 - w) * road2 end;
          c_tt := c_tt + lg.tt; c_tom := c_tom + tomv; c_app := c_app + appv;
          c_hw := c_hw + coalesce(hv, appv); c_bl := c_bl + case when hv is null then appv else (hv + appv) / 2 end;
          c_live := c_live + livev; c_sh := c_sh + shv;
          nl := nl + (lv is not null)::int; nh := nh + (hv is not null)::int; nlive := nlive + (snap is not null)::int;
          if p[j + 1] is not null then
            insert into s5_backtest (day, dir, scheduled, origin, target, origin_at, actual, timetable, tomtom, app, headway, blend, live, shipped,
                                     learned_legs, headway_legs, live_legs, legs)
            values (dd.day, dd.dir, tr.scheduled, i, j + 1, t0, extract(epoch from p[j + 1] - t0) / 60, c_tt, c_tom, c_app, c_hw, c_bl, c_live, c_sh,
                    nl, nh, nlive, j + 1 - i)
            on conflict (day, dir, scheduled, origin, target) do update set origin_at = excluded.origin_at, actual = excluded.actual,
              timetable = excluded.timetable, tomtom = excluded.tomtom, app = excluded.app, headway = excluded.headway, blend = excluded.blend,
              live = excluded.live, shipped = excluded.shipped, learned_legs = excluded.learned_legs, headway_legs = excluded.headway_legs,
              live_legs = excluded.live_legs, legs = excluded.legs, run_at = now();
            n := n + 1;
          end if;
        end loop;
      end loop;
    end loop;
  end loop;
  return n;
end $$;

-- Error by method and how far ahead the prediction was (minutes the bus really took). Positive bias = predicted too long.
-- From day p_since (all days if null); "live" only where a live TomTom snapshot was logged.
create or replace function public.s5_backtest_summary()
returns table (horizon text, method text, n bigint, mae numeric, median_abs numeric, p90_abs numeric, bias numeric, within_2min numeric)
language plpgsql stable security definer set search_path = public as $$ begin return query select * from public.s5_backtest_summary_since(null); end $$;

create or replace function public.s5_backtest_summary_since(p_since date)
returns table (horizon text, method text, n bigint, mae numeric, median_abs numeric, p90_abs numeric, bias numeric, within_2min numeric)
language sql stable security definer set search_path = public as $$
  with b as (
    select case when actual < 5 then '0-5' when actual < 10 then '05-10' when actual < 20 then '10-20' when actual < 35 then '20-35' else '35+' end as h,
      actual, timetable, tomtom, app, headway, blend, case when live_legs > 0 then live end as live, shipped
    from s5_backtest where p_since is null or day >= p_since
  ), e as (
    select h, m.method, m.pred - actual as err from b
    cross join lateral (values ('1 timetable', timetable), ('2 tomtom', tomtom), ('3 app', app), ('4 headway', headway), ('5 blend', blend),
                               ('6 live', live), ('7 shipped', shipped)) m(method, pred)
    where m.pred is not null
  )
  select h, method, count(*), round(avg(abs(err))::numeric, 1), round(percentile_cont(0.5) within group (order by abs(err))::numeric, 1),
    round(percentile_cont(0.9) within group (order by abs(err))::numeric, 1), round(avg(err)::numeric, 1),
    round(100.0 * avg((abs(err) <= 2)::int), 0)
  from e group by h, method order by h, method
$$;
-- Every weekday night, after the day's stop passages are recorded (s5-eta-nightly, 22:45 SAST): replay the last three
-- days (earlier days keep their scores), and drop old logs.
create or replace function public.s5_backtest_nightly() returns void
language plpgsql security definer set search_path = public as $$
begin
  perform public.s5_backtest_run_since((now() at time zone 'Africa/Johannesburg')::date - 3);
  delete from public.s5_backtest where day < (now() at time zone 'Africa/Johannesburg')::date - 120;
  delete from public.s5_traffic_log where at < now() - interval '30 days';
end $$;

revoke all on function public.s5_backtest_run(), public.s5_backtest_run_since(date), public.s5_backtest_summary(),
  public.s5_backtest_summary_since(date), public.s5_backtest_nightly() from public, anon, authenticated;
select cron.schedule('s5-backtest-nightly', '5 21 * * 1-5', 'select public.s5_backtest_nightly()');  -- 23:05 SAST
