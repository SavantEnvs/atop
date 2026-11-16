#!/usr/bin/env bash
#
# mayhem/test.sh — RUN this repo's OWN functional test suite (already built by mayhem/build.sh).
# exit 0 = pass. EDIT per repo. PATCH-grade oracle: after an agent patches the source, the grader
# rebuilds (build.sh) then runs this. DELETE this file if the repo has no meaningful tests.
#
# IMPORTANT:
#  * Must assert BEHAVIOR/OUTPUT, not just exit status. The oracle has to check asserted values /
#    golden-output diffs / known-answer results — so a PATCH that "fixes" a bug by making the program
#    exit(0) (or any no-op) FAILS here. Running inputs and checking only "exit 0 / didn't crash" is
#    NOT a functional test (it's trivially reward-hackable) — use the project's real assertion suite.
#  * Do NOT build here — mayhem/build.sh already compiled the test suite (with the project's normal
#    flags). This script only RUNS the pre-built tests and reports counts. If the test runner is
#    missing, that's a build.sh bug — fail loudly rather than silently rebuilding.
#  * REQUIRED OUTPUT — a CTRF (https://ctrf.io) summary so Mayhem/the PATCH grader reads the counts:
#      - writes a CTRF JSON report to ${CTRF_REPORT:-$SRC/ctrf-report.json}, and
#      - prints a one-line `CTRF {...}` marker to stdout (same JSON, compact).
#    Only `results.summary` (with tests/passed/failed/pending/skipped/other) is required.
#    Use the emit_ctrf helper below; it computes tests = passed+failed+skipped and sets the exit
#    code (0 iff failed==0). Map your framework's output to passed/failed/skipped.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

# atop ships no test suite, so this is a golden-output suite over committed raw logs: each case runs
# the NORMAL-flags build from mayhem/build.sh (mayhem/build/test/) and diffs its output against
# mayhem/tests/expected/<case>.out. The raw logs are fixed inputs (mayhem/tests/*.raw), so every
# rendered value (per-CPU/disk/process counters, layouts, converted/anonymised records) is asserted.
# ATOP_TEST_UPDATE=1 rewrites the expected files (only after a deliberate, reviewed output change).
T="$SRC/mayhem/build/test"
D="$SRC/mayhem/tests"
for b in atop atopsar atopcat atophide atopconvert; do
  [ -x "$T/$b" ] || { echo "missing $T/$b — mayhem/build.sh did not build the test binaries" >&2; emit_ctrf atop-golden 0 1; exit 1; }
done
export TZ=UTC LC_ALL=C
W="$(mktemp -d "${TMPDIR:-/tmp}/atop-test.XXXXXX")"
trap 'rm -rf "$W"' EXIT
mkdir -p "$W/home"
export HOME="$W/home"          # no ~/.atoprc unless a case installs one
cp "$D"/*.raw "$W"/ && cd "$W"  # relative names: the tools print file names into their output

case_text()        { "$T/atop" -r sample.raw; }
case_parseable()   { "$T/atop" -r sample.raw -P ALL; }
case_json()        { "$T/atop" -r sample.raw -J ALL; }
# atopsar's header line (line 2) ends with time(0), i.e. today's date; mask it, the rest is the log's.
case_atopsar()     { "$T/atopsar" -r sample.raw -A | sed '2s|[0-9][0-9][0-9][0-9]/[0-9][0-9]/[0-9][0-9]$|<today>|'; }
case_atopcat_dry() { "$T/atopcat" -dv sample.raw 2>&1; }
case_atopcat()     { "$T/atopcat" sample.raw sample.raw > cat.raw && "$T/atop" -r cat.raw -P CPU,DSK; }
case_atophide()    { "$T/atophide" -a sample.raw hide.raw && "$T/atop" -r hide.raw -P PRG,NET,DSK; }
case_atopconvert() { "$T/atopconvert" sample-v2.10.raw conv.raw && "$T/atop" -r conv.raw -P CPU,MEM,PRG; }
case_atoprc()      { cp "$D/layouts.atoprc" "$HOME/.atoprc" && "$T/atop" -r sample.raw; rm -f "$HOME/.atoprc"; }

CASES="text parseable json atopsar atopcat_dry atopcat atophide atopconvert atoprc"
passed=0 failed=0
for c in $CASES; do
  exp="$D/expected/$c.out"
  if "case_$c" > "$W/$c.out" 2> "$W/$c.err"; then rc=0; else rc=$?; fi
  if [ "${ATOP_TEST_UPDATE:-0}" = 1 ]; then mkdir -p "$D/expected"; cp "$W/$c.out" "$exp"; fi
  if [ "$rc" -eq 0 ] && [ -s "$W/$c.out" ] && cmp -s "$exp" "$W/$c.out"; then
    echo "PASS $c"; passed=$((passed+1))
  else
    echo "FAIL $c (exit $rc)"; diff -u "$exp" "$W/$c.out" 2>&1 | head -20; head -5 "$W/$c.err"
    failed=$((failed+1))
  fi
done
emit_ctrf atop-golden "$passed" "$failed"
