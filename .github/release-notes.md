## Daily gameplay allowance candidate

Parents can choose No limit, Single session, or Daily allowance. Both timed modes
pause in menus and sleep. Each child has an independent Daily budget; usage survives
reboot and mode changes, unused time and bonus expire at local midnight, and a PIN
permits extra time today. Daily warns at five and one minute and blocks new play at
zero after requesting the supported RetroArch save/exit path.

This builds on whawker's multi-child profiles in #7. The save-recovery repair is a
separate commit: interrupted handoffs resume a checksummed transaction without
replacing another child's saves. The core timer feature is squashed separately.

A separate menu-audio commit uses Onion's active-theme navigation sound and standard
fallback, respects menu/master sound settings, prevents overlapping cues, and closes
the mixer before launching games. Background music remains separate. Operator
testing confirmed navigation and game/menu audio handoff.

## Installation and clock support

These are **unofficial, UNQUALIFIED candidate** archives, not a universal hardware
compatibility claim. Read `docs/daily-allowance.md` and back up the entire `Saves`
directory, app and boot hook. Exit Kids Mode normally before replacing the app.
Preserve per-child `.allowance-id` and allowance records across updates.

Daily opt-in automatically configures offline clock flags only on supported Onion
v4.3.1-1 with retained RTC evidence at boot. Original flags are backed up for rollback;
network time is disabled to avoid conflicting RTC writers. No continuous Wi-Fi is
required. Unsupported devices can use Single session or No limit.

## Verification limits

Pinned ARM builds and focused host checks cover profile recovery, clock and timer
adapters, strict C diagnostics, static analysis, ASan/UBSan/leak detection, runtime
I/O faults and bounded fuzzing. Daily accounting, warnings, bonus, child isolation,
offline renewal and restart have operator acceptance on the tested Miyoo.

A child-switch display freeze remains unresolved, despite completed save ownership
transfer. Actual save validity after timer expiry, rollback on hardware, fresh-device
clock setup and the updated Single session behavior still need qualification.
See the guide for details; host tests do not establish arbitrary FAT32 power-loss
recovery or a tamper-proof kiosk boundary.

GPL-3.0; original contributor history and attribution retained. Development used
OpenAI Codex assistance and physical-device feedback.
