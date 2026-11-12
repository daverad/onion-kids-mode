#!/bin/sh
# Exercise the real setup boundary against SD-card directories; replace only
# hardware commands. No host clock, /tmp trust marker or Wi-Fi is modified.
set -eu
root=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT HUP INT TERM
# shellcheck source=../App/KidsMode/clock.sh
. "$root/App/KidsMode/clock.sh"
system="$work/system"; backup="$work/Saves/kidmode"; runtime="$work/runtime"
mkdir -p "$system/config" "$system/onionVersion" "$backup" "$runtime"
printf v4.3.1-1 > "$system/onionVersion/version.txt"
printf UTC+08:00 > "$system/config/.tz"
printf original-ntp-contents > "$system/config/.ntpState"
printf 'protected-save\n' > "$backup/save"
epoch=1794332738; rtc_epoch=1794332738; hardware_rc=0; network_rc=1
boot_log='ms_rtcpwc 1f006800.rtcpwc: setting system clock to 2026-11-10 17:45:38 UTC (1794332738)'
dmesg() { printf '%s\n' "$boot_log"; }
date() { printf '%s\n' "$epoch"; }
pgrep() { return "$network_rc"; }
sync() { :; }
hwclock() {
    [ "$TZ" = UTC0 ] && [ "$1" = -u ] || return 1
    printf '%s\n' "$2" >> "$work/hw-operations"
    [ "$hardware_rc" = 0 ] || return 1
    case "$2" in -s) epoch=$rtc_epoch ;; -w|-r) ;; *) return 1 ;; esac
}
setup() { clock_setup "$1" "$system" "$backup" "$runtime" "$work/rtc"; }
refused() { rc=0; setup "$1" || rc=$?; [ "$rc" = "$2" ]; }

# Registration/current RTC/network time alone must never certify retained RTC.
good_log=$boot_log
for boot_log in '' 'ms_rtcpwc 1f006800.rtcpwc: rtc core: registered as rtc0' \
 'ms_rtcpwc 1f006800.rtcpwc: setting system clock to 1970-01-01 00:02:33 UTC (153)' \
 'ms_rtcpwc 1f006800.rtcpwc: setting system clock to bogus UTC (1794332738xxx)' \
 'ms_rtcpwc 1f006800.rtcpwc: setting system clock to date UTC (99999999999999999999)' \
 'another_rtc: setting system clock to date UTC (1794332738)'; do
    touch "$runtime/ntp_synced"
    refused enable 10
    [ ! -e "$backup/clock-settings" ] && [ ! -e "$system/config/.noTimeRestore" ]
done
boot_log=$(printf '%s\n%s\n' "$good_log" "$good_log")
refused enable 10
boot_log=$good_log
rm "$runtime/ntp_synced"
printf v9 > "$system/onionVersion/version.txt"
refused enable 10
printf v4.3.1-1 > "$system/onionVersion/version.txt"
printf 'RTC evidence rejects registration, restored/NTP time, duplicate and invalid records\n'

# Automatic first enable corrects emulated system time from RTC, saves exact
# original flags, writes RTC in UTC and leaves timezone/saves alone.
epoch=1794347138
setup enable
[ "$(cat "$work/hw-operations")" = "$(printf '%s\n' -s -w -r)" ]
[ -f "$system/config/.noTimeRestore" ] && [ ! -e "$system/config/.ntpState" ]
[ -f "$runtime/kidmode_rtc_available" ] && [ -f "$backup/clock-settings/applied" ]
[ "$(cat "$backup/clock-settings/.ntpState")" = original-ntp-contents ]
[ "$(cat "$backup/save")" = protected-save ]
[ "$(cat "$system/config/.tz")" = UTC+08:00 ]
cp "$work/hw-operations" "$work/before-repeat"
setup enable
cmp "$work/hw-operations" "$work/before-repeat"
rm "$runtime/kidmode_rtc_available"
setup boot
[ -f "$runtime/kidmode_rtc_available" ]
printf 'fresh setup is automatic, UTC, repeatable; saves and timezone unchanged\n'

# Switching away and back later in the same boot must not depend on a kernel
# message surviving ring-buffer wrap. Reuse only the volatile verified marker;
# after reboot (marker gone), absent boot evidence must still refuse setup.
boot_log=''
cp "$work/hw-operations" "$work/before-reentry"
setup enable
cmp "$work/hw-operations" "$work/before-reentry"
rm "$runtime/kidmode_rtc_available"
refused enable 10
[ -f "$backup/clock-settings/applied" ]
boot_log=$good_log
setup boot
printf 'same-boot reentry survives log wrap; no marker/evidence still refuses\n'

# At startup, disabled restore/NTP writers plus a valid kernel-initialized
# matching RTC survive boot-log wrap. The same current clock cannot authorize
# parent opt-in without a fresh boot marker. Uninitialized or software-set time
# must not gain trust, nor can a copied SD snapshot certify a different driver.
rm "$runtime/kidmode_rtc_available"
boot_log=''
mkdir "$work/rtc"
printf 1f006800.rtcpwc > "$work/rtc/name"
printf 1 > "$work/rtc/hctosys"
printf '%s' "$epoch" > "$work/rtc/since_epoch"
refused enable 10
setup boot
[ -f "$runtime/kidmode_rtc_available" ]
setup enable
cmp "$work/hw-operations" "$work/before-reentry"
rm "$runtime/kidmode_rtc_available"
touch "$runtime/ntp_synced"
refused boot 10
rm "$runtime/ntp_synced"
printf 153 > "$work/rtc/since_epoch"
refused boot 10
printf '%s' "$((epoch - 60))" > "$work/rtc/since_epoch"
refused boot 10
printf '%s' "$epoch" > "$work/rtc/since_epoch"
printf 0 > "$work/rtc/hctosys"
refused boot 10
printf 1 > "$work/rtc/hctosys"
printf another_rtc > "$work/rtc/name"
refused boot 10
printf 1f006800.rtcpwc > "$work/rtc/name"
touch "$system/config/.ntpState"
refused boot 10
rm "$system/config/.ntpState" "$system/config/.noTimeRestore"
refused boot 10
touch "$system/config/.noTimeRestore"
setup boot
boot_log=$good_log
printf 'boot-only RTC evidence survives log wrap; software/uninitialized clocks refused\n'

# Explicit rollback is byte-exact and repeatable; later opt-in works again.
setup restore
[ ! -e "$system/config/.noTimeRestore" ] && [ ! -e "$runtime/kidmode_rtc_available" ]
[ "$(cat "$system/config/.ntpState")" = original-ntp-contents ]
setup restore
: > "$work/hw-operations"
touch "$runtime/ntp_synced"
setup enable
[ "$(cat "$work/hw-operations")" = "$(printf '%s\n' -w -r)" ]
printf 'rollback preserves original bytes; current synced time beats old RTC\n'

# Power loss before completion must restore both settings on boot, not mark
# the partially applied setup trusted or enable a child.
rm "$backup/clock-settings/applied" "$runtime/kidmode_rtc_available"
refused boot 10
[ ! -e "$system/config/.noTimeRestore" ] && [ -f "$system/config/.ntpState" ]
[ -f "$backup/clock-settings/restored" ]
hardware_rc=1
refused enable 13
[ ! -e "$system/config/.noTimeRestore" ] && [ -f "$system/config/.ntpState" ]
[ ! -e "$runtime/kidmode_rtc_available" ]
hardware_rc=0
network_rc=0
refused enable 12
network_rc=1
printf 'partial setup / RTC failure roll back; active network writer postpones setup\n'

# External settings changes, symlinks and missing timezone cannot be hidden
# by reusing or overwriting the original recovery snapshot.
printf changed > "$system/config/.ntpState"
refused enable 13
printf original-ntp-contents > "$system/config/.ntpState"
rm "$system/config/.tz"
refused enable 11
printf UTC > "$system/config/.tz"
ln -s "$backup/save" "$system/config/.noTimeRestore"
refused enable 13
[ "$(cat "$backup/save")" = protected-save ]
rm "$system/config/.noTimeRestore"
printf 'external configuration and invalid paths are preserved, never guessed\n'

# Pre-existing manual settings survive setup and rollback. Stale incomplete
# staging is safe to resume because configuration was not touched yet.
backup="$work/manual"; mkdir "$backup" "$backup/clock-settings.new"
printf incomplete > "$backup/clock-settings.new/.ntpState"
printf existing > "$system/config/.noTimeRestore"
rm "$system/config/.ntpState"
setup enable
setup restore
[ "$(cat "$system/config/.noTimeRestore")" = existing ]
[ ! -e "$system/config/.ntpState" ]
printf 'manual settings and interrupted staging recover without an experiment\n'

# Exercise the actual timer entry point: failure cannot enable Daily; a
# backward setup correction must use checked confirmation before the limit.
(
    # shellcheck source=../App/KidsMode/timers.sh
    . "$root/App/KidsMode/timers.sh"
    sysdir=$system; backupdir=$backup
    clock_setup() { return "$setup_rc"; }
    daily_read() { daily_uncertain=1; daily_generation=42; }
    daily_call() { printf '%s\n' "$1" >> "$work/ledger-operations"; }
    update_remaining_now() { :; }
    infoPanel() { :; }
    setup_rc=10
    if daily_edit daily 5; then echo 'enabled Daily without RTC'; exit 1; fi
    [ ! -e "$work/ledger-operations" ]
    setup_rc=0
    daily_edit daily 5
    [ "$(cat "$work/ledger-operations")" = "$(printf '%s\n' confirm daily)" ]
)
printf 'parent opt-in gates the ledger and adopts corrected dates through checked API\n'

# Hook publication is atomic; a failed copy must not claim installation.
(
    export kidmode_test=1 KIDMODE_APP_DIR="$root/App/KidsMode"
    # shellcheck source=../App/KidsMode/kid_mode_loop.sh
    . "$root/App/KidsMode/kid_mode_loop.sh"
    sysdir="$work/hook-system"; hook_src="$root/App/KidsMode/kidmode_boot.sh"
    hook_dst="$sysdir/startup/kidmode_boot.sh"
    log() { :; }
    install_hook
    cmp "$hook_src" "$hook_dst"
    printf old > "$hook_dst"
    cp() { return 1; }
    if install_hook; then echo 'accepted failed boot hook copy'; exit 1; fi
    [ "$(cat "$hook_dst")" = old ]
)
printf 'boot hook publishes verified bytes and preserves old hook on copy failure\n'
