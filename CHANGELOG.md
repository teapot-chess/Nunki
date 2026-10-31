# Changelog

What changed in Nunki, newest first. The format loosely follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and each entry is
tagged so that a version can be skimmed:

| tag | meaning |
|---|---|
| [Feature] | something new you can do |
| [Fix] | something that was broken |
| [Change] | existing behaviour works differently |
| [Removed] | something is gone |
| [Security] | a hole closed, or judged not to be one |
| [Verified] | checked against the real thing, no code change |

## [Unreleased]

- [Change] **The hall link is a contract now, not two essays.** The protocol between OpenPairings and Nunki was written out by hand here and again in Polis, and the two copies had started to disagree about things as basic as how long a join code is. It now lives once, as JSON Schemas in OpenPairings (`priv/contracts/hall-link-v1`), vendored here byte for byte. The tests hold every frame Nunki sends and every answer it takes to those schemas, the fake OpenPairings the other tests talk to included (it had been sending tournament ids no real server would). `docs/protocol.md` shrank to what the schemas cannot say. CI compares the vendored copy with OpenPairings on every pull request and once a day, so the next disagreement is found by a machine instead of by an announcer saying nothing.
- [Change] **One pairing code for every hall app.** A new join link carries a 43-character code (32 random bytes) instead of 16 letters: the same code Polis and Manubrium are paired with, still good once, for fifteen minutes. Nobody types it, so the extra length costs nothing. A link made before the change works until it runs out, and an announcer already joined is not touched: its key was never a join code.
- [Change] **A phone's link is turned away by name.** Pasting a Manubrium connect link (`manubrium://...`) into the control page now says it is for the phone app, before anything is sent, instead of calling it "not a join link" and leaving you to guess. In OpenPairings the announcer's QR code is now explained for what it is: scan it with Manubrium on your phone to pass the link on to the hall PC, which has no eyes of its own.
- [Fix] **The OpenPairings plugin is tested in this repository's CI.** Its tests ran only when somebody remembered to run them inside an OpenPairings checkout, which is a schedule of sorts. A new job builds OpenPairings' `main` with the plugin in it, checks warnings and formatting, and runs the plugin's tests, on every push and every morning.
- [Removed] **Build output under `plugins/`.** A `_build` directory of the plugin had been committed, translations and a migration included, in case anyone wanted two of each. Gone, and ignored from now on.

## [0.5.0] - 2026-10-30

- [Security] **phoenix_html 4.4.0.** 4.3.0 picked up an advisory overnight (EEF-CVE-2026-117645, medium), and the dependency audit stopped the build, as it should.
- [Security] **Bandit 1.14.1.** Three fresh advisories against the old Bandit (HTTP/2 header blocks that unfold into unbounded allocations, quadratic work on blocked streams, WebSocket frames after a close) turned the dependency audit red. Updated, with `plug_crypto` 2.2.1 riding along; the audit is green. Nunki never spoke HTTP/2 to anybody, but the audit does not grade on intent.

- [Change] **The control page fits a 3.5 inch screen.** A Nunki box with a 480x320 panel (or 320x480 upright) showed the control page as a desktop one: a header that did not fit upright and pushed the page sideways, links and language buttons about 30 pixels tall, ticks the size of a comma. Under 520 pixels wide or 360 tall the margins, panels and type tighten and the nav links, language buttons, buttons, fields and ticks get 44 pixel targets; upright, the nav drops to its own row under the logo instead of leaving the screen. The hall screen already scaled itself and is unchanged. A bigger screen sees the same page it always did. `NunkiWeb.CompactCssTest`.

- [Change] **The control page is small until you ask for more: "Show advanced features".** Most halls want the announcer, the list, Join, Read now and a countdown, and had to scroll past voice pickers, two Test buttons, a rooms form per tournament and a panel about the device's name to find them. All of that now sits behind a switch at the bottom of the page, off by default; the voice you chose keeps being used while its picker is hidden, and a missing speech engine is reported regardless, because silence with no explanation is not a minimalist design. An existing installation that already uses any of it (a chosen voice, a room or announcer name, a renamed device, update checks off) is switched on once, when it first starts, and stays as it is. The manual marks the advanced parts.

## [0.4.3] - 2026-10-21

- [Change] **The Mac app is signed with a Developer ID and notarised by Apple.** Until now it was signed with nothing but good intentions, and every Mac that downloaded it asked the arbiter to override Gatekeeper by hand, which is a strange way to greet someone who just installed your software. The release workflow now signs every binary inside Nunki.app, hardened runtime and BEAM entitlements included, sends the bundle to Apple, staples the ticket and checks the verdict with `spctl` before the zip exists. A fork without the secrets still builds, with a warning, ad-hoc signed. The workflow can also be started by hand with *mac_only* to test all this without publishing anything.
- [Change] **Releases carry signed build provenance.** Every file of a release, `SHA256SUMS` included, is now attested through GitHub and Sigstore, keyless, so `gh attestation verify <file> --repo teapot-chess/Nunki` can say who built it and from what. Until now the checksums vouched for a download only against the release they sat in, which is a witness who was hired by the defendant.

## [0.4.2] - 2026-10-20

- [Fix] **Stopping from Ascella, an update or a logout no longer hangs on "Stopping".** On a Mac, the window waited for its server to end inside the very queue that was to bring the news, so the server ended and the window kept saying "Stopping" until somebody force-quit it. Quit from the menu never had the problem, which is how it survived this long. Any stop that hangs anyway now ends after forty seconds.

## [0.4.1] - 2026-10-20

- [Feature] **Nunki for Intel Macs, from macOS 10.13.** macOS 10 exists only on Intel Macs, and they had been struck off on the 14th because their build is slow. It is back, and it is built only when there is a release to put it in (or when somebody starts the workflow by hand), so the other pushes are as quick as they were. Nunki's own update notice picks the zip for the Mac it is on, and no longer says an Intel Mac has no build; an Intel Nunki running under Rosetta on an Apple Silicon Mac is treated as the Apple Silicon Mac it is. Every program in the bundle is checked against the oldest macOS promised, as before. Whether a 2017 Mac and its `say` voices agree is for a person with both to say; see docs/macos.md.

## [0.4.0] - 2026-10-19

- [Fix] **Switching the hall announcer off now cuts the announcers off.** The feature only removed the menu entry: announcers already joined kept receiving every round (and read it aloud), a join link made in the fifteen minutes before still worked, and the admin could not remove an announcer because the disabled-feature guard swallowed Remove. An announcer of an account without the feature is now refused at `hello` (as revoked) and at joining; the page keeps listing the announcers, with Remove, while the feature is off.
- [Security] **A web page can no longer drive the announcer by renaming it.** The pages were open to any `Host` and any socket origin, so a page in the hall PC's browser could point its own name at 127.0.0.1, count as same-origin, and press the control page's buttons, including the ones that decide what the hall's loudspeakers read out. Nunki now answers 403 to a `Host` that is not its own (`localhost`, `127.0.0.1`, `PHX_HOST`, and with `NUNKI_LISTEN=lan` the machine's host name and addresses), and the live socket checks the same list. The launcher, the in-app window, the hall screen on another machine and LAN mode ask for those names and carry on as before.

## [0.3.1] - 2026-10-18

- [Fix] **Stopping no longer ends in a red stack trace.** On the way out the launcher-details process tidied up its secret by asking the application controller, which at that point is busy dying and answers everyone with an exit. The secret goes with the VM anyway, so now it lets the question go unanswered and leaves quietly.

## [0.3.0] - 2026-10-18

- [Feature] **An announcer's room is now a room of the tournament, and it reads only that room's boards.** The free-text field was a label with ambitions; the tournament's rooms (Settings, Rooms in OpenPairings) are the list now, kept by id, so renaming "Hall B" to "Annexe" does not strand anyone. An announcer in a room is sent just the boards the room holds, and a room change sends the round again. No room still means every board. The `settings` frame gains `rooms_available` and, for a room the tournament never heard of, `error: "room"` (hall-link v1, additive). Nunki shows a select when the server sends the list and a text field when it does not. Rooms typed before this existed match nothing, stay on screen as a label, and filter nothing; they are not migrated, because there was nothing to migrate them to.
- [Change] **New address.** The repository moved to github.com/teapot-chess; old links still redirect, out of politeness rather than obligation.
## [0.2.0] - 2026-10-18

- [Fix] **Stopping Nunki stops the voice too, whoever goes first.** Every program Nunki starts - `say`, `espeak-ng`, PowerShell, `kill` itself - now has a deadline, and is killed when whoever was waiting for it is gone. The voice reading a line aloud is killed even when the Speaker is not given the chance to say goodbye, and whatever is still talking when Nunki stops goes with it. Erlang closes the port and walks away; the program on the other end used to finish its sentence to an empty hall.
- [Fix] **No part of a stop waits forever.** Every supervisor has a deadline, open browser connections get three seconds instead of fifteen, and on the Mac the launcher's SIGKILL after twenty seconds now reaches the whole tree under the server - the BEAM and the programs it started - rather than the BEAM alone. The app's own last resort, ten seconds later, does the same instead of killing only the script and leaving the server to launchd.

- [Change] **The Hall announcer moved from a tournament's top bar into its Settings.** It is set up once per tournament and then left alone, which is what the Settings rail is for; the top bar goes back to what is used every day. In OpenPairings: the tournament's Settings, Hall announcer, Add an announcer. The page keeps the rail beside it, and every text that told you where to look now tells you where to look.
- [Feature] **An announcer has a name and a room, and both sides can change them.** OpenPairings shows the room beside the name and has a small form per announcer; Nunki shows both per tournament and has its own. There is one truth, the server's: a change from either side becomes a new `settings` frame (hall-link v1, additive, still version 1), and the other side shows what the server says, not what it was asked. With the line down the fields are disabled, because asking nobody for a change is just typing.
- [Change] **The Hall announcer switch is in the Belgian pack** of OpenPairings' Features, not under "Optional tools for any federation", a heading whose main achievement was never being read.

## [0.1.0] - 2026-10-18

- [Feature] **Nunki exists.** It reads the pairings aloud the moment OpenPairings publishes them, white first, byes last, and counts down to the round: ten minutes, five, one, and "starts now". Only the moments still ahead, so a countdown started at five minutes does not open with "ten".
- [Feature] **English and Dutch**, following the tournament unless the control page says otherwise. Dutch says "je", because nobody in a playing hall has ever been addressed as "u" by a loudspeaker and liked it.
- [Feature] **The machine's own voice, not the browser's:** PowerShell on Windows, `say` on a Mac, espeak-ng on Linux. It speaks with every page closed and never waits for somebody to click first.
- [Feature] **A control page:** join a tournament with one pasted link, see whether each line is up and why not, Read now, Stop, a countdown of your own, the voice per language and a button to hear it before the players do.
- [Feature] **A hall screen for a projector:** the minutes in very large digits, then "Round 3 has started"; the latest pairings otherwise; the line being said at the bottom. One button for full screen.
- [Feature] **A round that is corrected after it was read is not read again by itself.** Reading the same pairings twice is how a hall learns to stop listening.
- [Feature] **Installers and updates as in the other hall programs:** a Windows installer that updates itself and a portable zip, Linux archives for PCs and the Raspberry Pi with a one-line installer and a systemd service, and an Apple Silicon Mac app. An update refuses while a countdown runs or Nunki is speaking, unless somebody says yes twice; a countdown that stops a minute before zero is a round that starts in silence. The news of a newer version is on the control page and the help, and never on the hall screen, which the players read and which is none of their business.
- [Feature] **"Start Nunki when Windows starts"**, on the control page of an installed Windows copy, off until somebody turns it on. Uninstalling takes the setting with it, so Windows is not left starting something that is gone.
