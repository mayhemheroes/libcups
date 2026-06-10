#!/usr/bin/env bash
#
# libcups/mayhem/build.sh — build OpenPrinting/libcups's two OSS-Fuzz harnesses as sanitized
# libFuzzer targets (+ standalone reproducers), AND libcups' own self-contained unit tests for
# mayhem/test.sh.
#
# Fuzzed surface (attacker-controlled bytes into libcups' C parsers):
#   fuzzipp  — IPP message wire format. Feeds raw bytes through ippReadIO()/ippWriteIO()
#              (round-trips an IPP request through cupsFile I/O). Exercises cups/ipp.c, the
#              attribute encode/decode + the string-pool interning in cups/string.c.
#   fuzzfile — libcups file/dir API (cups/file.c, cups/dir.c): cupsFileOpen/Read/Write/Gets/
#              Seek/Lock + gzip (zlib) compressed I/O + cupsDirOpen/Read on a parsed segment list.
#
# Harnesses come from OpenPrinting/fuzzing (the upstream OSS-Fuzz fuzzer repo); they are vendored
# into mayhem/harnesses/ so the build is self-contained (no network clone at image-build time).
#
# Build contract comes from the org base ENV (CC/CXX/SANITIZER_FLAGS/LIB_FUZZING_ENGINE/SRC/
# STANDALONE_FUZZ_MAIN/OUT). We build libcups ITSELF with $SANITIZER_FLAGS so the parsed code (not
# just the harness) is instrumented.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# `=` (not `:=`) for SANITIZER_FLAGS so an explicit empty --build-arg builds with NO sanitizers.
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
# Ensure SanitizerCoverage instrumentation is present in the library under test.
# The base image's SANITIZER_FLAGS contains only ASan/UBSan — no coverage hooks.
# Without -fsanitize=fuzzer-no-link, libcups itself is uninstrumented → 0 Mayhem edges.
# Guard: only inject if neither 'fuzzer' variant is already present.
case "$SANITIZER_FLAGS" in
  *fuzzer*) ;;
  *) SANITIZER_FLAGS="$SANITIZER_FLAGS -fsanitize=fuzzer-no-link" ;;
esac
# DEBUG_FLAGS: explicit DWARF-3 so Mayhem triage can read symbols (clang-19 defaults to DWARF-5).
# `:=` so an explicit empty override is honoured.
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
export DEBUG_FLAGS
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${STANDALONE_FUZZ_MAIN:=/opt/mayhem/StandaloneFuzzTargetMain.c}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${OUT:=/mayhem}"
: "${SRC:=/mayhem}"

# ── Benign-UB relaxation (build.sh only) ───────────────────────────────────────────────────────
# libcups' IPP parser and string-pool deliberately use idioms that trip UBSan on essentially every
# input, drowning out any real bug:
#   * ipp.c:        request_id = (buffer[4] << 24) | ...   -> shift / signed-integer-overflow
#   * string.c:     casts an arbitrary input buffer to _cups_sp_item_t (string interning) -> alignment
#   * array.c:      calls a typed comparator through a generic fn pointer                 -> function
# Upstream OSS-Fuzz disables UBSan ENTIRELY for libcups (project.yaml sanitizers: address, memory).
# We keep ASan + the meaningful UBSan checks (null deref, bounds, etc.) HALTING and disable only this
# set of well-known benign checks so the harness reaches real parser code instead of crashing at byte 0.
UBSAN_RELAX="function,alignment,shift,signed-integer-overflow,unsigned-integer-overflow,implicit-integer-sign-change,enum"
case "$SANITIZER_FLAGS" in
  *undefined*) SANITIZER_FLAGS="$SANITIZER_FLAGS -fno-sanitize=$UBSAN_RELAX" ;;
esac

export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE STANDALONE_FUZZ_MAIN MAYHEM_JOBS OUT SRC

cd "$SRC"

# ── 1) Build libcups (static, sanitized) ───────────────────────────────────────────────────────
# pdfio is a git submodule; the image bakes the full .git so we can materialise it offline.
git config --global --add safe.directory "$SRC" 2>/dev/null || true
if [ ! -f pdfio/pdfio.h ]; then
  git submodule update --init --recursive
fi

# libcups requires a DNS-SD backend (Avahi) and uses TLS; OpenSSL is in the base, Avahi/dbus/systemd
# come from apt in the Dockerfile. Static-only so the harness binaries are self-contained.
export CFLAGS="${CFLAGS:-} $SANITIZER_FLAGS $DEBUG_FLAGS"
export CXXFLAGS="${CXXFLAGS:-} $SANITIZER_FLAGS $DEBUG_FLAGS"
export LDFLAGS="${LDFLAGS:-} $SANITIZER_FLAGS"

./configure --enable-static --disable-shared --with-tls=openssl
make -j"$MAYHEM_JOBS"

LIBCUPS="$SRC/cups/libcups3.a"
LIBPDFIO="$SRC/pdfio/libpdfio.a"
[ -f "$LIBCUPS" ] || { echo "ERROR: $LIBCUPS not built" >&2; exit 1; }

# ── 2) Build each OSS-Fuzz harness: libFuzzer (-> $OUT/<name>) + standalone reproducer ──────────
INC="-I$SRC -I$SRC/cups -I$SRC/pdfio"
# Link deps mirror OpenPrinting/fuzzing's Makefile (sans the static .a forms the base lacks):
AVAHI_LIBS="$(pkg-config --libs avahi-client 2>/dev/null || echo '-lavahi-client -lavahi-common')"
DBUS_LIBS="$(pkg-config --libs dbus-1 2>/dev/null || echo '-ldbus-1')"
LINK_LIBS="-L$SRC/cups -L$SRC/pdfio -lcups3 -lpdfio -lz -lpthread $AVAHI_LIBS $DBUS_LIBS -lssl -lcrypto -lm -lsystemd"

# Standalone driver object (no libFuzzer runtime; reads one input file at a time).
$CC $SANITIZER_FLAGS $DEBUG_FLAGS $INC -c "$STANDALONE_FUZZ_MAIN" -o "$SRC/mayhem/standalone_main.o"

for harness in fuzzipp fuzzfile; do
  $CC $SANITIZER_FLAGS $DEBUG_FLAGS $INC -c "$SRC/mayhem/harnesses/$harness.c" -o "$SRC/mayhem/$harness.o"

  # libFuzzer target -> $OUT/<name>
  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE "$SRC/mayhem/$harness.o" $LINK_LIBS \
       -o "$OUT/$harness"

  # standalone reproducer -> $OUT/<name>-standalone
  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS "$SRC/mayhem/$harness.o" "$SRC/mayhem/standalone_main.o" $LINK_LIBS \
       -o "$OUT/$harness-standalone"

  echo "built $harness (+ standalone)"
done

# ── 3) Build libcups' OWN unit tests with NORMAL flags in a CLEAN tree so test.sh only RUNS them. ──
# Keep test.sh an honest PATCH oracle: no sanitizers (ASan/LSan would flag benign OpenSSL/test-harness
# leaks in testjwt/testjson as failures even though every assertion passes) and no benign-UB noise.
# Use a separate copy of the source so the sanitized objects from step 1 are NOT reused.
if [ "${SKIP_TESTS:-0}" != "1" ]; then
  TESTTREE="$SRC/mayhem-tests"
  rm -rf "$TESTTREE"
  mkdir -p "$TESTTREE"
  # Mirror the source (incl. the already-materialised pdfio submodule) into the clean tree.
  cp -a "$SRC/." "$TESTTREE/" 2>/dev/null || true
  rm -rf "$TESTTREE/mayhem-tests"
  (
    cd "$TESTTREE"
    # Purge any sanitized objects/libs copied from step 1 so the unsanitized build is from scratch.
    make clean >/dev/null 2>&1 || true
    rm -f cups/*.o cups/*.a pdfio/*.o pdfio/*.a tools/*.o 2>/dev/null || true
    env -u CFLAGS -u CXXFLAGS -u LDFLAGS -u SANITIZER_FLAGS \
      ./configure --enable-static --disable-shared --with-tls=openssl >/dev/null
    # Full build first (builds the pdfio submodule lib + libcups3.a the test programs link against),
    # then the unit-test binaries.
    env -u CFLAGS -u CXXFLAGS -u LDFLAGS -u SANITIZER_FLAGS make -j"$MAYHEM_JOBS"
    env -u CFLAGS -u CXXFLAGS -u LDFLAGS -u SANITIZER_FLAGS make -C cups unittests -j"$MAYHEM_JOBS"
  ) || echo "WARNING: unittests build failed (test.sh will report)" >&2
fi

echo "build.sh complete:"
ls -la "$OUT/fuzzipp" "$OUT/fuzzfile" "$OUT/fuzzipp-standalone" "$OUT/fuzzfile-standalone" 2>&1 || true
