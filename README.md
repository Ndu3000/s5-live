# S5 Live

Live map of Gautrain buses between Montecasino and Sandton, with alerts when a bus is
a set number of minutes from your stop.

Open it at **https://ndu3000.github.io/s5-live/**. Tap **Turn on alerts** and keep the
page open: alerts only sound while the page is on screen.

- `index.html` — the app (single file, Leaflet + OpenStreetMap).
- `relay/gautrain-bus/index.ts` — Supabase Edge Function (project `gautrain-s5-live`) that
  forwards requests to Gautrain's bus-location feed and adds the CORS headers browsers need.

Bus positions come from Gautrain's unofficial bus-location feed, which doesn't say which
route a bus is on, so the map shows every Gautrain bus between Montecasino and Sandton.
Arrival times are estimates from live GPS and straight-line distance.
