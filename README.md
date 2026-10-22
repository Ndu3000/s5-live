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
- The route line and stop positions come from OpenStreetMap route relation 3281475 (© OpenStreetMap
  contributors, ODbL). Map tiles © CARTO.
