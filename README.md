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
| depends | ALSA + fontconfig/freetype/png/bz2/expat/zlib | ALSA + JACK |
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

### Why armhf cannot be cross-compiled

Cross-compiling from a Debian amd64 image with
`arm-unknown-linux-gnueabihf` + `-march=armv6` was tried and rejected: it
produces an ELF tagged `Tag_CPU_arch=v7`, which would `SIGILL` on a Pi 1 /
Zero. Of 368 objects in the link, exactly one crate is responsible — `ring`.
Its OpenSSL-derived perlasm (`sha256-armv4`, `chacha-armv4`, `armv4-mont`,
`ghash-armv4`, `bsaes-armv7`, `vpaes-armv7`) selects code paths on
`__ARM_ARCH`, which comes from the assembler's default `-march`, and those
files sit on unconditional code paths — not behind the NEON runtime check.

- Debian `arm-linux-gnueabihf-gcc` → `__ARM_ARCH 7` → v7 objects.
- Raspberry Pi OS `gcc (Raspbian 12.2.0)` → `__ARM_ARCH 6`, `__ARM_ARCH_6__`
  → the ARMv4/v6 branches, genuinely ARMv6 objects.

That is the whole reason for the QEMU + Pi OS rootfs route. A `readelf -A`
gate in the Dockerfile asserts it, so a regression cannot ship silently.

Also note `uname -m` reports `armv7l` inside an armv6 container under QEMU, so
rustup's host detection has to be overridden explicitly or it installs an
armv7 toolchain and the binary is v7 again.

The desktop `qbz` binary is out of scope here: its generated `qbz_ui` crate is
one ~1.6M-line module needing ~30 GB for a single `rustc`. `qbzd` is the
Slint-free column of the workspace — 381 crates whose entire native surface is
`alsa-sys`, `jack-sys` and a bundled `libsqlite3-sys`, with no OpenSSL
(`reqwest` uses rustls/ring), no libdbus (`zbus` is pure Rust), and no bindgen
or cmake anywhere in the graph.

## Patches

`patches/*.patch` holds the minimum needed to make the upstream tree build for
a 32-bit target. Upstream builds this workspace for x86_64 and aarch64 only, so
nothing there exercises 32-bit portability:

- `0001-qbz-audio-use-alsa-pcm-Frames-for-buffer-sizes.patch` —
  `HwParams::set_buffer_size_near` takes `alsa::pcm::Frames`, i.e. `c_long`:
  i64 on 64-bit, **i32** on 32-bit. Three `as i64` casts in
  `qbz-audio/src/alsa_direct.rs` therefore fail with six `E0308`s on armhf.
  Casting to `alsa::pcm::Frames` is a no-op on 64-bit and correct on 32-bit
  (every value is a sample rate divided by 2..8, so at most 96000).

Patches are applied to **every** arch, not just armhf, so all three packages
are built from identical source. A patch that no longer applies **fails the
build** rather than being skipped — that means either upstream fixed it (delete
the patch) or the code moved (rewrite it). The one benign case, the change
already being present upstream, is detected by a reverse-apply check and
skipped with a log line.

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
