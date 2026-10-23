# S5 Bus Tracker

Never miss the Gautrain S5 bus between Sandton Station and Montecasino. Open it at
**https://ndu3000.github.io/s5-live/**.

- **Live**: the next bus you can catch, when to leave, and where your bus really is (live GPS).
- **Route**: a live map of the S5 with every bus on it, plus the stop-by-stop list with times.
- **Timetable** and **Plan**: the weekday timetable from any stop, and "arrive by" / "leave after" planning.
- Alerts ring (sound, vibration, notification) when it's time to leave. Keep the page open on screen.

How live GPS works:

- Positions come from Gautrain's bus-location feed every 10 seconds, through the relay in
  `relay/gautrain-bus/index.ts` (Supabase Edge Function in project `gautrain-s5-live`), which adds the
  headers browsers need.
- The feed doesn't say which route a bus is on. The app snaps each bus to the S5 road line, taking
  its direction into account, and pairs it with the nearest timetable trip.
- An early bus brings "leave by" forward. A late one only moves it back once the scheduled leave time has passed.
- Arrival estimates use TomTom's typical weekday traffic for each stretch of the route (sampled at ten times
  of day with TomTom routing, historical traffic). Each stretch's timetable minutes are scaled by how much slower or
  faster it is than its daily average, for live arrival times and for the "expected" times when live GPS
  can't see a bus. "Arrive by" plans pick a bus that typically makes it.
- Live traffic: `relay/s5-traffic/index.ts` (Supabase Edge Function, needs the `TOMTOM_API_KEY` secret) asks
  TomTom for the current driving time of every stretch, cached for 2 minutes. The app trusts it for the next
  15 minutes, blends back to typical traffic over the following 45, and names slow stretches.
- Backup routes: if the Edge Functions are unavailable, the app calls database functions on the same Supabase
  project through its REST API (`supabase/backup-relays.sql`). The TomTom key can be stored either as the
  `TOMTOM_API_KEY` Edge Function secret or in Supabase Vault as `tomtom_api_key`. A scheduled GitHub workflow
  calls the project every two days so Supabase doesn't pause it for inactivity.
- Departure log: on weekdays the Supabase project saves the S5 buses' GPS every 30 seconds and works out, for
  every timetabled departure from Montecasino and from Sandton Station, whether a bus left, how late, and when it
  arrived (`supabase/departure-log.sql`). The app warns when a departure has no bus on live GPS, and the timetable
  marks departures that often don't run or leave late (`public.s5_reliability`).
- Without a TomTom key, Gautrain's own buses are the traffic sensors: each S5 bus's progress over the last 3-6
  minutes, against what the timetable expects in typical traffic, sets a live factor for the stretches it drove
  (kept for 15 minutes).
- The route line and stop positions come from OpenStreetMap route relation 3281475, and the map tiles are
  OpenStreetMap's (© OpenStreetMap contributors, ODbL).
