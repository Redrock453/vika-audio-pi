# Raspberry Pi deployment status — 2026-11-23

## Confirmed on actual hardware

- Target: Raspberry Pi 3 Model A+, Raspberry Pi OS Lite / Raspbian 13 Trixie 32-bit, user `vika`.
- MPD (`0.24.4-1`) and MPC (`0.35-1+b1`) installed successfully.
- `vika-audio.service` is **enabled** and **active**. MPD plays locally from `/home/vika/media` through ALSA analog `plughw:0,0`; no streaming from T450 is needed.
- `vika-audio-usb.timer` is **enabled** and **active**.
- MPD reported **playing** with **272 items** in its queue. The library is stored on the Pi microSD; no audio files are kept in Git.
- Analog ALSA `PCM` volume was set to **100%** (+4.00 dB displayed by ALSA). MPD volume was set to **100%**. This high gain can distort; reduce if necessary. Mixer persistence across power cycles has not been tested.
- MPD service is configured without network-online dependencies and only exposes a local Unix socket. Actual unplugged Wi-Fi boot test is still pending.
- SSH public-key login for `vika` was already working; administrative operations used the owner's interactive `sudo` authorization.
- Bluetooth A2DP verified: the **HD-610** headset is paired, bonded and trusted; BlueALSA exposes an `A2DP (SBC) S16_LE 48000 Hz` PCM and `aplay -D bluealsa:DEV=<MAC>,PROFILE=a2dp /usr/share/sounds/alsa/Front_Center.wav` played the sample successfully. The headset reconnected automatically after a reboot. MPD has a second ALSA output, `Bluetooth (BlueALSA)`, targeting the same device; `scripts/audio-out.sh bt|analog` selects the output with `mpc enable/disable`, and MPD playback was verified through BlueALSA (PCM opened, position advancing, no ALSA errors).
- GPIO contact controls verified: `vika-audio-gpio.service` is enabled and active; shorting GPIO27 -> next, GPIO22 -> prev and GPIO17 -> toggle changes playback as expected. Buttons were confirmed working by the operator.

## Installation obstacles and fixes

1. Initial Raspbian redirect sent one package download to an unreachable regional mirror. The live Pi Raspbian APT source was changed to `https://archive.raspbian.org/raspbian/`; an original copy was saved under `/var/backups/vika-audio/apt-sources/`. Helper script: `scripts/fix-apt-and-install.sh`.
2. MPD initially failed to autoplay because `mpc play` accepts **1-based** song positions, but `scripts/lib/media-lib.sh` supplied 0. Corrected in commit `ff1807a` and redeployed; playback verified as active after a systemd service restart.
3. Test fake MPC was corrected to mirror the real 1-based behavior; all six scripted suites pass on the T450.

## Still needs physical testing

- Cold power-on automatic playback with **no Wi-Fi** available.
- USB flash insertion, filename-ordered playback, safe removal, and return to microSD playlist on the actual Pi.
- Inline wired JBL button events; the built-in 3.5 mm jack cannot receive them (a separate microphone/button interface is still needed).

## Verification commands (run on Pi)

```sh
systemctl is-enabled vika-audio.service vika-audio-usb.timer
systemctl is-active vika-audio.service vika-audio-usb.timer
MPD_HOST=/run/vika-audio/mpd.sock mpc status
amixer -c 0 sget PCM
/usr/local/lib/vika-audio/usb-media.sh status

# Bluetooth (optional output)
systemctl is-active bluetooth bluealsa
bluetoothctl info                 # expect paired/bonded/trusted/connected
bluealsa-aplay --list-devices     # expect an A2DP (SBC) PCM
```

This file records observed device behavior, not a claim that all USB/offline acceptance tests have passed.
