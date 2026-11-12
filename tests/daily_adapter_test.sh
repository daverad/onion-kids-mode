#!/bin/sh
set -eu
root=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT HUP INT TERM
# shellcheck source=../App/KidsMode/timers.sh
. "$root/App/KidsMode/timers.sh"
# System keymon must not inherit the app's local timezone. The real Onion
# exit routine converts UTC through mktime, so a local TZ shifts the clock.
(
    export kidmode_test=1 KIDMODE_APP_DIR="$root/App/KidsMode"
    # shellcheck source=../App/KidsMode/kid_mode_loop.sh
    . "$root/App/KidsMode/kid_mode_loop.sh"
    keymon() { printf '%s\n' "$TZ" > "$work/keymon-zone"; }
    TZ=UTC+08:00; export TZ
    start_keymon
    wait
    [ "$(cat "$work/keymon-zone")" = UTC0 ]
    [ "$TZ" = UTC+08:00 ]
)
printf 'keymon UTC boundary: parent local timezone preserved\n'

# Starting the ticker must publish the fresh allowance synchronously; its
# old stop path deleted that file and left the initial carousel unmetered.
(
    remaining_file="$work/remaining"; ticker_pid_file="$work/ticker.pid"
    backupdir="$work/ticker-backup"; mkdir -p "$backupdir/allowance"
    touch "$backupdir/allowance/state.v1"
    daily_read() { daily_enabled=1; daily_remaining=300; }
    ticker_loop() { :; }
    printf 0 > "$remaining_file"
    start_ticker
    [ "$(cat "$remaining_file")" = 300 ]
    wait
    rm "$ticker_pid_file"
    stop_ticker
)
printf 'ticker startup publishes the daily balance before the UI\n'

# MainUI's audio shim must stay in the parent/game environment, never the helper.
(
    sysdir="$work/system"; backupdir="$work/backup"; daily_profile="$work/child"
    mkdir -p "$sysdir/config"
    printf UTC > "$sysdir/config/.tz"
    kidui_bin="$work/preload-probe"
    cat > "$kidui_bin" <<'PROBE'
#!/bin/sh
[ -z "$LD_PRELOAD" ] && [ "$KIDMODE_GAME_LD_PRELOAD" = 'onion-audio-shim' ]
PROBE
    chmod +x "$kidui_bin"
    LD_PRELOAD=onion-audio-shim
    daily_call status
    [ "$LD_PRELOAD" = 'onion-audio-shim' ]
)
printf 'audio preload isolated from allowance helper, parent preserved\n'

saves_dir="$work/Saves"
daily_profile="$saves_dir/KidsProfile.Ada"
mkdir -p "$daily_profile" "$saves_dir/KidsProfile.Bea"
log() { :; }
printf '0123456789abcdef\n' > "$daily_profile/.allowance-id"
printf 'fedcba9876543210\n' > "$saves_dir/KidsProfile.Bea/.allowance-id"
daily_unique_identity
cp "$daily_profile/.allowance-id" "$saves_dir/KidsProfile.Bea/.allowance-id"
if daily_unique_identity; then echo 'accepted duplicated profile identity'; exit 1; fi
mv "$saves_dir/KidsProfile.Bea" "$saves_dir/Other"
daily_unique_identity
printf 'daily profile identity ambiguity: safely refused\n'

# Missing/corrupt boot ownership cannot become a new Off-mode profile.
unset daily_profile
backupdir="$saves_dir/kidmode"
active_kid_file="$backupdir/active_kid.txt"
kids_profile_prefix="$saves_dir/KidsProfile."
legacy_kids_profile="$saves_dir/KidsProfile"
mkdir -p "$backupdir/allowance"
printf recorded > "$backupdir/allowance/state.v1"
valid_kid_name() { [ "$1" != '../bad' ]; }
if daily_owner_valid; then echo 'accepted missing owner'; exit 1; fi
printf '../bad\n' > "$active_kid_file"
if daily_owner_valid; then echo 'accepted unsafe owner'; exit 1; fi
printf 'Unknown\n' > "$active_kid_file"
if daily_owner_valid; then echo 'accepted absent child'; exit 1; fi
printf '\n' > "$active_kid_file"
if daily_owner_valid; then echo 'enrolled unnamed child after owner loss'; exit 1; fi
printf 'Ada\n' > "$active_kid_file"
daily_owner_valid
printf 'missing/corrupt active ownership: safely refused\n'

# An armed pre-profile version has no pointer or ledger but does have the
# unnamed save root. Migrate that owner before initializing Off-mode state.
saves_dir="$work/legacy/Saves"
backupdir="$saves_dir/kidmode"
active_kid_file="$backupdir/active_kid.txt"
kids_profile_prefix="$saves_dir/KidsProfile."
legacy_kids_profile="$saves_dir/KidsProfile"
mkdir -p "$legacy_kids_profile" "$backupdir"
kid_count() { echo 0; }
active_kids_profile() { printf '%s\n' "$legacy_kids_profile"; }
set_active_kid() { printf '%s\n' "$1" > "$active_kid_file"; }
daily_ui_status() { :; }
daily_call() {
    [ -f "$active_kid_file" ] || return 1
    case "$1" in
        enroll)
            mkdir -p "$backupdir/allowance"
            printf recorded > "$backupdir/allowance/state.v1"
            printf '0123456789abcdef\n' > "$legacy_kids_profile/.allowance-id"
            ;;
        status) printf '%s\n' '-1 0 0 1 1 0 0' ;;
        *) return 1 ;;
    esac
}
daily_prepare
[ "$daily_enabled" = 0 ] && [ "$(cat "$active_kid_file")" = '' ]
printf 'armed legacy owner migrated without enabling Daily\n'

# A successful helper exit with malformed output must still block play. None
# of the previous successful status fields may survive the failed read.
daily_call() { printf '%s\n' "$protocol_output"; }
for protocol_output in '0 1' '0 1 30 0 2 0 20261109 extra' \
    '0 0 0 0 2 0 20261109' '-1 1 30 0 2 0 20261109' \
    '100 1 31 0 2 0 20261109' '100 1 30 7 2 0 20261109' \
    '01 1 30 0 2 0 20261109' '9999999999999 1 30 0 2 0 20261109' \
    '* 1 30 0 2 0 20261109' '100 1 30 0 2 -1 20261109'; do
    daily_enabled=0; daily_remaining=-1; daily_error=0
    if daily_read; then echo 'accepted malformed helper status'; exit 1; fi
    [ "$daily_error" = 1 ] && [ "$daily_enabled" = 1 ] && [ "$daily_remaining" = 0 ]
done
protocol_output='100 1 30 0 9223372036854775807 1700 20261109'
daily_read
[ "$daily_error" = 0 ] && [ "$daily_remaining" = 100 ]
printf 'helper status boundary: malformed output blocks play without stale values\n'

# Apply succeeds: all modes return to the carousel. Apply fails: retain the
# parent menu. The second simulated UI action is an explicit parent exit,
# making an unintended reopen distinguishable from the normal return path.
(
    export kidmode_test=1 KIDMODE_APP_DIR="$root/App/KidsMode"
    # shellcheck source=../App/KidsMode/kid_mode_loop.sh
    . "$root/App/KidsMode/kid_mode_loop.sh"
    uiresult="$work/menu-result"; autoresume_result="$work/ar"; brightness_result="$work/bright"
    uilog="$work/menu-log"; sysdir="$work/menu-system"; kidui_bin="$work/menu-ui"
    export uiresult menu_calls="$work/menu-calls" menu_choice
    mkdir -p "$sysdir/config"; printf UTC > "$sysdir/config/.tz"
    cat > "$kidui_bin" <<'UI'
#!/bin/sh
count=$(cat "$menu_calls"); count=$((count + 1)); echo "$count" > "$menu_calls"
if [ "$count" = 1 ]; then printf 'MENU\n%s\n5\n' "$menu_choice" > "$uiresult"
else printf 'MENU\nUNLOCK\n' > "$uiresult"; fi
exit 5
UI
    chmod +x "$kidui_bin"
    config_get() { echo false; }; kid_roster() { :; }; get_active_kid() { echo Child; }
    get_timer_minutes() { echo 5; }; timer_remaining() { echo 300; }; get_brightness_pct() { echo 50; }
    daily_read() { daily_enabled=0; daily_minutes=5; daily_uncertain=0; daily_used=0; daily_day=20261112; }
    daily_edit() { return "$apply_rc"; }; start_single_session() { return "$apply_rc"; }
    set_timer_minutes() { return "$write_rc"; }; state_write() { :; }; update_remaining_now() { :; }
    log() { :; }; infoPanel() { :; }
    write_rc=0
    for menu_choice in DAILY SESSION NOTIMER; do
        apply_rc=0; echo 0 > "$menu_calls"; result=0
        parent_menu || result=$?
        [ "$result:$(cat "$menu_calls")" = 1:1 ]
        apply_rc=1; echo 0 > "$menu_calls"; result=0
        parent_menu || result=$?
        [ "$result:$(cat "$menu_calls")" = 0:2 ]
    done
    menu_choice=NOTIMER; apply_rc=0; write_rc=1; echo 0 > "$menu_calls"; result=0
    parent_menu || result=$?
    [ "$result:$(cat "$menu_calls")" = 0:2 ]
)
printf 'all applied timer modes close menu; failed updates keep it open\n'
