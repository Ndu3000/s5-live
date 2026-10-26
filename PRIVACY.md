# Privacy notice

**S5 Bus Tracker** · last updated **26 October 2026** · applies to https://ndu3000.github.io/s5-live/

This notice explains, in plain language, what the app does with information about you, as required by South
Africa's Protection of Personal Information Act, 2013 (POPIA). The short version:

- You can use every feature without an account, and without telling us anything about yourself.
- Your saved places, settings and alerts stay **on your phone**.
- Only if you choose to **help plan new routes** does anything about your commute leave your phone. Even then,
  it is the rough area (about 500 m) where your commute starts and ends, never names or addresses. You can stop,
  and delete it, at any time.

## 1. Who we are

S5 Bus Tracker is a free, **independent, open-source citizen project**, built and run by a volunteer. It is
**not** affiliated with, endorsed by or run on behalf of the Gautrain Management Agency, its operator SSM, or any
government body. For official timetables and service notices, see gautrain.co.za or call the Gautrain bus
information line on 010 223 1098.

The **responsible party** under POPIA is the project maintainer, GitHub user **Ndu3000**, who is also the
information officer for this project.

**Contact:** open an issue at https://github.com/Ndu3000/s5-live/issues. Issues are public, so please don't
include personal details there; say you have a privacy request and the maintainer will arrange a private way to
continue.

## 2. What stays on your phone

Stored only in your browser's storage on your phone, and never sent to us:

| Information | Why | How to remove it |
|---|---|---|
| Settings (stops, walking time, alerts, commute times) | So the app remembers how you use it | Change them in Settings, or clear this site's data in your browser |
| **Saved places** (names and exact points, e.g. "Home") | To plan the ride to and from the S5 | Delete them in Settings → Saved places |
| Ride times for each saved place | So the commute card can plan without asking again | Deleted with the place, or after 30 days |
| A random code for route-planning sharing (only if you turn it on) | So your shared entry can be updated or deleted | Clear this site's data |

## 3. What leaves your phone, and why

| When | What is sent | To whom | Kept by this project? |
|---|---|---|---|
| Always, while the app is open | Requests for live bus positions, live traffic and service reliability. **No personal information.** | The app's server (Supabase, see section 6), which fetches Gautrain's and TomTom's data | No. Like any website, the hosting services see your device's IP address in short-lived technical logs. |
| You add a saved place | The place's coordinates, **once**, to work out driving times to and from the S5 | The app's server, which asks TomTom | No. The coordinates travel in the body of the request, so they don't appear in server logs, and nothing is stored. TomTom handles the request under its own privacy policy. |
| You search for an address | The text you type | OpenStreetMap Foundation's Nominatim search | No |
| You tap "Save where I am now" | Nothing. Your phone asks your permission, then gives the app your location once, and it is saved only on your phone. | Nobody | No |
| You tap "I'm on a bus" (or it's your commute time and you've allowed location) | Nothing. While it runs, your location is compared with the buses' GPS **on your phone** to recognise your bus; it stops when you get off, tap Stop, or after 25 minutes without a match. | Nobody | No |
| **Only if you choose "Share my confirmed rides"**, when a confirmed ride ends | See section 4A | The app's server | Yes, see section 4A |
| You tap "Open Uber" | The pickup and drop-off points, inside the Uber app | Uber | No. Uber's privacy policy applies. |
| **Only if you agree to help plan new routes** | See section 4 | The app's server | Yes, see section 4 |

The app has no accounts, no advertising, no analytics trackers and no cookies.

## 4. Helping plan new routes (optional, only with your consent)

**Purpose.** To find out where people's journeys start and end compared with where the S5 runs. That shows where
a new route, an extra stop, a feeder service or more frequent buses would help the most people. It also supports
the case for better public transport with evidence.

**What is shared**, once you agree on the consent screen:

- the **area** your commute starts in (first mile) and ends in (last mile), rounded **on your phone** to a grid of
  about 500 m, so it is a neighbourhood, not an address;
- the time you usually set off, rounded to the nearest 15 minutes;
- a **random code** made on your phone. It is not linked to your name, number, phone or any account. It only lets
  your entry be updated or deleted;
- the date of the notice you agreed to, as a record of your consent.

**Never shared:** place names, exact points, addresses, your live location or trips, your name, phone number or
contacts.

**Who can see it.** Only the project maintainer. Results are used, published or shared (for example with
transport authorities, municipalities or researchers) **only as counts per area or per hour, and never for groups
of fewer than 3 people.** It is never sold, never used for advertising, and we don't try to work out who anyone is.

**How long.** Until you turn sharing off, which deletes your entry from the server immediately. While you keep
using the app, it refreshes your entry about once a month. Entries not refreshed for 12 months are deleted
automatically.

**It's your choice.** Sharing is voluntary and off unless you turn it on. The app works exactly the same either
way. Please don't turn it on if you are under 18.

## 4A. Sharing your confirmed rides (optional, only if you choose it)

**Purpose.** To check and improve the app's arrival times. A ride you confirmed shows which bus really ran which
departure, and when it reached the stops along the way.

**What is shared**, when a ride you confirmed with "I'm on a bus" ends: the bus number, its direction and timetabled
departure, how the ride was recognised (GPS match or picked from the list), the stop and time where the ride was
confirmed, the stop and time where it ended, and why it ended (last stop, got off, or you tapped "I got off").

**Never shared:** your location or GPS track, your saved places, your name, number, or anything that links the
ride to you or your phone. There is no random code for rides.

**Who can see it, and how long.** Only the maintainer, to improve arrival times. Results may be published only as
summaries of many rides. Kept for 12 months.

**Your choice.** Off unless you choose it, either on the ride card after your first confirmed ride or in Settings →
Share my confirmed rides, and you can turn it off at any time. Because shared rides aren't linked to you, rides that
have already been shared can't be traced back to you or picked out to delete.

The app also learns real travel times from **Gautrain's own bus GPS** (when each bus passed each stop). That is
data about the buses, not about anyone.

## 5. Your rights

Under POPIA you may ask what personal information we hold about you, ask for it to be corrected or deleted,
object to its processing, and withdraw your consent at any time.

- **The quickest way:** Settings → Help plan new routes → **Stop and delete**. Your entry is deleted from the
  server straight away. Settings also shows exactly what is being shared.
- Because shared entries aren't linked to you, we can only find yours through the random code on your phone. If
  you have cleared the app's data or changed phones, we can't identify your entry. It will then be deleted
  automatically after 12 months.
- For any other request or question, contact us as in section 1.
- If you're not satisfied with how we respond, you may complain to the **Information Regulator (South Africa)**:
  https://inforegulator.org.za.

## 6. Where information is processed

These providers process information on the project's behalf or when you use their service. Some are outside
South Africa, in countries with data-protection laws that give protection comparable to POPIA:

| Provider | What for | Where |
|---|---|---|
| Supabase | The app's server and database, including shared route-planning entries | Frankfurt, Germany (EU) |
| GitHub Pages | Hosting the app's web page | United States |
| TomTom | Traffic and ride times | Netherlands (EU) |
| OpenStreetMap Foundation | Map tiles and address search | United Kingdom / EU |

## 7. Security

All connections use HTTPS. The route-planning table can only be **written to** by the app (to add, update or
delete your own entry); it **cannot be read back** publicly, and only the maintainer can read it. We collect the
least information that answers the planning question, and coarsen it on your phone before it is sent. If there
were ever a security compromise involving personal information, we would notify the Information Regulator and,
where we can, the people affected, as POPIA requires.

## 8. Changes to this notice

Each consent is recorded with the version of the section you agreed to: route planning (section 4) is version
2026-10-23, and sharing confirmed rides (section 4A) is version rides-2026-10-26. If a section changes in a way that
affects what is shared, its version changes and the app asks for your consent again before sharing anything more.
The history of this file is public on GitHub.
