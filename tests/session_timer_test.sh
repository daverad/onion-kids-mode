#!/bin/sh
set -eu
root=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT HUP INT TERM
# shellcheck source=../App/KidsMode/timers.sh
. "$root/App/KidsMode/timers.sh"
# Both endpoints must be the same live game and awake. Menus, game changes,
# dark-screen sleep and the long SIGSTOP gap cannot count as gameplay.
sample() {
    session_interval "$1" "$2" "$3"
    [ "$session_charge" = "$4" ] || { echo "Wrong charge at $1: $session_charge"; exit 1; }
}
sample 10 '' 0 0
sample 70 '' 0 0
sample 71 123 10 0
sample 72 123 10 1
sample 73 123 0 0
sample 74 123 0 0
sample 75 123 10 0
sample 76 123 10 1
sample 1000 123 10 0
sample 1001 123 10 1
sample 1002 456 10 0
sample 1003 '' 0 0
sample 1004 456 10 0
sample 1005 456 10 1
printf 'session intervals: menus, game handoff, PWM sleep and SIGSTOP gap passed\n'
# Run the real ticker with a deterministic source of observations: only
# intervals 3->4 and 4->5 contain gameplay; the rest is menu or sleep.
(
    flagfile="$work/armed"; touch "$flagfile"
    remaining_file="$work/remaining"; timer_state="$work/state"; backupdir="$work"
    tick=0; status_reads=0; game_seen=0; last_notified_min=''
    sleep() { tick=$((tick + 1)); [ "$tick" -lt 10 ] || rm -f "$flagfile"; }
    session_sample() {
        case "$tick" in
            3|4|5) session_interval "$tick" 123 10 ;;
            6|7) session_interval "$tick" 123 0 ;;
            *) session_interval "$tick" '' 0 ;;
        esac
    }
    daily_read() { status_reads=$((status_reads + 1)); daily_enabled=0; daily_error=0; }
    get_timer_minutes() { echo 5; }
    game_is_running() { return 1; } # no messaging side effects in this fixture
    state_write 0 0
    ticker_loop
    [ "$(state_used)" = 2 ]
    [ "$status_reads" = 2 ]
)
printf 'real session ticker charges only the two observed gameplay seconds\n'

# Idle polling is bounded, including Daily rollover/status publication. The
# independent one-second observations still run; expensive status reads do not.
(
    flagfile="$work/idle-armed"; touch "$flagfile"
    remaining_file="$work/remaining"; tick=0; status_reads=0
    sleep() { tick=$((tick + 1)); [ "$tick" -lt 31 ] || rm -f "$flagfile"; }
    session_sample() { session_interval "$tick" '' 0; }
    daily_read() { status_reads=$((status_reads + 1)); daily_enabled=1; daily_remaining=300; }
    ticker_loop
    [ "$status_reads" = 3 ]
)
printf 'idle ticker: three status reads in thirty observations, not thirty\n'
# Starting a parent-selected session turns Daily off via its checked API,
# clears only the legacy session usage/bonus, then publishes the new balance.
(
    timer_state="$work/state"; backupdir="$work"; remaining_file="$work/remaining"
    daily_edit() { [ "$1:$2" = off:0 ]; }
    config_merge() { [ "$3" = 15 ]; }
    log() { :; }
    get_timer_minutes() { echo 15; }
    active_kids_profile() { echo "$work/nonexistent"; }
    state_write 80 300
    start_single_session 15
    [ "$(state_used):$(state_bonus):$(cat "$remaining_file")" = 0:0:900 ]
    # A settings-write failure must not disable Daily or reset old usage.
    state_write 80 300
    config_merge() { return 1; }
    daily_edit() { touch "$work/incorrect-disable"; }
    infoPanel() { :; }
    if start_single_session 15; then echo 'Failed write reported success'; exit 1; fi
    [ ! -e "$work/incorrect-disable" ]
    [ "$(state_used):$(state_bonus)" = 80:300 ]
)
printf 'explicit session start replaces session budget without a daily reset command\n'

# Publish failure must not execute the game; success retains a foreground
# launch and removes its marker even when the game exits with an error.
(
    sysdir="$work"; tz_value=UTC; session_game_file="$work/missing/marker"
    daily_read() { daily_enabled=0; }
    printf 'test -s "$1"; exit 7\n' > "$work/cmd_to_run.sh"
    if timer_run_game 2>/dev/null; then echo 'Missing marker accepted'; exit 1; fi
    session_game_file="$work/marker"
    printf 'test -s "%s" || exit 8; exit 7\n' "$session_game_file" > "$work/cmd_to_run.sh"
    result=0
    timer_run_game || result=$?
    [ "$result" = 7 ] && [ ! -e "$session_game_file" ]
)
printf 'session launch refuses marker failure and cleans up after game exit\n'
