# syntax=docker/dockerfile:1
#
# Builds qbzd natively per target, under QEMU binfmt where the runner is not
# already that arch. Same shape as b0bbywan/spotifyd's .github/Dockerfile.linux.
# See the README for why armhf is not cross-compiled.
#
# bookworm keeps the glibc floor at 2.36 (Pi OS bookworm and trixie). armv6 has
# no Debian port, hence the pinned Raspberry Pi OS rootfs
# (https://github.com/vascoguita/raspios-docker) — same pin spotifyd uses.
FROM --platform=linux/amd64  debian:bookworm-slim AS base-amd64
FROM --platform=linux/arm64  debian:bookworm-slim AS base-arm64
FROM --platform=linux/arm/v6 vascoguita/raspios:armhf-bookworm-2025-05-13@sha256:38b812d3a83a9760f9c208d96aa55156ba56fed35a3f41d063bcbe9f00c54639 AS base-armv6

# ── Builder ────────────────────────────────────────────────────────────────
ARG TARGETARCH
ARG TARGETVARIANT
FROM base-${TARGETARCH}${TARGETVARIANT} AS builder

ARG TARGETARCH
ARG TARGETVARIANT
ENV DEBIAN_FRONTEND=noninteractive

# qbzd's native surface is alsa-sys, jack-sys, a bundled libsqlite3-sys and the
# system OpenSSL (patches/0002, applied on every arch). No libdbus — zbus is
# pure Rust.
RUN apt-get update && apt-get install -y --no-install-recommends \
      curl ca-certificates patch \
      gcc make libc6-dev pkg-config \
      libasound2-dev libjack-jackd2-dev libssl-dev \
 && rm -rf /var/lib/apt/lists/*

# QEMU reports armv7 even in an armv6 container, so rustup's host detection has
# to be overridden or it installs an armv7 toolchain.
RUN set -eux; \
    case "${TARGETARCH}${TARGETVARIANT}" in \
      armv6) RUST_HOST="arm-unknown-linux-gnueabihf"   ;; \
      arm64) RUST_HOST="aarch64-unknown-linux-gnu"     ;; \
      amd64) RUST_HOST="x86_64-unknown-linux-gnu"      ;; \
      *)     echo "unsupported platform ${TARGETARCH}${TARGETVARIANT}" >&2; exit 1 ;; \
    esac; \
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
      | sh -s -- -y --profile minimal --default-toolchain stable \
                 --default-host "$RUST_HOST"
ENV PATH="/root/.cargo/bin:$PATH"

WORKDIR /build
COPY upstream/ /build/
COPY patches/ /patches/

# Applied on every arch: 0002 is a packaging choice we want everywhere, so
# scoping it to armhf would only mean shipping three binaries built from two
# different sources. A patch that no longer applies is a hard failure; already
# being present upstream is caught by the reverse-apply test.
RUN set -eux; \
    for p in /patches/*.patch; do \
      [ -f "$p" ] || continue; \
      name="$(basename "$p")"; \
      if patch -p1 --forward --dry-run < "$p" >/dev/null 2>&1; then \
        patch -p1 --forward < "$p" >/dev/null; echo "applied  $name"; \
      elif patch -p1 -R --dry-run < "$p" >/dev/null 2>&1; then \
        echo "skipped  $name — already present in this upstream tag"; \
      else \
        echo "ERROR: patch $name no longer applies: check whether upstream fixed it (delete it) or the code moved (rewrite it)" >&2; \
        exit 1; \
      fi; \
    done

# One RUN: /build/crates/target is a cache mount, so nothing under it survives
# into the layer.
RUN --mount=type=cache,target=/root/.cargo/registry \
    --mount=type=cache,target=/root/.cargo/git \
    --mount=type=cache,target=/build/crates/target \
    set -eux; \
    \
    echo "=== gate: qbzd must stay Slint-free ==="; \
    hits="$(cargo tree --manifest-path crates/Cargo.toml --locked -p qbzd -e normal \
            | grep -E '\b(slint|qbz-ui|qbz-slint-common|qbz-dac-wizard) v' || true)"; \
    if [ -n "$hits" ]; then echo "$hits"; echo "ERROR: qbzd's graph now resolves Slint" >&2; exit 1; fi; \
    \
    cargo build --locked --release --manifest-path crates/Cargo.toml -p qbzd; \
    \
    mkdir -p /out/completions; \
    install -Dm755 crates/target/release/qbzd /out/qbzd; \
    \
    echo "=== gate: ELF ==="; \
    readelf -h /out/qbzd | grep -E 'Machine|Class'; \
    if [ "${TARGETARCH}${TARGETVARIANT}" = "armv6" ]; then \
      cpu="$(readelf -A /out/qbzd | sed -n 's/^ *Tag_CPU_arch: *//p' | head -1)"; \
      echo "Tag_CPU_arch: ${cpu}"; \
      case "$cpu" in \
        v6|v6KZ|v6K|v6T2) ;; \
        *) echo "ERROR: armhf build is ${cpu}, not ARMv6 — it would SIGILL on a Pi 1 / Zero" >&2; \
           echo "inputs tagged above v6 (the attribute is the max over all objects):" >&2; \
           find crates/target -name '*.rlib' -o -name '*.a' | sort | while read -r f; do \
             t="$(readelf -A "$f" 2>/dev/null | sed -n 's/^ *Tag_CPU_arch: *//p' | sort -u | tr '\n' ',')"; \
             case "$t" in *v7*|*v8*) echo "  ${f} [${t}]" >&2 ;; esac; \
           done; \
           exit 1 ;; \
      esac; \
    fi; \
    \
    echo "=== gate: glibc floor <= 2.36 ==="; \
    floor="$(objdump -T /out/qbzd | grep -oE 'GLIBC_[0-9]+\.[0-9]+' | sort -Vu | tail -1)"; \
    echo "glibc floor: ${floor:-none}"; \
    if [ -n "$floor" ] && [ "$(printf '%s\n%s\n' "$floor" GLIBC_2.36 | sort -V | tail -1)" != "GLIBC_2.36" ]; then \
      echo "ERROR: glibc floor $floor exceeds 2.36" >&2; exit 1; \
    fi; \
    \
    echo "=== shared libraries required (cross-check packaging/nfpm.yaml) ==="; \
    objdump -p /out/qbzd | sed -n 's/^ *NEEDED *//p' | sort; \
    \
    echo "=== smoke: the binary actually runs on this arch ==="; \
    /out/qbzd --version; \
    \
    for sh in bash zsh fish; do \
      /out/qbzd completions "$sh" > "/out/completions/qbzd.$sh"; \
      [ -s "/out/completions/qbzd.$sh" ] || { echo "ERROR: empty $sh completions" >&2; exit 1; }; \
    done; \
    \
    install -Dm644 crates/qbzd/service/qbzd.service           /out/qbzd.service; \
    install -Dm644 packaging/linux/qbzd-standalone-README.md  /out/README.md; \
    install -Dm644 LICENSE                                    /out/LICENSE

# Export: the relative paths packaging/nfpm.yaml expects.
FROM scratch AS export
COPY --from=builder /out/ /
