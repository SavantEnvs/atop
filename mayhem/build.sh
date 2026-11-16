#!/usr/bin/env bash
#
# mayhem/build.sh — build this repo's fuzz harness(es). EDIT per repo.
#
# Runs inside the commit image (mayhem/Dockerfile) as `mayhem` in /mayhem. The base image
# (ghcr.io/savantenvs/base) already exports the build contract — use these, don't redefine:
#   CC, CXX             stock clang / clang++
#   LIB_FUZZING_ENGINE  -fsanitize=fuzzer   (link into each harness that has a LLVMFuzzer entry)
#   SANITIZER_FLAGS     -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer
#                       (ASan + UBSan, both set to HALT — so Mayhem catches memory AND UB defects)
#   DEBUG_FLAGS         -g -gdwarf-3   (DWARF debug info — always on for fuzz/standalone builds,
#                       independent of the sanitizer off-switch; DWARF version must be < 4)
#   RUST_DEBUG_FLAGS    -C debuginfo=2 -C force-frame-pointers=yes -C llvm-args=-gdwarf-3
#                       (thread through RUSTFLAGS on every cargo-fuzz build)
#   GO_DEBUG_FLAGS      -gcflags=all=-N -l
#                       (thread through go build / go-fuzz-build so the linked ELF keeps symbols)
#   SRC                 /mayhem (the repo source)
#
# Contract: build EVERYTHING here — one runnable binary per fuzz harness, AND the project's test
# suite (so mayhem/test.sh only has to RUN it, never compile). Keep it ADDITIVE (build upstream as
# upstream documents; don't edit upstream files). IMPORTANT: build the PROJECT ITSELF with
# $SANITIZER_FLAGS and $DEBUG_FLAGS (not just the harness) so the fuzzed code is instrumented
# AND carries DWARF < 4 symbols — otherwise ASan/UBSan only see the harness, not the library
# you're trying to find bugs in, and backtraces won't resolve project source lines. Build the TEST
# suite with the project's NORMAL flags (a clean, independent build) so test.sh stays an honest
# functional oracle and won't false-fail on benign UB. Leave the test binary/runner where test.sh
# expects it.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — it must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# Build knobs come from the ENVIRONMENT (overridable), with sane defaults — no if-statements,
# just parameter-expansion fallbacks. Default sanitizers are the base's ASan+UBSan (halting); override
# per build via the Dockerfile's `--build-arg SANITIZER_FLAGS="..."`.
# NB: SANITIZER_FLAGS uses `=` (no colon) on purpose — `=` only fills when the var is UNSET, so an
# explicit EMPTY value (`--build-arg SANITIZER_FLAGS=`) is honored and builds with NO sanitizers
# (useful when you want the program's natural crash / full backtrace, not an ASan report). The other
# knobs use `:=` (default on empty too). MAYHEM_JOBS sets build parallelism (falls back to nproc).
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
# DEBUG_FLAGS carries DWARF debug info INDEPENDENTLY of the sanitizer off-switch (so an empty
# SANITIZER_FLAGS still yields DWARF symbols). DWARF MUST be < 4 (Mayhem triage can't read >=4); clang-19's
# plain `-g` emits DWARF-5, so `-gdwarf-3` is explicit. Apply $DEBUG_FLAGS to the fuzz/harness/standalone
# builds (NOT the test/oracle build). Rust/Go carry the same intent via their language flags below.
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${RUST_DEBUG_FLAGS:=-C debuginfo=2 -C force-frame-pointers=yes -C llvm-args=-gdwarf-3}"
: "${GO_DEBUG_FLAGS:=-gcflags=all=-N -l}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
# COVERAGE_FLAGS: empty by default → no effect on the normal oracle build. Set it via the Dockerfile's
# `--build-arg COVERAGE_FLAGS="-fprofile-instr-generate -fcoverage-mapping"` to instrument the TEST
# build for source-coverage measurement (how much of the project the test suite actually exercises —
# a quality signal for the oracle; complements the anti-reward-hack sabotage check). APPEND it to the
# test build's compile+link flags in step 3 (NOT the fuzz build); after `test.sh` runs, merge with
# `llvm-profdata` and report with `llvm-cov`. Empty value is honored (`=`, not `:=`).
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS RUST_DEBUG_FLAGS GO_DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

# atop is a plain Makefile project (no configure) building in-tree; it appends our CFLAGS/LDFLAGS
# after its own (`override CFLAGS := -O2 -I. -Wall <glib> ... $(CFLAGS)`). Every target is a CLI
# reading a file (main()+exit() with heavy global state), so we fuzz the real binaries.
TOOLS="atop atopconvert atopcat atophide"
OUT="$SRC/mayhem/build"
GLIB_CFLAGS="$(pkg-config --cflags glib-2.0)"
GLIB_LIBS="$(pkg-config --libs glib-2.0)"
mkdir -p "$OUT/bin" "$OUT/test" "$OUT/obj"

# Objects linked into `atop` besides atop.o itself (the Makefile's ALLMODS): everything make left in
# the tree except the other tools' mains.
allmods() {
  local o
  for o in *.o; do
    case "$o" in atop.o|atopacctd.o|netlink.o|atopconvert.o|atopcat.o|atophide.o) ;; *) echo "$o" ;; esac
  done
}

# 1) Test/oracle build with the project's NORMAL flags (plus the optional COVERAGE_FLAGS), stashed
#    in mayhem/build/test/ for test.sh; then clean the shared in-tree objects.
make clean >/dev/null
make -j"$MAYHEM_JOBS" CC="$CC" CFLAGS="$COVERAGE_FLAGS" LDFLAGS="$COVERAGE_FLAGS" $TOOLS
for t in $TOOLS; do cp -f "$t" "$OUT/test/$t"; done
cp -f atop "$OUT/test/atopsar"     # atopsar is atop run under the name "atopsar" (argv[0])
make clean >/dev/null

# 2) Fuzz build: the whole project with ASan+UBSan (halting) and DWARF 3, LeakSanitizer off.
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c mayhem/lsan_off.c -o "$OUT/obj/lsan_off.o"
# One UBSan check is relaxed, for atopsar.o only: float-cast-overflow. atopsar's memline() computes
# (totswap - freeswap) * 100.0 / totswap, i.e. 0/0 = NaN on every host without swap, and casts it to
# unsigned (atopsar.c, see mayhem/atopsar_report/known-findings/). With halting UBSan that aborts every
# swapless log before any report is printed, which starves the atopsar target. Every other object
# (atop, atopcat, atopconvert, atophide included) keeps the check; ASan and every other UBSan check
# stay on and halting everywhere. Only relaxed when sanitizers are on (empty SANITIZER_FLAGS = none).
UBSAN_RELAX=""
case "$SANITIZER_FLAGS" in *undefined*) UBSAN_RELAX="-fno-sanitize=float-cast-overflow" ;; esac
# rawlog.c waits up to 2 s (usleep) for a truncated raw record to be completed by a writer; a fuzz
# input has none, so every truncated input cost 2 s. Wrapping libc usleep() skips that wait only.
# isatty() -> 0 keeps "atop -r file" off its ncurses branch (Mayhem gives it a pty). malloc/calloc/realloc
# return NULL above 256 MiB like glibc does, instead of ASan aborting where atop's ptrverify() exits cleanly.
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c mayhem/usleep_wrap.c -o "$OUT/obj/usleep_wrap.o"
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c mayhem/alloc_wrap.c -o "$OUT/obj/alloc_wrap.o"
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c mayhem/tty_wrap.c -o "$OUT/obj/tty_wrap.o"
FUZZ_CFLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS"
FUZZ_LDFLAGS="$SANITIZER_FLAGS -Wl,--wrap=usleep,--wrap=isatty,--wrap=malloc,--wrap=calloc,--wrap=realloc $OUT/obj/usleep_wrap.o $OUT/obj/alloc_wrap.o $OUT/obj/tty_wrap.o $OUT/obj/lsan_off.o"
# atopsar.o is built first with the relaxed flags (same flags the Makefile uses); make then finds it
# up to date and links it as is.
# shellcheck disable=SC2086
$CC -O2 -I. -Wall $GLIB_CFLAGS $FUZZ_CFLAGS $UBSAN_RELAX -c atopsar.c -o atopsar.o
make -j"$MAYHEM_JOBS" CC="$CC" CFLAGS="$FUZZ_CFLAGS" LDFLAGS="$FUZZ_LDFLAGS" $TOOLS
for t in $TOOLS; do cp -f "$t" "$OUT/bin/$t"; done
cp -f atop "$OUT/bin/atopsar"      # a real copy, not a symlink: Mayhem runs it as argv[0]=atopsar

# 3) Wrapper targets around atop's own main() (atop.c compiled again with -Dmain=atop_main, same
#    flags as the Makefile uses): ~/.atoprc parsing and the atopgpud socket protocol.
$CC -O2 -I. -Wall $GLIB_CFLAGS $FUZZ_CFLAGS -Dmain=atop_main -c atop.c -o "$OUT/obj/atop_as_main.o"
MODS="$(allmods)"
$CC $FUZZ_CFLAGS \
    -c mayhem/harnesses/atop_rc_main.c -o "$OUT/obj/atop_rc_main.o"
$CC $FUZZ_CFLAGS -c mayhem/harnesses/atop_gpud_main.c -o "$OUT/obj/atop_gpud_main.o"
# shellcheck disable=SC2086
$CC $FUZZ_CFLAGS -Wl,--wrap=fopen,--wrap=access,--wrap=sleep "$OUT/obj/atop_rc_main.o" "$OUT/obj/atop_as_main.o" $MODS "$OUT/obj/lsan_off.o" \
    -o "$OUT/bin/atop_rc" -lncursesw -lz -lm -lrt $GLIB_LIBS
# shellcheck disable=SC2086
$CC $FUZZ_CFLAGS -Wl,--wrap=connect "$OUT/obj/atop_gpud_main.o" "$OUT/obj/atop_as_main.o" $MODS \
    "$OUT/obj/lsan_off.o" -o "$OUT/bin/atop_gpud" -lncursesw -lz -lm -lrt $GLIB_LIBS

ls -l "$OUT/bin" "$OUT/test"
