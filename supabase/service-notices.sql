-- Gautrain service notices: the status ticker on gautrain.co.za's home page ("All services are operating to schedule",
-- with a green, or other coloured, icon), checked every 5 minutes. Each distinct notice is one row with when it was
-- first and last seen, so train delays can be lined up with the bus and connection data. One small page request per
-- check, about 200 a day. Kept 12 months.
create table if not exists public.s5_service_notices (
  id bigserial primary key,
  first_seen timestamptz not null default now(),
  last_seen timestamptz not null default now(),
  level text not null,              -- the ticker icon: green, or another colour when something is wrong
  title text not null default '',   -- the ticker's heading, when it has one
  message text not null
);
create index if not exists s5_service_notices_seen on public.s5_service_notices (last_seen desc);
alter table public.s5_service_notices enable row level security;
revoke all on public.s5_service_notices from anon, authenticated;

create or replace function public.s5_service_notices_tick() returns int
language plpgsql security definer set search_path = public, extensions as $$
declare
  r extensions.http_response; m text[]; n int := 0; v_title text; v_msg text; v_id bigint;
  ent constant text[] := array['&amp;', '&', '&#39;', '''', '&quot;', '"', '&nbsp;', ' ', '&lt;', '<', '&gt;', '>'];
begin
  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT', '20');
  r := extensions.http_get('https://www.gautrain.co.za/');
  if r.status <> 200 then return -1; end if;
  for m in select regexp_matches(r.content,
      -- (each part runs up to its own </span>; PostgreSQL doesn't honour a lazy .*? next to greedy quantifiers)
      '<li>\s*<img[^>]*src="/img/ticker_([a-z0-9_-]+)\.png"[^>]*>\s*<span>((?:[^<]|<(?!/span>))*)</span>\s*<span class="tickerTapeMsg">((?:[^<]|<(?!/span>))*)</span>', 'gi') loop
    v_title := btrim(regexp_replace(regexp_replace(m[2], '<[^>]+>', ' ', 'g'), '\s+', ' ', 'g'));
    v_msg := btrim(regexp_replace(regexp_replace(m[3], '<[^>]+>', ' ', 'g'), '\s+', ' ', 'g'));
    for i in 1 .. array_length(ent, 1) / 2 loop
      v_title := replace(v_title, ent[2 * i - 1], ent[2 * i]); v_msg := replace(v_msg, ent[2 * i - 1], ent[2 * i]);
    end loop;
    continue when v_msg = '';
    -- the same notice still showing (seen in the last 15 minutes): extend it; otherwise it's a new one
    select id into v_id from public.s5_service_notices
      where level = m[1] and title = v_title and message = v_msg and last_seen > now() - interval '15 minutes'
      order by last_seen desc limit 1;
    if v_id is null then
      insert into public.s5_service_notices (level, title, message) values (m[1], v_title, v_msg);
    else
      update public.s5_service_notices set last_seen = now() where id = v_id;
    end if;
    n := n + 1;
  end loop;
  delete from public.s5_service_notices where last_seen < now() - interval '12 months';
  return n;  -- notices on the page now; 0 means the page's layout changed and the reader needs a look
end $$;
revoke all on function public.s5_service_notices_tick() from public, anon, authenticated;
select cron.schedule('s5-service-notices', '*/5 3-20 * * *', 'select public.s5_service_notices_tick()');  -- 05:00-22:55 SAST, every day
