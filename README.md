# Kids Mode for Onion OS

A fullscreen, favorites-only launcher that locks a **Miyoo Mini / Mini+**
running [Onion OS](https://github.com/OnionUI/Onion) so a young child can
use it unsupervised — big box art, one-button play, a PIN-protected exit,
and an optional play timer.

- **Boots straight into a kid-proof carousel** showing only your ★ favorited
  games: box art, big label, left/right to browse, **A** to play, **X** to
  start over. Long titles wrap onto a second line, and the battery sits
  top right exactly as it does everywhere else in Onion, with the
  play-time chip opposite it.
- **Native Onion look**: every screen renders through Onion's own theme
  engine — your active theme's background, fonts, colors, header/footer
  bars, button hints and full-width list rows — so Kids Mode feels like
  part of the OS, not an app drawn on top of it.
- **Exiting a game returns to the carousel — never to Onion's menus.**
- **Play timer** (per session, optional): pick 5–120 minutes when arming.
  Countdown shows inside games via RetroArch's on-screen messages (pinned
  during the last 5 minutes); at zero the game is asked to quit gracefully,
  so Onion's auto-save keeps the exact spot.
- **Auto power-off**: if the "Time's up!" screen is left alone for
  5 minutes (nobody turns the device off), it powers itself down cleanly
  instead of draining the battery.
- **Parent menu** (hold **SELECT+START 3 s** → PIN): exit Kids Mode, add
  play time right on the menu row — **◀ ▶** picks +5…+120 min,
  **A**/**START** applies, and the header previews the remaining time before
  and after — **turn the timer off entirely**, set the **screen
  brightness**, flip **auto-resume**, or **change the PIN** — all without
  leaving the launcher.
- **Start over**: **X** on a game asks "Start over?" and launches from the
  beginning without touching in-game saves.
- **MENU button in-game saves and exits** back to the carousel.
- **RetroArch is locked down while armed**: settings are hidden (kiosk
  mode) *and* every documented in-game hotkey is unbound — MENU+SELECT
  (RetroArch's menu), MENU+L2/R2 (save/load state), MENU+L/R (rewind and
  fast-forward), MENU+←/→ (save slots), plus screenshots, cheats, shaders,
  disc swap and the rest. MENU+VOLUME for brightness is handled outside
  RetroArch and still works. Everything is restored from a backup on
  unlock.
- **The kid gets their own saves**: while armed, `Saves/CurrentProfile`'s
  `saves`, `states` and `romScreens` are swapped for a persistent
  `Saves/KidsProfile`, so a child can't overwrite your save states or fill
  the game switcher with their thumbnails — and their own progress is
  still there next session. Per-core settings and themes stay shared.
- **MENU+B blue-light toggle is disabled** while armed (any schedule you
  have configured still runs).
- **Auto-resume** (optional): boot straight back into the last game the
  kid played instead of the carousel. Toggle it in the parent menu.
- Survives reboots; a powered-off-mid-game session resumes on next boot.

## Screenshots

| ![The kid's carousel](docs/screenshots/carousel.png) | ![Parent menu](docs/screenshots/parent-menu.png) | ![PIN screen](docs/screenshots/pin.png) |
| :--: | :--: | :--: |
| *The kid's carousel — one favorite at a time, box art and all; **A** plays, **X** starts over* | *Parent menu — play time with a live preview in the header, brightness, auto-resume and change PIN* | *The PIN gate — set once when arming; **A** confirms* |

*(Rendered with Onion's stock theme — Kids Mode picks up whatever theme
your device uses.)*

## Requirements

- Miyoo Mini or Mini+ running **Onion OS 4.3 or newer**.
- Games your kid should see must be **favorited** (★, press X on a game in
  Onion) and Onion's *auto save & resume* left on (it is by default).

Tested on a Miyoo Mini Plus with Onion 4.4-beta. The Mini V4's 752×560
screen and the base Mini are supported in code but less tested — reports
welcome.

## Install

1. Download `KidsMode.zip` from [Releases](../../releases).
2. Copy the `KidsMode` folder into the `App` folder on your SD card
   (so it becomes `/App/KidsMode/`). Don't replace the `App` folder itself.
3. Reboot. Nothing changes until you arm it.

## Usage

1. **Arm:** Apps tab → **Kids Mode**. First time, set + confirm a 4-digit
   PIN (up/down changes a digit, left/right moves between digits,
   A confirms).
2. Pick a session timer (OFF / 5–120 min) — the device switches straight
   into the kid launcher.
3. Hand it over:

   | Button | Action |
   | ------ | ------ |
   | ◀ ▶ | browse favorites |
   | A | play (resumes where the game last stopped) |
   | X | start over (with confirmation; in-game saves untouched) |
   | MENU (in-game) | save and exit back to the carousel |
   | everything else | does nothing — no dead ends |

4. **Parent access:** hold **SELECT+START ~3 s**, enter the PIN →
   *Exit Kids Mode / Add play time / Turn off timer / Brightness /
   Auto-resume last game / Change PIN / Back*.
   - **Add play time:** **◀ ▶** picks the amount (the header shows what the
     remaining time becomes), **A**/**START** applies — you drop straight
     back into the kid launcher.
   - **Turn off timer:** removes any running timer (unlimited play until you
     re-arm or add time again).
   - **Brightness:** **◀ ▶** changes the screen brightness as you move it,
     in 10% steps down to 10% (never fully dark) — no confirm needed, and
     it's remembered for the next session. MENU+VOLUME still works in-game,
     so a kid can change it back; this is a convenience, not a lock.
   - **Auto-resume last game:** **◀ ▶** flips it On/Off. On means the next
     boot goes straight into the last game the kid played instead of the
     carousel (it falls back to the carousel if that game is gone). The
     flip is saved the moment you make it, so **B** or *Back* both keep it.
   - **Change PIN:** set a new 4-digit PIN on the spot (no computer needed).
5. **Time's up:** the kid sees a friendly "Time's up!" screen. If the
   device is left on there, it powers off by itself after 5 minutes.

Kids Mode stays armed across reboots until you exit it via the PIN.

## Settings

Optional keys in `App/KidsMode/kidmode.json` (edit from a computer; the
file also holds the PIN, so leave the `pin_*` keys alone unless you're
resetting it):

| Key | Default | What it does |
| --- | --- | --- |
| `lock_retroarch_hotkeys` | `true` | Unbinds every documented RetroArch in-game hotkey while armed. Set to `false` to keep stock RetroArch shortcuts — the kiosk settings (hidden menus) still apply either way. |
| `auto_resume_last_game` | `false` | Boot straight into the kid's last game instead of the carousel. Also on the parent menu, which is the easier place to change it. |
| `brightness_pct` | unset | Screen brightness applied at the start of each session (floor 10%). Normally set from the parent menu. |
| `fav_shortcut` | `false` | Adds a **Kids Mode** entry to Onion's Favorites tab so arming doesn't need the Apps tab. Off by default because it can clutter MainUI's search results. |

Changes take effect the next time you arm Kids Mode. Note that updating the
app replaces `kidmode.json`, so re-apply your edits after an update (the
PIN itself is restored automatically from `Saves/kidmode/`).

Play-time limits are not settings — you pick the session length each time
you arm, and can add more from the parent menu.

## FAQ

**Why does the timer stop at 120 minutes?** It's a design choice, not a
technical limit — two hours is already a long session for the kind of kid
this is built for. To change it, edit `TIMER_MAX` in
`src/kidsMode/kidui.c` (and the matching `timer_max` in
`App/KidsMode/kid_mode_loop.sh`) and rebuild.

**Does netplay work in Kids Mode?** No. Hosting or joining a netplay
session is driven entirely from the RetroArch menu, which Kids Mode blocks
while armed, and games are launched directly from the carousel with no
netplay options. Unlock with the PIN to use netplay.

**Can my kid still open the RetroArch menu?** Not with the default
settings — the menu combo (MENU+SELECT) and every other documented hotkey
are unbound while armed and restored on unlock. If you *want* them back,
set `lock_retroarch_hotkeys` to `false`.

**Where did my save states go?** Nowhere — while armed, the kid plays on
their own `Saves/KidsProfile` and yours are parked; exiting Kids Mode puts
yours straight back. Both sides keep their progress.

## PIN reset / recovery

Everything is recoverable from a computer — nothing on the card is moved
or renamed:

- **Forgot the PIN:** in `App/KidsMode/kidmode.json` set `"pin_hash"` and
  `"pin_salt"` to `""` and `"pin_plain"` to `"1234"` — the new PIN is
  accepted and re-hashed on next use. Also delete
  `Saves/kidmode/pin_backup.json` (the PIN's update-proof snapshot) so the
  old PIN can't be restored from it.
- **Updating the app while armed is safe:** the PIN survives replacing
  `App/KidsMode` thanks to the snapshot in `Saves/kidmode/`. If there's
  genuinely no PIN anywhere (e.g. fresh SD contents while armed), the
  SELECT+START unlock asks you to set a **new** PIN instead of locking
  you out.
- **Force-disarm:** delete the hidden file `/.kidmode` at the SD root →
  next boot is normal Onion.
- **RetroArch settings stuck hidden or shortcuts still unbound:** copy
  `Saves/kidmode/retroarch.cfg.backup` over
  `RetroArch/.retroarch/retroarch.cfg`.
- **Blue-light toggle still dead:** copy `Saves/kidmode/blue_light.sh.backup`
  over `.tmp_update/script/blue_light.sh` (or delete the guard block at the
  top of that file, marked `KIDMODE_BLF_GUARD`).
- **Saves look wrong after a crash mid-session:** the kid's are in
  `Saves/KidsProfile/`, yours are parked in `Saves/kidmode/profile-parked-*`.
  Move the parked folders back into `Saves/CurrentProfile/` to undo the swap
  by hand.
- **Uninstall:** delete `/App/KidsMode/`, `/.kidmode` (if present),
  `/.tmp_update/startup/kidmode_boot.sh`, `/Saves/kidmode/` and
  `/Saves/KidsProfile/` (that last one is the kid's save data — keep it if
  you might re-arm later).

Fail-safes: if the launcher binary is missing or crashes repeatedly, Kids
Mode disarms itself and boots normal Onion instead of brick-looping. A log
is written to `.tmp_update/logs/kidmode.log`.

## How it works

Onion runs everything in `.tmp_update/startup/` before launching its main
UI. Kids Mode installs a hook there (automatically, on first arm) that
checks for the `/.kidmode` flag file: when present, it blocks in the kid
launcher loop, so Onion's MainUI simply never starts until a PIN unlock
removes the flag. Games are launched with the exact command format Onion
itself uses (per-game core overrides, play-activity tracking, V4 560p
handling, auto-save/resume all preserved). No Onion binaries are modified;
everything it touches while armed — `retroarch.cfg` (kiosk lock and
hotkeys), `keymap.json` (MENU button), `blue_light.sh` (MENU+B guard) and
the personal half of `Saves/CurrentProfile` — is backed up to
`Saves/kidmode/` and put back on unlock.

A determined child can still force a shutdown with a long power press —
the device just boots back into Kids Mode. Hardening that path would
require a patched `keymon`; it's documented in the source as future work.

## Building from source

`src/kidsMode/kidui.c` builds inside an Onion source tree with the
[miyoomini toolchain](https://hub.docker.com/r/aemiii91/miyoomini-toolchain):

```sh
git clone https://github.com/OnionUI/Onion && cp -r src/kidsMode Onion/src/
docker run --rm -v "$PWD/Onion":/root/workspace aemiii91/miyoomini-toolchain:latest \
  /bin/bash -c "source /root/.bashrc; cd src/kidsMode && make"
```

The GitHub workflow in this repo does the same on every push and attaches
an install zip to tagged releases.

## Credits & license

Built on and for [Onion OS](https://github.com/OnionUI/Onion) and its
common UI infrastructure. The RetroArch kiosk-lock approach was inspired
by [OnionUI/Onion#1910](https://github.com/OnionUI/Onion/pull/1910).
The in-game hotkey lockout, the MENU+B blue-light guard, per-kid save
isolation and auto-resume come from [@Veuks](https://github.com/Veuks),
forwarded by [@andygeorge](https://github.com/andygeorge) in
[#5](https://github.com/daverad/onion-kids-mode/pull/5).
GPL-3.0, same as Onion.
