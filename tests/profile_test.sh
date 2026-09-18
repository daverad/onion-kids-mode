#!/bin/sh
# ---------------------------------------------------------------------------
# Save-profile tests for Kids Mode.
#
# There is no way to try this on the device from a dev machine, and the
# failure modes here destroy real save data — a child's progress, or a
# parent's. So the isolation functions are driven against a fixture that
# mirrors the card layout, with every dummy file carrying unique contents so
# a test can say exactly which file ended up where.
#
# Every mutating step is also checked against one blanket invariant: no file
# that existed before a step may have vanished after it (assert_no_loss).
# Data can move anywhere on the card, but it may not disappear.
#
# Run:  sh tests/profile_test.sh
# The device shell is busybox ash, so this is plain POSIX sh — no bashisms,
# no arrays, no [[.
# ---------------------------------------------------------------------------

testdir="$(CDPATH= cd -- "$(dirname "$0")" > /dev/null 2>&1 && pwd -P)"
loopsh="$testdir/../App/KidsMode/kid_mode_loop.sh"

work="${TMPDIR:-/tmp}/kidmode_profile_test.$$"
trap 'rm -rf "$work"' EXIT INT TERM

# The roots kid_mode_loop.sh resolves through — pointed at the fixture
export saves_dir="$work/Saves"
export backupdir="$work/Saves/kidmode"
export logfile="$work/kidmode.log"
export flagfile="$work/.kidmode"
export configfile="$work/kidmode.json"
export kidmode_test=1

# shellcheck source=../App/KidsMode/kid_mode_loop.sh
. "$loopsh"

tests_run=0
tests_failed=0
current_test=""
failures=""

fail() {
    tests_failed=$((tests_failed + 1))
    failures="$failures
  $current_test: $1"
    printf '  FAIL  %s\n' "$1"
}

# --------------------------------- fixture ---------------------------------

# Reset to a card with a parent profile holding save data and the shared
# folders that must never move (config/theme/lists).
fixture_reset() {
    rm -rf "$work"
    mkdir -p "$saves_dir/CurrentProfile"
    rm -f "$flagfile"
    seed "$saves_dir/CurrentProfile/saves/parent.srm" "parent-save"
    seed "$saves_dir/CurrentProfile/states/parent.state" "parent-state"
    seed "$saves_dir/CurrentProfile/romScreens/parent.png" "parent-thumb"
    seed "$saves_dir/CurrentProfile/config/retroarch.cfg" "shared-config"
    seed "$saves_dir/CurrentProfile/theme/theme.json" "shared-theme"
    seed "$saves_dir/CurrentProfile/lists/recent.json" "shared-list"
}

seed() {
    mkdir -p "$(dirname "$1")"
    printf '%s\n' "$2" > "$1"
}

# A child profile with its own identifiable progress
seed_kid_profile() {
    seed "$1/saves/$2.srm" "$2-save"
    seed "$1/states/$2.state" "$2-state"
    seed "$1/romScreens/$2.png" "$2-thumb"
}

# What the kid writes while playing: the launcher moved the profile in, so
# new progress lands in CurrentProfile
play_as() {
    seed "$saves_dir/CurrentProfile/saves/$1.srm" "$1-save"
    seed "$saves_dir/CurrentProfile/states/$1.state" "$1-state"
}

# -------------------------------- assertions -------------------------------

assert_file() {
    if [ ! -f "$1" ]; then
        fail "missing: ${1#$work/}"
        return 1
    fi
    got="$(cat "$1")"
    if [ "$got" != "$2" ]; then
        fail "${1#$work/} contains '$got', expected '$2'"
        return 1
    fi
    return 0
}

assert_absent() {
    [ -e "$1" ] && fail "should not exist: ${1#$work/}"
    return 0
}

assert_equals() {
    [ "$1" = "$2" ] || fail "$3: got '$1', expected '$2'"
    return 0
}

# Every file's contents, one per line. Contents are unique per file, so this
# is a set of "things on the card" that survives files being moved around.
all_contents() { find "$work" -type f ! -name 'kidmode.log' -exec cat {} \; | sort; }

assert_no_loss() {
    now="
$(all_contents)
"
    lost=""
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        case "$now" in
            *"
$line
"*) ;;
            *) lost="$lost $line" ;;
        esac
    done <<EOF
$1
EOF
    [ -n "$lost" ] && fail "data lost:$lost"
    return 0
}

# Run a step and assert it destroyed nothing
step() {
    before_op="$(all_contents)"
    "$@"
    assert_no_loss "$before_op"
}

run_test() {
    current_test="$1"
    tests_run=$((tests_run + 1))
    printf '%s\n' "$current_test"
    fixture_reset
    "$1"
}

# ---------------------------------- tests ----------------------------------

# A card that has never run Kids Mode: no profile of any kind, no roster.
# Nothing should ask who is playing, and the parent's saves must come back.
test_first_ever_arm() {
    assert_equals "$(kid_count)" "0" "fresh card has no children"
    pick_session_kid
    assert_equals "$?" "0" "picker skipped with no children"
    assert_equals "$(active_kids_profile)" "$legacy_kids_profile" "unnamed profile in use"

    step apply_profile_isolation
    assert_absent "$saves_dir/CurrentProfile/saves/parent.srm"
    assert_file "$backupdir/profile-parked-saves/parent.srm" "parent-save"
    # Shared folders are never touched
    assert_file "$saves_dir/CurrentProfile/config/retroarch.cfg" "shared-config"
    assert_file "$saves_dir/CurrentProfile/theme/theme.json" "shared-theme"
    assert_file "$saves_dir/CurrentProfile/lists/recent.json" "shared-list"

    play_as kid
    step restore_profile_isolation
    assert_file "$saves_dir/CurrentProfile/saves/parent.srm" "parent-save"
    assert_file "$saves_dir/CurrentProfile/states/parent.state" "parent-state"
    assert_file "$legacy_kids_profile/saves/kid.srm" "kid-save"
    assert_absent "$saves_dir/CurrentProfile/saves/kid.srm"
}

# The single-child setup every pre-multi-child install already has: a plain
# KidsProfile with real progress in it, and still no picker.
test_unnamed_profile_keeps_working() {
    seed_kid_profile "$legacy_kids_profile" "kid"
    pick_session_kid
    assert_equals "$(kid_count)" "0" "an unnamed profile is not a roster entry"

    step apply_profile_isolation
    assert_file "$saves_dir/CurrentProfile/saves/kid.srm" "kid-save"
    assert_file "$saves_dir/CurrentProfile/romScreens/kid.png" "kid-thumb"
    assert_file "$backupdir/profile-parked-saves/parent.srm" "parent-save"

    step restore_profile_isolation
    assert_file "$legacy_kids_profile/saves/kid.srm" "kid-save"
    assert_file "$saves_dir/CurrentProfile/saves/parent.srm" "parent-save"
}

# Two children, three sessions: Ada plays, Bea starts fresh, Ada comes
# back to exactly where they left off.
test_switching_children() {
    seed_kid_profile "${kids_profile_prefix}Ada" "ada"
    mkdir -p "${kids_profile_prefix}Bea"
    assert_equals "$(kid_count)" "2" "two children on the roster"

    set_active_kid "Ada"
    step apply_profile_isolation
    assert_file "$saves_dir/CurrentProfile/saves/ada.srm" "ada-save"
    play_as ada2
    step restore_profile_isolation
    assert_file "${kids_profile_prefix}Ada/saves/ada2.srm" "ada2-save"

    set_active_kid "Bea"
    step apply_profile_isolation
    assert_absent "$saves_dir/CurrentProfile/saves/ada.srm"
    assert_absent "$saves_dir/CurrentProfile/saves/ada2.srm"
    play_as bea
    step restore_profile_isolation
    assert_file "${kids_profile_prefix}Bea/saves/bea.srm" "bea-save"
    assert_file "${kids_profile_prefix}Ada/saves/ada2.srm" "ada2-save"
    assert_absent "${kids_profile_prefix}Ada/saves/bea.srm"

    set_active_kid "Ada"
    step apply_profile_isolation
    assert_file "$saves_dir/CurrentProfile/saves/ada.srm" "ada-save"
    assert_file "$saves_dir/CurrentProfile/saves/ada2.srm" "ada2-save"
    assert_absent "$saves_dir/CurrentProfile/saves/bea.srm"
    step restore_profile_isolation
    assert_file "$saves_dir/CurrentProfile/saves/parent.srm" "parent-save"
}

# Onion's Guest Mode swaps the whole profile folder before Kids Mode ever
# runs. Kids Mode parks whatever it finds, so this is the same flow with a
# guest's data in CurrentProfile — and the guest's saves must come back.
test_arming_from_guest_mode() {
    mkdir -p "$saves_dir/MainProfile/saves"
    seed "$saves_dir/MainProfile/saves/main.srm" "main-save"
    seed "$saves_dir/CurrentProfile/saves/guest.srm" "guest-save"
    seed_kid_profile "${kids_profile_prefix}Cal" "cal"

    set_active_kid "Cal"
    step apply_profile_isolation
    assert_file "$saves_dir/CurrentProfile/saves/cal.srm" "cal-save"
    assert_file "$backupdir/profile-parked-saves/guest.srm" "guest-save"
    # The main profile is not part of this and must not be touched
    assert_file "$saves_dir/MainProfile/saves/main.srm" "main-save"

    step restore_profile_isolation
    assert_file "$saves_dir/CurrentProfile/saves/guest.srm" "guest-save"
    assert_file "$saves_dir/MainProfile/saves/main.srm" "main-save"
    assert_file "${kids_profile_prefix}Cal/saves/cal.srm" "cal-save"
}

# Forced power-off mid-session: no disarm ran, so the parent's saves are
# still parked. The next boot disarms normally and both sides are intact.
test_crash_then_disarm() {
    seed_kid_profile "${kids_profile_prefix}Ada" "ada"
    set_active_kid "Ada"
    step apply_profile_isolation
    play_as ada2
    # ... power cut: no restore_profile_isolation, process gone ...
    step restore_profile_isolation
    assert_file "$saves_dir/CurrentProfile/saves/parent.srm" "parent-save"
    assert_file "${kids_profile_prefix}Ada/saves/ada2.srm" "ada2-save"
}

# The documented lockout recovery: the flag file is deleted from a computer
# while the profiles are still swapped, so the next arm starts with the
# parent's saves parked and a kid's in CurrentProfile. Arming over the top
# would rm -rf the parent's copy.
test_arming_over_an_interrupted_session() {
    seed_kid_profile "${kids_profile_prefix}Ada" "ada"
    set_active_kid "Ada"
    step apply_profile_isolation
    play_as ada2

    step recover_interrupted_session
    assert_file "$saves_dir/CurrentProfile/saves/parent.srm" "parent-save"
    assert_file "${kids_profile_prefix}Ada/saves/ada2.srm" "ada2-save"
    assert_absent "$backupdir/profile-parked-saves"

    set_active_kid "Ada"
    step apply_profile_isolation
    assert_file "$backupdir/profile-parked-saves/parent.srm" "parent-save"
    assert_file "$saves_dir/CurrentProfile/saves/ada2.srm" "ada2-save"
}

# Adding a second child names the first one, whose saves are live in
# CurrentProfile at the time. Nothing may move except the empty shell.
test_naming_the_first_child_mid_session() {
    seed_kid_profile "$legacy_kids_profile" "kid"
    set_active_kid ""
    step apply_profile_isolation
    : > "$flagfile" # armed

    step adopt_legacy_profile "Ada"
    assert_absent "$legacy_kids_profile"
    assert_equals "$(get_active_kid)" "Ada" "the running session is now Ada's"

    step create_kid_profile "Bea"
    assert_equals "$(kid_count)" "2" "Ada and Bea on the roster"

    step restore_profile_isolation
    assert_file "${kids_profile_prefix}Ada/saves/kid.srm" "kid-save"
    assert_file "$saves_dir/CurrentProfile/saves/parent.srm" "parent-save"
    assert_absent "${kids_profile_prefix}Bea/saves/kid.srm"
}

# A card someone edited by hand: named children AND the old unnamed profile
# still holding saves the picker would never offer.
test_stranded_unnamed_profile_is_adopted() {
    seed_kid_profile "$legacy_kids_profile" "forgotten"
    mkdir -p "${kids_profile_prefix}Bea"

    step adopt_stranded_legacy
    assert_absent "$legacy_kids_profile"
    assert_file "${kids_profile_prefix}Player 1/saves/forgotten.srm" "forgotten-save"
    assert_equals "$(kid_count)" "2" "the stranded child joined the roster"
}

# An empty leftover folder is tidied away instead of showing up as a child
test_empty_unnamed_profile_is_tidied() {
    mkdir -p "$legacy_kids_profile/saves" "${kids_profile_prefix}Bea"
    step adopt_stranded_legacy
    assert_absent "$legacy_kids_profile"
    assert_equals "$(kid_count)" "1" "only Bea remains"
}

# A corrupted pointer must never send one child's saves into another child's
# profile: park them under a name nobody is using instead.
test_unreadable_pointer_parks_rather_than_guesses() {
    seed_kid_profile "${kids_profile_prefix}Ada" "ada"
    mkdir -p "${kids_profile_prefix}Bea" "$backupdir"
    printf '%s\n' "../../../etc" > "$active_kid_file"
    play_as mystery

    step restore_profile_isolation
    assert_file "${kids_profile_prefix}Recovered 1/saves/mystery.srm" "mystery-save"
    assert_file "${kids_profile_prefix}Ada/saves/ada.srm" "ada-save"
    assert_absent "${kids_profile_prefix}Ada/saves/mystery.srm"
}

# Names land in a path on a FAT32 card, so the character set is the
# security boundary as well as a tidiness rule.
test_name_validation() {
    for good in Ada Bea "Mary Anne" R2-D2 Cal_2 "123456789012345678901234"; do
        valid_kid_name "$good" || fail "rejected a good name: '$good'"
    done
    for bad in "" "../evil" "a/b" "a\\b" ".." "." " Ada" "Ada " "Jo*e" "Jo?e" \
        "Jo:e" 'Jo"e' "Jo|e" "Jo<e" "1234567890123456789012345"; do
        valid_kid_name "$bad" && fail "accepted a bad name: '$bad'"
    done
    # Case-insensitive, because FAT32 folder names are
    mkdir -p "${kids_profile_prefix}Ada"
    kid_exists "ada" || fail "kid_exists should ignore case"
    kid_exists "ADA" || fail "kid_exists should ignore case"
    kid_exists "Joanne" && fail "kid_exists matched a different name"
    create_kid_profile "ADA" && fail "a duplicate name should be refused"
    create_kid_profile "../escape" && fail "an unsafe name should be refused"
    assert_absent "$saves_dir/escape"
    # A hand-made folder with an unusable name is skipped, not offered
    mkdir -p "${kids_profile_prefix}no!good"
    assert_equals "$(kid_count)" "1" "only the usable name is on the roster"
}

# Handing the device to a sibling from the parent menu, without leaving the
# launcher. This is the sequence switch_kid performs once the picker has
# answered: the finishing child's saves go back to THEIR folder, named
# explicitly, because the session pointer already names the child taking
# over.
test_handover_between_children() {
    seed_kid_profile "${kids_profile_prefix}Ada" "ada"
    mkdir -p "${kids_profile_prefix}Bea"
    set_active_kid "Ada"
    step apply_profile_isolation
    play_as ada2

    handing_over_from="$(active_kids_profile)"
    set_active_kid "Bea" # the picker answered
    step restore_profile_isolation "$handing_over_from"
    step apply_profile_isolation

    # Ada keeps everything, including what they did this session
    assert_file "${kids_profile_prefix}Ada/saves/ada.srm" "ada-save"
    assert_file "${kids_profile_prefix}Ada/saves/ada2.srm" "ada2-save"
    # Bea starts clean and cannot see Ada's progress
    assert_absent "$saves_dir/CurrentProfile/saves/ada.srm"
    assert_absent "$saves_dir/CurrentProfile/saves/ada2.srm"
    # The parent's saves stayed parked throughout — they were never in play
    assert_file "$backupdir/profile-parked-saves/parent.srm" "parent-save"

    play_as bea
    step restore_profile_isolation
    assert_file "${kids_profile_prefix}Bea/saves/bea.srm" "bea-save"
    assert_file "$saves_dir/CurrentProfile/saves/parent.srm" "parent-save"
    assert_absent "${kids_profile_prefix}Ada/saves/bea.srm"
}

# The carousel's opening game belongs to the child, not to the device, so
# it lives in their profile. Ada coming back to their own game matters as
# much as Cal not being dropped into it.
test_last_game_is_per_child() {
    mkdir -p "${kids_profile_prefix}Ada" "${kids_profile_prefix}Cal"
    set_active_kid "Ada"
    seed "$(last_game_file)" "adas-game"
    assert_file "${kids_profile_prefix}Ada/last_game.txt" "adas-game"

    set_active_kid "Cal"
    assert_absent "$(last_game_file)"
    seed "$(last_game_file)" "cals-game"

    set_active_kid "Ada"
    assert_file "$(last_game_file)" "adas-game"
    assert_file "${kids_profile_prefix}Cal/last_game.txt" "cals-game"
}

# It also has to survive the session it was written in: the isolation moves
# three subfolders, and this sits at the profile root beside them.
test_last_game_survives_a_session() {
    mkdir -p "${kids_profile_prefix}Ada"
    set_active_kid "Ada"
    seed "$(last_game_file)" "adas-game"
    step apply_profile_isolation
    assert_file "$(last_game_file)" "adas-game"
    step restore_profile_isolation
    assert_file "${kids_profile_prefix}Ada/last_game.txt" "adas-game"
}

# Upgrading from a version that kept one shared last_game.txt: the kid
# playing now is the only one it can belong to.
test_shared_last_game_is_migrated() {
    mkdir -p "$backupdir" "${kids_profile_prefix}Ada"
    set_active_kid "Ada"
    seed "$backupdir/last_game.txt" "adas-game"

    step migrate_shared_last_game
    assert_file "${kids_profile_prefix}Ada/last_game.txt" "adas-game"
    assert_absent "$backupdir/last_game.txt"

    # A second run has nothing to do, and never overwrites a kid's own
    seed "$backupdir/last_game.txt" "stale-pointer"
    migrate_shared_last_game
    assert_file "${kids_profile_prefix}Ada/last_game.txt" "adas-game"
    assert_absent "$backupdir/last_game.txt"
}

# With exactly one child there is no picker: the acceptance criterion that
# existing setups see no new screens.
test_single_child_skips_the_picker() {
    mkdir -p "${kids_profile_prefix}Ada"
    pick_session_kid
    assert_equals "$?" "0" "one child needs no picker"
    assert_equals "$(get_active_kid)" "Ada" "the only child is the active one"
    assert_equals "$(active_kids_profile)" "${kids_profile_prefix}Ada" "Ada's profile is in use"
}

# ---------------------------------- main -----------------------------------

run_test test_first_ever_arm
run_test test_unnamed_profile_keeps_working
run_test test_switching_children
run_test test_arming_from_guest_mode
run_test test_crash_then_disarm
run_test test_arming_over_an_interrupted_session
run_test test_naming_the_first_child_mid_session
run_test test_stranded_unnamed_profile_is_adopted
run_test test_empty_unnamed_profile_is_tidied
run_test test_unreadable_pointer_parks_rather_than_guesses
run_test test_name_validation
run_test test_handover_between_children
run_test test_last_game_is_per_child
run_test test_shared_last_game_is_migrated
run_test test_last_game_survives_a_session
run_test test_single_child_skips_the_picker

printf '\n%s tests, %s failed\n' "$tests_run" "$tests_failed"
if [ "$tests_failed" -ne 0 ]; then
    printf '%s\n' "$failures"
    exit 1
fi
exit 0
