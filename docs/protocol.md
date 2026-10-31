# The hall link, as Nunki speaks it

The protocol between OpenPairings and Nunki is not written down here any
more. It is OpenPairings' contract **hall-link-v1**:

- the provider's copy:
  <https://github.com/teapot-chess/openpairings/tree/main/priv/contracts/hall-link-v1>
  (its `README.md` is the prose: pairing a device, the line, changing it);
- this repository's vendored copy, byte for byte:
  `priv/contracts/vendor/openpairings/hall-link-v1/` (`mix contracts.sync`;
  `mix contracts.check` in CI, on every pull request and daily, says when
  the two differ).

JSON Schemas, one per message, with examples. `test/contracts/` holds
Nunki (`Nunki.Join`, `Nunki.Link`) to them, and
`plugins/openpairings_nunki/test/openpairings_nunki_web/contract_test.exs`
holds the server half to the same files. Two hand-written descriptions of
one protocol had already drifted apart; one set of schemas checked from
both ends cannot.

The messages Nunki takes and sends are the contract's `join-*`,
`device-hello`, `device-status-nunki`, `device-settings-nunki`,
`device-leave`, and `server-welcome`, `server-refused`,
`server-settings-nunki`, `server-round`, `server-countdown`,
`server-countdown-cancel`, `server-read`, `server-stop`, `server-announce`,
`server-leave`.
What follows is what the schemas cannot say: what Nunki does with them.

## Joining

The link is `https://<server>/p/nunki/join/<code>`, pasted into the
control page (the contract's "Pairing a device"). A print station's link
(`/p/polis/join/...`) or a phone's (`manubrium://connect?...`) is refused
in words before anything is sent, so its code is not spent on the wrong
device. The code is taken as it comes, whatever its length.

## Reading

- A `round` whose number has not been read before is read aloud, when
  "Read the pairings when they are published" is on. A changed payload of
  a round already read is kept and not read again by itself; "Read now"
  (here, or `read` from the server) reads what is held.
- `spoken` is what is said; without it, Nunki turns `name` round itself.
- `locale` is the language, unless the control page says otherwise.
- `stop` stops speaking and forgets the queue.

## Announcements

`announce` carries a `canned` key, free `text`, or both, and an `id` the
server makes for each announcement. Nunki words a canned key in the
announcement language (the tournament's, or the control page's override);
a key it does not know falls back to `text`, and a frame with neither is
ignored. An `id` equal to the last one Nunki saw for that tournament is a
repeat and is not said again. What is said is also kept as the
tournament's last announcement: the hall screen shows it for 90 seconds,
the control page until the next one. The buttons and the text box on the
control page do the same locally, with no server in between.

## Why seconds, not a time

`countdown` says how many seconds are left, never at what o'clock the
round starts. Nunki adds them to its own monotonic clock. Nobody's wall
clock is involved, so nobody's wall clock can be wrong - and a hall PC's
wall clock is wrong surprisingly often. The same `id` again (after a
reconnect) only moves the end; nothing already said is said again.
`countdown_cancel` cancels that id, and only that one.

## Name and room: the server is the truth

The announcer's name and room live in OpenPairings; Nunki holds a copy for
display and shows what the server's `settings` says, not what it asked for.
With the line down there is nobody to ask, so the control page disables the
fields. `rooms_available` present: the page offers "No room" and those
names; absent (an older server): the room is free text. A refused room
(`"error": "room"`) is said on the page. An announcer in a room is sent only
that room's boards, and the payload says which room (`room`).

## What the server must not expect

- A device to be connected. Announcing is the device's business; the
  server only says what happened. A device that was off when a round was
  published hears it on `welcome` - and reads it, since it was never read.
- A device to answer a command. There is no reply frame; `status` says
  what the device is doing, when it changes.
