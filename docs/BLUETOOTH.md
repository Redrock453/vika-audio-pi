# Bluetooth A2DP (HD-610) on Vika Audio Pi

Status: experimental. Analog 3.5 mm is the primary output and already works.
Bluetooth is optional and not required for MVP.

## Known problem

Previously observed:

```
a2dp-sink profile connect failed: Protocol not available
```

This almost always means the BlueALSA daemon did not register the A2DP
profiles with BlueZ. On Raspberry Pi OS Lite + `bluez-alsa-utils` the
package service often starts without an explicit `--profile`.

## Quick fix

On the Pi:

```sh
cd ~/vika-audio-pi
./scripts/bt-a2dp-setup.sh          # diagnose
sudo ./scripts/bt-a2dp-setup.sh --apply
```

The script installs a systemd drop-in that forces:

```
ExecStart=/usr/bin/bluealsa -S --profile=a2dp-source --profile=a2dp-sink
```

Then restart and re-pair.

## Pairing (once)

```sh
bluetoothctl
power on
agent on
default-agent
scan on
# wait for HD-610
pair <MAC>
trust <MAC>
connect <MAC>
```

## Test playback

```sh
bluealsa-aplay --list-devices
aplay -D bluealsa:DEV=<MAC>,PROFILE=a2dp /usr/share/sounds/alsa/Front_Center.wav
```

If that works, uncomment the BlueALSA output block in `/etc/vika-audio/mpd.conf`
and switch with `mpc enable/disable`.

## Notes

- Do not install PulseAudio or PipeWire just for this. They fight with BlueALSA.
- Keep the analog output as fallback.
- After a successful long connection + reboot test, record the result in
  `docs/DEPLOYMENT_STATUS.md`.
