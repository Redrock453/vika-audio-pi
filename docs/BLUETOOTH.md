# Bluetooth A2DP (HD-610) on Vika Audio Pi

Status: experimental. Analog 3.5 mm is the primary output and already works.
Bluetooth is optional and not required for MVP.

Last review of this page: 2026-11-23, against bluez-alsa 4.3.1-3 in Debian
Trixie (the version installed on the Pi).

## What "Protocol not available" actually means

```
a2dp-sink profile connect failed: Protocol not available
```

This error comes from `bluetoothd`: **at the moment of the connection nobody
had registered A2DP endpoints (SEPs) with BlueZ**. The headset offers its A2DP
sink, BlueZ has no matching endpoint on the Pi side, so the profile connect
fails. The endpoint registrar is the audio stack — in this project BlueALSA.

**Important correction (verified against Debian packaging sources):** the
`bluealsa.service` unit shipped in Debian Trixie already runs the daemon with
both A2DP profiles:

```
ExecStart=/usr/bin/bluealsa -S -p a2dp-source -p a2dp-sink
```

(the arguments are the upstream build-time default; Debian does not override
them, and `/etc/default/bluez-alsa` ships `OPTIONS=""`). So the earlier
assumption "the package service starts without an explicit `--profile`" was
most likely **wrong**. The drop-in in `scripts/bt-a2dp-setup.sh --apply` is
harmless (it sets the same arguments), but it is a fallback, not the usual
fix. Work through the decision tree below first.

## Decision tree (run on the Pi)

### Step 1 — is bluealsa really up with A2DP profiles?

```sh
systemctl is-active bluealsa.service bluetooth.service
systemctl cat bluealsa.service | grep ExecStart   # must contain -p a2dp-source -p a2dp-sink
journalctl -b -u bluealsa.service --no-pager | tail -30
journalctl -b -u bluetooth.service --no-pager | grep -i -E 'a2dp|sep|endpoint' | tail
```

If `bluealsa.service` is not active: `sudo systemctl enable --now bluealsa`
and reconnect. If it is active but its journal shows registration errors,
restart both in order (`bluealsa` starts after `bluetooth`):

```sh
sudo systemctl restart bluealsa.service
```

A restart of `bluetooth.service` drops all connections and forces clients to
re-register their endpoints — if you had to restart it, restart `bluealsa`
afterwards as well, then reconnect the headset.

### Step 2 — clear the stale pairing

The first pairing attempt happened before/without a working A2DP endpoint
registrar. A device paired under those conditions keeps failing profile
connection even after the audio side is fixed. Remove and re-pair **after**
step 1 is green:

```sh
bluetoothctl devices Paired            # find the HD-610 MAC
bluetoothctl remove XX:XX:XX:XX:XX:XX
bluetoothctl scan on                   # wait for HD-610, then scan off
bluetoothctl pair XX:XX:XX:XX:XX:XX
bluetoothctl trust XX:XX:XX:XX:XX:XX
bluetoothctl connect XX:XX:XX:XX:XX:XX
bluetoothctl info XX:XX:XX:XX:XX:XX    # check UUIDs below
```

In `bluetoothctl info` the headset should list
`0000110b-0000-1000-8000-00805f9b34fb` (AudioSink) and
`0000110d-0000-1000-8000-00805f9b34fb` (A2DP source role on the headset).
If the adapter does not power itself up at boot, set `AutoEnable=true` in the
`[General]` section of `/etc/bluetooth/main.conf` and reboot once.

### Step 3 — raw ALSA test (before MPD)

```sh
bluealsa-aplay --list-pcms             # must list the HD-610 A2DP PCM
aplay -D bluealsa:DEV=XX:XX:XX:XX:XX:XX,PROFILE=a2dp \
      /usr/share/sounds/alsa/Front_Center.wav
```

Sound here proves BlueALSA end-to-end. No sound but no error: check the
headset volume and `--sbc-quality` later; error "Invalid argument"/unknown
PCM: `libasound2-plugin-bluez` (the BlueALSA ALSA plugin) is missing.

### Step 4 — MPD output

Uncomment the BlueALSA block in `/etc/vika-audio/mpd.conf`, put the real MAC
in place of the placeholder, then:

```sh
sudo systemctl restart vika-audio
MPD_HOST=/run/vika-audio/mpd.sock mpc enable "Bluetooth (BlueALSA)"
MPD_HOST=/run/vika-audio/mpd.sock mpc disable "Analog 3.5mm (plughw:0,0)"
```

Then run the F06 acceptance test from `docs/SPEC.md`: three headset
power-off/power-on cycles and one Pi reboot, position kept each time; record
the result in `docs/DEPLOYMENT_STATUS.md`.

### If step 3 works but step 4 fails

MPD opens the BlueALSA PCM via ALSA; if the headset disconnects, MPD keeps
the output disabled until it is re-enabled with `mpc enable`. Check
`MPD_HOST=/run/vika-audio/mpd.sock mpc outputs` and the unit journal.

## Pairing checklist (fresh device)

```sh
bluetoothctl
power on
agent on
default-agent
scan on
pair <MAC>
trust <MAC>
connect <MAC>
```

## Notes

- Do not install PulseAudio or PipeWire just for this. They fight with
  BlueALSA, and Debian's own wiki confirms that with those stacks the same
  "Protocol not available" error means the stack has not registered its A2DP
  endpoints (or needs a restart after codec packages change).
- `libasound2-plugin-bluez` in Trixie is the **BlueALSA** ALSA plugin (same
  source package, bluez-alsa 4.3.1-3) — it is required for the
  `bluealsa:DEV=...` device string and does not conflict with anything.
- Keep the analog output as fallback.
- After a successful long connection + reboot test, record the result in
  `docs/DEPLOYMENT_STATUS.md`.
