Everything a kid can reach is now locked down: RetroArch's in-game
shortcuts, the blue-light toggle, and your save states. Plus longer play
sessions, volume and brightness ceilings, and a PIN you can change on the
device.

## Locked down while armed

- **RetroArch's in-game hotkeys are dead** — MENU+SELECT (the RetroArch
  menu), MENU+L2/R2 (save/load state), MENU+L/R (rewind, fast-forward),
  MENU+←/→ (save slots), screenshots, cheats, shaders, disc swap and the
  rest. Kiosk mode only ever hid the *settings*; the menu itself still
  opened. MENU+VOLUME for brightness is untouched — that one is handled
  outside RetroArch. Fixes #4. Prefer stock shortcuts? Set
  `"lock_retroarch_hotkeys": false`.
- **MENU+B blue-light toggle** does nothing while armed (a schedule you
  have configured still runs).
- **The kid gets their own saves**: `saves`, `states` and `romScreens` are
  swapped for a persistent `Saves/KidsProfile` while armed, so a child
  can't overwrite your save states or flood the game switcher with their
  thumbnails. Their progress persists between sessions; yours comes back
  untouched on unlock. Per-core settings and themes stay shared.

## Parent menu

- **Longer sessions**: the play timer now goes to **120 minutes**, up from
  50 — on the arm screen and on *Add play time*.
- **Brightness** straight from the menu, in 10% steps down to 10%.
- **Change PIN** on the device — no computer, no SD card reader.
- **Auto-resume last game**: boot straight back into what the kid was
  playing instead of the carousel.
- Coming back from a game reopens the carousel **on the game just played**,
  not at the start.

## Carousel

- **Battery level** on the kid screen, opposite the play-time chip, turning
  accent-coloured under 15%.
- **X = RESTART** now has a footer hint and icon, so the start-over shortcut
  is visible instead of hidden.
- **Long titles wrap** onto a second line instead of being cut off with an
  ellipsis.

## Faster

Arming went from ~15 seconds of black screen to about **1.5**. Three
things were doing it, none of them what they looked like:

- The RetroArch lock matched every setting against every line with a
  regex built from a variable, which busybox awk recompiles each time —
  ~133,000 compilations. Matching each line's key once and looking it up
  in a hash: 14s → under 1s. (It also left duplicate keys later in the
  file untouched, and RetroArch honours the last one, so a repeated key
  silently defeated the lock.)
- Every config read spawned `jq`. Reads now parse in the shell, with jq
  kept for writes and as a fallback for any file the parser won't touch.
- The timer state file cost three `sed` processes per read, and the
  ticker reads it every 10 seconds.

## Also

- README gains a settings table for `kidmode.json` and an FAQ (including
  netplay — it's driven from the RetroArch menu, which Kids Mode blocks, so
  it isn't available while armed).
- A `kidmode.json` with broken JSON is now backed up before being reset,
  so a stray comma doesn't silently lose your settings.

## Install

1. Download `KidsMode.zip` below
2. Copy the `KidsMode` folder into `App/` on your SD card (so it becomes
   `/App/KidsMode/`)
3. Reboot, then arm from **Apps → Kids Mode**

**Updating from v1.1.0:** replace the `KidsMode` folder — your PIN survives
(it's snapshotted in `Saves/kidmode/`). The new locks apply the next time
you arm Kids Mode.

## Thanks

The hotkey lockout, blue-light guard, save isolation and auto-resume are
[@Veuks](https://github.com/Veuks)' work, forwarded by
[@andygeorge](https://github.com/andygeorge) in #5.

Requires **Onion OS 4.3+**. Tested on a Miyoo Mini Plus running Onion
4.4-beta; base Mini and Mini V4 are supported in code but less tested —
reports welcome.
