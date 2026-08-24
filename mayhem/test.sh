#!/usr/bin/env bash
#
# mayhem/test.sh — the BEHAVIORAL oracle for nickel (nickel-lang/nickel).
#
# Direct KAT (known-answer) probes against `/mayhem/kat` (built by mayhem/build.sh, CLEAN/
# non-sanitized) — a small additive crate that reads a Nickel program from stdin, evaluates it
# via the exact same public API path (and NickelValue Display impl) the real `nickel eval` CLI
# subcommand uses (see mayhem/kat/Cargo.toml for why this is a standalone crate rather than the
# real cli/ CLI binary — disk footprint on a host shared with ~14 other concurrent workers).
#
# bash pipes fixed Nickel source in via stdin, we assert the EXACT stdout/exit behavior. This is
# NOT exit-code-only, NOT --version/--help, NOT "the harness is executable", and NOT a
# statically-linked `cargo test` binary the LD_PRELOAD sabotage shim can't touch: `kat` is a real
# dynamically linked ELF the shim's neuter-to-exit(0) constructor fires in directly, so sabotage
# turns every KAT below into a failure (empty/wrong stdout, or an unexpectedly-accepted bad
# input). Two of the four are lifted verbatim from upstream's own cli/tests/snapshot fixtures +
# their checked-in expected snapshots, so the expected values are upstream's, not invented.
# Unconditional: a missing binary is a hard failure, never a skipped check.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
cd "${SRC:=/mayhem}"

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

kat_passed=0
kat_failed=0

kat_check() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$actual" = "$expected" ]; then
    kat_passed=$((kat_passed + 1))
    echo "KAT ok: $desc"
  else
    kat_failed=$((kat_failed + 1))
    echo "KAT FAILED: $desc"
    echo "  expected: [$expected]"
    echo "  actual:   [$actual]"
  fi
}

KAT_BIN=/mayhem/kat
if [ ! -x "$KAT_BIN" ]; then
  echo "ERROR: $KAT_BIN missing or not executable — cannot run the behavioral oracle" >&2
  emit_ctrf "nickel-kat" 0 1
  exit 1
fi

# KAT 1: record literal + arithmetic + `| Number` contract, lifted verbatim from upstream's own
# cli/tests/snapshot/inputs/eval/records.ncl, asserted against upstream's own checked-in
# snapshot cli/tests/snapshot/snapshots/snapshot__eval_stdout_records.ncl.snap.
out1="$(printf '%s' '{ a = true, b | Number = 6 * 7 }' | "$KAT_BIN" 2>/tmp/kat1.err)"
kat_check "record literal + arithmetic + Number contract (upstream records.ncl fixture)" \
  '{ a = true, b | Number = 42, }' "$out1"

# KAT 2: string escaping round-trip, lifted verbatim from upstream's own
# cli/tests/snapshot/inputs/eval/escaping.ncl / snapshot__eval_stdout_escaping.ncl.snap.
out2="$(printf '%s' '"a\"bcd\""' | "$KAT_BIN" 2>/tmp/kat2.err)"
kat_check "string escaping round-trip (upstream escaping.ncl fixture)" '"a\"bcd\""' "$out2"

# KAT 3: bare arithmetic, independent of any record/contract machinery.
out3="$(printf '%s' '2 + 2' | "$KAT_BIN" 2>/tmp/kat3.err)"
kat_check "bare arithmetic (2 + 2 == 4)" '4' "$out3"

# KAT 4: an unbound identifier must be REJECTED (non-zero exit) — proves evaluation actually
# happens rather than the binary just echoing/no-op'ing on its input.
if printf '%s' 'totally_undefined_identifier_zzz' | "$KAT_BIN" >/tmp/kat4.out 2>/tmp/kat4.err; then
  kat_failed=$((kat_failed + 1))
  echo "KAT FAILED: unbound identifier was accepted (should have been rejected)"
  cat /tmp/kat4.out
else
  kat_passed=$((kat_passed + 1))
  echo "KAT ok: unbound identifier correctly rejected"
fi

echo "=== KAT summary: $kat_passed passed, $kat_failed failed ==="

emit_ctrf "nickel-kat" "$kat_passed" "$kat_failed"
