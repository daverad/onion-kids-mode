#!/bin/sh
# Kid Mode boot hook — runs from /mnt/SDCARD/.tmp_update/startup/ before
# Onion launches MainUI (see runtime.sh "Startup scripts"). If the Kid Mode
# flag is present this blocks here in the kid launcher loop; MainUI only
# starts after a successful PIN unlock removed the flag.
#
# This file ships in App/KidsMode/ and is copied into .tmp_update/startup/
# automatically the first time Kid Mode is armed (see kid_mode_loop.sh).
#
# Recovery from a computer: delete /mnt/SDCARD/.kidmode (or the copy of
# this file in .tmp_update/startup/) and the device boots normal Onion.

flagfile=/mnt/SDCARD/.kidmode
looper=/mnt/SDCARD/App/KidsMode/kid_mode_loop.sh

# A transaction can outlive the armed flag at its final disarm boundary.
# Never hand a half-swapped profile to MainUI.
while [ -f /mnt/SDCARD/Saves/kidmode/profile.txn ]; do
    sh "$looper" recover && break
    infoPanel -t "Kids Mode" -m "Save recovery needs attention.\nPower off and keep the SD card intact." --auto
    sleep 5
done
# Record clock provenance even when Kids Mode is not armed at startup.
if [ -f /mnt/SDCARD/App/KidsMode/timers.sh ] && [ -f /mnt/SDCARD/App/KidsMode/clock.sh ]; then
    # shellcheck source=timers.sh
    . /mnt/SDCARD/App/KidsMode/timers.sh
    daily_boot_clock /mnt/SDCARD/.tmp_update /tmp /mnt/SDCARD/Saves/kidmode
fi
[ -f "$flagfile" ] || exit 0

if [ -f "$looper" ]; then
    while [ -f "$flagfile" ]; do
        sh "$looper" run
        [ -f "$flagfile" ] && sleep 5
    done
else
    # App folder missing — fail open so the device stays usable
    rm -f "$flagfile"
fi
