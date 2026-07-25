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
they are desktop packages: one `qbz` package containing both the Slint GUI
binary and `qbzd`, so it depends on the whole GUI runtime (fontconfig,
freetype, wayland, xcb, GL/EGL) and carries a glibc 2.39 floor from its
`ubuntu-24.04` builder. There is no 32-bit build at all.

This repo ships the opposite: **daemon only**, no GUI dependencies, glibc 2.36
floor, and armhf included.

| | upstream `qbz` deb | this repo's `qbzd` deb |
|---|---|---|
| contents | `qbz` (GUI) + `qbzd` | `qbzd` only |
| depends | ALSA + fontconfig/freetype/png/bz2/expat/zlib | ALSA + libssl |
| glibc floor | 2.39 | 2.36 |
| arches | amd64, arm64 | amd64, arm64, **armhf** |

The package declares `Conflicts`/`Replaces` on `qbz`, because upstream's
package installs the same `/usr/bin/qbzd` and
`/usr/lib/systemd/user/qbzd.service`.

## Architectures

| deb arch | docker platform | rootfs | Rust host |
|---|---|---|---|
| `amd64` | `linux/amd64` | `debian:bookworm-slim` | `x86_64-unknown-linux-gnu` |
| `arm64` | `linux/arm64` | `debian:bookworm-slim` | `aarch64-unknown-linux-gnu` |
| `armhf` | `linux/arm/v6` | Raspberry Pi OS armhf (bookworm) | `arm-unknown-linux-gnueabihf` |

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

The desktop `qbz` binary is out of scope here: its generated `qbz_ui` crate is
one ~1.6M-line module needing ~30 GB for a single `rustc`. `qbzd` is the
Slint-free column of the workspace — 381 crates whose entire native surface is
`alsa-sys`, `jack-sys`, a bundled `libsqlite3-sys` and the system OpenSSL, with
no libdbus (`zbus` is pure Rust) and no bindgen or cmake anywhere
in the graph.

## Patches

`patches/*.patch` holds the minimum needed to make the upstream tree build and
run correctly on a 32-bit target. Upstream builds this workspace for x86_64 and
aarch64 only, so nothing there exercises 32-bit portability:

- `0002-tls-use-the-system-openssl-instead-of-a-bundled-crypto-stack.patch` —
  moves reqwest and tokio-tungstenite to native-tls, because no rustls provider
  can produce an ARMv6 binary (see above). Several declarations, since cargo
  features are additive and one crate asking for rustls pulls it back in — the
  workspace entry, `qbz-integrations` (which declares its own reqwest), and
  `qconnect-transport-ws`. `Cargo.lock` is in the patch because the build runs
  `--locked`. Upstream documents native-tls as the intended escape hatch in
  `qbz-qobuz/src/cmaf.rs`, and the Tauri build used it.

  Bundled crypto also bypasses distro security updates: a flaw in ring would
  mean rebuilding and republishing, whereas the system libssl is fixed by
  `apt upgrade`.

Patches are applied on **every** arch: 0002 is a packaging choice wanted
everywhere, so scoping it to armhf would only mean shipping three binaries built
from two different sources, and it would leave the 64-bit packages declaring a
`libssl3` dependency they do not link.

A patch that no longer applies **fails the build** rather than being skipped —
that means either upstream fixed it (delete the patch) or the code moved
(rewrite it). The one benign case, the change already being present upstream, is
detected by a reverse-apply check and skipped with a log line. Since every arch
applies every patch, a stale one surfaces in the 4-minute amd64 job rather than
hours into the emulated armhf build.

## Releasing

Tag this repo with the upstream version to release:

```bash
git tag v2.0.2 && git push origin v2.0.2
```

A prerelease (routed to the `testing` channel of the APT repo) uses a suffix;
the underlying upstream tag is the same:

```bash
git tag v2.0.2-rc1 && git push origin v2.0.2-rc1
```

The CI strips `-rc<N>`, `-beta<N>`, `-alpha<N>` to resolve the upstream tag,
turns the suffix into a Debian-sortable `~rc1` in the package version, marks
the GitHub Release as a prerelease, and dispatches a rebuild of
`odio-apt-repo`.

`watch-upstream.yml` polls `vicrodh/qbz` daily and pushes the tag by itself
when a new upstream release appears.

## Build gates

Every arch fails the build loudly rather than shipping a subtly broken daemon.
All of them run inside the builder, natively, so they need no cross tooling:

- **Slint-free dependency graph** — mirrors upstream's own gate. If a future
  release wires the UI into `qbzd`'s graph, this stops being a small build and
  we find out before `rustc` starts.
- **ARMv6 baseline** (armhf only) — `readelf -A` must report `Tag_CPU_arch: v6`.
  This is a *proxy*: the attribute records the highest architecture of any input
  object, so one hand-written asm file raises the whole binary even when the
  instruction that matters is never executed. It is cheap and it caught the real
  bug, but the property it stands in for is "does this start on an ARM1176",
  which only an execution test answers. Verify a new armhf binary by hand with
  `qemu-arm -cpu arm1176 -L <armhf-sysroot> ./qbzd --version`, and compare
  against `-cpu cortex-a7` to tell a genuine SIGILL from an unrelated failure.
- **glibc floor ≤ 2.36**, so one package per arch covers Raspberry Pi OS
  bookworm *and* trixie.
- **Smoke test** — `qbzd --version` actually executes on the target arch, which
  is also how the shipped shell completions are generated: from the very binary
  that goes into the package.
- The `NEEDED` soname list is printed on every build, to be cross-checked
  against the `depends:` in `packaging/nfpm.yaml`.

## Building locally

```bash
git clone --depth 1 --branch v2.0.2 https://github.com/vicrodh/qbz upstream
# only needed for armhf, and only if binfmt is not already registered:
docker run --privileged --rm tonistiigi/binfmt --install arm
./scripts/build-qbzd-deb.sh --arch armhf --version 2.0.2
```

The checkout must live at `./upstream` — it is part of the docker build
context. Needs docker with buildx, and `nfpm` on the host.

## Installing

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
