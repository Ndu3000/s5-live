// Live traffic for the S5 Bus Tracker: asks TomTom how long each stretch between
// consecutive S5 stops takes right now (live traffic), in both directions, and
// returns the seconds per stretch. Answers are cached for two minutes, so TomTom
// is only called while someone has the app open, and at most ~1,000 times a day.
// Needs the TOMTOM_API_KEY secret. Deploys as a Supabase Edge Function.

const KEY = Deno.env.get("TOMTOM_API_KEY") ?? "";
const CACHE_MS = 120_000;

// Timetable stops, in order, as [lat, lon] (same points the app uses).
const STOPS: Record<string, [number, number][]> = {
  toSandton: [[-26.02467, 28.01143], [-26.02813, 28.00963], [-26.03346, 28.01029], [-26.04185, 28.01514], [-26.04338, 28.0168], [-26.04839, 28.02081], [-26.05209, 28.02137], [-26.06134, 28.02386], [-26.07572, 28.02687], [-26.07411, 28.03452], [-26.07773, 28.0484], [-26.08025, 28.0496], [-26.08638, 28.04777], [-26.08809, 28.04718], [-26.09487, 28.052], [-26.09998, 28.05028], [-26.10431, 28.05094], [-26.10807, 28.05673]],
  toMontecasino: [[-26.10807, 28.05673], [-26.10409, 28.05345], [-26.1016, 28.05076], [-26.09993, 28.05015], [-26.09356, 28.05116], [-26.08678, 28.04687], [-26.08561, 28.04922], [-26.07972, 28.04936], [-26.0775, 28.04828], [-26.07495, 28.03125], [-26.07584, 28.0276], [-26.0645, 28.02444], [-26.0598, 28.02331], [-26.05276, 28.02132], [-26.04458, 28.01799], [-26.04165, 28.0148], [-26.0321, 28.00966], [-26.02467, 28.01143]],
};

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, OPTIONS",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json", "Cache-Control": "no-store" } });

async function legSeconds(points: [number, number][]) {
  const path = points.map(([lat, lon]) => `${lat},${lon}`).join(":");
  const url = `https://api.tomtom.com/routing/1/calculateRoute/${path}/json?key=${encodeURIComponent(KEY)}&traffic=true&routeType=fastest&computeTravelTimeFor=all`;
  const res = await fetch(url, { signal: AbortSignal.timeout(10000) });
  if (!res.ok) throw new Error(`TomTom HTTP ${res.status}`);
  const route = (await res.json()).routes?.[0];
  if (!route?.legs?.length) throw new Error("TomTom sent no route");
  return {
    live: route.legs.map((l: any) => l.summary.travelTimeInSeconds),
    typical: route.legs.map((l: any) => l.summary.historicTrafficTravelTimeInSeconds ?? null),
    delay: route.summary.trafficDelayInSeconds ?? 0,
  };
}

let cache: { at: number; body: Record<string, unknown> } | null = null;
let pending: Promise<Record<string, unknown>> | null = null;

async function refresh() {
  const [toSandton, toMontecasino] = await Promise.all([legSeconds(STOPS.toSandton), legSeconds(STOPS.toMontecasino)]);
  return { at: Date.now(), source: "TomTom live traffic", toSandton, toMontecasino };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: CORS });
  if (!KEY) return json({ error: "TOMTOM_API_KEY is not set" }, 503);
  if (!cache || Date.now() - cache.at > CACHE_MS) {
    try {
      pending ??= refresh().finally(() => { pending = null; });
      cache = { at: Date.now(), body: await pending };
    } catch (e) {
      if (!cache) return json({ error: "live traffic unavailable", detail: String(e) }, 502);
      // Keep serving the last good answer (the app shows its age) and try TomTom again in 30 s.
      cache.at = Date.now() - CACHE_MS + 30_000;
    }
  }
  return json(cache.body);
});
