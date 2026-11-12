# Daily allowance — unofficial candidate

This local build includes whawker's multi-profile contribution (PR #7), a separate
save-recovery repair, and opt-in daily gameplay allowances. It is not an upstream
release. Core behaviors have been exercised on a Miyoo with Onion v4.3.1-1; see
[verification and known limits](#verification-and-known-limits) before trying it.

In the PIN-protected parent menu, choose **Timer mode** with left/right:

- **No limit** allows unlimited play.
- **Single session** gives one allowance for this handoff. Choose **Time this session**
  and press A (**START**) to start a fresh budget. Midnight does not renew it.
- **Daily allowance** gives **Time each day**, renewing at local midnight. Press A
  (**APPLY**) to enable or change it. **No play** means a zero daily limit.

Left/right previews changes; B discards them. Applying any timer mode successfully returns
to the carousel; a failed update keeps the parent menu open. Each child has independent Daily base
and usage. **Bonus today** expires at midnight; **Add to this session** extends only
that session. Changing the Daily base, disabling Daily or starting a Single session
does not erase recorded Daily usage. Returning to Daily on the same date retains it.
The original arming picker is labelled **Single session**; Daily-enabled children
skip it and keep their recurring budget.

Both timed modes charge only while a game is open, including title screens and
in-game pause menus. Menus and sleep use no time. Session now samples monotonic
uptime and Onion's display/sleep state once per second; partial game/sleep boundaries
favor the child. It retains the existing session state format and save/exit path.
Daily retains the durable prepayment and recovery model described below.
Idle status refreshes run every ten seconds; parent changes publish immediately and game
launches always validate current status. One-second gameplay observations remain independent
of that slower idle work. Timer renewal and counting explanations live here, not in menu rows.

In Daily mode, at five and one minute remaining,
Kids Mode sends a short RetroArch warning three times, two gameplay seconds apart.
This uses the local command socket and works with Wi-Fi off. Both warnings were observed on the Miyoo with Wi-Fi off on November 12, 2026.
At zero, supported RetroArch games receive the normal QUIT request with automatic
save enabled. A hung/failed emulator is reported as unconfirmed; forced termination
is never described as a successful save. Native emulator launchers are refused in
Daily mode until they have an explicit save/exit adapter.

A trustworthy offline RTC or successful Onion network time permits daily resets.
A trusted clock automatically clears a stale date warning once it reaches the
last recorded time. Recovery on the same date preserves usage and bonus; a later
date receives exactly one new daily allowance. Invalid, untrusted or still-backward
time cannot grant a fresh day. There is no child-facing date-setting control.

### Automatic clock setup

Copy the app and open Kids Mode normally. **Daily stays off until a parent enables
it.** On Onion **v4.3.1-1**, that action automatically detects retained RTC evidence
from the kernel's startup clock record (or Onion's native RTC marker), saves the
original clock flags in `Saves/kidmode/clock-settings`, enables `.noTimeRestore`,
and disables automatic network time. It adopts the RTC in UTC unless the current
clock was already synchronized or parent-confirmed, then saves the RTC in UTC.
No Wi-Fi connection, shutdown experiment, hidden-file editing or recurring date
confirmation is part of setup. The boot hook is installed automatically on arming.

Detection is deliberately about the clock **at boot**, before saved-time restoration
or NTP. Within that boot, repeated Daily opt-in reuses the volatile verified-RTC marker,
so later kernel log wrap cannot revoke eligibility. Reboot clears that marker and requires
fresh boot evidence; the SD-card settings snapshot alone never proves RTC capability.
If the boot log has wrapped, the startup hook also accepts the known Miyoo RTC driver
when the kernel initialized system time from it, its valid epoch matches system time,
both Onion clock writers were disabled, and no network-sync marker exists. This fallback
is startup-only; parent opt-in cannot certify a currently readable clock by itself.
An `rtc0` registration alone is insufficient.
Missing trustworthy boot evidence or an unreviewed Onion version leaves the existing
timer unchanged and explains that offline Daily setup is unavailable. A completely
uninitialized clock may need its date/time set once in Onion; a later normal boot
can expose retention. Software cannot supply calendar time while powered off on
hardware without powered RTC. No model name, serial range or stored SD-card proof
is treated as a hardware guarantee. Battery removal and long-term drift remain
hardware limits. The supported automatic configuration version is intentionally
narrow; newer Onion releases need their own reviewed clock-write contract.

Setup does not replace Onion scripts, change Wi-Fi/timezone, or touch game saves.
Its snapshot is committed before changing flags. An interrupted setup restores the
original flag contents at the next boot; hardware/write failures restore immediately.
Repeated setup does not overwrite the baseline. A new child shares these device-wide
clock settings. Turning a child's timer off keeps them, since other children may
still use Daily. To undo them before uninstalling, unlock normally, then run
`sh /mnt/SDCARD/App/KidsMode/kid_mode_loop.sh restore-clock` through the existing
maintenance connection. It refuses while armed or a save transaction is pending;
keep the original app/hook and complete save backup for full rollback. Restoring
flags does not rewind the system clock or delete allowance records. A changed or
corrupt baseline requires recovery; it is never silently replaced.

An uncertain/backward clock retains the ledger without granting a new day. The
supported retained clock recovers automatically; there is no date-setting control
in the child UI or parent timer menu. If the hardware clock itself is uninitialized
or incorrect, unlock normally and correct its initial date/time and timezone in
Onion before retrying. No network connection or external account is required.

## Data and recovery

- Each profile root has `.allowance-id`; it follows a renamed child and is never
  swapped with `saves`, `states` or `romScreens`.
- `Saves/kidmode/allowance/state.v1` and `previous.v1` contain bounded, versioned,
  checksum-protected records. They live outside the replaceable app. The checksum
  detects accidental corruption; this is not protection against SD-card editing.
- At most five seconds are prepaid. A hard shutdown can consume that unused slice;
  a normal game exit or observed sleep refunds it. Rebooting never grants a new
  slice for free. Long scheduling gaps favor the child rather than charging sleep.
- `Saves/kidmode/profile.txn` records interrupted folder moves. Recovery resumes one
  step at a time; a conflicting destination stops recovery without deleting saves.
- If a ledger is missing/corrupt, new Daily launches are blocked. Parent unlock
  remains available. Preserve both ledger generations and profile IDs before any
  repair. An older generation can have stale usage, so restoration is a deliberate
  parent recovery, never an automatic fresh budget.

FAT32 cannot guarantee recovery from arbitrary SD failure or power loss. Back up
**the entire `Saves` directory**, `App/KidsMode`, `.kidmode`, and the installed
`.tmp_update/startup/kidmode_boot.sh` before trying this build. Unlock normally first
so the parent and child folders are restored. Never downgrade while a profile
transaction is pending or while a child profile is mounted in `CurrentProfile`.
Rollback means powering off, restoring the known-good app/hook and the matching
complete save snapshot on a computer. Keep the candidate snapshot too if new game
progress must be recovered; do not merge profiles by guessing from a folder name.

## Small development checks

`sh tests/check.sh quick` runs shell syntax/ShellCheck, profile regressions, and
strict policy tests. `full` adds Clang Static Analyzer, ASan/UBSan/Linux leak checks,
asserted broken-program controls, runtime/I/O failure tests and 60 seconds of ledger/parser and session-transition
fuzzing. `candidate` uses 600 seconds. Full checks require Linux Clang, Python 3,
BusyBox and ShellCheck. Use `actionlint` after workflow changes. There is no framework,
mandatory editor setup, git hook, or repo-wide formatter.

Onion MainUI preloads an OSS audio compatibility library which can break the helper's
filesystem calls. `timers.sh` clears that preload only for the allowance process;
the supervisor restores the original value in its game child before execution, so
RetroArch keeps its normal audio environment. The supervisor never loads that shim.

Kids Mode starts Onion's system key monitor (`keymon`) in UTC, matching normal
Onion startup. Its clock-save routine mixes UTC reads with local-time conversion;
inheriting an app's local timezone would shift the clock when keymon is restarted.
Allowance calendar calculations and games still use Onion's configured local timezone.
Automatic setup disables internet time and keeps the RTC in UTC; the installed
Onion 4.3 network script otherwise writes local time into it.
Wi-Fi can remain off. The timer publishes the current balance before opening the
carousel, so the first frame does not wait for a background tick.

Timer modes and the helper protocol are owned by `App/KidsMode/timers.sh`.
The pure C session model produces durable-change and one-shot exit actions;
the runtime handles I/O. Sleep refunds are committed immediately, and sleeping
does not consume the emulator’s save grace period.

The new policy/codec/runtime uses fixed bounds and no explicit heap allocation.
New allocation-failure injection is therefore inapplicable. Existing SDL/cJSON and
Onion library behavior is not fully sanitizer-covered. Real UI rendering and
hardware save/sleep behavior remain qualification gates. The runtime depends on
Onion's pinned PWM path and SIGSTOP sleep behavior; other firmware is unqualified.
The device's own `time_t`/RTC limits also apply, including 2038 on a 32-bit time ABI.

Set `CHECK_REPORT=/absolute/path/checks.json` for a successful candidate receipt.
Cross-build against Onion `07505ea58c7bba698d6b9220ff43946a43cac76b` with
`aemiii91/miyoomini-toolchain@sha256:e5123590ad75d27f0f4c91196e3119a255cad45f3ae15243e29a8e0a2ec50132`.
Compute `source_hash` using `python3 tools/source_hash.py`; pass its `sha256` field as
`make KIDS_BUILD_SOURCE="$source_hash"`. Build from the committed checkout, with
`src/kidsMode` copied into the pinned Onion tree. Verify the ARM ELF dynamic entries
with the toolchain's `readelf`, including `libkbinput.so`, SDL and SDL_rotozoom.

`python3 tools/package.py --binary /path/to/kidui --checks /path/to/checks.json`
refuses dirty source, a mismatched receipt, or a binary without the same embedded
source fingerprint. It checks archive extraction, executable modes and checksums,
and produces an **UNQUALIFIED** ZIP, matching source archive and provenance in
`dist/`. It never installs anything. The existing CI gates build/release on safety
checks; tagged candidates use the longer fuzz duration.

Before installation, verify the exact package on the Miyoo: parent controls and
both profiles; launch/resume/start-over; zero-time save/exit; normal and keep-running
sleep; shutdown during sleep; date rollover/recovery; and rollback using the backup.
This is testing the new accounting and data transitions, not a general emulator tour.

### Theme menu sounds

Navigation, confirm and back inputs use Onion's active-theme `sound/change.wav`,
with Onion's standard sound as fallback. Menu volume (`bgmvol`), master zero volume
and master mute are respected. Background-music mute remains separate; Kids Mode
does not start background music. No Kids Mode sound preference is introduced.
A missing/invalid sound or unavailable audio device leaves the menus usable silently.
One channel prevents overlapping cues, and the mixer closes after input inactivity
once the current sound ends. Audio closes before game launch; confirmation playback
can delay that handoff by at most 100 milliseconds.

Operator testing confirmed navigation and parent-menu sounds, game audio, and menu
audio after returning from a game on November 12. The active theme had no custom
change sound, so this exercised Onion's fallback. Theme selection, mute/volume and
invalid-WAV behavior also passed real SDL/Onion host integration checks.

## Verification and known limits

As of November 12, 2026, operator testing on Onion v4.3.1-1 confirmed Daily gameplay
accounting, sleep pause, five/one-minute warnings with Wi-Fi off, zero-time lockout,
parent bonus, separate child balances, offline restart with the correct date, and
an exhausted allowance renewing on the following day offline. Switching back to
Daily and applying its settings after an offline boot also succeeded.

Host checks cover profile interruption/replay, malformed ownership/ledgers, clock
setup/rollback, session menu/sleep accounting, arithmetic and parser bounds, runtime
I/O failures, sanitizers and fuzzing. ARM builds use the pinned Onion/toolchain above.
Host and operator observations establish different things; neither proves arbitrary
FAT32 power-loss recovery.

Outstanding hardware limits:

- A child switch once left the display on the child picker although the save
  transaction had completed. Sleep/wake did not recover it; a normal shutdown and
  power-on did. Its cause is unresolved. This is not claimed fixed by the save-loss
  repair, which protects ownership and folder moves.
- Actual save validity after timer-driven expiry and a complete rollback rehearsal
  still need qualification; a QUIT request or unchanged file hash alone is insufficient.
- The gameplay-only Single session change and automatic clock setup on a fresh
  device still need their own end-to-end hardware qualification. The existing
  device's accepted offline tests are not a fresh-install test.
- Battery header refresh/icon sizing and the carousel's restart hint remain theme
  concerns. Reduced idle CPU work does not establish battery runtime.
- The inherited missing-binary/repeated-UI-crash recovery can disarm Kids Mode into
  normal Onion. This contribution is not a tamper-proof kiosk boundary.

The implementation intentionally differs from the original proposal in issue #8:
both timer modes now pause in menus/sleep; supported offline Daily opt-in configures
Onion's clock flags with a recovery snapshot; the implementation uses a bounded
checksummed ledger and per-game supervisor rather than a persistent request daemon.
No calendar can recover elapsed powered-off time on hardware without a retained RTC.
