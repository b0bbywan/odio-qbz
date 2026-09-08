# odio-qbz

Build pipeline that produces multi-arch Debian packages of **qbzd**, the
headless Qobuz playback daemon from [qbz](https://github.com/vicrodh/qbz), for
the [Odio APT repository](https://apt.odio.love).

This is **not a fork** — no source code is vendored here. The CI clones the
upstream tag, applies the portability patches in `patches/`, builds `qbzd`
natively inside a per-arch rootfs, and publishes `.deb` artifacts as a GitHub
Release.

## Why not just use upstream's .deb

Upstream already ships `.deb`s (`QBZ_<v>_amd64.deb`, `QBZ_<v>_arm64.deb`), but
they are desktop packages: one `qbz` package containing both the GUI binary
and `qbzd`, so it depends on the whole GUI runtime (fontconfig,
freetype, wayland, xcb, GL/EGL) and carries a glibc 2.39 floor from its
`ubuntu-24.04` builder. There is no 32-bit build at all.

This repo ships the opposite: **daemon only**, no GUI dependencies, and armhf
included. The target is Debian 13 / Raspberry Pi OS trixie and later — every
arch builds there, so the packages ask for glibc 2.41 (see below).

| | upstream `qbz` deb | this repo's `qbzd` deb |
|---|---|---|
| contents | `qbz` (GUI) + `qbzd` | `qbzd` only |
| depends | ALSA + fontconfig/freetype/png/bz2/expat/zlib | ALSA + libssl |
| glibc floor | 2.39 | 2.41 |
| arches | amd64, arm64 | amd64, arm64, **armhf** |

The package declares `Conflicts`/`Replaces` on `qbz`, because upstream's
package installs the same `/usr/bin/qbzd` and
`/usr/lib/systemd/user/qbzd.service`.

## Architectures

| deb arch | docker platform | rootfs | Rust host |
|---|---|---|---|
| `amd64` | `linux/amd64` | `debian:trixie-slim` | `x86_64-unknown-linux-gnu` |
| `arm64` | `linux/arm64` | `debian:trixie-slim` | `aarch64-unknown-linux-gnu` |
| `armhf` | `linux/arm/v6` | Raspberry Pi OS armhf (**trixie**) | `arm-unknown-linux-gnueabihf` |

`armhf` is **ARMv6**, so a Pi 1 / Zero still runs it — the same choice
`go-odio-api` makes with `GOARM=6`. The package arch stays `armhf` because
that is what dpkg reports on Raspberry Pi OS armhf; an `armel` package would
not be installable there without adding a foreign architecture.

Each arch is built **natively in its own rootfs**, under QEMU binfmt where the
runner is not already that arch — the same shape as
[b0bbywan/spotifyd](https://github.com/b0bbywan/spotifyd)'s
`.github/Dockerfile.linux`. amd64 and arm64 get native runners; only armhf is
emulated, and emulating a 381-crate Rust build takes **hours**, not minutes
(hence `timeout-minutes: 350` and the buildx cache).

### What ARMv6 actually took

Two things had to be true, and the second was not obvious.

**The toolchain is not enough.** Cross-compiling with `-march=armv6` produces an
ELF tagged `Tag_CPU_arch=v7`. So does a *native* build in the Raspberry Pi OS
rootfs, whose gcc is `--with-arch=armv6`.

**The crypto stack was the problem.** rustls delegates to a provider, and both
`ring` and `aws-lc-rs` ship the same OpenSSL-derived ARM assembly emitting

```
#if !defined(OPENSSL_NO_ASM) && defined(OPENSSL_ARM) && defined(__ELF__)
@ Silence ARMv8 deprecated IT instruction warnings. …
.arch	armv7-a
```

— always true for an ARM ELF build. The directive overrides `-march`, which is
why no flag and no rootfs helps, and it enables Thumb-2 encodings. Measured
under `qemu-arm -cpu arm1176`: the binary dies on `mov.w`, which ARMv6Z does not
implement, while the same binary runs under `-cpu cortex-a7`.

Swapping ring for aws-lc-rs did not help — aws-lc-sys carries the same 20 asm
files, in 0.33.0 as in 0.39.1, and `AWS_LC_SYS_NO_ASM` panics outside debug
builds. So `patches/0002` drops the bundled crypto entirely and links the
**system OpenSSL** via native-tls: no crypto assembly in the binary at all, and
the shared library on the target is whatever the distribution built — ARMv6 on
Raspberry Pi OS armhf. spotifyd and myMPD both ship working v6 binaries exactly
this way; their `NEEDED` lists show `libssl.so.3`. It is also what Debian
prefers to a vendored crypto stack.

One more trap: `uname -m` reports `armv7l` inside an armv6 container under QEMU,
so rustup's host detection has to be overridden or it installs an armv7
toolchain and the binary is v7 again for an unrelated reason.

### Why everything targets trixie

Debian's 64-bit `time_t` transition landed in trixie, so on 32-bit arches every
struct carrying a `time_t` changed width. `struct timespec` went from 8 bytes to
16, and libasound was rebuilt for it **without a SONAME bump** — so the
incompatibility is invisible to the linker and to apt.

A bookworm-built binary therefore installs happily on trixie and then dies. The
crash is exact: `snd_pcm_status_get_htstamp` writes 16 bytes into the 8-byte
slot its caller reserved, overruns into the saved `lr`, and the function returns
into address 0. Reached through cpal, which asks for the timestamp on every
callback, so it takes the first note played.

The rootfs alone does not fix this. `libc::timespec` is sized from the target
triple, so it stays 8 bytes on `arm-unknown-linux-gnueabihf` no matter how new
the rootfs is. What fixes it is `alsa-sys` measuring `sizeof(snd_htimestamp_t)`
against the rootfs's own ALSA headers and, when that is 16, defining its own
`timespec` — which `alsa` then uses in place of libc's, and cpal after it. The
first two shipped on 2026-07-31 as `alsa-sys` 0.6.1 and `alsa` 0.12.1; cpal
merged its part but has not released it — 0.18.2 still asks for `alsa ^0.11` —
so `patches/0003` asks for those two by version and pins cpal from git.
(`RUST_LIBC_UNSTABLE_GNU_TIME_BITS=64` widens libc's for the whole crate graph
instead, but it is unstable, and `alsa` 0.11 does not compile with it: its
`timespec` literals do not fill the private `__pad` a time64 libc adds.)

`ci/abi-probe` asserts the width the crate settled on and then makes the ALSA
call, because what can regress silently is that measurement — a rootfs whose
ALSA headers disagree with its libasound, or an alsa-sys bump that drops the
probe.

The bundled C (`libsqlite3-sys`) needs no equivalent flag: it is self-consistent
with glibc, which still exports both ABIs of its own symbols. Only a
third-party library rebuilt for time64 under an unchanged SONAME can bite, and
libasound is the one in this dependency graph.

The consequence is that **one armhf package cannot serve bookworm and trixie**.
The 2.41 glibc floor is what enforces the split, and it is the only mechanism
that does: the `libasound2t64 | libasound2` alternative is a package rename, not
a guard.

amd64 and arm64 have no such constraint — 64-bit arches always had a 64-bit
`time_t` — and they were built on bookworm for a while precisely to keep their
floor at 2.36. That is over: three arches now build on trixie and declare the
same 2.41. It costs the 64-bit packages their installability on Debian 12,
Raspberry Pi OS bookworm and Ubuntu ≤ 24.10 (2.39), and buys one distribution
to reason about — one glibc floor, one set of package names, one set of
headers behind `alsa-sys`' probe — instead of a split that only armhf actually
needed.

The desktop binary is out of scope here — this package is the daemon, and the
UI half of the workspace is an order of magnitude more expensive to compile.
`qbzd` is the column that carries no UI: 381 crates whose entire native surface
is `alsa-sys`, `jack-sys`, a bundled `libsqlite3-sys` and the system OpenSSL,
with no libdbus (`zbus` is pure Rust) and no bindgen or cmake anywhere in the
graph.

## Patches

`patches/*.patch` holds the minimum needed to make the upstream tree build and
run correctly as a headless daemon on a 32-bit target. Upstream builds this
workspace for x86_64 and aarch64 only, so nothing there exercises 32-bit
portability, and the desktop app is what gets exercised day to day:

- `0002-tls-use-the-system-openssl-instead-of-a-bundled-crypto-stack.patch` —
  moves reqwest and tokio-tungstenite to native-tls, because no rustls provider
  can produce an ARMv6 binary (see above). Four declarations, since cargo
  features are additive and one crate asking for rustls pulls it back in — the
  workspace entry, `qbz-integrations` (which declares its own reqwest),
  `qconnect-transport-ws`, and the aws-lc-rs provider `qbz-app` installs.
  Upstream documents native-tls as the intended escape hatch in
  `qbz-qobuz/src/cmaf.rs`, and the Tauri build used it.

  Bundled crypto also bypasses distro security updates: a flaw in ring would
  mean rebuilding and republishing, whereas the system libssl is fixed by
  `apt upgrade`.
- `0003-alsa-take-the-time64-timespec-fix-cpal-and-rodio-from-git.patch` — moves
  the graph onto the time64 `timespec` fix (see above). `alsa-sys` 0.6.1 and
  `alsa` 0.12.1 carry it and are on crates.io, so they are version requirements;
  `cpal` is pinned to a master rev, because
  [cpal#1285](https://github.com/RustAudio/cpal/pull/1285) was squash-merged —
  master is already 0.19.0-dev and no 0.18.x release will carry the fix. No
  rodio accepts a cpal 0.19 yet, and `links = "alsa"` forbids two `alsa-sys`
  copies in one graph, so rodio comes from a
  [fork branch](https://github.com/b0bbywan/rodio/tree/cpal-0.19): rodio master
  plus the one-line `cpal = "0.19"` bump upstream will make itself at the cpal
  release. Both pins drop together once cpal 0.19 is out and rodio requires it.
- `0005-mpris-implement-shuffle-and-loopstatus.patch` — the MPRIS `Shuffle`
  and `LoopStatus` properties were published but stubbed: always `false` /
  `None`, and writes were dropped, so a media widget showed buttons that did
  nothing. The core already had the setters and emitted the change events;
  the patch stores both in the MPRIS state, forwards writes, and wires qbzd
  (seed + bus). Taken from
  [b0bbywan/qbz@267ee043](https://github.com/b0bbywan/qbz/commit/267ee043)
  (branch `bugfix/external/mpris-shuffle-loop`), not yet submitted upstream.
  Daemon side only: the original carried the desktop too, and the Qt port that
  replaced it exposes toggle/cycle steps where an MPRIS write carries a target,
  so `qbz-qt` names both events and drops them rather than flipping the wrong
  way. This package compiles neither.

0002 and 0003 carry `Cargo.lock`, because the build runs `--locked`.

The gap at 0004 was a playback-to-bus publisher: `qbzd`'s MPRIS, scrobbler
and `GET /api/events` all subscribed to a bus the core never published on.
Upstream merged an equivalent on 2026-08-28
([#700](https://github.com/vicrodh/qbz/pull/700), `qbzd/src/events_bridge.rs`),
so the patch is gone. It is worth remembering that it went stale INVISIBLY —
it added a new file and its two anchors still matched, so the apply gate
would have shipped two publishers and doubled every scrobble.

Patches are applied on **every** arch: 0002 is a packaging choice wanted
everywhere, 0003 is the same dependency graph everywhere, and 0005 is a
daemon bug that has nothing to do with the CPU. Scoping any of them to armhf would
only mean shipping three binaries built from two different sources, and for
0002 it would leave the 64-bit packages declaring a `libssl3` dependency they
do not link.

A patch that no longer applies **fails the build** rather than being skipped —
that means either upstream fixed it (delete the patch) or the code moved
(rewrite it). A reverse-apply check recognises the benign case, upstream having
taken the change verbatim, and skips it with a log line; it does not recognise a
reformulation, which is how the `alsa::pcm::Frames` patch left this directory —
upstream merged it as `as Frames` with an import, so the check saw neither an
applicable nor an applied patch. Since every arch applies every patch, a stale
one surfaces in the 4-minute amd64 job rather than hours into the emulated armhf
build.

## Releasing

Tag this repo with the upstream version to release:

```bash
git tag v2.1.0 && git push origin v2.1.0
```

A prerelease, routed to the APT repo's `testing` suite, uses a suffix:

```bash
git tag v2.1.1-alpha.1 && git push origin v2.1.1-alpha.1
```

The suffix must be `-rc`, `-beta` or `-alpha`; the number may be attached
(`-rc1`) or dotted (`-rc.1`), as the other odio repos write it. Those three
words are not a style choice: `odio-ci` marks the GitHub Release as a
prerelease on exactly them, and `odio-apt-repo` reads that flag to pick the
suite, so a `-pre1` tag would build and then land in `stable`. The suffix
becomes a Debian-sortable `~alpha.1` in the package version, which sorts below
`2.1.1` where a dash-revision would sort above.

### When `patches/` targets a branch instead of a tag

`patches/` is written against `UPSTREAM_DEV_REF` in `build.yml`, normally the
upstream tag of the last release (`v2.1.0` today). Between releases it can be
rebased onto upstream's `pre-release` branch instead, to ship fixes that are
merged but not tagged. Then no upstream tag applies, so
`PRERELEASE_TRACKS_DEV_REF` is set to `true` and a prerelease tag builds
`UPSTREAM_DEV_REF` instead of the upstream tag its name implies. That is how
`v2.0.3-alpha.1` was built:

```
upstream ref   353ed7ff…            (pre-release, resolved to a commit)
deb version    2.0.3~alpha.1+g353ed7ff
suite          testing
```

The version carries the upstream commit because a branch moves: without it two
testing packages a week apart are indistinguishable in `dpkg -l`. It does NOT
order them — `dpkg --compare-versions` reads a hex sha as an arbitrary string —
so a rebuild of the same branch at a newer commit needs the next `alpha.<N>`,
not the same one retagged. The ref is resolved once, in its own job, and handed
to all three arches: three jobs resolving a branch separately can package three
different trees into one release.

Why `2.0.3` and not `2.0.2`: upstream had released 2.0.2 and `pre-release` had
moved past it, so the package held code newer than 2.0.2 and had to sort above
it. `2.0.3~alpha.1` does, and still sits below the eventual `2.0.3` (which
upstream then shipped as 2.1.0, hence the gap).

The number is only a label, though. Nothing checks the tag against upstream,
because nothing checks the tag out — and upstream's branch still declares the
last release in `crates/Cargo.toml`, so `qbzd --version` disagrees with
`dpkg -l` until upstream bumps it. The `+g<sha>` is the part that identifies
the build.

A tag with **no** suffix ignores the flag entirely and always builds the
upstream tag of the same name. A stable package comes from an immutable
upstream ref or it does not ship.

Going back at the next upstream release means rebasing `patches/` onto the
new tag, pointing `UPSTREAM_DEV_REF` at it and setting
`PRERELEASE_TRACKS_DEV_REF` back to `false`.

`watch-upstream.yml` polls `vicrodh/qbz` daily and pushes the plain `vX.Y.Z`
tag by itself when a new upstream release appears — which is also the alarm
clock for the paragraph above: that build takes the stable path, so it fails
loudly if `patches/` has not moved onto the tag yet.

`workflow_dispatch` still takes any ref plus an explicit version, and publishes
nothing:

```bash
gh workflow run build.yml -f upstream_ref=pre-release -f version=2.1.0+pre.1
```

## Build gates

Every arch fails the build loudly rather than shipping a subtly broken daemon.
All of them run inside the builder, natively, so they need no cross tooling:

- **ARMv6 baseline** (armhf only) — `readelf -A` must report `Tag_CPU_arch: v6`.
  This is a *proxy*: the attribute records the highest architecture of any input
  object, so one hand-written asm file raises the whole binary even when the
  instruction that matters is never executed. It is cheap and it caught the real
  bug, but the property it stands in for is "does this start on an ARM1176",
  which only an execution test answers. Verify a new armhf binary by hand with
  `qemu-arm -cpu arm1176 -L <armhf-sysroot> ./qbzd --version`, and compare
  against `-cpu cortex-a7` to tell a genuine SIGILL from an unrelated failure.
- **time_t width** (all arches, and first, so it fails in minutes rather than
  hours into the emulated build) — `ci/abi-probe` asserts a 16-byte
  `alsa::timespec` and then makes the ALSA call that a mismatch crashes on.
- **glibc floor** ≤ 2.41 on every arch, matching the trixie builder base and the
  `libc6 (>= 2.41)` the package declares.
- **Smoke test** — `qbzd --version` actually executes on the target arch, which
  is also how the shipped shell completions are generated: from the very binary
  that goes into the package.
- The `NEEDED` soname list is printed on every build, to be cross-checked
  against the `depends:` in `packaging/nfpm.yaml`.

## Building locally

```bash
git clone --depth 1 --branch v2.1.0 https://github.com/vicrodh/qbz upstream
# only needed for armhf, and only if binfmt is not already registered:
docker run --privileged --rm tonistiigi/binfmt --install arm
./scripts/build-qbzd-deb.sh --arch armhf --version 2.1.0
```

The checkout must live at `./upstream` — it is part of the docker build
context. Needs docker with buildx, and `nfpm` on the host.

## Installing

Debian 13 / Raspberry Pi OS trixie or newer, on all three arches: the packages
declare `libc6 (>= 2.41)`, so apt refuses them on bookworm instead of
installing something that would break.

```bash
sudo apt install qbzd
sudo loginctl enable-linger "$USER"   # required on a headless box
qbzd setup                            # six-screen TUI: login, audio device, name
systemctl --user enable --now qbzd
```

The systemd **user** unit is upstream's own, shipped verbatim and not enabled
by default — the same convention as `odio-api`. Without linger the unit stops
when you log out of SSH and the device disappears from the Qobuz app;
`qbzd status` warns when linger is off.

## License

The build scripts, Dockerfile and packaging in this repo are licensed under
the [MIT License](LICENSE). The produced packages contain compiled `qbzd`,
which is [MIT](https://github.com/vicrodh/qbz/blob/main/LICENSE) as well.
