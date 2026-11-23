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
- MPD LAN control enabled for phone clients (MALP): `/etc/vika-audio/mpd.local.conf` adds `bind_to_address "0.0.0.0"`, port 6600 answers on the LAN and the MPD handshake was verified from the phone-side network. Local scripts keep using the UNIX socket; the port is not reachable from the internet and has no password (home LAN only). `verify.sh` understands the opt-in listener.
- Bluetooth speaker mode (Pi as A2DP sink for AIMP on a phone/PC) installed: `vika-bt-speaker.service` starts, marks the adapter discoverable/pairable and runs `bluealsa-aplay` to the 3.5 mm jack; `scripts/bt-speaker.sh on|off|status` toggles it. A real phone/PC stream is still to be tested.
- Bluetooth reconnect after host reboot fixed: BlueZ does not page a paired headset by itself, so `vika-bt-autoswitch` also issues `bluetoothctl connect` for paired+trusted audio devices (address discovered on D-Bus, retried every 15 s). Verified by disconnecting the headset: audio moved to analog, the service reconnected it and switched back to Bluetooth automatically. Confirmed with a real reboot: MPD started on analog, the headset was paged and connected about 10 s later, the output switched to Bluetooth and playback continued.
- Bluetooth output autoswitch installed: MPD no longer stays silent after a reboot. `vika-bt-autoswitch.service` enables the BlueALSA output when an audio device connects (verified by disabling both outputs and restarting it: BT was re-enabled and playback resumed) and switches back to analog on disconnect. This fixes the boot race where MPD starts before the headset reconnects.
- AVRCP headset buttons verified: BlueZ exposes the headset as `HD-610 (AVRCP)` (`/dev/input/eventN`); `vika-avrcp-keys.service` maps 163/165/200/201 to `mpc next/prev/toggle`. Pause was confirmed on the hardware. The earlier MPRIS bridge (`vika-avrcp`) is kept as an alternative but is disabled, because BlueZ consumed its commands without delivering them and suppressed the uinput fallback.

## Installation obstacles and fixes

1. Initial Raspbian redirect sent one package download to an unreachable regional mirror. The live Pi Raspbian APT source was changed to `https://archive.raspbian.org/raspbian/`; an original copy was saved under `/var/backups/vika-audio/apt-sources/`. Helper script: `scripts/fix-apt-and-install.sh`.
2. MPD initially failed to autoplay because `mpc play` accepts **1-based** song positions, but `scripts/lib/media-lib.sh` supplied 0. Corrected in commit `ff1807a` and redeployed; playback verified as active after a systemd service restart.
3. Test fake MPC was corrected to mirror the real 1-based behavior; all six scripted suites pass on the T450.
4. Verified against the Debian packaging sources of bluez-alsa 4.3.1-3 (Trixie): the shipped `bluealsa.service` already runs `/usr/bin/bluealsa -S -p a2dp-source -p a2dp-sink`, and `libasound2-plugin-bluez` is the BlueALSA ALSA plugin required for the `bluealsa:DEV=...` device string. Consequence for the A2DP blocker: the drop-in in `bt-a2dp-setup.sh --apply` is only a fallback; the working hypothesis for "Protocol not available" is stale pairing / bluealsa not registered at pairing time — see `docs/BLUETOOTH.md`.

## Still needs physical testing

- Remaining HD-610 buttons: next/prev and volume (same evdev path).
- Bluetooth speaker mode with a real phone/PC running AIMP (pairing, stream, analog output).
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
systemctl is-active bluetooth bluealsa vika-avrcp
journalctl -u bluetooth -b --no-pager | grep -i 'Player registered'
bluetoothctl info                 # expect paired/bonded/trusted/connected
bluealsa-aplay --list-devices     # expect an A2DP (SBC) PCM
```

This file records observed device behavior, not a claim that all USB/offline acceptance tests have passed.
