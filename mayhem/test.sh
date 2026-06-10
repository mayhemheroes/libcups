#!/usr/bin/env bash
#
# libcups/mayhem/test.sh — RUN libcups' OWN self-contained unit tests (built by mayhem/build.sh
# step 3 with NORMAL, unsanitized flags) and emit a CTRF summary. exit 0 iff no test failed.
#
# BEHAVIORAL oracle (§6.3 anti-reward-hacking): each test binary produces a KNOWN number of "PASS"
# lines to stdout/stderr. We capture that output and assert the count meets the minimum.  A no-op
# patch (binary neutered to exit(0)) outputs NOTHING, so the count is 0 → assertion fails → CTRF
# reports a failure and this script exits non-zero.  A genuine passing run produces the expected
# count and exits 0.  This script never compiles — it only runs pre-built binaries.
#
# Subset rationale: we run the network-free, fixture-free unit tests. We EXCLUDE the ones that need
# a live server / network / long wall-clock sleeps and so are non-deterministic in a build sandbox:
#   testclient testcups testdest testgetdests testdnssd testhttp testcreds testoauth (network/server)
#   testclock                                                              (sleeps up to 60s each)
#   testthreads                                                            (timing-sensitive)
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${SRC:=/mayhem}"

# Prefer the clean, unsanitized test tree built by mayhem/build.sh step 3; fall back to the
# in-place tree if that's where the unit tests landed.
if [ -x "$SRC/mayhem-tests/cups/testipp" ]; then
  cd "$SRC/mayhem-tests/cups"
else
  cd "$SRC/cups"
fi

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
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

# Behavioral minimum "PASS" line counts per binary.
# Derived from a real run; a neutered exit(0) binary produces 0 lines → fails.
# These are conservative lower bounds (real counts are higher), so upstream additions don't break us.
declare -A MIN_PASS_LINES=(
  [testarray]=20
  [testfile]=50
  [testform]=10
  [testhash]=10
  [testipp]=30
  [testi18n]=10
  [testjson]=30
  [testjwt]=30
  [testlang]=50
  [testoptions]=2
  [testpwg]=10
  [testraster]=50
  [testtestpage]=50
)

TESTS="testarray testfile testform testhash testipp testi18n testjson testjwt testlang testoptions testpwg testraster testtestpage"

PASSED=0; FAILED=0; SKIPPED=0
for t in $TESTS; do
  if [ ! -x "./$t" ]; then
    echo "SKIP  $t (binary missing — build it via mayhem/build.sh)"
    SKIPPED=$(( SKIPPED + 1 ))
    continue
  fi
  echo "=== running $t ==="
  if ! timeout 120 "./$t" >"/tmp/$t.log" 2>&1; then
    rc=$?
    echo "FAIL  $t (exit $rc)"
    tail -20 "/tmp/$t.log" | sed 's/^/      /'
    FAILED=$(( FAILED + 1 ))
    continue
  fi

  # Behavioral assertion: count "PASS" lines in the output.
  # A binary neutered to exit(0) produces 0 PASS lines → fails this check.
  n_pass=$(grep -c "PASS" "/tmp/$t.log" 2>/dev/null || true)
  min="${MIN_PASS_LINES[$t]:-1}"
  if [ "$n_pass" -ge "$min" ]; then
    echo "PASS  $t ($n_pass 'PASS' lines, min=$min)"
    PASSED=$(( PASSED + 1 ))
  else
    echo "FAIL  $t — only $n_pass 'PASS' lines in output (expected at least $min; binary may be broken or no-op)"
    tail -5 "/tmp/$t.log" | sed 's/^/      /'
    FAILED=$(( FAILED + 1 ))
  fi
done

# Guard against a silently empty run (every binary missing) being reported as a clean pass.
if [ "$(( PASSED + FAILED ))" -eq 0 ]; then
  echo "no unit-test binaries were present — build did not produce them" >&2
  emit_ctrf "libcups-unittests" 0 1 "$SKIPPED"; exit 2
fi

emit_ctrf "libcups-unittests" "$PASSED" "$FAILED" "$SKIPPED"
