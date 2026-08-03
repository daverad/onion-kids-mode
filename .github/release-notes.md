Straight from the r/MiyooMini thread: a longer play timer you can set
yourself, and RetroArch's in-game shortcuts really are off while armed.

## What's new

- **Longer play sessions**: the timer now goes up to **60 minutes** by
  default, and the ceiling is yours to set — `"timer_max_minutes"` in
  `App/KidsMode/kidmode.json` takes any 5-minute step up to 240. It applies
  to both the arm screen and *Add play time* in the parent menu.
- **RetroArch shortcuts locked while armed**: kiosk mode only ever hid the
  settings — the menu combo (MENU+SELECT) still opened the RetroArch menu.
  Now the menu combo, save/load state, state slots, rewind, fast-forward,
  screenshot, cheats, shader cycling and disc swap are all unbound while
  Kids Mode is armed, and restored from the backup on unlock. Prefer stock
  RetroArch shortcuts? Set `"lock_retroarch_hotkeys": false`.
- **README**: a Settings table for `kidmode.json`, plus an FAQ (including
  netplay — it needs the RetroArch menu, so it doesn't work while armed).

## Still in

- **Native Onion look**: your active theme's background, fonts, and colors
  everywhere — header bar with battery, footer button hints, and an
  Apps-menu-style parent menu with full-width rows
- **Add play time inline** on the parent menu row, with a live preview of
  what the remaining time becomes, or **Turn off timer** for unlimited play
- **Auto power-off**: if the "Time's up!" screen is left alone for 5 minutes,
  the device shuts down cleanly instead of draining the battery overnight
- **PIN that can't lock you out**: it survives app updates via a snapshot in
  `Saves/kidmode/`, and if no PIN exists at all the unlock gesture asks you
  to set a new one

## Install

1. Download `KidsMode.zip` below
2. Copy the `KidsMode` folder into `App/` on your SD card (so it becomes
   `/App/KidsMode/`)
3. Reboot, then arm from **Apps → Kids Mode**

**Updating from v1.1.0:** replace the `KidsMode` folder — your PIN survives
(it's snapshotted in `Saves/kidmode/`). The new RetroArch lock applies the
next time you arm Kids Mode.

Requires **Onion OS 4.3+**. Tested on a Miyoo Mini Plus running Onion
4.4-beta; base Mini and Mini V4 are supported in code but less tested —
reports welcome.
