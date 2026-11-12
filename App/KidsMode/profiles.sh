#!/bin/sh
# Globals and callbacks are supplied by kid_mode_loop.sh / the test fixture.
# shellcheck disable=SC2154,SC2034
# Recoverable save-folder transactions. Never overwrite a destination: if the
# layout is ambiguous, leave every byte in place and require parent recovery.
# Journal progress is flushed before the next rename reuses a path. Replaying
# the current step is safe even after power loss between rename and checkpoint.

profile_path() {
    case "$1" in
        '') printf '%s\n' "$legacy_kids_profile" ;;
        *) valid_kid_name "$1" || return 1
           printf '%s\n' "$kids_profile_prefix$1" ;;
    esac
}

profile_boundary() { :; } # tests replace this with a power-cut injector

profile_write_journal() {
    mkdir -p "$backupdir" || return 1
    printf '1\n%s\n%s\n%s\n%s\n' "$pt_mode" "$pt_from" "$pt_to" "$pt_step" > "$backupdir/profile.txn.new" || return 1
    cksum < "$backupdir/profile.txn.new" > "$backupdir/profile.txn.new.check" || return 1
    cat "$backupdir/profile.txn.new.check" >> "$backupdir/profile.txn.new" || return 1
    rm -f "$backupdir/profile.txn.new.check"
    sync
    mv -f "$backupdir/profile.txn.new" "$backupdir/profile.txn" || return 1
    sync
    profile_boundary journal
}

profile_move() {
    # No symlinks, merging, recursive deletion, or mv's "move inside folder"
    # interpretation. A missing source and present destination is a replay.
    [ ! -L "$1" ] && [ ! -L "$2" ] || return 1
    if [ -d "$1" ] && [ ! -e "$2" ]; then
        mv "$1" "$2" || return 1
        sync
        profile_boundary rename
    elif [ ! -e "$1" ] && [ -d "$2" ]; then
        :
    else
        log "Profile recovery stopped: conflicting or missing directory."
        return 1
    fi
}

profile_resume() {
    [ -e "$backupdir/profile.txn" ] || return 0
    [ ! -L "$backupdir/profile.txn" ] || return 1
    [ "$(wc -c < "$backupdir/profile.txn")" -le 128 ] || return 1
    [ "$(wc -l < "$backupdir/profile.txn")" -eq 6 ] || return 1
    [ "$(sed -n 1p "$backupdir/profile.txn")" = 1 ] || return 1
    [ "$(head -n 5 "$backupdir/profile.txn" | cksum)" = "$(sed -n 6p "$backupdir/profile.txn")" ] || return 1
    pt_mode=$(sed -n 2p "$backupdir/profile.txn")
    pt_from=$(sed -n 3p "$backupdir/profile.txn")
    pt_to=$(sed -n 4p "$backupdir/profile.txn")
    pt_step=$(sed -n 5p "$backupdir/profile.txn")
    case "$pt_mode" in arm|disarm|switch|adopt|rename) ;; *) return 1 ;; esac
    case "$pt_step" in 0|1|2|3|4|5|6) ;; *) return 1 ;; esac
    pt_old=$(profile_path "$pt_from") || return 1
    pt_new=$(profile_path "$pt_to") || return 1
    if [ "$pt_mode" = adopt ] || [ "$pt_mode" = rename ]; then
        [ "$pt_old" != "$pt_new" ] || return 1
        if [ "$pt_step" -eq 0 ]; then
            profile_move "$pt_old" "$pt_new" || return 1
            pt_step=6; profile_write_journal || return 1
        fi
        [ "$pt_step" -eq 6 ] || return 1
    fi
    pt_i=0
    for pt_dir in $isolated_subdirs; do
        [ "$pt_mode" != adopt ] && [ "$pt_mode" != rename ] || break
        case "$pt_mode" in
            arm) pt_src1="$current_profile/$pt_dir"; pt_dst1="$backupdir/profile-parked-$pt_dir"
                 pt_src2="$pt_new/$pt_dir"; pt_dst2="$current_profile/$pt_dir" ;;
            disarm) pt_src1="$current_profile/$pt_dir"; pt_dst1="$pt_old/$pt_dir"
                    pt_src2="$backupdir/profile-parked-$pt_dir"; pt_dst2="$current_profile/$pt_dir" ;;
            switch) pt_src1="$current_profile/$pt_dir"; pt_dst1="$pt_old/$pt_dir"
                    pt_src2="$pt_new/$pt_dir"; pt_dst2="$current_profile/$pt_dir" ;;
        esac
        if [ "$pt_step" -eq "$pt_i" ]; then
            profile_move "$pt_src1" "$pt_dst1" || return 1
            pt_step=$((pt_step + 1)); profile_write_journal || return 1
        fi
        pt_i=$((pt_i + 1))
        if [ "$pt_step" -eq "$pt_i" ]; then
            profile_move "$pt_src2" "$pt_dst2" || return 1
            pt_step=$((pt_step + 1)); profile_write_journal || return 1
        fi
        pt_i=$((pt_i + 1))
    done
    if [ "$pt_mode" = disarm ]; then
        rm -f "$flagfile" || return 1
    elif [ "$pt_mode" != rename ]; then
        set_active_kid "$pt_to" || return 1
        profile_boundary owner
        touch "$flagfile" || return 1
    fi
    sync
    profile_boundary commit
    rm -f "$backupdir/profile.txn" || return 1
    sync
}

profile_begin() {
    profile_resume || return 1
    pt_mode=$1; pt_from=$2; pt_to=$3; pt_step=0
    pt_old=$(profile_path "$pt_from") || return 1
    pt_new=$(profile_path "$pt_to") || return 1
    [ "$pt_mode" != switch ] || [ "$pt_old" != "$pt_new" ] || return 1
    for pt_root in "$current_profile" "$backupdir" "$pt_old" "$pt_new"; do
        [ ! -L "$pt_root" ] || return 1
    done
    mkdir -p "$current_profile" "$backupdir" "$pt_old" "$pt_new" || return 1
    # Validate the complete layout before the first destructive rename. Empty
    # directories for a new profile are safe to create before journaling.
    for pt_dir in $isolated_subdirs; do
        case "$pt_mode" in
            arm)
                [ ! -e "$backupdir/profile-parked-$pt_dir" ] || return 1
                mkdir -p "$current_profile/$pt_dir" "$pt_new/$pt_dir" || return 1 ;;
            switch|disarm)
                [ -d "$backupdir/profile-parked-$pt_dir" ] || return 1
                [ -d "$current_profile/$pt_dir" ] || return 1
                [ ! -e "$pt_old/$pt_dir" ] || return 1
                if [ "$pt_mode" = switch ]; then
                    mkdir -p "$pt_new/$pt_dir" || return 1
                fi ;;
            *) return 1 ;;
        esac
        [ ! -L "$current_profile/$pt_dir" ] && [ ! -L "$pt_new/$pt_dir" ] &&
            [ ! -L "$backupdir/profile-parked-$pt_dir" ] || return 1
    done
    profile_write_journal && profile_resume
}

apply_profile_isolation() {
    profile_begin arm '' "${selected_kid-$(get_active_kid)}"
}

restore_profile_isolation() {
    profile_resume || return 1
    _rpi_target=${1:-$(restore_target_profile)}
    case "$_rpi_target" in
        "$legacy_kids_profile") _rpi_owner='' ;;
        "$kids_profile_prefix"*) _rpi_owner=${_rpi_target#"$kids_profile_prefix"} ;;
        *) return 1 ;;
    esac
    profile_begin disarm "$_rpi_owner" ''
}
