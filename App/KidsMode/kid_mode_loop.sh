#!/bin/sh
# ---------------------------------------------------------------------------
# Kid Mode for Onion OS — arming, play loop, and unlock logic.
#
# The device is locked to a fullscreen favorites-only launcher (kidui).
# Exiting a game always returns to the launcher, never to MainUI.
#
# Usage:
#   kid_mode_loop.sh arm    arm Kid Mode (first run asks to set a PIN),
#                           then enter the loop; called by the Apps-tab app
#   kid_mode_loop.sh run    enter the loop if armed; called by the startup
#                           hook (.tmp_update/startup/kidmode_boot.sh)
#
# Mode flag: /mnt/SDCARD/.kidmode  (present = armed; delete it from a
# computer to force-disable Kid Mode)
#
# v2 HARDENING HOOK: while armed, a determined kid can still force-shutdown
# with a long power press (keymon handles power directly). To harden, patch
# src/keymon/keymon.c to ignore/limit power events while /mnt/SDCARD/.kidmode
# exists. Out of scope for v1 by design.
# ---------------------------------------------------------------------------

sysdir=/mnt/SDCARD/.tmp_update
miyoodir=/mnt/SDCARD/miyoo
appdir=/mnt/SDCARD/App/KidsMode

kidui_bin="$appdir/bin/kidui"
configfile="$appdir/kidmode.json"
flagfile=/mnt/SDCARD/.kidmode
favfile=/mnt/SDCARD/Roms/favourite.json
# Backups and state live OUTSIDE the app folder so that replacing
# App/KidsMode during an update can never delete them.
backupdir=/mnt/SDCARD/Saves/kidmode

racfg=/mnt/SDCARD/RetroArch/.retroarch/retroarch.cfg
rabackup="$backupdir/retroarch.cfg.backup"
legacy_rabackup="$appdir/retroarch.cfg.kidmode-backup"
keymapcfg=/mnt/SDCARD/.tmp_update/config/keymap.json
keymapbackup="$backupdir/keymap.json.backup"
keymapnone="$backupdir/keymap-was-absent"
blfscript=/mnt/SDCARD/.tmp_update/script/blue_light.sh
blfbackup="$backupdir/blue_light.sh.backup"
last_game_file="$backupdir/last_game.txt"
logfile=/mnt/SDCARD/.tmp_update/logs/kidmode.log

timer_state="$backupdir/timer_state.txt" # 3 lines: day / used seconds / bonus seconds
# The PIN also lives in kidmode.json inside the app folder, which an app
# update replaces. Keep a copy outside so updating while armed can't cause
# a lockout (see restore_pin_backup).
pin_backup="$backupdir/pin_backup.json"
remaining_file=/tmp/kidmode_remaining
ticker_pid_file=/tmp/kidmode_ticker.pid

# kidui reports results via this file, NOT stdout — the device's SDL/driver
# stack prints noise on stdout, which broke first-line parsing on hardware.
uiresult=/tmp/kidmode_ui_result
autoresume_result=/tmp/kidmode_autoresume_result
uilog=/tmp/kidmode_ui_log

export LD_LIBRARY_PATH="/lib:/config/lib:$miyoodir/lib:$sysdir/lib:$sysdir/lib/parasyte"
export PATH="$sysdir/bin:$PATH"

log() {
    mkdir -p "$(dirname "$logfile")"
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$logfile"
}

# --------------------------- PIN handling ----------------------------------

hash_string() {
    if command -v sha256sum > /dev/null 2>&1; then
        printf '%s' "$1" | sha256sum | awk '{print $1}'
    elif command -v openssl > /dev/null 2>&1; then
        printf '%s' "$1" | openssl dgst -sha256 2> /dev/null | awk '{print $NF}'
    else
        return 1
    fi
}

make_salt() {
    if [ -r /dev/urandom ]; then
        dd if=/dev/urandom bs=8 count=1 2> /dev/null | od -An -tx1 | tr -d ' \n'
    else
        printf '%s' "$(date +%s)$$"
    fi
}

config_get() {
    [ -f "$configfile" ] || return 1
    # NB: not `.[$k] // empty` — that would swallow boolean false
    jq -r --arg k "$1" \
        'if has($k) and .[$k] != null then (.[$k] | tostring) else empty end' \
        "$configfile" 2> /dev/null
}

is_4_digits() {
    case "$1" in
        [0-9][0-9][0-9][0-9]) return 0 ;;
        *) return 1 ;;
    esac
}

ensure_config() {
    if [ ! -f "$configfile" ] || ! jq -e . "$configfile" > /dev/null 2>&1; then
        if [ -f "$configfile" ]; then
            mkdir -p "$backupdir"
            cp "$configfile" "$backupdir/kidmode.json.broken" 2> /dev/null
            log "kidmode.json had invalid JSON; reset to defaults. Broken copy saved to $backupdir/kidmode.json.broken — check it for a missing/extra comma."
        fi
        printf '{\n    "pin_hash": "",\n    "pin_salt": "",\n    "pin_plain": ""\n}\n' > "$configfile"
    fi
}

config_merge() {
    # $1 = jq filter mutating the config; keeps all other keys intact
    ensure_config
    tmpcfg=/tmp/kidmode_config.$$
    jq "$@" "$configfile" > "$tmpcfg" && mv -f "$tmpcfg" "$configfile"
    sync
}

store_pin() {
    new_pin="$1"
    salt="$(make_salt)"
    hash="$(hash_string "${salt}${new_pin}" 2> /dev/null || true)"
    if [ -n "$hash" ]; then
        config_merge --arg h "$hash" --arg s "$salt" \
            '.pin_hash = $h | .pin_salt = $s | .pin_plain = ""'
    else
        # No hashing tool available — plaintext fallback (threat model: child)
        config_merge --arg p "$new_pin" \
            '.pin_hash = "" | .pin_salt = "" | .pin_plain = $p'
    fi
    backup_pin
    log "PIN updated."
}

# Snapshot the PIN fields outside the app folder, so replacing App/KidsMode
# (an update) while armed can't lose the PIN.
backup_pin() {
    [ -f "$configfile" ] || return 1
    mkdir -p "$backupdir"
    if jq '{pin_hash: (.pin_hash // ""), pin_salt: (.pin_salt // ""), pin_plain: (.pin_plain // "")}' \
        "$configfile" > "$pin_backup.tmp" 2> /dev/null; then
        mv -f "$pin_backup.tmp" "$pin_backup"
        sync
    else
        rm -f "$pin_backup.tmp"
        return 1
    fi
}

# The config has no PIN (fresh kidmode.json after an app update): bring it
# back from the snapshot in Saves/kidmode. Returns 0 if a PIN is on file
# afterwards.
restore_pin_backup() {
    [ -f "$pin_backup" ] || return 1
    bk_hash="$(jq -r '.pin_hash // ""' "$pin_backup" 2> /dev/null)"
    bk_salt="$(jq -r '.pin_salt // ""' "$pin_backup" 2> /dev/null)"
    bk_plain="$(jq -r '.pin_plain // ""' "$pin_backup" 2> /dev/null)"
    if [ -n "$bk_hash" ] || is_4_digits "$bk_plain"; then
        config_merge --arg h "$bk_hash" --arg s "$bk_salt" --arg p "$bk_plain" \
            '.pin_hash = $h | .pin_salt = $s | .pin_plain = $p'
        log "PIN restored from $pin_backup (app folder replaced?)."
        migrate_plain_pin
        has_pin
        return $?
    fi
    return 1
}

has_pin() {
    [ -n "$(config_get pin_hash)" ] && return 0
    is_4_digits "$(config_get pin_plain)"
}

# If the parent wrote a plaintext PIN into kidmode.json, hash it in place.
migrate_plain_pin() {
    plain="$(config_get pin_plain)"
    if is_4_digits "$plain"; then
        store_pin "$plain"
    fi
}

verify_pin() {
    entered="$1"
    is_4_digits "$entered" || return 1

    stored_plain="$(config_get pin_plain)"
    if is_4_digits "$stored_plain" && [ "$entered" = "$stored_plain" ]; then
        return 0
    fi

    stored_hash="$(config_get pin_hash)"
    stored_salt="$(config_get pin_salt)"
    if [ -n "$stored_hash" ]; then
        entered_hash="$(hash_string "${stored_salt}${entered}" 2> /dev/null || true)"
        [ -n "$entered_hash" ] && [ "$entered_hash" = "$stored_hash" ] && return 0
    fi

    return 1
}

run_pin_entry() {
    # $1 = title, $2 = optional notice shown under the PIN boxes;
    # echoes the PIN on success
    rm -f "$uiresult"
    if [ -n "$2" ]; then
        "$kidui_bin" --set-pin -t "$1" --notice "$2" > "$uilog" 2>&1
    else
        "$kidui_bin" --set-pin -t "$1" > "$uilog" 2>&1
    fi
    [ $? -eq 3 ] || return 1
    [ "$(sed -n 1p "$uiresult")" = "PIN" ] || return 1
    entered="$(sed -n 2p "$uiresult")"
    rm -f "$uiresult"
    is_4_digits "$entered" || return 1
    printf '%s\n' "$entered"
}

ensure_pin() {
    migrate_plain_pin
    has_pin || restore_pin_backup
    if has_pin; then
        [ -f "$pin_backup" ] || backup_pin
        return 0
    fi

    # First-time setup; a mismatch retries in place (B cancels)
    setup_notice=""
    while :; do
        pin1="$(run_pin_entry "Set Kids Mode PIN" "$setup_notice")" || return 1
        pin2="$(run_pin_entry "Confirm PIN")" || return 1
        if [ "$pin1" = "$pin2" ]; then
            store_pin "$pin1"
            return 0
        fi
        setup_notice="PINs did not match - try again"
    done
}

# ----------------------- RetroArch kiosk lock ------------------------------
# While armed, hide RetroArch's settings so the in-game menu can't be used to
# change cores, shaders, mappings, etc. Restored from backup on unlock.
# (Approach borrowed from OnionUI PR #1910.)
#
# Kiosk mode only hides settings — the menu itself and RetroArch's other
# in-game hotkeys still work, so a kid can still reach Quit/Load Content or
# scramble save-state slots by mashing combos. lock_ra_hotkeys() unbinds
# them; set "lock_retroarch_hotkeys": false in kidmode.json to keep stock
# RetroArch shortcuts while armed.

apply_ra_lock() {
    [ -f "$racfg" ] || return 0
    mkdir -p "$backupdir"
    if [ ! -f "$rabackup" ] && [ ! -f "$legacy_rabackup" ]; then
        cp "$racfg" "$rabackup"
    fi

    # Every setting below used to go through ra_set (one grep + one sed —
    # a full read+rewrite of retroarch.cfg — per call). With ~70 settings
    # that was up to 140 full passes over the file, adding a multi-second
    # stall between confirming the timer and reaching the carousel. This
    # applies all of them in a single awk pass instead: one read, one
    # write, regardless of how many settings there are.
    #
    #   kiosk_mode_enable true — locks down the in-game quick menu
    #   video_font_enable true — timer countdown arrives via RA's OSD
    #     (SHOW_MSG), so on-screen notifications must stay on
    #   quick_menu_show_* false — hide options/cheats/shaders/record/stream
    #     from the (already locked-down) quick menu
    #   settings_show_* false — hide every settings category
    #   input_*_btn nul — every documented RetroArch hotkey action,
    #     disabled. MENU is input_enable_hotkey_btn, held with another
    #     button: this covers MENU+SELECT (open RA's menu), MENU+L2/R2
    #     (save/load state), MENU+L/R (rewind/fast-forward), MENU+LEFT/
    #     RIGHT (save-slot change), MENU+START (fullscreen), and every
    #     other hotkey RetroArch documents — even ones not expected by
    #     default, so nothing is left reachable via MENU+<button>. The
    #     individual actions are cleared rather than input_enable_hotkey_btn
    #     itself, because unbinding the enable button would make each of
    #     these fire on a single un-combo'd press instead. MENU+VOLUME for
    #     brightness is handled outside RetroArch (by the system's button
    #     daemon) and is unaffected by any of this.
    ra_keys="kiosk_mode_enable video_font_enable quick_menu_show_options
        quick_menu_show_cheats quick_menu_show_shaders
        quick_menu_show_start_recording quick_menu_show_start_streaming
        settings_show_configuration settings_show_core
        settings_show_directory settings_show_drivers
        settings_show_file_browser settings_show_input
        settings_show_latency settings_show_network settings_show_recording
        settings_show_user settings_show_user_interface settings_show_video
        settings_show_audio"

    # The in-game hotkeys are the half a parent may want to keep: set
    # "lock_retroarch_hotkeys": false in kidmode.json to leave RetroArch's
    # own shortcuts alone (the kiosk settings above always apply).
    ra_hotkeys="input_menu_toggle_btn input_save_state_btn
        input_load_state_btn input_rewind_btn input_toggle_fast_forward_btn
        input_hold_fast_forward_btn input_state_slot_increase_btn
        input_state_slot_decrease_btn input_toggle_fullscreen_btn
        input_shader_toggle_btn input_shader_next_btn input_shader_prev_btn
        input_reset_btn input_screenshot_btn input_pause_toggle_btn
        input_frame_advance_btn input_cheat_toggle_btn
        input_movie_record_toggle_btn input_recording_toggle_btn
        input_streaming_toggle_btn input_netplay_game_watch_btn
        input_ai_service_btn input_audio_mute_btn
        input_cheat_index_minus_btn input_cheat_index_plus_btn
        input_close_content_btn input_desktop_menu_toggle_btn
        input_disk_eject_toggle_btn input_disk_next_btn input_disk_prev_btn
        input_exit_emulator_btn input_fps_toggle_btn
        input_game_focus_toggle_btn input_grab_mouse_toggle_btn
        input_hold_slowmotion_btn input_osk_toggle_btn
        input_overlay_next_btn input_preempt_toggle_btn
        input_runahead_toggle_btn input_send_debug_info_btn
        input_toggle_slowmotion_btn input_toggle_statistics_btn
        input_toggle_vrr_runloop_btn input_volume_up_btn
        input_volume_down_btn input_netplay_fade_chat_toggle_btn
        input_netplay_host_toggle_btn input_netplay_ping_toggle_btn
        input_netplay_player_chat_btn"

    if [ "$(config_get lock_retroarch_hotkeys)" != "false" ]; then
        ra_keys="$ra_keys $ra_hotkeys"
    fi

    tmpra=/tmp/kidmode_ra.$$
    awkprog=/tmp/kidmode_ra_awk.$$
    {
        echo 'BEGIN {'
        i=0
        for k in $ra_keys; do
            i=$((i + 1))
            case "$k" in
                kiosk_mode_enable | video_font_enable) v=true ;;
                quick_menu_show_* | settings_show_*) v=false ;;
                *) v=nul ;;
            esac
            printf '  key[%d]="%s"; val[%d]="%s";\n' "$i" "$k" "$i" "$v"
        done
        echo "  n=$i"
        echo '}'
        cat << 'AWKEOF'
{
    matched = 0
    for (i = 1; i <= n; i++) {
        if (!done[i] && $0 ~ ("^[ \t]*" key[i] "[ \t]*=")) {
            print key[i] " = \"" val[i] "\""
            done[i] = 1
            matched = 1
            break
        }
    }
    if (!matched) print $0
}
END {
    for (i = 1; i <= n; i++)
        if (!done[i]) print key[i] " = \"" val[i] "\""
}
AWKEOF
    } > "$awkprog"

    awk -f "$awkprog" "$racfg" > "$tmpra" && mv -f "$tmpra" "$racfg"
    rm -f "$awkprog"
    sync
    log "RetroArch kiosk lock applied (in-game hotkeys disabled), single pass."
}

restore_ra_lock() {
    if [ -f "$rabackup" ]; then
        cp "$rabackup" "$racfg"
        rm -f "$rabackup"
        sync
        log "RetroArch config restored."
    elif [ -f "$legacy_rabackup" ]; then
        cp "$legacy_rabackup" "$racfg"
        rm -f "$legacy_rabackup"
        sync
        log "RetroArch config restored (legacy backup)."
    fi
}

# ------------------------ Blue-light-filter lock ----------------------------
# MENU+B is a system-level shortcut (handled by keymon, outside RetroArch)
# that toggles the blue-light filter by calling this script with "enable" or
# "disable". While armed, we prepend a guard that makes those two calls a
# no-op, so the manual toggle does nothing. The scheduled auto on/off (if the
# person has that feature configured) is untouched, since it calls the
# enable/disable shell functions directly rather than going through this
# case dispatch. Original script restored byte-for-byte on unlock.

apply_blf_lock() {
    [ -f "$blfscript" ] || return 0
    mkdir -p "$backupdir"
    if ! grep -q "KIDMODE_BLF_GUARD" "$blfscript" 2> /dev/null; then
        [ -f "$blfbackup" ] || cp "$blfscript" "$blfbackup"
        tmpblf=/tmp/kidmode_blf.$$
        {
            printf '%s\n' "# KIDMODE_BLF_GUARD: while Kids Mode is armed, ignore the manual"
            printf '%s\n' "# MENU+B toggle (this script called with enable/disable) so a kid"
            printf '%s\n' "# can't turn the blue-light filter on/off mid-game."
            printf '%s\n' 'if [ -f /mnt/SDCARD/.kidmode ] && { [ "$1" = "enable" ] || [ "$1" = "disable" ]; }; then'
            printf '%s\n' '    exit 0'
            printf '%s\n' 'fi'
            cat "$blfscript"
        } > "$tmpblf"
        mv -f "$tmpblf" "$blfscript"
        chmod +x "$blfscript" 2> /dev/null
        sync
        log "MENU+B blue-light toggle disabled while armed."
    fi
}

restore_blf_lock() {
    if [ -f "$blfbackup" ]; then
        cp "$blfbackup" "$blfscript"
        rm -f "$blfbackup"
        chmod +x "$blfscript" 2> /dev/null
        sync
        log "blue_light.sh restored."
    fi
}

# ------------------------------ save profile --------------------------------
# Saves/CurrentProfile holds several DIFFERENT kinds of data mixed together:
# actual save files/save-states and GameSwitcher's thumbnail cache (personal,
# tied to who's playing) alongside config/ — RetroArch's per-core settings
# like aspect ratio, scanlines/shaders, CPU clock — and theme/, which are
# device-wide preferences, not personal data, and should stay exactly the
# same no matter who's playing.
#
# Onion's own Guest Mode swaps the WHOLE folder (MainProfile <->
# GuestProfile) since a guest is meant to get a fully separate setup. Kids
# Mode only wants the personal parts isolated — so we swap just the
# saves/states/romScreens subfolders individually, leaving config/, theme/,
# and lists/ untouched and shared throughout.
#
# The kid's own save progress should persist across sessions — so instead of
# a throwaway park each time, Kids Mode keeps its own permanent
# Saves/KidsProfile (holding just these three subfolders) that's swapped in
# at arm time and swapped back out (keeping whatever was added) at disarm,
# while whatever was there before (from Main or Guest — we don't need to
# know which) is parked untouched in between. A plain directory rename
# can't partially fail or leave mismatched data the way editing files in
# place could.
current_profile=/mnt/SDCARD/Saves/CurrentProfile
kids_profile=/mnt/SDCARD/Saves/KidsProfile
isolated_subdirs="saves states romScreens"

apply_profile_isolation() {
    mkdir -p "$kids_profile" "$current_profile" "$backupdir"
    for d in $isolated_subdirs; do
        rm -rf "$backupdir/profile-parked-$d"
        if [ -d "$current_profile/$d" ]; then
            mv "$current_profile/$d" "$backupdir/profile-parked-$d"
        fi
        if [ -d "$kids_profile/$d" ]; then
            mv "$kids_profile/$d" "$current_profile/$d"
        else
            mkdir -p "$current_profile/$d"
        fi
    done
    sync
    log "Switched to the kid's own saves/states/thumbnails for this session."
}

restore_profile_isolation() {
    mkdir -p "$kids_profile"
    for d in $isolated_subdirs; do
        rm -rf "$kids_profile/$d"
        if [ -d "$current_profile/$d" ]; then
            mv "$current_profile/$d" "$kids_profile/$d" # keep kid's progress for next time
        fi
        if [ -d "$backupdir/profile-parked-$d" ]; then
            mv "$backupdir/profile-parked-$d" "$current_profile/$d"
        fi
    done
    sync
    log "Restored the previous saves/states/thumbnails."
}

# ------------------------- MENU button override ----------------------------
# While armed, a single press of the MENU button in-game saves and exits
# straight back to the kid launcher (keymap ingame_single_press = 2,
# "exit to menu") instead of opening the GameSwitcher overlay, which could
# expose the parent's recent games. keymon reads keymap.json at startup, so
# it is restarted after the change. Original keymap restored on unlock.

apply_keymap_override() {
    mkdir -p "$backupdir"
    if [ -f "$keymapcfg" ]; then
        [ -f "$keymapbackup" ] || cp "$keymapcfg" "$keymapbackup"
        tmpkm=/tmp/kidmode_keymap.$$
        if jq '.ingame_single_press = 2' "$keymapcfg" > "$tmpkm" 2> /dev/null; then
            mv -f "$tmpkm" "$keymapcfg"
        else
            rm -f "$tmpkm"
        fi
    else
        touch "$keymapnone"
        printf '{\n    "ingame_single_press": 2\n}\n' > "$keymapcfg"
    fi
    sync
    killall keymon 2> /dev/null
    keymon &
    log "MENU button set to exit-to-launcher while armed."
}

restore_keymap_override() {
    keymap_restored=0
    if [ -f "$keymapnone" ]; then
        rm -f "$keymapcfg" "$keymapnone"
        keymap_restored=1
    elif [ -f "$keymapbackup" ]; then
        cp "$keymapbackup" "$keymapcfg"
        rm -f "$keymapbackup"
        keymap_restored=1
    fi
    if [ "$keymap_restored" = "1" ]; then
        sync
        killall keymon 2> /dev/null
        keymon &
        log "keymap.json restored."
    fi
}

# ------------------------------ play timer ---------------------------------
# Daily play budget in 5-minute steps (timer_minutes in kidmode.json;
# 0 = no timer). A background ticker counts *consumed* seconds — not wall
# clock — so sleeping the device pauses the timer and rebooting doesn't
# reset it (used/bonus persist in timer_state.txt, keyed to the day).
# The countdown shows inside games via RetroArch's OSD (see notify_game);
# at zero RetroArch gets a network QUIT, which triggers Onion's normal
# auto-save — the game resumes exactly there next launch.

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

# ------------------------- volume / brightness caps ------------------------
# Optional ceilings (percent, 10% steps) the kid can't exceed. kidui does the
# actual clamping (it can call setVolume / display_setBrightness and poke
# keymon); the shell just stores the ceiling and asks kidui to enforce it on
# change and on every ticker tick. Absent / 100 = no cap.

get_max_volume_pct() {
    v="$(config_get max_volume_pct)"
    case "$v" in
        '' | *[!0-9]*) echo 100 ;;
        *) [ "$v" -gt 100 ] && echo 100 || echo "$v" ;;
    esac
}

get_max_brightness_pct() {
    v="$(config_get max_brightness_pct)"
    case "$v" in
        '' | *[!0-9]*) echo 100 ;;
        *)
            [ "$v" -gt 100 ] && v=100
            [ "$v" -lt 10 ] && v=10 # never let the screen go fully dark
            echo "$v"
            ;;
    esac
}

# Enforce the ceilings now (no-ops when set to 100% / no cap, and when the
# live level is already at or below the ceiling).
enforce_caps() {
    [ -x "$kidui_bin" ] || return 0
    vcap="$(get_max_volume_pct)"
    [ "$vcap" -lt 100 ] && "$kidui_bin" --clamp-volume "$vcap" > /dev/null 2>&1
    bcap="$(get_max_brightness_pct)"
    [ "$bcap" -lt 100 ] && "$kidui_bin" --clamp-brightness "$bcap" > /dev/null 2>&1
    return 0
}

state_day() { sed -n 1p "$timer_state" 2> /dev/null; }
state_used() {
    v="$(sed -n 2p "$timer_state" 2> /dev/null)"
    case "$v" in '' | *[!0-9]*) echo 0 ;; *) echo "$v" ;; esac
}
state_bonus() {
    v="$(sed -n 3p "$timer_state" 2> /dev/null)"
    case "$v" in '' | *[!0-9]*) echo 0 ;; *) echo "$v" ;; esac
}

state_write() { # $1 used, $2 bonus
    mkdir -p "$backupdir"
    printf '%s\n%s\n%s\n' "$(date +%Y-%m-%d)" "$1" "$2" > "$timer_state.tmp"
    mv -f "$timer_state.tmp" "$timer_state"
}

# Recompute and publish remaining seconds right now (clamped to >= 0;
# file absent = timer off). Called by the ticker and after menu changes.
# NB: the budget is per SESSION (set at arm / extended via Add play time);
# there is no daily reset — a new arm starts a fresh budget.
update_remaining_now() {
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
    state_write "$(state_used)" "$(($(state_bonus) + $1))"
    update_remaining_now
    log "Bonus play time added: $1 s"
}

set_timer_minutes() {
    config_merge --argjson m "$1" '.timer_minutes = $m'
    update_remaining_now
    log "Timer set to $1 min/day."
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

ticker_loop() {
    prev_rem=999999
    while [ -f "$flagfile" ]; do
        sleep 10
        [ -f "$flagfile" ] || break
        [ -f /tmp/shutting_down ] && break

        # Re-assert the volume/brightness ceilings if the kid nudged past
        # them with the physical buttons (keymon owns those live).
        enforce_caps

        budget=$(($(get_timer_minutes) * 60 + $(state_bonus)))
        if [ "$budget" -le 0 ]; then
            rm -f "$remaining_file"
            prev_rem=999999
            continue
        fi

        used=$(($(state_used) + 10))
        state_write "$used" "$(state_bonus)"
        rem=$((budget - used))
        [ "$rem" -lt 0 ] && rem=0
        echo "$rem" > "$remaining_file"

        if game_is_running; then
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
            last_notified_min=""
        fi
        prev_rem=$rem
    done
    rm -f "$remaining_file"
}

start_ticker() {
    stop_ticker
    ticker_loop &
    echo $! > "$ticker_pid_file"
}

stop_ticker() {
    if [ -f "$ticker_pid_file" ]; then
        kill "$(cat "$ticker_pid_file")" 2> /dev/null
        rm -f "$ticker_pid_file"
    fi
    killall imgpop 2> /dev/null # remove any lingering chip overlay
    rm -f "$remaining_file"
}

# --------------------------- shutdown handling -----------------------------
# runtime.sh's main loop normally reacts to /tmp/.offOrder; while Kid Mode
# blocks that loop we must handle it ourselves or the device won't power off
# cleanly after keymon kills a game.

check_off_order() {
    [ -f /tmp/.offOrder ] || return 0
    touch /tmp/shutting_down
    for _off_script in "$sysdir"/checkoff/*.sh; do
        [ -f "$_off_script" ] && sh "$_off_script"
    done
    bootScreen "$1" &
    sleep 1
    shutdown
    sleep 60 # never reached; wait for poweroff
}

# ----------------------------- game launch ---------------------------------

start_audioserver_if_needed() {
    if ! pgrep audioserver > /dev/null 2>&1; then
        defvol=$(/customer/app/jsonval vol | awk '{ printf "%.0f\n", 48 * (log(1 + $1) / log(10)) - 60 }')
        "$miyoodir/app/audioserver" "$defvol" &
        sleep 0.5
    fi
}

set_resolution() {
    _res_x="${1%x*}"
    _res_y="${1#*x}"
    bootScreen clear
    fbset -g "$_res_x" "$_res_y" "$_res_x" $((_res_y * 2)) 32
    killall -SIGUSR1 batmon 2> /dev/null
    killall -SIGUSR1 keymon 2> /dev/null
}

enable_ra_network_cmds() {
    # Same patch runtime.sh applies before every game (Onion features rely
    # on RetroArch network commands, e.g. save-on-shutdown).
    if [ -x "$sysdir/script/patch_ra_cfg.sh" ]; then
        cat > /tmp/onion_ra_patch.cfg <<- EOM
network_cmd_enable = "true"
EOM
        "$sysdir/script/patch_ra_cfg.sh" /tmp/onion_ra_patch.cfg
        rm -f /tmp/onion_ra_patch.cfg
    fi
}

# "Start over": launch without loading the auto-save snapshot. Same
# mechanism Onion's runtime.sh uses for its reset-game flag. In-game saves
# (battery saves etc.) are untouched — only the resume snapshot is skipped.
reset_cfg=/tmp/kidmode_reset.cfg

strip_reset_appendconfig() { # $1 = emulator launch script
    [ -n "$1" ] && [ -w "$1" ] || return 0
    if grep -q "$reset_cfg" "$1" 2> /dev/null; then
        sed -i "s| --appendconfig \"$reset_cfg\"||g" "$1"
    fi
}

# Build $sysdir/cmd_to_run.sh for a favorite exactly like MainUI would,
# including the per-rom core override (.game_config/<rom>.cfg).
# $3 = "fresh" to start over instead of resuming.
build_game_cmd() {
    game_launch="$1"
    game_rompath="$2"
    game_fresh="${3:-}"

    if [ -f "$game_rompath" ]; then
        game_rompath="$(realpath "$game_rompath")"
    fi

    # Never leave a stale injection behind from an interrupted fresh launch
    strip_reset_appendconfig "$game_launch"

    if [ "$game_fresh" = "fresh" ]; then
        printf 'savestate_auto_load = "false"\nconfig_save_on_exit = "false"\n' > "$reset_cfg"
    fi

    echo "LD_PRELOAD=$miyoodir/lib/libpadsp.so \"$game_launch\" \"$game_rompath\"" > "$sysdir/cmd_to_run.sh"

    game_ext="$(basename "$game_rompath" | awk -F. '{print tolower($NF)}')"
    game_cfg="$(dirname "$game_rompath")/.game_config/$(basename "$game_rompath" ".$game_ext").cfg"

    game_direct=0
    if [ -f "$game_cfg" ] && [ -f "$game_launch" ] &&
        grep -q '.retroarch/cores' "$game_launch"; then
        game_core=$(grep "core\b" "$game_cfg" | awk '{split($0,a,"="); print a[2]}' | awk -F'"' '{print $2}' | tr -d '\n')
        if [ -n "$game_core" ] && [ -f "/mnt/SDCARD/RetroArch/.retroarch/cores/$game_core.so" ]; then
            if [ "$game_fresh" = "fresh" ]; then
                echo "LD_PRELOAD=$miyoodir/lib/libpadsp.so ./retroarch -v --appendconfig \"$reset_cfg\" -L \".retroarch/cores/$game_core.so\" \"$game_rompath\"" > "$sysdir/cmd_to_run.sh"
            else
                echo "LD_PRELOAD=$miyoodir/lib/libpadsp.so ./retroarch -v -L \".retroarch/cores/$game_core.so\" \"$game_rompath\"" > "$sysdir/cmd_to_run.sh"
            fi
            game_direct=1
        fi
    fi

    # Fresh launch through the emulator's launch script: inject the
    # appendconfig into the script like runtime.sh does (removed after)
    if [ "$game_fresh" = "fresh" ] && [ "$game_direct" -eq 0 ] &&
        [ -f "$game_launch" ] && grep -q './retroarch -v' "$game_launch"; then
        sed -i "s|./retroarch -v|& --appendconfig \"$reset_cfg\"|g" "$game_launch"
    fi

    # Escape dollar signs in rom filenames, like runtime.sh does
    if echo "$game_rompath" | grep -q '\$'; then
        sed -i 's/\$/\\$/g' "$sysdir/cmd_to_run.sh"
    fi

    chmod a+x "$sysdir/cmd_to_run.sh"
}

# Run whatever is in $sysdir/cmd_to_run.sh and clean up afterwards.
# Mirrors runtime.sh launch_game: audio, LOADING splash, 560p handling on the
# Miyoo Mini V4, playActivity tracking, and the post-game SAVING splash —
# so Onion auto-save/resume keeps working unchanged.
run_game_cmd() {
    [ -f "$sysdir/cmd_to_run.sh" ] || return 1

    run_cmd="$(cat "$sysdir/cmd_to_run.sh")"
    run_rompath="$(echo "$run_cmd" | awk '{ st = index($0,"\" \""); if (st) print substr($0,st+3,length($0)-st-3)}')"
    run_launch="$(echo "$run_cmd" | awk -F'"' '{print $2}')"

    tz_value="$(cat "$sysdir/config/.tz" 2> /dev/null)"

    start_audioserver_if_needed
    enable_ra_network_cmds

    # Miyoo Mini V4 (752x560): switch resolution if this system supports it
    changed_res=0
    fullres_path="$(dirname "$run_launch")/full_resolution"
    if [ -f /tmp/new_res_available ] && [ -f "$fullres_path" ]; then
        set_resolution "$(cat /tmp/screen_resolution 2> /dev/null || echo 752x560)"
        changed_res=1
    elif [ ! -f /tmp/new_res_available ]; then
        infoPanel --message "LOADING" --persistent --romscreen &
        touch /tmp/dismiss_info_panel
        sync
    fi

    [ -n "$run_rompath" ] && playActivity start "$run_rompath"

    log "launching: $run_cmd"
    cd /mnt/SDCARD/RetroArch || cd "$appdir"
    TZ="$tz_value" sh "$sysdir/cmd_to_run.sh"
    run_retval=$?
    log "game exited with $run_retval"

    if [ "$changed_res" -eq 1 ]; then
        set_resolution "640x480"
    fi

    if [ ! -f /tmp/.offOrder ] && [ -f /tmp/.displaySavingMessage ]; then
        rm -f /tmp/.displaySavingMessage
        infoPanel --message "SAVING" --persistent --romscreen &
        touch /tmp/dismiss_info_panel
        sync
    fi

    [ -n "$run_rompath" ] && playActivity stop "$run_rompath"

    # Remove any fresh-launch injection from the emulator's launch script
    strip_reset_appendconfig "$run_launch"
    rm -f "$reset_cfg"

    rm -f "$sysdir/cmd_to_run.sh"
    cd "$appdir" 2> /dev/null

    check_off_order "End_Save"
    return 0
}

is_game_cmd() {
    grep -q "retroarch/cores\|/../../Roms/\|/mnt/SDCARD/Roms/" "$1" 2> /dev/null
}

# --------------------------- boot hook install -----------------------------
# The startup hook ships inside the app folder and is (re)installed on every
# arm, so installing Kid Mode is just copying App/KidsMode onto the card —
# no manual edits inside the hidden .tmp_update folder.

hook_src="$appdir/kidmode_boot.sh"
hook_dst="$sysdir/startup/kidmode_boot.sh"

install_hook() {
    [ -f "$hook_src" ] || return 1
    mkdir -p "$sysdir/startup"
    if ! cmp -s "$hook_src" "$hook_dst" 2> /dev/null; then
        cp "$hook_src" "$hook_dst"
        sync
        log "Boot hook installed to $hook_dst"
    fi
    return 0
}

# ------------------------ MainUI favorites shortcut ------------------------
# Adds a "Kid Mode" entry to Onion's Favorites tab (usually the boot tab),
# so arming is one tap without visiting Apps. kidui filters this entry out
# of the kid carousel. Disable with "fav_shortcut": false in kidmode.json.

fav_entry='{"label":"Kids Mode","launch":"/mnt/SDCARD/App/KidsMode/launch.sh","type":5,"imgpath":"/mnt/SDCARD/Icons/Default/app/guest_on.png","rompath":"/mnt/SDCARD/App/KidsMode/launch.sh"}'

# An earlier version appended the shortcut without checking that the file
# ended in a newline, which could glue two JSON entries onto one line and
# corrupt the favorites list (breaking MainUI search results too). Split
# any glued lines back apart.
repair_favourites() {
    [ -f "$favfile" ] || return 0
    if grep -q '}{' "$favfile"; then
        awk '{gsub(/\}\{/, "}\n{"); print}' "$favfile" > "$favfile.tmp" &&
            mv -f "$favfile.tmp" "$favfile"
        sync
        log "Repaired glued lines in favourite.json."
    fi
}

ensure_fav_shortcut() {
    repair_favourites

    # Default OFF: the entry confused MainUI's search results on some
    # setups. Opt in with "fav_shortcut": true in kidmode.json.
    if [ "$(config_get fav_shortcut)" != "true" ]; then
        if grep -qF "/App/KidsMode/launch.sh" "$favfile" 2> /dev/null; then
            grep -vF "/App/KidsMode/launch.sh" "$favfile" > "$favfile.tmp" &&
                mv -f "$favfile.tmp" "$favfile"
            sync
            log "Removed Kid Mode shortcut from favorites."
        fi
        return 0
    fi

    if ! grep -qF "/App/KidsMode/launch.sh" "$favfile" 2> /dev/null; then
        # Never append onto a final line that lacks its newline
        if [ -s "$favfile" ] && [ -n "$(tail -c 1 "$favfile")" ]; then
            echo >> "$favfile"
        fi
        printf '%s\n' "$fav_entry" >> "$favfile"
        sync
        log "Added Kid Mode shortcut to favorites."
    fi
}

# --------------------------- session timer picker --------------------------
# Shown right after arming: LEFT/RIGHT picks OFF / 5 / 10 / ... / 120 minutes
# (default OFF; must match TIMER_MAX in src/kidsMode/kidui.c). Selecting a
# value starts a fresh budget for this session.

pick_session_timer() {
    rm -f "$uiresult"
    "$kidui_bin" --pick-timer > "$uilog" 2>&1
    picker_rc=$?

    picked=0
    if [ "$picker_rc" -eq 5 ] && [ "$(sed -n 1p "$uiresult")" = "TIMER" ]; then
        picked="$(sed -n 2p "$uiresult")"
        case "$picked" in
            '' | *[!0-9]*) picked=0 ;;
        esac
        [ "$picked" -gt "$timer_max" ] && picked="$timer_max"
    fi
    rm -f "$uiresult"

    set_timer_minutes "$picked"
    state_write 0 0 # fresh budget for this session
    update_remaining_now
}

# -------------------------------- change PIN -------------------------------
# Set a new PIN from inside the parent menu (the parent already unlocked, so
# no need to re-verify the old one). A mismatch retries in place; B cancels.

change_pin() {
    cp_notice=""
    while :; do
        cp1="$(run_pin_entry "Set new PIN" "$cp_notice")" || return 1
        cp2="$(run_pin_entry "Confirm new PIN")" || return 1
        if [ "$cp1" = "$cp2" ]; then
            store_pin "$cp1"
            infoPanel -t "Kids Mode" -m "PIN updated." --auto
            return 0
        fi
        cp_notice="PINs did not match - try again"
    done
}

# ------------------------------ parent menu --------------------------------
# Shown after a correct PIN: exit Kids Mode, add/turn off play time, set the
# max volume/brightness ceilings, flip auto-resume, or change the PIN. Value
# rows report the chosen value on line 3 of the result; the auto-resume
# toggle is reported separately (see below). Returns 0 = unlock requested,
# 1 = stay in Kid Mode.

parent_menu() {
    while :; do
        rm -f "$uiresult" "$autoresume_result"
        ar_val=0
        [ "$(config_get auto_resume_last_game)" = "true" ] && ar_val=1
        "$kidui_bin" --parent-menu \
            --remaining "$(timer_remaining)" \
            --maxvol "$(get_max_volume_pct)" \
            --maxbright "$(get_max_brightness_pct)" \
            --autoresume "$ar_val" > "$uilog" 2>&1
        menu_rc=$?

        # The toggle is written the instant the parent flips it (not
        # deferred to some specific exit action), so sync it into
        # kidmode.json regardless of how the menu was left — Back, B, or
        # any other action below.
        if [ -f "$autoresume_result" ]; then
            new_ar_val="$(sed -n 1p "$autoresume_result")"
            rm -f "$autoresume_result"
            case "$new_ar_val" in
                1)
                    config_merge '.auto_resume_last_game = true'
                    log "Auto-resume last game turned ON from the parent menu."
                    ;;
                0)
                    config_merge '.auto_resume_last_game = false'
                    log "Auto-resume last game turned OFF from the parent menu."
                    ;;
            esac
        fi

        if [ "$menu_rc" -ne 5 ] || [ "$(sed -n 1p "$uiresult")" != "MENU" ]; then
            rm -f "$uiresult"
            return 1
        fi

        menu_action="$(sed -n 2p "$uiresult")"
        menu_arg="$(sed -n 3p "$uiresult")"
        rm -f "$uiresult"
        case "$menu_action" in
            UNLOCK)
                return 0
                ;;
            NOTIMER)
                # Turn the play timer off entirely: clear the configured
                # minutes AND any bonus, so nothing keeps a budget alive.
                # The kid can play with no limit until re-armed or time is
                # added again.
                set_timer_minutes 0
                state_write 0 0
                update_remaining_now
                log "Play timer turned off from the parent menu."
                return 1
                ;;
            VOLUME)
                # Store the new volume ceiling and enforce it now. Stay in
                # the menu so the parent can tweak more settings.
                case "$menu_arg" in
                    '' | *[!0-9]*) ;;
                    *)
                        [ "$menu_arg" -gt 100 ] && menu_arg=100
                        config_merge --argjson v "$menu_arg" '.max_volume_pct = $v'
                        [ "$menu_arg" -lt 100 ] &&
                            "$kidui_bin" --clamp-volume "$menu_arg" > /dev/null 2>&1
                        log "Max volume set to ${menu_arg}%."
                        ;;
                esac
                ;;
            BRIGHTNESS)
                case "$menu_arg" in
                    '' | *[!0-9]*) ;;
                    *)
                        [ "$menu_arg" -gt 100 ] && menu_arg=100
                        [ "$menu_arg" -lt 10 ] && menu_arg=10
                        config_merge --argjson v "$menu_arg" '.max_brightness_pct = $v'
                        [ "$menu_arg" -lt 100 ] &&
                            "$kidui_bin" --clamp-brightness "$menu_arg" > /dev/null 2>&1
                        log "Max brightness set to ${menu_arg}%."
                        ;;
                esac
                ;;
            CHANGEPIN)
                change_pin
                # Stay in the menu regardless of outcome
                ;;
            ADDTIME)
                case "$menu_arg" in
                    '' | *[!0-9]*)
                        # Older kidui without the inline selector: fall back
                        # to the separate picker screen; B cancels
                        rm -f "$uiresult"
                        "$kidui_bin" --pick-timer --no-off -t "Add play time" > "$uilog" 2>&1
                        if [ $? -eq 5 ] && [ "$(sed -n 1p "$uiresult")" = "TIMER" ]; then
                            menu_arg="$(sed -n 2p "$uiresult")"
                        else
                            menu_arg=""
                        fi
                        rm -f "$uiresult"
                        ;;
                esac
                case "$menu_arg" in
                    '' | *[!0-9]* | 0) ;; # canceled: back to the parent menu
                    *)
                        [ "$menu_arg" -gt "$timer_max" ] && menu_arg="$timer_max"
                        add_bonus $((menu_arg * 60))
                        # Straight back to the kid so they can play (the menu
                        # already previewed the new remaining time)
                        return 1
                        ;;
                esac
                ;;
        esac
    done
}

# ------------------------------ unlock -------------------------------------

disarm() {
    rm -f "$flagfile"
    stop_ticker
    restore_ra_lock
    restore_blf_lock
    restore_profile_isolation
    restore_keymap_override
    ensure_fav_shortcut
    rm -f "$sysdir/cmd_to_run.sh" "$uiresult"
    sync
    log "Kid Mode disarmed."
    infoPanel -t "Kids Mode" -m "Unlocked!\nReturning to Onion." --auto
    # Reset the framebuffer (page/pan) so the relaunched MainUI is actually
    # visible — without this the screen can stay on our last-flipped page.
    bootScreen clear 2> /dev/null
}

# ------------------------------ main loop ----------------------------------

cmd_run() {
    if [ ! -f "$kidui_bin" ]; then
        log "kidui binary missing; disarming."
        rm -f "$flagfile"
        sync
        return 1
    fi
    chmod a+x "$kidui_bin" 2> /dev/null

    ui_fails=0
    pin_fails=0
    pin_notice=""
    update_remaining_now

    # Existing installs from before the PIN snapshot existed: take one now,
    # so the next app update can't lose the PIN either
    if has_pin && [ ! -f "$pin_backup" ]; then
        backup_pin
    fi

    # Apply any stored volume/brightness ceilings right away (the ticker
    # keeps re-asserting them thereafter)
    enforce_caps

    start_ticker

    # A game left in cmd_to_run.sh means the device powered off mid-game:
    # relaunch it first so RetroArch auto-resume works like stock Onion.
    if [ -f "$sysdir/cmd_to_run.sh" ] && is_game_cmd "$sysdir/cmd_to_run.sh"; then
        if [ "$(timer_remaining)" = "0" ]; then
            rm -f "$sysdir/cmd_to_run.sh"
        else
            log "resuming interrupted game"
            run_game_cmd
        fi
    elif [ "$(config_get auto_resume_last_game)" = "true" ] &&
        [ -f "$last_game_file" ] && [ "$(timer_remaining)" != "0" ]; then
        # Opt in with "auto_resume_last_game": true in kidmode.json: skip
        # the carousel on boot and go straight back into the last game the
        # child played, like stock Onion's own auto-resume.
        lg_launch="$(sed -n 1p "$last_game_file")"
        lg_rompath="$(sed -n 2p "$last_game_file")"
        if [ -n "$lg_launch" ] && [ -f "$lg_launch" ] && [ -f "$lg_rompath" ]; then
            log "auto-resuming last game: $lg_rompath"
            build_game_cmd "$lg_launch" "$lg_rompath"
            run_game_cmd
        else
            log "auto_resume_last_game set but last game no longer exists; showing carousel."
            rm -f "$last_game_file"
        fi
    fi

    while [ -f "$flagfile" ]; do
        check_off_order "End"

        # Defensive cleanup: nothing may divert the loop into GameSwitcher
        rm -f "$sysdir/.runGameSwitcher" 2> /dev/null
        pgrep keymon > /dev/null 2>&1 || keymon &

        # No PIN on file (armed, but the app folder was replaced and no
        # snapshot existed): the unlock gesture sets a NEW pin instead of
        # rejecting everything — never lock the parent out.
        no_pin_recovery=0
        if ! has_pin; then
            no_pin_recovery=1
        fi

        rm -f "$uiresult"
        select_rompath=""
        [ -f "$last_game_file" ] && select_rompath="$(sed -n 2p "$last_game_file")"
        if [ "$no_pin_recovery" = "1" ] && [ -n "$pin_notice" ]; then
            "$kidui_bin" -t "Set a new PIN" --start-pin --notice "$pin_notice" > "$uilog" 2>&1
        elif [ "$no_pin_recovery" = "1" ]; then
            "$kidui_bin" -t "Set a new PIN" > "$uilog" 2>&1
        elif [ -n "$pin_notice" ]; then
            # Wrong PIN last time: reopen straight on the PIN screen so the
            # parent can try again in place
            "$kidui_bin" --start-pin --notice "$pin_notice" > "$uilog" 2>&1
        elif [ -n "$select_rompath" ]; then
            "$kidui_bin" --select "$select_rompath" > "$uilog" 2>&1
        else
            "$kidui_bin" > "$uilog" 2>&1
        fi
        ui_rc=$?
        pin_notice=""

        check_off_order "End"

        case "$ui_rc" in
            0) # game selected
                sel_verb="$(sed -n 1p "$uiresult")"
                case "$sel_verb" in
                    LAUNCH | LAUNCH_FRESH) ;;
                    *) continue ;;
                esac
                sel_launch="$(sed -n 2p "$uiresult")"
                sel_rompath="$(sed -n 3p "$uiresult")"
                [ -f "$sel_rompath" ] || continue

                sel_rem="$(timer_remaining)"
                [ "$sel_rem" = "0" ] && continue # out of time; kidui shows it

                if [ "$sel_verb" = "LAUNCH_FRESH" ]; then
                    build_game_cmd "$sel_launch" "$sel_rompath" fresh
                else
                    build_game_cmd "$sel_launch" "$sel_rompath"
                fi
                # Remember this as "the last game" (plain resume form, not
                # the fresh-start variant) so a future boot can auto-resume
                # it if auto_resume_last_game is enabled.
                mkdir -p "$backupdir"
                printf '%s\n%s\n' "$sel_launch" "$sel_rompath" > "$last_game_file"
                run_game_cmd
                ui_fails=0
                ;;
            7) # "Time's up!" screen sat idle for 5 minutes: power off
                # cleanly so the battery isn't drained (same path keymon's
                # power button takes — checkoff scripts, save splash, off).
                log "Times-up screen idle; powering off."
                touch /tmp/.offOrder
                check_off_order "End"
                ;;
            3) # PIN entered
                [ "$(sed -n 1p "$uiresult")" = "PIN" ] || continue
                entered_pin="$(sed -n 2p "$uiresult")"
                rm -f "$uiresult"
                is_4_digits "$entered_pin" || continue

                if [ "$no_pin_recovery" = "1" ]; then
                    # The PIN just entered becomes the new PIN (after a
                    # confirm step)
                    confirm_pin="$(run_pin_entry "Confirm new PIN")"
                    if [ -n "$confirm_pin" ] && [ "$confirm_pin" = "$entered_pin" ]; then
                        store_pin "$entered_pin"
                        pin_fails=0
                        if parent_menu; then
                            disarm
                            return 0
                        fi
                    elif [ -n "$confirm_pin" ]; then
                        pin_notice="PINs did not match - try again"
                    fi
                elif verify_pin "$entered_pin"; then
                    pin_fails=0
                    if parent_menu; then
                        disarm
                        return 0
                    fi
                else
                    pin_fails=$((pin_fails + 1))
                    log "Wrong PIN attempt ($pin_fails)."
                    sleep 1 # slow down guessing
                    if [ "$pin_fails" -ge 3 ]; then
                        pin_notice="Wrong PIN - to reset it, see the README"
                    else
                        pin_notice="Wrong PIN - try again"
                    fi
                fi
                ;;
            *) # UI crashed or won't start
                ui_fails=$((ui_fails + 1))
                log "kidui exited with unexpected code $ui_rc (fail $ui_fails/3)"
                if [ "$ui_fails" -ge 3 ]; then
                    # Fail open: a broken Kid Mode must never brick the
                    # device. Parent can re-arm after fixing the SD card.
                    infoPanel -t "Kids Mode" -m "Kids Mode UI failed.\nReturning to normal Onion." --auto
                    disarm
                    return 1
                fi
                sleep 1
                ;;
        esac
    done

    # Flag removed externally (e.g. deleted from a computer) — clean up
    stop_ticker
    restore_ra_lock
    restore_blf_lock
    restore_profile_isolation
    restore_keymap_override
    rm -f "$sysdir/cmd_to_run.sh"
    bootScreen clear 2> /dev/null
    return 0
}

cmd_arm() {
    if [ ! -f "$kidui_bin" ]; then
        infoPanel -t "Kids Mode" -m "kidui binary is missing.\nReinstall the KidsMode app." --auto
        return 1
    fi

    fav_count=0
    [ -f "$favfile" ] && fav_count=$(grep -c "rompath" "$favfile" 2> /dev/null)
    if [ "$fav_count" -eq 0 ]; then
        infoPanel -t "Kids Mode" -m "No favorites found.\nAdd some favorites first,\nthen arm Kids Mode." --auto
        return 1
    fi

    if ! install_hook; then
        infoPanel -t "Kids Mode" -m "kidmode_boot.sh is missing.\nReinstall the KidsMode app." --auto
        return 1
    fi

    if ! ensure_pin; then
        infoPanel -t "Kids Mode" -m "PIN setup canceled.\nKids Mode was NOT armed." --auto
        return 1
    fi

    pick_session_timer

    apply_ra_lock
    apply_blf_lock
    apply_profile_isolation
    apply_keymap_override
    ensure_fav_shortcut
    touch "$flagfile"
    sync
    log "Kid Mode armed (timer: $(get_timer_minutes) min)."

    cmd_run
}

case "${1:-run}" in
    arm)
        cmd_arm
        ;;
    run)
        [ -f "$flagfile" ] || exit 0
        migrate_plain_pin
        # App updated while armed? kidmode.json ships blank — bring the PIN
        # back from the snapshot in Saves/kidmode
        has_pin || restore_pin_backup
        cmd_run
        ;;
    *)
        echo "Usage: kid_mode_loop.sh [arm|run]" >&2
        exit 1
        ;;
esac
