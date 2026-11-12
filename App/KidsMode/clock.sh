#!/bin/sh
# Offline clock compatibility belongs here, not in allowance policy. This
# module never edits a ledger, profile, timezone, Wi-Fi setting or Onion code.
# Settings are device-wide and survive switching children / turning Daily off.

clock_epoch_valid() {
    case "$1" in ''|*[!0-9]*) return 1 ;; esac
    [ "${#1}" -eq 10 ] && [ "$1" -ge 1577836800 ] && [ "$1" -lt 2147483647 ]
}

clock_hardware_present() {
    # Both markers are volatile, established during this boot. Kernel logs can
    # wrap before a parent switches modes; do not discard already-verified RTC
    # provenance. A copied SD card or a reboot cannot carry this marker over.
    [ -f "$clock_runtime/rtc_available" ] ||
        [ -f "$clock_runtime/kidmode_rtc_available" ] && return 0
    # The kernel sampled RTC before Onion could restore a saved timestamp or
    # run NTP. Merely finding rtc0 or reading it after NTP proves nothing.
    # Accept exactly one known Miyoo driver record; no registration messages,
    # unrelated RTCs, malformed epochs or 1970 clocks. Never persist dmesg.
    _clock_log=$(dmesg 2>/dev/null) || return 1
    _clock_boot=$(printf '%s\n' "$_clock_log" | sed -n \
        's/^.*ms_rtcpwc 1f006800\.rtcpwc: setting system clock to .* UTC (\([0-9][0-9]*\))$/\1/p')
    clock_epoch_valid "$_clock_boot"
}

# Only the startup hook may use this fallback. With both Onion clock writers
# disabled before startup, a valid kernel-initialized RTC matching system time
# is fresh evidence even when Wi-Fi/framebuffer messages wrapped the boot log.
# Never use this during parent opt-in: software may have set the clock by then.
clock_boot_retained() {
    [ ! -e "$clock_runtime/ntp_synced" ] || return 1
    [ "$(cat "$clock_rtc/name" 2>/dev/null)" = 1f006800.rtcpwc ] &&
        [ "$(cat "$clock_rtc/hctosys" 2>/dev/null)" = 1 ] || return 1
    _clock_rtc_epoch=$(cat "$clock_rtc/since_epoch" 2>/dev/null) || return 1
    _clock_system_epoch=$(date -u +%s) || return 1
    clock_epoch_valid "$_clock_rtc_epoch" && clock_epoch_valid "$_clock_system_epoch" || return 1
    _clock_delta=$((_clock_system_epoch - _clock_rtc_epoch))
    [ "$_clock_delta" -ge -2 ] && [ "$_clock_delta" -le 2 ]
}

clock_settings_safe() {
    [ -d "$clock_system/config" ] && [ ! -L "$clock_system/config" ] || return 1
    for _clock_flag in .noTimeRestore .ntpState; do
        _clock_path="$clock_system/config/$_clock_flag"
        [ ! -L "$_clock_path" ] || return 1
        [ ! -e "$_clock_path" ] || [ -f "$_clock_path" ] || return 1
    done
}

clock_snapshot_valid() {
    [ -d "$clock_backup" ] && [ ! -L "$clock_backup" ] || return 1
    for _clock_item in version applied restored .noTimeRestore .ntpState .noTimeRestore.absent .ntpState.absent; do
        [ ! -L "$clock_backup/$_clock_item" ] || return 1
        [ ! -e "$clock_backup/$_clock_item" ] || [ -f "$clock_backup/$_clock_item" ] || return 1
    done
    [ "$(cat "$clock_backup/version" 2>/dev/null)" = 1 ] || return 1
    for _clock_flag in .noTimeRestore .ntpState; do
        [ ! -L "$clock_backup/$_clock_flag" ] || return 1
        if [ -f "$clock_backup/$_clock_flag" ]; then
            [ ! -e "$clock_backup/$_clock_flag.absent" ] || return 1
        else
            [ -f "$clock_backup/$_clock_flag.absent" ] || return 1
        fi
    done
}

clock_snapshot() {
    [ ! -e "$clock_backup" ] && [ ! -L "$clock_backup" ] || return 1
    # Incomplete staging predates all settings changes. Remove only our fixed
    # file names; unexpected content or a symlink is a recovery error.
    [ ! -L "$clock_backup.new" ] || return 1
    if [ -d "$clock_backup.new" ]; then
        rm -f "$clock_backup.new/version" "$clock_backup.new/.noTimeRestore" \
            "$clock_backup.new/.ntpState" "$clock_backup.new/.noTimeRestore.absent" \
            "$clock_backup.new/.ntpState.absent" && rmdir "$clock_backup.new" || return 1
    fi
    mkdir "$clock_backup.new" || return 1
    for _clock_flag in .noTimeRestore .ntpState; do
        if [ -f "$clock_system/config/$_clock_flag" ]; then
            cp "$clock_system/config/$_clock_flag" "$clock_backup.new/$_clock_flag" || return 1
            cmp -s "$clock_system/config/$_clock_flag" "$clock_backup.new/$_clock_flag" || return 1
        else
            : > "$clock_backup.new/$_clock_flag.absent" || return 1
        fi
    done
    printf '1\n' > "$clock_backup.new/version" || return 1
    sync
    mv "$clock_backup.new" "$clock_backup" || return 1
    sync
}

clock_restore() {
    clock_settings_safe && clock_snapshot_valid || return 1
    # Remove the completion marker first: interruption replays restoration at
    # boot. Retain original bytes until both readbacks have succeeded.
    rm -f "$clock_backup/applied" "$clock_backup/restored" "$clock_runtime/kidmode_rtc_available" || return 1
    for _clock_flag in .noTimeRestore .ntpState; do
        if [ -f "$clock_backup/$_clock_flag" ]; then
            [ ! -L "$clock_system/config/$_clock_flag.kids-restore" ] || return 1
            [ ! -e "$clock_system/config/$_clock_flag.kids-restore" ] ||
                [ -f "$clock_system/config/$_clock_flag.kids-restore" ] || return 1
            cp "$clock_backup/$_clock_flag" "$clock_system/config/$_clock_flag.kids-restore" &&
                mv "$clock_system/config/$_clock_flag.kids-restore" "$clock_system/config/$_clock_flag" &&
                cmp -s "$clock_backup/$_clock_flag" "$clock_system/config/$_clock_flag" || return 1
        else
            rm -f "$clock_system/config/$_clock_flag" || return 1
            [ ! -e "$clock_system/config/$_clock_flag" ] || return 1
        fi
    done
    sync
    # Keep a restored snapshot for recovery/audit; future setup reuses it only
    # if the parent's settings still match, never overwriting their baseline.
    : > "$clock_backup/restored" || return 1
    sync
}

clock_settings_original() {
    for _clock_flag in .noTimeRestore .ntpState; do
        if [ -f "$clock_backup/$_clock_flag" ]; then
            cmp -s "$clock_backup/$_clock_flag" "$clock_system/config/$_clock_flag" || return 1
        else
            [ ! -e "$clock_system/config/$_clock_flag" ] || return 1
        fi
    done
}

clock_settings_applied() {
    [ -f "$clock_system/config/.noTimeRestore" ] &&
        [ ! -e "$clock_system/config/.ntpState" ]
}

clock_enable() {
    clock_hardware_present || return 10
    clock_settings_safe || return 13
    [ -s "$clock_system/config/.tz" ] || return 11
    # Do not race an already-running Onion network time writer. No killing
    # services, network request, Wi-Fi toggle or blocking wait is needed.
    _clock_busy=0
    pgrep -f '/script/network/update_networking.sh' >/dev/null 2>&1 || _clock_busy=$?
    [ "$_clock_busy" -eq 1 ] || return 12
    if [ -d "$clock_backup" ]; then
        clock_snapshot_valid || return 13
        if [ -f "$clock_backup/applied" ]; then
            clock_settings_applied || return 13
            clock_epoch_valid "$(date -u +%s)" || return 11
            : > "$clock_runtime/kidmode_rtc_available" || return 13
            return 0
        fi
        [ -f "$clock_backup/restored" ] && clock_settings_original || return 13
        rm -f "$clock_backup/restored" || return 13
    else
        mkdir -p "$(dirname "$clock_backup")" || return 13
        clock_snapshot || return 13
    fi
    if ! clock_apply; then
        clock_restore || return 13
        return 13
    fi
    : > "$clock_backup/applied" || return 13
    sync
    : > "$clock_runtime/kidmode_rtc_available" || return 13
}

clock_apply() {
    touch "$clock_system/config/.noTimeRestore" &&
        rm -f "$clock_system/config/.ntpState" || return 1
    sync
    _clock_busy=0
    pgrep -f '/script/network/update_networking.sh' >/dev/null 2>&1 || _clock_busy=$?
    [ "$_clock_busy" -eq 1 ] || return 1
    # NTP or a parent-confirmed current clock beats potentially local-time RTC
    # contents. Otherwise undo Onion's emulated time using the retained RTC.
    if [ ! -f "$clock_runtime/ntp_synced" ] && [ ! -f "$clock_runtime/kidmode_clock_confirmed" ]; then
        TZ=UTC0 hwclock -u -s || return 1
    fi
    clock_epoch_valid "$(date -u +%s)" || return 1
    TZ=UTC0 hwclock -u -w && TZ=UTC0 hwclock -u -r >/dev/null || return 1
    clock_settings_applied
}

# One entry point; paths are supplied by the timer/boot boundary and isolated
# in a subshell. Return codes: 10 unsupported RTC/version, 11 date/timezone,
# 12 network writer busy, 13 storage/configuration error. Never source state.
clock_setup() (
    _clock_action=$1; clock_system=$2; clock_backup="$3/clock-settings"; clock_runtime=$4
    clock_rtc=${5:-/sys/class/rtc/rtc0}
    # Explicit rollback remains available after an Onion upgrade; only setup
    # and automatic boot recovery rely on this version's startup contract.
    if [ "$_clock_action" = restore ]; then clock_restore; exit $?; fi
    [ "$(cat "$clock_system/onionVersion/version.txt" 2>/dev/null)" = v4.3.1-1 ] || exit 10
    case "$_clock_action" in
        enable) clock_enable ;;
        boot)
            if [ -d "$clock_backup" ] && [ ! -f "$clock_backup/applied" ] && [ ! -f "$clock_backup/restored" ]; then
                clock_restore || exit 13
            fi
            # Existing manually prepared installs use the same capability
            # check; a copied SD card never inherits another device's trust.
            clock_settings_safe && clock_settings_applied &&
                { clock_hardware_present || clock_boot_retained; } &&
                clock_epoch_valid "$(date -u +%s)" || exit 10
            : > "$clock_runtime/kidmode_rtc_available"
            ;;
        *) exit 13 ;;
    esac
)
