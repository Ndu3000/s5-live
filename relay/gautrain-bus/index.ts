// Relay for the S5 live map: forwards bus-position requests to Gautrain's
// bus-location feed and adds CORS headers so a phone browser can read the answer.
// It only ever calls that one feed, only for a box inside Gauteng, and caches
// each answer for a few seconds so many open phones make few upstream calls.
// Deploys as a Supabase Edge Function.

const UPSTREAM = "https://api.gautrain.co.za/transport-api/api/0/busses/location";
const GAUTENG = { west: 27.0, south: -26.9, east: 29.0, north: -25.0 };
const DEFAULT_BOX = { west: 27.94, south: -26.15, east: 28.10, north: -25.97 };
const CACHE_MS = 5000;

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
};

type Box = { west: number; south: number; east: number; north: number };
const cache = new Map<string, { at: number; status: number; body: string }>();

function clampBox(input: Record<string, unknown> | null): Box {
  const n = (k: keyof Box) => {
    const v = Number(input?.[k]);
    return Number.isFinite(v) ? v : DEFAULT_BOX[k];
  };
  const box = {
    west: Math.max(GAUTENG.west, n("west")),
    south: Math.max(GAUTENG.south, n("south")),
    east: Math.min(GAUTENG.east, n("east")),
    north: Math.min(GAUTENG.north, n("north")),
  };
  return box.west < box.east && box.south < box.north ? box : DEFAULT_BOX;
}

export async function handle(req: Request): Promise<Response> {
  if (req.method === "OPTIONS") return new Response(null, { headers: CORS });

  let input: Record<string, unknown> | null = null;
  if (req.method === "POST") {
    try { input = await req.json(); } catch { input = null; }
  } else {
    input = Object.fromEntries(new URL(req.url).searchParams);
  }
  const box = clampBox(input);
  const key = [box.west, box.south, box.east, box.north].map((v) => v.toFixed(3)).join(",");

  const hit = cache.get(key);
  let result = hit && Date.now() - hit.at < CACHE_MS ? hit : null;
  if (!result) {
    try {
      const res = await fetch(UPSTREAM, {
        method: "POST",
        headers: { "Content-Type": "application/json", "Accept": "application/json" },
        // The feed takes the box as strings.
        body: JSON.stringify({
          east: String(box.east), south: String(box.south), north: String(box.north), west: String(box.west),
        }),
        signal: AbortSignal.timeout(10000),
      });
      result = { at: Date.now(), status: res.status, body: await res.text() };
      cache.set(key, result);
    } catch (e) {
      return new Response(JSON.stringify({ error: "upstream unreachable", detail: String(e) }), {
        status: 502, headers: { ...CORS, "Content-Type": "application/json" },
      });
    }
  }

  return new Response(result.body, {
    status: result.status,
    headers: { ...CORS, "Content-Type": "application/json", "Cache-Control": "no-store" },
  });
}

Deno.serve(handle);
