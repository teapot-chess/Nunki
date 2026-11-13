# Local control API, v1

A small JSON API for programs **on the same machine** as Nunki: the touch
menu of the Raspberry Pi image (the "nunki role") uses it to drive the hall
screens and the sound. This page is the contract; the image depends on it.
Anything that would break a caller written against it is a `v2` at a new
path, never an edit here. Adding a field to a response is not a break, and
callers must ignore fields they do not know.

Base: `http://127.0.0.1:<PORT>/api/local/v1` (`PORT` defaults to `4062`).

## Who may call it

Only this machine. A request is refused with **403** and
`{"error": "..."}` when

- the peer address is not loopback (`127.0.0.0/8`, `::1`) - whatever the
  PIN, whatever `NUNKI_LISTEN` says. With `NUNKI_LISTEN=lan` the pages are
  open to the network (PIN-protected); this API never is;
- it carries a proxy header (`X-Forwarded-For`, `Forwarded`, `X-Real-IP`,
  `CF-Connecting-IP`, `X-Forwarded-Host`, `Tailscale-User-Login`,
  `Tailscale-User-Name`, `Tailscale-Headers-Info`): a reverse proxy on this
  machine (`tailscale serve` included) makes everybody a loopback peer, so a
  proxied request is not this machine's. **Do not put the API behind a
  proxy**;
- it has an `Origin` header naming a host Nunki does not answer to (a web
  page in a browser on this machine). There is no CORS: call it from a
  program (curl, a backend), not from browser JavaScript on another origin;
- its `Host` is not one of Nunki's own names (`localhost`, `127.0.0.1`,
  `::1`, ...); that one is a plain-text 403 from the host check, before the
  API.

No PIN, no session, no CSRF token.

## Requests

`POST` bodies are JSON objects with `Content-Type: application/json`, at
most 16 KiB. Otherwise:

| status | when |
|---|---|
| 415 | no `Content-Type: application/json` |
| 413 | body larger than 16 KiB |
| 422 | not a JSON object, a missing or wrong field, an unknown screen, mode or tournament |

Every error body is `{"error": "<words for a human>"}`.

Every successful `POST` answers **200** with the full state, exactly as
`GET /state`, so a caller never has to ask twice.

## Screens

Two named screens: `"hdmi1"` and `"hdmi2"`. Point the kiosk browsers at

- `http://127.0.0.1:4062/hall` (or `/hall?screen=hdmi1`) for HDMI 1,
- `http://127.0.0.1:4062/hall?screen=hdmi2` for HDMI 2.

An unknown `screen=` in the page address is `hdmi1`. `?t=<id>` in the
address still forces a tournament for whoever opens a screen by hand; leave
it out of the kiosk URLs so the menu's choice applies.

Modes:

- `live` - follows everything (countdown, pairings, announcements, the line
  being said);
- `paused` - stays on what it showed when paused, clock included, until set
  back to `live`. Speech is not paused. A page loaded while paused shows the
  state at that moment and then stays put. Pausing a black screen shows the
  present, frozen;
- `black` - fully black, no text, no button, cursor hidden.

Each screen's mode and tournament are stored in Nunki's `state.json` and
survive a restart. A change reaches the open `/hall` pages at once.

## Endpoints

### `GET /state`

```json
{
  "screen": "live",
  "audio": true,
  "hall_tournament": null,
  "screens": {
    "hdmi1": {"mode": "live", "tournament": null, "shows": "Ab3dEf9h",
              "countdown": {"tournament_id": "Ab3dEf9h", "round": 4,
                            "ends_at": "2026-11-15T10:05:00Z", "started": false}},
    "hdmi2": {"mode": "black", "tournament": "Zz81Qq0w", "shows": "Zz81Qq0w",
              "countdown": null}
  },
  "tournaments": [
    {"id": "Ab3dEf9h", "name": "Club Championship", "connected": true},
    {"id": "Zz81Qq0w", "name": "Youth Open", "connected": false}
  ],
  "countdown": {"tournament_id": "Ab3dEf9h", "round": 4,
                "ends_at": "2026-11-15T10:05:00Z", "started": false},
  "speaking": false,
  "version": "0.7.0"
}
```

| field | meaning |
|---|---|
| `screen` | `hdmi1`'s mode (kept for callers that know one screen) |
| `audio` | whether Nunki speaks |
| `hall_tournament` | `hdmi1`'s chosen tournament id, or `null` for automatic |
| `screens.<name>.mode` | `live`, `paused` or `black` |
| `screens.<name>.tournament` | the chosen tournament id, or `null` = automatic |
| `screens.<name>.shows` | the tournament the screen actually shows now (the choice, or the automatic pick), or `null` with nothing joined |
| `screens.<name>.countdown` | that tournament's countdown, or `null` |
| `tournaments` | the joined tournaments, oldest first; `connected` is whether the line to OpenPairings is up |
| `countdown` | `screens.hdmi1.countdown` |
| `speaking` | whether a line is being said right now |
| `version` | Nunki's version |

A countdown: `round` is the round it counts down to; `ends_at` is the end
on this machine's wall clock, UTC, whole seconds (Nunki counts on the
monotonic clock; this is a conversion for display); `started` is `true` for
ten minutes after zero ("Round 4 has started"), with `ends_at` in the past.

The automatic pick: the tournament with a countdown still running, else one
whose round has just started, else the first joined.

### `POST /screen`

```json
{"screen": "hdmi2", "mode": "black"}
```

`screen` is optional and defaults to `"hdmi1"`; `mode` is required.

### `POST /audio`

```json
{"enabled": false}
```

`enabled` must be a JSON boolean. Off stops what is being said, empties the
queue, and from then on nothing is said and nothing is queued for later.
The hall screens keep showing pairings, countdowns and announcements; the
"line being said" at the bottom stays away, because nothing is said.

### `POST /hall_tournament`

```json
{"screen": "hdmi1", "id": "Ab3dEf9h"}
```

`screen` is optional (default `"hdmi1"`). `id` is required: a joined
tournament's id from `tournaments`, or `null` for automatic. An id that is
not joined is a 422. Removing a tournament puts every screen that had chosen
it back on automatic.

### `POST /identify`

No body needed. Every open hall screen shows its number (`1` or `2`) very
large for about 5 seconds, over whatever it shows, black included. For a
setup wizard: "which monitor shows 1?".

### `POST /stop`

No body needed. Stops what is being said now and forgets the queue (the
control page's Stop). It does not switch the sound off.

## Environment

| variable | effect |
|---|---|
| `PORT` | the port (default `4062`) |
| `NUNKI_LISTEN=lan` | the pages (not this API) are open to the network, PIN-protected; the host check then also answers to this machine's host name, interface addresses, and its Tailscale MagicDNS name and addresses |
| `NUNKI_AUDIO=off` | the sound starts **off** on a fresh install. Only the default: once the switch is used (page or API), the stored choice wins. `off`, `0`, `false`, `no` all count |

## Example

```sh
curl -s http://127.0.0.1:4062/api/local/v1/state
curl -s -H 'content-type: application/json' \
     -d '{"screen":"hdmi1","mode":"black"}' \
     http://127.0.0.1:4062/api/local/v1/screen
```
