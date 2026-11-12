#!/bin/sh
# Globals and callbacks are supplied by kid_mode_loop.sh / the test fixture.
# shellcheck disable=SC2154,SC2034
set -eu
root=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT HUP INT TERM
export KIDMODE_APP_DIR="$root/App/KidsMode" kidmode_test=1
export saves_dir="$work/Saves" backupdir="$work/Saves/kidmode" flagfile="$work/armed" logfile="$work/log"
# The device loop itself does not use nounset.
set +u
. "$KIDMODE_APP_DIR/kid_mode_loop.sh"
set -u
sync() { :; }
fixture() {
    rm -rf "$saves_dir" "$flagfile"
    unset selected_kid
    for child in CurrentProfile KidsProfile.Ada KidsProfile.Bea; do
        for dir in saves states romScreens; do
            mkdir -p "$saves_dir/$child/$dir"
            printf '%s/%s\n' "$child" "$dir" > "$saves_dir/$child/$dir/progress"
        done
    done
    set_active_kid Ada
}
verify() {
    for child in CurrentProfile KidsProfile.Ada KidsProfile.Bea; do
        for dir in saves states romScreens; do
            [ "$(cat "$saves_dir/$child/$dir/progress")" = "$child/$dir" ] || exit 1
        done
    done
}
# Every journal write, rename, owner commit and transaction commit is a
# possible power cut. Re-source disk state in recovery; do it twice.
for mode in arm switch disarm adopt; do
    cut=1
    while [ "$cut" -le 15 ]; do
        fixture
        [ "$mode" = arm ] || apply_profile_isolation
        if [ "$mode" = adopt ]; then
            restore_profile_isolation
            rmdir "$legacy_kids_profile"
            mv "$kids_profile_prefix"Ada "$legacy_kids_profile"
            set_active_kid ''
            apply_profile_isolation
        fi
        (
            count=0
            profile_boundary() {
                count=$((count + 1))
                [ "$count" -ne "$cut" ] || exit 97
            }
            case "$mode" in
                arm) apply_profile_isolation ;;
                switch)
                    # Exercise the actual hand-over, including picker timing.
                    pick_session_kid() { selected_kid=Bea; }
                    pick_session_timer() { [ "$(get_active_kid)" = Ada ]; }
                    auto_resume_if_set() { :; }
                    switch_kid ;;
                disarm) restore_profile_isolation ;;
                adopt) adopt_legacy_profile Ada ;;
            esac
        ) && rc=0 || rc=$?
        [ "$rc" -eq 0 ] || [ "$rc" -eq 97 ] || { echo "$mode cut $cut: $rc"; exit 1; }
        profile_resume
        profile_resume
        [ ! -f "$flagfile" ] || restore_profile_isolation
        verify
        cut=$((cut + 1))
    done
    echo "$mode: 15 interruption/replay boundaries preserved every save"
done
fixture
apply_profile_isolation
# A conflict must fail before any move, leaving both copies available.
mkdir -p "${kids_profile_prefix}Ada/saves"
printf conflict > "${kids_profile_prefix}Ada/saves/conflict"
if profile_begin switch Ada Bea; then echo 'accepted conflict'; exit 1; fi
[ "$(cat "$current_profile/saves/progress")" = 'KidsProfile.Ada/saves' ]
[ "$(cat "${kids_profile_prefix}Ada/saves/conflict")" = conflict ]
rmdir "${kids_profile_prefix}Ada/saves" 2>/dev/null && exit 1
# Inject a real rename failure; journal remains and retry finishes safely.
rm "${kids_profile_prefix}Ada/saves/conflict"
rmdir "${kids_profile_prefix}Ada/saves"
(mv() { return 1; }; profile_begin switch Ada Bea) && exit 1
profile_resume
restore_profile_isolation
verify
# Corrupt journal cannot be interpreted as shell commands or an owner.
printf '1\nswitch\n../Ada\nBea\n0\n' > "$backupdir/profile.txn"
if profile_resume; then echo 'accepted corrupt journal'; exit 1; fi
echo 'conflict, rename failure and corrupt journal: safely refused'
