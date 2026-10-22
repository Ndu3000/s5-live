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
  15 minutes, blends back to typical traffic over the following 45, and names slow stretches. Without the
  key, the app uses typical traffic.
- The route line and stop positions come from OpenStreetMap route relation 3281475, and the map tiles are
  OpenStreetMap's (© OpenStreetMap contributors, ODbL).
