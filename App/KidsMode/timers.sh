#!/bin/sh
# Parent mutations are called only after PIN authentication. The C helper
# owns locking, bounds, stable IDs, checksums and durable usage; never source
# a ledger as shell code. Off/Session and Daily share this timer boundary.
# shellcheck disable=SC2154,SC2034
: "${session_game_file:=/tmp/kidmode_session_game}"

# Clock setup is device-wide; parent-only Daily opt-in owns configuration.
# Boot only restores an interrupted setup and records fresh RTC provenance.
daily_boot_clock() {
    # Also works with an older installed hook during an app-folder update.
    # shellcheck source=clock.sh
    . "${appdir:-/mnt/SDCARD/App/KidsMode}/clock.sh" || return 1
    clock_setup boot "$1" "${3:-/mnt/SDCARD/Saves/kidmode}" "$2"
}

daily_clock_setup() {
    clock_setup enable "$sysdir" "$backupdir" /tmp
    _dc_result=$?
    case "$_dc_result" in
        0) return 0 ;;
        10) _dc_message="Offline daily limit unavailable.\nNo supported retained clock\nwas detected at startup.\nThe existing timer is unchanged." ;;
        11) _dc_message="Set the date and timezone\nin Onion before enabling\nthe daily limit." ;;
        12) _dc_message="Onion is updating the clock.\nTry enabling the daily limit\nagain in a moment." ;;
        *) _dc_message="Clock setup did not finish.\nRestart and try again.\nIf this repeats, keep the\nSD card intact for recovery." ;;
    esac
    infoPanel -t "Daily limit setup" -m "$_dc_message"
    return 1
}

daily_call() (
    # MainUI's OSS audio shim interposes filesystem calls and breaks ledger I/O.
    # Keep it out of the supervisor; the runtime restores it only for the game.
    export KIDMODE_GAME_LD_PRELOAD="${LD_PRELOAD-}"
    TZ="$(cat "$sysdir/config/.tz" 2>/dev/null)" || TZ=''
    export LD_PRELOAD='' TZ
    exec "$kidui_bin" --allowance \
        "$backupdir/allowance" "${daily_profile:-$(active_kids_profile)}" "$@"
)

# A parent-selected profile is explicit. During boot/play, however, a corrupt
# or missing owner must not enroll a new default child with an unlimited mode.
daily_owner_valid() {
    [ -z "${daily_profile:-}" ] || return 0
    if [ ! -f "$active_kid_file" ]; then
        [ ! -f "$backupdir/allowance/state.v1" ] &&
            [ ! -f "$backupdir/allowance/previous.v1" ] &&
            [ "$(kid_count)" -eq 0 ] && [ -d "$legacy_kids_profile" ]
        return $?
    fi
    _do_owner=$(sed -n 1p "$active_kid_file")
    if [ -n "$_do_owner" ]; then
        valid_kid_name "$_do_owner" && [ -d "$kids_profile_prefix$_do_owner" ]
        return $?
    fi
    if [ -f "$backupdir/allowance/state.v1" ]; then
        [ -f "$legacy_kids_profile/.allowance-id" ] || return 1
    fi
    return 0
}

daily_unique_identity() {
    _du_profile=${daily_profile:-$(active_kids_profile)}
    [ -f "$_du_profile/.allowance-id" ] || return 0
    for _du_other in "$saves_dir/KidsProfile" "$saves_dir"/KidsProfile.*; do
        [ "$_du_other" != "$_du_profile" ] || continue
        [ -f "$_du_other/.allowance-id" ] || continue
        if cmp -s "$_du_profile/.allowance-id" "$_du_other/.allowance-id"; then
            log "Duplicate allowance identity: parent recovery required."
            return 1
        fi
    done
    return 0
}

# Validate the helper protocol before exposing any fields to shell arithmetic.
# Generation is opaque to the shell; the C mutation path checks its exact bound.
timer_uint() {
    case "$1" in ''|*[!0-9]*|0[0-9]*) return 1 ;; esac
    [ "${#1}" -le "$2" ]
}

daily_read() {
    daily_error=1; daily_remaining=0; daily_enabled=1; daily_minutes=0
    daily_uncertain=1; daily_generation=0; daily_used=0; daily_day=0
    daily_ui_status
    daily_owner_valid && daily_unique_identity && _daily_status=$(daily_call status) || return 1
    case "$_daily_status" in *[!0-9\ -]*) return 1 ;; esac
    # Only decimal digits, spaces and minus survive above: no glob expansion.
    # shellcheck disable=SC2086
    set -- $_daily_status
    [ "$#" -eq 7 ] || return 1
    case "$2:$4" in 0:0|0:1|1:0|1:1) ;; *) return 1 ;; esac
    timer_uint "$3" 3 && [ "$3" -le 120 ] && [ "$(( $3 % 5 ))" -eq 0 ] || return 1
    timer_uint "$5" 19 && timer_uint "$6" 5 && [ "$6" -le 93600 ] || return 1
    timer_uint "$7" 8 || return 1
    [ "$7" = 0 ] || { [ "$7" -ge 20200101 ] && [ "$7" -le 20991231 ]; } || return 1
    if [ "$2" = 0 ]; then
        [ "$1" = -1 ] || return 1
    else
        timer_uint "$1" 5 && [ "$1" -le 93600 ] || return 1
    fi
    daily_remaining=$1; daily_enabled=$2; daily_minutes=$3
    daily_uncertain=$4; daily_generation=$5; daily_used=$6; daily_day=$7; daily_error=0
    daily_ui_status
}

daily_ui_status() {
    printf '%s %s %s\n' "$daily_enabled" "$daily_error" "$daily_uncertain" > /tmp/kidmode_daily_status.new &&
        mv /tmp/kidmode_daily_status.new /tmp/kidmode_daily_status
}

daily_prepare() {
    daily_owner_valid || return 1
    # A pre-profile version can already be armed with the unnamed profile.
    # Record that unambiguous legacy owner before first ledger enrollment.
    if [ -z "${daily_profile:-}" ] && [ ! -f "$active_kid_file" ]; then
        set_active_kid "" || return 1
    fi
    mkdir -p "${daily_profile:-$(active_kids_profile)}" "$backupdir" || return 1
    daily_call enroll >/dev/null || return 1
    daily_read
}

daily_edit() {
    if [ "$1" = daily ]; then
        daily_read || return 1
        daily_clock_setup || return 1
        # First enrollment can predate RTC setup and contain Onion's emulated
        # future date. This authenticated opt-in adopts the detected clock via
        # the existing checked API; a backward correction preserves all usage.
        daily_read || return 1
        if [ "$daily_uncertain" = 1 ]; then
            daily_call confirm 0 "$daily_generation" || return 1
        fi
    fi
    if [ "$1" = confirm ] && [ ! -s "$sysdir/config/.tz" ]; then
        infoPanel -t "Kids Mode" -m "Set the local timezone in\nOnion's Clock app first." --auto
        return 1
    fi
    daily_read && daily_call "$1" "$2" "$daily_generation" && daily_read || {
        if [ "$1" = confirm ]; then
            infoPanel -t "Kids Mode" -m "Date could not be confirmed.\nCheck the date and timezone\nin Onion's Clock app, then retry." --auto
        else
            infoPanel -t "Kids Mode" -m "Allowance update did not finish.\nCheck remaining time before retrying.\nCheck the SD card and date." --auto
        fi
        return 1
    }
    update_remaining_now
}

timer_run_game() {
    daily_read || return 1
    if [ "$daily_enabled" = 0 ]; then
        # Publish before launching: failure must not start unmetered play.
        # The live launcher owns the marker until the foreground game returns.
        printf '%s\n' "$$" > "$session_game_file" || return 1
        TZ="$tz_value" sh "$sysdir/cmd_to_run.sh"
        _session_rc=$?
        rm -f "$session_game_file"
        return "$_session_rc"
    fi
    if [ "$daily_remaining" -le 0 ]; then
        infoPanel -t "Kids Mode" -m "Time's up for today.\nA parent can add bonus time." --auto
        return 1
    fi
    # The approved automatic-save contract is RetroArch only. Inspect the
    # generated command AND its launch script; a favorite cannot bypass this
    # gate through resume/start-over/core override paths.
    if ! grep -q './retroarch .* -L ' "$sysdir/cmd_to_run.sh" &&
        { [ ! -f "$run_launch" ] || ! grep -q './retroarch .* -L ' "$run_launch"; }; then
        infoPanel -t "Kids Mode" -m "Daily allowance needs a\nRetroArch game with auto-save." --auto
        return 1
    fi
    touch /tmp/kidmode_daily_game
    daily_call run "$sysdir/cmd_to_run.sh"
    _daily_rc=$?
    rm -f /tmp/kidmode_daily_game
    if [ "$_daily_rc" -ne 0 ]; then
        # The parent shell survives a failed supervisor. Stop a remaining
        # emulator before permitting another launch or a profile switch.
        save_quit_game
        while pgrep retroarch >/dev/null 2>&1; do
            infoPanel -t "Kids Mode" -m "Game did not close.\nSave completion is unconfirmed.\nPower off before switching profiles." --auto
            sleep 5
        done

        infoPanel -t "Kids Mode" -m "Game stopped with an error.\nSave completion is unconfirmed.\nCheck the SD card before playing." --auto
    fi
    return "$_daily_rc"
}

# Selection is temporary until the profile transaction commits. Subshell scope
# prevents an interrupted/cancelled picker leaking the selected child's ID.
timer_choose_for_child() (
    daily_profile=$(profile_path "$1") || exit 1
    daily_prepare || exit 1
    [ "$daily_enabled" = 1 ] || pick_session_timer
)

get_timer_minutes() {
    tm="$(config_get timer_minutes)"
    case "$tm" in
        '' | *[!0-9]*) echo 0 ;;
        *) echo "$tm" ;;
    esac
}

# Highest value the pickers offer, in minutes; must match TIMER_MAX in
# src/kidsMode/kidui.c
timer_max=120


# Read all three lines in one go, in the shell. This is called from the
# ticker every 10s and twice on the way to the launcher; three sed spawns
# each time is a real cost on this hardware.
state_read() {
    st_day=""
    st_used=0
    st_bonus=0
    [ -f "$timer_state" ] || return 0
    {
        IFS= read -r st_day || true
        IFS= read -r st_used || true
        IFS= read -r st_bonus || true
    } < "$timer_state" 2> /dev/null
    case "$st_used" in '' | *[!0-9]*) st_used=0 ;; esac
    case "$st_bonus" in '' | *[!0-9]*) st_bonus=0 ;; esac
    return 0
}

state_day() {
    state_read
    printf '%s\n' "$st_day"
}
state_used() {
    state_read
    printf '%s\n' "$st_used"
}
state_bonus() {
    state_read
    printf '%s\n' "$st_bonus"
}

state_write() { # $1 used, $2 bonus
    mkdir -p "$backupdir" || return 1
    printf '%s\n%s\n%s\n' "$(date +%Y-%m-%d)" "$1" "$2" > "$timer_state.tmp" || return 1
    mv -f "$timer_state.tmp" "$timer_state"
}

# Recompute and publish remaining seconds right now (clamped to >= 0;
# file absent = timer off). Called by the ticker and after menu changes.
# NB: the budget is per SESSION (set at arm / extended via Add play time);
# there is no daily reset — a new arm starts a fresh budget.
update_remaining_now() {
    if [ -f "$backupdir/allowance/state.v1" ] || [ -f "$backupdir/allowance/previous.v1" ] || [ -f "$(active_kids_profile)/.allowance-id" ]; then
        daily_read || { echo 0 > "$remaining_file"; return 1; }
        if [ "$daily_enabled" = 1 ]; then
            echo "$daily_remaining" > "$remaining_file"
            return 0
        fi
    fi
    budget=$(($(get_timer_minutes) * 60 + $(state_bonus)))
    if [ "$budget" -le 0 ]; then
        rm -f "$remaining_file"
        return 0
    fi
    rem=$((budget - $(state_used)))
    [ "$rem" -lt 0 ] && rem=0
    echo "$rem" > "$remaining_file"
    return 0
}

timer_remaining() {
    update_remaining_now
    if [ -f "$remaining_file" ]; then
        cat "$remaining_file"
    else
        echo -1 # timer off
    fi
}

add_bonus() {
    daily_read || return 1
    if [ "$daily_enabled" = 1 ]; then
        daily_edit bonus "$(( $1 / 60 ))"
        return $?
    fi
    state_write "$(state_used)" "$(($(state_bonus) + $1))"
    update_remaining_now
    log "Bonus play time added: $1 s"
}

set_timer_minutes() {
    config_merge --argjson m "$1" '.timer_minutes = $m' || return 1
    log "Session allowance set to $1 minutes."
}

# RetroArch redraws the framebuffer every frame, so imgpop overlays are not
# reliably visible inside games. Use RetroArch's own OSD instead (SHOW_MSG
# network command — same socket used for the graceful QUIT). Silently
# ignored by anything that isn't RetroArch.
notify_game() {
    sendUDP "SHOW_MSG $1" > /dev/null 2>&1 &
}

# RA's OSD messages last ~3 s; re-pushing the same text every ~2 s makes it
# render as one continuous message.
pin_message() {
    (
        for _i in 1 2 3 4 5; do
            sendUDP "SHOW_MSG $1" > /dev/null 2>&1
            sleep 2
        done
    ) &
}

game_is_running() {
    pgrep -f "cmd_to_run.sh" > /dev/null 2>&1
}

# Ask the running game to stop gracefully. RetroArch first (network QUIT →
# normal exit path → Onion auto-save state); escalate only if needed.
# Non-RetroArch games (ports, standalone) get a plain TERM — best effort.
save_quit_game() {
    notify_game "Time's up! Saving your game..."
    sleep 2
    if pgrep retroarch > /dev/null 2>&1; then
        sendUDP QUIT
        sleep 3
        if pgrep retroarch > /dev/null 2>&1; then
            sendUDP QUIT
            sleep 3
        fi
        if pgrep retroarch > /dev/null 2>&1; then
            killall -TERM retroarch 2> /dev/null
            sleep 2
        fi
    elif game_is_running; then
        pkill -TERM -f "cmd_to_run.sh" 2> /dev/null
        sleep 2
    fi
    log "Play time over; game stopped."
}

# Sample both ends of each interval. A game PID change, dark display or a
# long scheduling gap (Onion SIGSTOP sleep) must never debit menu/sleep time.
# Integer uptime gives at most one second of quantization per game boundary;
# incomplete intervals favor the child. Wall-clock/date changes are irrelevant.
session_sample() {
    _ss_uptime=''; _ss_idle=''; _ss_pid=''; _ss_light=0
    read -r _ss_uptime _ss_idle < /proc/uptime || return 1
    _ss_now=${_ss_uptime%%.*}
    case "$_ss_now" in ''|*[!0-9]*) return 1 ;; esac
    if [ -f "$session_game_file" ]; then
        read -r _ss_pid < "$session_game_file" || _ss_pid=''
    fi
    case "$_ss_pid" in ''|*[!0-9]*|0) _ss_pid='' ;; esac
    if [ -n "$_ss_pid" ]; then
        kill -0 "$_ss_pid" 2>/dev/null || _ss_pid=''
        read -r _ss_light < /sys/devices/soc0/soc/1f003400.pwm/pwm/pwmchip0/pwm0/duty_cycle || return 1
    fi
    session_interval "$_ss_now" "$_ss_pid" "$_ss_light"
}

session_interval() { # monotonic whole seconds, live game PID (or empty), brightness
    session_charge=0
    case "$3" in ''|*[!0-9]*) return 1 ;; esac
    _si_elapsed=$(( $1 - ${session_previous_time:-$1} ))
    if [ -n "$2" ] && [ "$2" = "${session_previous_game:-}" ] &&
       [ "$3" -gt 0 ] && [ "${session_previous_light:-0}" -gt 0 ] &&
       [ "$_si_elapsed" -gt 0 ] && [ "$_si_elapsed" -le 2 ]; then
        session_charge=$_si_elapsed
    fi
    session_previous_time=$1; session_previous_game=$2; session_previous_light=$3
}

# A parent starts a fresh one-off budget explicitly. Switching away from
# Daily does not erase its retained usage or change any other child's policy.
start_single_session() {
    # Prepare the one-off budget before disabling Daily. A failed write must
    # not turn a daily limit into unlimited play.
    if set_timer_minutes "$1" && state_write 0 0 && daily_edit off 0; then
        update_remaining_now
        return $?
    fi
    infoPanel -t "Play timer" -m "Session could not start.\nCheck the SD card and retry." --auto
    return 1
}

ticker_loop() {
    session_previous_time=''; session_previous_game=''; session_previous_light=0
    session_notice_tick=0; game_seen=0; last_notified_min=''
    idle_ticks=0
    while [ -f "$flagfile" ]; do
        sleep 1
        [ -f "$flagfile" ] || break
        [ -f /tmp/shutting_down ] && break

        session_charge=0
        if ! session_sample; then
            session_previous_game=''; session_previous_light=0
            # A missing observation cannot be charged as gameplay.
            session_charge=0
        fi
        [ -f /tmp/kidmode_daily_game ] && continue
        # Only the cheap monotonic/sleep observation needs one-second precision.
        # With no gameplay to debit, retain the original ten-second status rate.
        # Parent actions publish immediately; every game launch validates afresh.
        if [ "$session_charge" -eq 0 ]; then
            idle_ticks=$((idle_ticks + 1))
            [ "$idle_ticks" -ge 10 ] || continue
        fi
        idle_ticks=0
        if daily_read && [ "$daily_enabled" = 1 ]; then
            echo "$daily_remaining" > "$remaining_file"
            continue
        fi
        [ "$daily_error" = 0 ] || { echo 0 > "$remaining_file"; continue; }
        budget=$(($(get_timer_minutes) * 60 + $(state_bonus)))
        if [ "$budget" -le 0 ]; then
            rm -f "$remaining_file"
                    continue
        fi

        used=$(($(state_used) + session_charge))
        [ "$session_charge" -eq 0 ] || state_write "$used" "$(state_bonus)"
        rem=$((budget - used))
        [ "$rem" -lt 0 ] && rem=0
        echo "$rem" > "$remaining_file"

        if game_is_running; then
            session_notice_tick=$((session_notice_tick + 1))
            if [ "$game_seen" = 1 ] && [ "$rem" -gt 0 ] && [ "$session_notice_tick" -lt 10 ]; then
                continue
            fi
            session_notice_tick=0
            rem_min=$(((rem + 59) / 60))

            # Fresh game session: announce the budget once via RA's OSD
            if [ "$game_seen" != "1" ]; then
                game_seen=1
                [ "$rem" -gt 0 ] && notify_game "Play time: $rem_min minutes"
            fi

            # In-game countdown via RetroArch OSD only. (imgpop overlays are
            # erased by RA's per-frame redraw AND draw in panel-native
            # coordinates — rotated 180° from the viewed image — so they
            # only produce a brief flipped flash. Not used during games.)
            if [ "$rem" -gt 0 ]; then
                if [ "$rem_min" -le 5 ]; then
                    # Last 5 minutes: countdown stays pinned on screen
                    if [ "$rem_min" -eq 1 ]; then
                        pin_message "1 minute left!"
                    else
                        pin_message "$rem_min minutes left"
                    fi
                elif [ "$rem_min" != "$last_notified_min" ] &&
                    [ $((rem_min % 5)) -eq 0 ]; then
                    notify_game "$rem_min minutes left"
                fi
                last_notified_min="$rem_min"
            fi

            if [ "$rem" -le 0 ]; then
                save_quit_game
            fi
        else
            game_seen=0
            session_notice_tick=0
            last_notified_min=""
        fi
    done
    rm -f "$remaining_file"
}

start_ticker() {
    stop_ticker
    # Publish after stop_ticker removes the old file, before the UI can read it.
    # A new Daily session must not look unlimited until the first ten-second tick.
    update_remaining_now || return 1
    ticker_loop &
    echo $! > "$ticker_pid_file"
}

stop_ticker() {
    if [ -f "$ticker_pid_file" ]; then
        kill "$(cat "$ticker_pid_file")" 2> /dev/null
        rm -f "$ticker_pid_file"
    fi
    rm -f "$remaining_file"
}


enable_ra_network_cmds() {
    # Same patch runtime.sh applies before every game (Onion features rely
    # on RetroArch network commands, e.g. save-on-shutdown).
    if [ -x "$sysdir/script/patch_ra_cfg.sh" ]; then
        cat > /tmp/onion_ra_patch.cfg <<- EOM
network_cmd_enable = "true"
EOM
        if daily_read && [ "$daily_enabled" = 1 ]; then
            printf 'savestate_auto_save = "true"\n' >> /tmp/onion_ra_patch.cfg
        fi
        "$sysdir/script/patch_ra_cfg.sh" /tmp/onion_ra_patch.cfg
        rm -f /tmp/onion_ra_patch.cfg
    fi
}

# --------------------------- session timer picker --------------------------
# Shown right after arming: LEFT/RIGHT picks OFF / 5 / 10 / ... / 120 minutes
# (default OFF; must match TIMER_MAX in src/kidsMode/kidui.c). Selecting a
# value starts a fresh budget for this session.

pick_session_timer() {
    log "launcher: starting kidui (timer picker)"
    rm -f "$uiresult"
    "$kidui_bin" --pick-timer > "$uilog" 2>&1
    picker_rc=$?
    log_ui_timings

    # A picks the shown value, B means "no timer" — both come back as a
    # TIMER result. Anything else means kidui never got that far (crash,
    # missing libs), and arming on a launcher that won't start would leave
    # the device stuck, so bail out instead.
    if [ "$picker_rc" -ne 5 ] || [ "$(sed -n 1p "$uiresult")" != "TIMER" ]; then
        log_ui_failure "Timer picker returned nothing" "$picker_rc"
        rm -f "$uiresult"
        return 1
    fi

    picked="$(sed -n 2p "$uiresult")"
    case "$picked" in
        '' | *[!0-9]*) picked=0 ;;
    esac
    [ "$picked" -gt "$timer_max" ] && picked="$timer_max"
    rm -f "$uiresult"

    set_timer_minutes "$picked"
    state_write 0 0 # fresh budget for this session
    update_remaining_now
}
