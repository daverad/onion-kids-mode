#!/bin/sh
# One entry point, no test framework or git hooks. Candidate adds a ten-minute
# bounded fuzz run; ordinary full checks use one minute and replay the corpus.
set -eu
root=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
cd "$root"
mode=${1:-quick}
case "$mode" in quick|full|candidate) ;; *) exit 2 ;; esac
build=$(mktemp -d)
trap 'rm -rf "$build"' EXIT HUP INT TERM
python3 tools/source_hash.py > "$build/inputs.json"
cc=${CC:-clang}
flags='-std=c11 -Wall -Wextra -Wpedantic -Werror -Wformat=2 -Wshadow -Wconversion -Wstrict-prototypes'
source=src/kidsMode
for script in App/KidsMode/*.sh tests/*.sh; do sh -n "$script"; done
shellcheck -x -P SCRIPTDIR -S warning App/KidsMode/*.sh tests/*.sh
sh tests/profile_test.sh
sh tests/profile_recovery_test.sh
sh tests/daily_adapter_test.sh
sh tests/clock_setup_test.sh
sh tests/session_timer_test.sh
if command -v busybox >/dev/null; then
    busybox ash tests/profile_test.sh
    busybox ash tests/profile_recovery_test.sh
    busybox ash tests/daily_adapter_test.sh
    busybox ash tests/clock_setup_test.sh
    busybox ash tests/session_timer_test.sh
elif [ "$mode" != quick ]; then
    echo 'Full checks require BusyBox.' >&2; exit 1
fi
# shellcheck disable=SC2086
$cc $flags -I "$source" "$source/allowance.c" tests/allowance_test.c -o "$build/policy"
# shellcheck disable=SC2086
$cc $flags -I "$source" tests/menu_audio_test.c -o "$build/menu-audio"
"$build/menu-audio"
"$build/policy"
[ "$mode" != quick ] || exit 0
$cc --analyze -std=c11 -Xanalyzer -analyzer-output=text "$source/allowance.c" "$source/allowance_store.c" "$source/allowance_runtime.c" 2> "$build/analyzer.log"
[ ! -s "$build/analyzer.log" ] || { cat "$build/analyzer.log"; exit 1; }
sanitizers='-g -O1 -fno-omit-frame-pointer -fsanitize=address,undefined -fno-sanitize-recover=all'
export ASAN_OPTIONS=detect_leaks=1:halt_on_error=1
export UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1
# shellcheck disable=SC2086
$cc $flags $sanitizers -I "$source" "$source/allowance.c" tests/allowance_test.c -o "$build/policy-safe"
# shellcheck disable=SC2086
$cc $flags $sanitizers -I "$source" tests/menu_audio_test.c -o "$build/menu-audio-safe"
"$build/menu-audio-safe"
"$build/policy-safe"
# shellcheck disable=SC2086
$cc $flags $sanitizers -DALLOWANCE_STANDALONE -DALLOWANCE_TESTING "$source/allowance.c" "$source/allowance_store.c" "$source/allowance_runtime.c" -o "$build/runtime"
python3 tests/allowance_runtime_test.py "$build/runtime"
$cc -g -O0 -fsanitize=address,undefined -fno-sanitize-recover=all tests/sanitizer_probe.c -o "$build/probe"
for probe in uaf overflow leak; do
    if "$build/probe" "$probe" > "$build/$probe.log" 2>&1; then
        echo "Sanitizer negative control unexpectedly passed: $probe" >&2; exit 1
    fi
    case "$probe" in
        uaf) expected='AddressSanitizer: heap-use-after-free' ;;
        overflow) expected='runtime error: signed integer overflow' ;;
        leak) expected='LeakSanitizer: detected memory leaks' ;;
    esac
    grep -q "$expected" "$build/$probe.log" || { cat "$build/$probe.log"; exit 1; }
done
$cc -g -O1 -fsanitize=fuzzer,address,undefined -fno-sanitize-recover=all -I "$source" tests/allowance_fuzz.c "$source/allowance.c" -o "$build/fuzz"
mkdir "$build/corpus"
cp tests/corpus/* "$build/corpus/"
seconds=60
[ "$mode" != candidate ] || seconds=600
ASAN_OPTIONS="$ASAN_OPTIONS:quarantine_size_mb=32:thread_local_quarantine_size_kb=64" \
"$build/fuzz" -seed=20261109 -print_final_stats=1 -max_total_time="$seconds" -max_len=8192 -rss_limit_mb=512 -artifact_prefix="$build/" "$build/corpus" > "$build/fuzz.log" 2>&1 || {
    cat "$build/fuzz.log"
    # Preserve actionable failures instead of deleting the reproducer.
    cp "$build"/crash-* "$build"/timeout-* "$build"/oom-* tests/corpus/ 2>/dev/null || true
    exit 1
}
tail -3 "$build/fuzz.log"
python3 - "${CHECK_REPORT:-$build/checks.json}" "$mode" "$cc" "$build/fuzz.log" "$build/inputs.json" <<'PYREPORT'
import datetime, json, pathlib, subprocess, sys
inputs = json.loads(pathlib.Path(sys.argv[5]).read_text())
current = json.loads(subprocess.check_output(['python3', 'tools/source_hash.py']))
if inputs['sha256'] != current['sha256']:
    raise SystemExit('Source changed during verification; no receipt issued.')
report = {'result':'passed', 'mode':sys.argv[2], 'source_sha256':inputs['sha256'],
          'compiler':subprocess.check_output([sys.argv[3], '--version'], text=True).splitlines()[0],
          'fuzz_seed':20261109, 'fuzz_asan_quarantine_mb':32, 'fuzz_rss_limit_mb':512, 'fuzz_statistics':pathlib.Path(sys.argv[4]).read_text().splitlines()[-12:],
          'checks':['dash/BusyBox profile recovery','strict C diagnostics','static analyzer',
                    'policy/codec','runtime and I/O faults','ASan/UBSan/LSan','asserted negative controls','bounded fuzzing'],
          'completed_at':datetime.datetime.now(datetime.timezone.utc).isoformat(),
          'limits':['SDL rendering not instrumented','actual FAT32/power/sleep/save qualification pending']}
pathlib.Path(sys.argv[1]).write_text(json.dumps(report, indent=2)+'\n')
PYREPORT
echo "All $mode checks passed (including sanitizer negative controls)."
