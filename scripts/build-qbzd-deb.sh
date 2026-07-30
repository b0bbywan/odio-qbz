#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Build one qbzd .deb: buildx the per-arch native builder image, export the
# staged payload, run nfpm on it.
#
# Usage:
#   build-qbzd-deb.sh --arch <amd64|arm64|armhf> --version <2.0.2>
#                     [--src ./upstream] [--out ./dist]
#
# Needs docker with buildx and nfpm on the host, plus binfmt for any arch the
# host cannot run natively (docker/setup-qemu-action in CI, or
# `docker run --privileged --rm tonistiigi/binfmt --install all` locally).
#
# armhf maps to linux/arm/v6 in a Raspberry Pi OS rootfs; the package arch stays
# `armhf` because that is what dpkg reports on Pi OS armhf. See the README.
#
# The emulated armv6 build takes hours. The gha cache only covers the
# apt/rustup layers — a `type=cache` mount is never exported, so CI always
# compiles from scratch. Locally the mounts persist, which brings a trap: patches
# are applied inside the container, so toggling one leaves the host source at an
# older mtime than the cached objects and cargo reports everything fresh. When
# changing what gets patched, force it:
#   docker buildx prune --filter type=exec.cachemount -f
#   BUILDX_CACHE_ARGS="--no-cache-filter builder" ./scripts/build-qbzd-deb.sh ...

set -euo pipefail

ARCH="" VERSION="" SRC="./upstream" OUT="./dist"

die() { echo "error: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --arch)    ARCH="$2"; shift 2 ;;
    --version) VERSION="$2"; shift 2 ;;
    --src)     SRC="$2"; shift 2 ;;
    --out)     OUT="$2"; shift 2 ;;
    -h|--help) sed -n '4,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

[ -n "${ARCH}" ]    || die "--arch is required"
[ -n "${VERSION}" ] || die "--version is required"

# Every arch builds on trixie, so they share one floor; the glibc-floor gate in
# the builder is what keeps LIBC_MIN honest.
LIBC_MIN="2.41"
case "${ARCH}" in
  amd64) PLATFORM="linux/amd64"  ;;
  arm64) PLATFORM="linux/arm64"  ;;
  armhf) PLATFORM="linux/arm/v6" ;;
  *) die "unsupported arch: ${ARCH} (expected amd64, arm64 or armhf)" ;;
esac

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${REPO_ROOT}"

# The Dockerfile does `COPY upstream/ /build/`.
[ -f "${SRC}/crates/Cargo.toml" ] || die "no qbz workspace at ${SRC}/crates"
if [ "$(cd "${SRC}" && pwd)" != "${REPO_ROOT}/upstream" ]; then
  die "--src must be ${REPO_ROOT}/upstream (it is part of the docker build context)"
fi

command -v nfpm >/dev/null || die "nfpm not found in PATH"

mkdir -p "${OUT}"
OUT="$(cd "${OUT}" && pwd)"
STAGE="${OUT}/stage-${ARCH}"
# Created here: the local exporter's mkdir can be denied on SELinux hosts.
rm -rf "${STAGE}"
mkdir -p "${STAGE}"

echo "=== qbzd ${VERSION} → ${ARCH} (${PLATFORM}) ==="

# shellcheck disable=SC2086  # BUILDX_CACHE_ARGS must be word-split
docker buildx build \
  --platform "${PLATFORM}" \
  --file docker/builder.Dockerfile \
  --target export \
  --output "type=local,dest=${STAGE}" \
  --progress plain \
  ${BUILDX_CACHE_ARGS:-} \
  .

[ -x "${STAGE}/qbzd" ] || die "builder produced no qbzd at ${STAGE}"

echo "--- exported payload"
find "${STAGE}" -type f -printf '%10s  %P\n' | sort -k2

echo "--- nfpm"
DEB="${OUT}/qbzd_${VERSION}_${ARCH}.deb"
# nfpm resolves contents[].src relative to the CWD.
( cd "${STAGE}" \
  && QBZD_ARCH="${ARCH}" QBZD_VERSION="${VERSION}" QBZD_LIBC_MIN="${LIBC_MIN}" \
     nfpm package -f "${REPO_ROOT}/packaging/nfpm.yaml" -p deb -t "${DEB}" )

echo "--- package"
dpkg-deb --info "${DEB}"
dpkg-deb --contents "${DEB}"
ls -lh "${DEB}"
echo "=== done: ${DEB} ==="
