# Releasing Nunki

How a version gets from `main` to a hall, what each downloaded file is,
and - because none of it has happened yet - what the first release has to
prove. The machinery is Alnasl's and Arkab's, renamed; where it differs,
this says so.

## Cutting a release

One commit on `main`:

1. `mix.exs`: the new `version:`.
2. `CHANGELOG.md`: rename `## [Unreleased]` to `## [X.Y.Z] - YYYY-MM-DD`
   (and start a new, empty `## [Unreleased]` above it).

Push. `.github/workflows/release.yml` builds every target, starts each one
and looks at its answer, and then - only if every target passed - tags
`vX.Y.Z` at that commit and publishes the release with the changelog
section as its notes.

It publishes when **both** are true: `mix.exs` names a version without a
GitHub release, and the changelog has a section for exactly that version.
A version without notes publishes nothing (the run says so and stays
green). Until somebody writes that section, 0.1.0 is a version nobody can
download, which is deliberate.

A work-in-progress build can go out as a **pre-release**: start "Build and
release" by hand on `main` with "Publish as a pre-release" ticked. It is
tagged and published like any other, but it is not "latest": the update
check (which reads `/releases/latest`) never offers it, and
`releases/latest/download/<name>` keeps pointing at the last real release.
Fetch it by tag: `releases/download/vX.Y.Z/<name>`, or
`install.sh --version X.Y.Z` and `update.sh --version X.Y.Z`.

Do not tag by hand. There is no way to un-release: a wrong release is
followed by a right one with a higher number.

## What a release holds

All names are without a version, so that
`https://github.com/teapot-chess/Nunki/releases/latest/download/<name>`
stays right. The version is inside each file.

| File | What it is | Who asks for it by name |
|---|---|---|
| `Nunki-Setup.exe` | The Windows installer (Velopack, per user, one click) | the download page |
| `nunki-windows-x86_64-portable.zip` | The same release as a folder; installs nothing | the download page; a portable copy's update notice |
| `nunki-linux-x86_64.tar.gz` | The Linux release, PCs | `install.sh`, `update.sh` |
| `nunki-linux-aarch64.tar.gz` | The Linux release, 64-bit Raspberry Pi and other arm64 | the same |
| `nunki-macos-aarch64.zip` | `Nunki.app` for Apple Silicon, zipped with `ditto` | the download page; a Mac copy's update notice |
| `nunki-macos-x86_64.zip` | `Nunki.app` for Intel Macs (macOS 10.13 and newer), built only for a release | the same, on an Intel Mac |
| `install.sh` | The one-line installer | `curl ... \| sudo sh` |
| `update.sh`, `uninstall.sh` | Copies of what the archive carries, for reading | a person |
| `SHA256SUMS` | Checksums of everything above and below | `install.sh`, `update.sh` |
| `releases.win.json` | Velopack's feed | every installed Windows copy |
| `NunkiApp-X.Y.Z-full.nupkg` | The Windows program as Velopack fetches it | the same, via the feed |

Never rename `releases.win.json` or a `.nupkg`, and never change the pack
id `NunkiApp`: an installed copy that cannot find them stays on its version
for ever without saying why.

## Where things are built from

| | |
|---|---|
| `mix.exs`, `releases/0`, `release_extras/1` | one release, `nunki`; per system, the files beside `bin/` |
| `config/runtime.exs`, `lib/nunki/data_home.ex` | where an installed copy keeps `state.json`, and the refusal to keep it anywhere an installer owns |
| `priv/voice/windows.ps1` | the Windows voice. Shipped inside the release; CI parses it on Windows, and the release check looks for it |
| `rel/windows/launcher.c` | `Nunki.exe`: starts the release, opens the browser, is the stop button, applies an update |
| `rel/windows/build_installer.ps1` | `vpk pack`, with the check that no `state.json` is packed |
| `rel/windows/build_icon.py` | draws `Nunki.ico` and the Mac icon from the mark; run by hand when the mark changes |
| `rel/linux/*` | `install.sh`, `update.sh`, `uninstall.sh`, the unit (in the `audio` group) and the root-owned updater |
| `rel/macos/*` | `Nunki.app` around the release, its Swift launcher, signing and notarisation |
| `lib/nunki/updates.ex`, `updates/checker.ex` | the check, the notice, the hand-over |
| `tools/release_notes.sh` | the changelog section of one version |

## Building one by hand

Windows, with Elixir, `zig` and `vpk` on the PATH. Set `NUNKI_DATA` to a
scratch folder first: any `MIX_ENV=prod` task reads the runtime
configuration, and without it would create the real data folder of the PC
you are sitting at.

```
set MIX_ENV=prod
set NUNKI_DATA=%CD%\tmp\release-data
mix deps.get --only prod
mix assets.deploy
mix release nunki --overwrite
.\rel\windows\build_installer.ps1 -PayloadDir _build\prod\rel\nunki -OutputDir installer_out
```

Linux: the same `mix` lines, then
`tar -czf nunki-linux-$(uname -m).tar.gz -C _build/prod/rel nunki`.

**Building an installer is harmless. Running one is not a test to do on the
PC you work on.** Use a Windows Sandbox or a spare machine. A sister
project lost real data to an installer run "just to see".

## What the first release has to prove

Nothing below has been done.

**The workflow**

- [ ] `ci.yml` and `release.yml` run; the Windows job parses
      `priv/voice/windows.ps1`.
- [ ] The smoke tests pass on all three targets: the release starts on a
      scratch data folder, writes `state.json` there, answers on its port.
- [ ] A push with a version and no changelog section publishes nothing.

**Windows**

- [ ] `Nunki-Setup.exe` installs to `%LOCALAPPDATA%\NunkiApp` and starts
      the launcher; the browser opens on the control page.
- [ ] Voices are listed. On a PC with the Dutch speech pack, the Dutch
      voice is among them (WinRT). "Test voice" is heard, in both languages.
- [ ] Stop cuts a long line off at once, and no `powershell.exe` is left.
- [ ] The data is in `%LOCALAPPDATA%\NunkiData`, and **is still there after
      uninstalling**. Join a tournament first, so there is a key to lose.
- [ ] From the second release on: the update refuses while a countdown
      runs, "Install anyway" works, the launcher applies it.

**Linux**

- [ ] `install.sh` on Debian 12, Ubuntu 22.04 and Raspberry Pi OS 64-bit:
      user in `audio`, unit up, espeak-ng noted when missing.
- [ ] The service is **heard**. This is the open question (README, "Sound
      on Linux"): a system service may not reach a desktop's PipeWire or
      PulseAudio session.
- [ ] `update.sh`, the page's "Install", `uninstall.sh` (which leaves
      `/var/lib/nunki`).

**macOS**

- [ ] `Nunki.app` opens with no question; `say` speaks; a downloaded
      Dutch voice is listed and used. See `docs/macos.md`.

## Version numbers

Patch for fixes, minor for anything an arbiter would notice, 1.0.0 the day
a whole tournament has been announced by an installed copy without
anybody reaching for the Stop button in anger.

## Signing the Mac app

The macOS jobs sign `Nunki.app` with the Developer ID Application
certificate and the hardened runtime, notarise it with Apple, staple the
ticket and check it with `spctl` before the zip is made. A build without
the secrets (a fork) skips all of that with a warning and ships ad-hoc
signed. The secrets belong to the `teapot-chess` organisation, so every
repository in it has them:

| Secret | What |
|---|---|
| `MACOS_CERT_P12` | the *Developer ID Application* certificate with its private key and the intermediate, exported as `.p12`, then base64 |
| `MACOS_CERT_PASSWORD` | the `.p12`'s password |
| `APPLE_TEAM_ID` | the ten-character team id |
| `ASC_KEY_ID` | the App Store Connect API key's id |
| `ASC_ISSUER_ID` | the API key's issuer id |
| `ASC_KEY_P8` | the API key's `.p8` file, base64 |

`rel/macos/sign_and_notarize.sh` signs every binary with the hardened
runtime and the BEAM's entitlements, notarises with the API key, staples,
and asks Gatekeeper. The temporary keychain is deleted at the end of the
job, whatever happened.

To test the signing without releasing anything, start the workflow by hand
on a branch with **mac_only**: it builds and notarises the Mac apps and
publishes nothing.
