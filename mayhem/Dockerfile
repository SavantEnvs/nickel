# syntax=docker/dockerfile:1.7
#
# nickel commit-image Dockerfile — Rust cargo-fuzz on the org base (ghcr.io/savantenvs/base).
#
# Installs TWO pinned Rust toolchains under a fixed, $HOME-independent prefix
# (/opt/toolchains/rust — SPEC §6.2 item 8):
#   - a NIGHTLY, for -Zsanitizer=address (the OSS-Fuzz Rust ASan path) fuzz builds.
#   - STABLE, for the clean oracle build (the `nickel` CLI, used for direct KAT probes).
# Both are needed because the upstream repo root ships its own rust-toolchain.toml pinning
# stable 1.91.1, which would otherwise hijack every bare `cargo` under this tree — mayhem/build.sh
# and mayhem/test.sh instead pass an explicit `+$RUST_NIGHTLY`/`+$RUST_STABLE` on every
# invocation, so BOTH toolchains must already be present offline (an un-pinned bare toolchain
# name would otherwise make rustup hit the network on the air-gapped PATCH re-run).

FROM ghcr.io/savantenvs/base:20260621

ARG COMMIT
ARG REPO_URL
# SOURCE_DATE_EPOCH stays an ARG (never an ENV — an empty ENV breaks clang). build.sh unsets it when empty.
ARG SOURCE_DATE_EPOCH
# Undefaulted (no '=') so the base ENV default flows through unless --build-arg overrides it.
# Rust instrumentation goes through RUSTFLAGS (see mayhem/build.sh), not this — declared for
# parity with the C/C++ build-arg contract only.
ARG SANITIZER_FLAGS

ARG RUST_NIGHTLY=nightly-2025-09-05
ARG RUST_STABLE=stable
ARG CARGO_FUZZ_VERSION=0.12.0

ENV RUSTUP_HOME=/opt/toolchains/rust/rustup \
    CARGO_HOME=/opt/toolchains/rust/cargo \
    PATH=/opt/toolchains/rust/cargo/bin:${PATH}

USER root
RUN set -eux; \
    install -d /opt/toolchains/rust; \
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
      | sh -s -- -y --no-modify-path --profile minimal --default-toolchain "${RUST_NIGHTLY}"; \
    rustup component add rust-src --toolchain "${RUST_NIGHTLY}"; \
    rustup toolchain install "${RUST_STABLE}" --profile minimal; \
    cargo install cargo-fuzz --version "${CARGO_FUZZ_VERSION}" --locked; \
    chown -R 2000:2000 /opt/toolchains/rust; \
    rustc "+${RUST_NIGHTLY}" --version; rustc "+${RUST_STABLE}" --version; \
    cargo --version; cargo fuzz --version
USER mayhem

WORKDIR /mayhem
COPY --chown=2000:2000 . /mayhem

# Populates $CARGO_HOME (online, this first build), builds both sanitized fuzz targets, and the
# clean-oracle `nickel` CLI.
RUN bash mayhem/build.sh

# Runs the CLI known-answer (KAT) probes against the clean oracle build. A failing probe fails the build.
RUN if [ -f mayhem/test.sh ]; then bash mayhem/test.sh; else echo "no mayhem/test.sh"; fi

LABEL org.opencontainers.image.source="${REPO_URL}" \
      org.opencontainers.image.revision="${COMMIT}" \
      rlenv.tier="commit" \
      rlenv.source_date_epoch="${SOURCE_DATE_EPOCH}" \
      rlenv.user="mayhem"

USER mayhem
WORKDIR /mayhem
