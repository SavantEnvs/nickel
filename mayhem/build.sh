#!/usr/bin/env bash
#
# mayhem/build.sh — nickel (nickel-lang/nickel, the Tweag/nickel-lang configuration language;
# NOT the unrelated nickel.rs HTTP framework) commit-image build.
#
# Upstream ships NO fuzz/ directory at all, so this is an ADDITIVE mayhem/fuzz/ cargo-fuzz crate
# (libfuzzer-sys 0.4, path-deps on ../../core i.e. the nickel-lang-core library) with two targets:
#   - parse_typecheck : lex + parse + typecheck (Enforce mode) arbitrary bytes as Nickel source.
#   - eval             : lex + parse + typecheck + FULLY EVALUATE arbitrary bytes as Nickel source.
# Neither touches the filesystem; both go through the same public ProgramBuilder/Program API the
# `nickel` CLI itself uses, and run no harness-side timer: Nickel is Turing-complete, so a hang is a
# finding bounded by the Mayhemfile `timeout:` / libFuzzer -timeout, like a crash.
#
# Also builds mayhem/kat — a small ADDITIVE crate standing in for `nickel eval` (see
# mayhem/kat/Cargo.toml for why not the real cli/ CLI binary: its convert.rs unconditionally
# needs the heavy "format" feature regardless of the CLI's own flags), CLEAN (no sanitizer),
# used by mayhem/test.sh as a direct, dynamically-linked known-answer (KAT) oracle.
#
# TOOLCHAIN NOTE: the upstream repo root ships its OWN `rust-toolchain.toml` pinning stable
# 1.91.1. That file hijacks EVERY bare `cargo` invoked anywhere under this tree (rustup searches
# ancestor dirs), including our additive mayhem/fuzz and the cli/core builds below — so this
# script NEVER invokes bare `cargo`; every invocation carries an explicit `+$RUST_NIGHTLY` or
# `+$RUST_STABLE`. The Dockerfile installs both toolchains so neither override needs the network
# at build (or offline re-run) time.
#
# AIR-GAPPED CONTRACT (SPEC §6.5): the PATCH tier re-runs THIS script OFFLINE.
#   - This FIRST build (online) populates the cargo registry under $CARGO_HOME.
#   - The PATCH re-run resolves crates from that cache; the rlenv runtime exports
#     CARGO_NET_OFFLINE=true for it, so we never hard-code --offline here (it would break this
#     first, online build).
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SRC:=/mayhem}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${RUST_NIGHTLY:=nightly-2025-09-05}"
: "${RUST_STABLE:=stable}"
: "${RUST_DEBUG_FLAGS:=-C debuginfo=1 -C llvm-args=--dwarf-version=3}"
export MAYHEM_JOBS RUST_DEBUG_FLAGS
# cargo-fuzz has no --jobs flag; cargo reads parallelism from CARGO_BUILD_JOBS.
export CARGO_BUILD_JOBS="$MAYHEM_JOBS"

cd "$SRC"

# ── DWARF anchor (SPEC §6.2 item 10) ────────────────────────────────────────────────────────
# rustc's ASan codegen (-Zsanitizer=address) unconditionally emits DWARF5 for every compilation
# unit, ignoring -Cdwarf-version. verify-repo.sh's DWARF gate reads only the FIRST compilation
# unit, so PREPEND a tiny hand-built DWARF3 object as the first linker input via a `-C linker=`
# wrapper (must be prepended, not appended, or its CU doesn't land at .debug_info offset 0).
ANCHOR_C=/tmp/mayhem-dwarf-anchor.c
ANCHOR_O=/tmp/mayhem-dwarf-anchor.o
LINKER_WRAP=/tmp/mayhem-dwarf-linker.sh
cat > "$ANCHOR_C" <<'EOF'
int __mayhem_dwarf3_anchor;
EOF
clang -O0 -gdwarf-3 -c "$ANCHOR_C" -o "$ANCHOR_O"
cat > "$LINKER_WRAP" <<EOF
#!/bin/sh
exec clang "$ANCHOR_O" "\$@"
EOF
chmod +x "$LINKER_WRAP"

FUZZ_DIR="mayhem/fuzz"
TRIPLE="x86_64-unknown-linux-gnu"

FUZZ_TARGETS=()
for f in "$FUZZ_DIR"/fuzz_targets/*.rs; do
  FUZZ_TARGETS+=("$(basename "${f%.*}")")
done
[ "${#FUZZ_TARGETS[@]}" -gt 0 ] || { echo "ERROR: no fuzz targets under $FUZZ_DIR/fuzz_targets/" >&2; exit 1; }

# $SANITIZER_FLAGS is the C/C++ build-arg knob (a set of clang flags rustc can't consume
# directly) — cargo-fuzz drives Rust instrumentation via RUSTFLAGS instead. We still honor its
# on/off INTENT for build-arg parity with the C/C++ contract: ASan is on by default, and an
# explicitly EMPTY --build-arg SANITIZER_FLAGS= disables it (a not-set SANITIZER_FLAGS, e.g.
# outside Docker, leaves ASan on).
RUST_SAN="-Zsanitizer=address"
[ -z "${SANITIZER_FLAGS+x}" ] || [ -n "${SANITIZER_FLAGS}" ] || RUST_SAN=""

# OSS-Fuzz Rust libFuzzer+ASan flags, plus the DWARF3-anchor linker wrapper. debuginfo=1 (line
# tables only, not =2/full) — this host is shared with ~14 other concurrent build workers and
# routinely runs low on disk; level 1 is enough for triage (DWARF gate only checks the CU
# *version*, not the debuginfo *level*).
export RUSTFLAGS="${RUSTFLAGS:-} --cfg fuzzing $RUST_SAN -Cdebuginfo=1 -Cdwarf-version=3 -Cforce-frame-pointers -Csplit-debuginfo=off -Clinker=$LINKER_WRAP $RUST_DEBUG_FLAGS"

echo "=== cargo fuzz build (pinned nightly $RUST_NIGHTLY, ASan via RUSTFLAGS) ==="
echo "RUSTFLAGS=$RUSTFLAGS"
echo "targets: ${FUZZ_TARGETS[*]}"

for t in "${FUZZ_TARGETS[@]}"; do
  echo "--- building fuzz target: $t ---"
  cargo "+$RUST_NIGHTLY" fuzz build --fuzz-dir "$FUZZ_DIR" -O --debug-assertions "$t"
  bin="$SRC/$FUZZ_DIR/target/$TRIPLE/release/$t"
  [ -x "$bin" ] || { echo "ERROR: expected fuzz binary not found at $bin" >&2; exit 1; }
  cp "$bin" "/mayhem/$t"
  echo "built /mayhem/$t"
done

# DISK: this host is shared with ~14 other concurrent build workers and routinely runs low on
# disk (§6.2 item 9's idempotent re-run failed here with ENOSPC before this cleanup was added —
# the ASan build of nickel-lang-core's full dependency graph, with debug info, for two fuzz
# targets is genuinely large). The final binaries are already copied out to /mayhem/<target>
# above, so nothing needs mayhem/fuzz/target/ any more THIS run — wipe it so the image doesn't
# bake in a second full copy on top of $CARGO_HOME's registry cache. This trades incremental
# recompilation speed on a future re-run for a bounded, repeatable peak disk footprint (every
# build.sh invocation — including the offline PATCH re-run — starts from the same clean slate and
# rebuilds from $CARGO_HOME's cached registry sources, which stay untouched).
rm -rf "$FUZZ_DIR/target"

# ── Clean oracle build (stable toolchain, no sanitizer, no DWARF-anchor dance) ──────────────
# mayhem/kat — a minimal stand-in for `nickel eval` (same ProgramBuilder/eval_full API path,
# same NickelValue Display output), used by mayhem/test.sh as a direct, dynamically-linked
# known-answer probe. Only depends on nickel-lang-core (default-features=false, matching the
# fuzz targets) — no clap/directories/gix/topiary/tree-sitter/comrak/rustyline — which matters
# on a build host shared with ~14 other concurrent workers. Normal project flags; RUSTFLAGS
# explicitly cleared so nothing leaks in from the sanitized fuzz build above.
echo "=== building mayhem/kat (stable toolchain $RUST_STABLE, clean oracle build) ==="
( cd "$SRC/mayhem/kat" && RUSTFLAGS="" cargo "+$RUST_STABLE" build --release )
KAT_BIN="$SRC/mayhem/kat/target/release/kat"
[ -x "$KAT_BIN" ] || { echo "ERROR: expected KAT binary not found at $KAT_BIN" >&2; exit 1; }
cp "$KAT_BIN" /mayhem/kat
file /mayhem/kat | grep -q 'dynamically linked' || { echo "ERROR: /mayhem/kat is not dynamically linked (needed for the sabotage/LD_PRELOAD oracle check)" >&2; exit 1; }
echo "built /mayhem/kat"
rm -rf "$SRC/mayhem/kat/target"   # see the disk-footprint note above the fuzz-target cleanup

echo "build.sh complete:"
mayhem_paths=()
for t in "${FUZZ_TARGETS[@]}"; do mayhem_paths+=("/mayhem/$t"); done
ls -la "${mayhem_paths[@]}" /mayhem/kat
