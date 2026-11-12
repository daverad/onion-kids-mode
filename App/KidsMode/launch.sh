#!/bin/sh
# Kid Mode arm app — one tap in Onion's Apps tab arms Kid Mode and drops
# straight into the kid launcher. Unlock from inside the kid UI by holding
# SELECT+START for 3 seconds and entering the PIN.

progdir="$(CDPATH= cd -- "$(dirname "$0")" > /dev/null 2>&1 && pwd -P)"
cd "$progdir" || exit 1

sh ./kid_mode_loop.sh arm

# A failed write must not return a half-swapped save tree to Onion.
while [ -f /mnt/SDCARD/Saves/kidmode/profile.txn ] || [ -f /mnt/SDCARD/.kidmode ]; do
    if sh ./kid_mode_loop.sh recover; then
        sh ./kid_mode_loop.sh run
    else
        infoPanel -t "Kids Mode" -m "Save recovery needs attention.\nPower off and keep the SD card intact." --auto
    fi
    sleep 5
done
