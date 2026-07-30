//! Guards the `time_t` ABI the builder depends on.
//!
//! Debian's 64-bit time_t transition landed in trixie, so libasound there writes
//! a 16-byte `struct timespec`. `alsa::timespec` is alsa-sys' own, sized from a
//! build-time measurement of `sizeof(snd_htimestamp_t)` against the rootfs's
//! ALSA headers, while `libc::timespec` stays 8 bytes on
//! `arm-unknown-linux-gnueabihf`. Sized wrong, the 16-byte write lands 8 bytes
//! past the caller's slot and overwrites its saved `lr`:
//! `snd_pcm_status_get_htstamp` returns into address 0.
//!
//! What can regress silently is that measurement, not the ABI: a rootfs whose
//! ALSA headers disagree with its libasound, or an alsa-sys bump that drops the
//! probe. So this asserts the width the crate settled on and then makes the
//! call a wrong answer crashes on, minutes into the build rather than hours.

use std::mem::size_of;

use alsa::pcm::{Access, Format, HwParams, PCM};
use alsa::{Direction, ValueOr};

fn main() {
    let width = size_of::<alsa::timespec>();
    println!(
        "alsa::timespec: {width} bytes; libc::timespec: {} bytes",
        size_of::<libc::timespec>()
    );
    assert_eq!(
        width, 16,
        "alsa-sys sized its timespec at {width} bytes, so it did not measure a \
         64-bit time_t in this rootfs. Against a trixie libasound this build \
         would smash its stack inside snd_pcm_status_get_htstamp."
    );

    // `null` is internal to libasound: no hardware, no dlopened plugin module,
    // so this runs in any container.
    let pcm = PCM::new("null", Direction::Playback, false).expect("open the null PCM");
    {
        let hwp = HwParams::any(&pcm).expect("hw params");
        hwp.set_channels(2).expect("channels");
        hwp.set_rate(48000, ValueOr::Nearest).expect("rate");
        hwp.set_format(Format::s16()).expect("format");
        hwp.set_access(Access::RWInterleaved).expect("access");
        pcm.hw_params(&hwp).expect("apply hw params");
    }
    pcm.prepare().expect("prepare");

    // The call that crashed on a Pi 1. It has to run, not merely compile: the
    // assert above covers our side of the ABI, this covers the pairing with
    // whatever libasound the rootfs actually ships.
    let ts = pcm.status().expect("status").get_htstamp();

    println!("htstamp {}.{:09}", ts.tv_sec, ts.tv_nsec);
}
