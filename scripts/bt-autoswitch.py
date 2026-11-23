#!/usr/bin/env python3
"""Keep MPD's output in sync with Bluetooth audio devices.

At boot MPD starts before the headset reconnects; opening the BlueALSA
output fails, MPD disables it, and with the analog output disabled by a
previous `audio-out.sh bt` the player ends up with no output at all.

This service watches org.bluez for audio devices (major device class
Audio/Video or an A2DP/AVRCP UUID) and:

  * device connects   -> enable the Bluetooth output, verify that MPD
                         really opened it, then disable analog. If no
                         output was enabled before (the boot case), resume
                         playback.
  * device disconnects-> switch back to analog so playback continues on
                         the jack.
  * no output at all  -> enable analog (offline-first fallback).

It is a no-op while Bluetooth speaker mode is active: in that mode the Pi
receives audio and MPD output switching would fight the incoming stream.
"""

import os
import subprocess
import sys
import time

import dbus
from dbus.mainloop.glib import DBusGMainLoop
from gi.repository import GLib

MPD_HOST = os.environ.get("MPD_HOST", "/run/vika-audio/mpd.sock")
BT_OUTPUT = "Bluetooth (BlueALSA)"
ANALOG_OUTPUT = "Analog 3.5mm (plughw:0,0)"
SPEAKER_UNIT = "vika-bt-speaker.service"
POLL_SECONDS = 2

A2DP_UUIDS = (
    "0000110a-0000-1000-8000-00805f9b34fb",  # Audio Source
    "0000110b-0000-1000-8000-00805f9b34fb",  # Audio Sink
    "0000110e-0000-1000-8000-00805f9b34fb",  # A/V Remote Control
)


def log(msg):
    print("bt-autoswitch: %s" % msg, file=sys.stderr, flush=True)


def mpc(*args):
    env = dict(os.environ)
    env["MPD_HOST"] = MPD_HOST
    try:
        res = subprocess.run(
            ["mpc", *args],
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=5,
        )
        return res.stdout
    except Exception as exc:  # noqa: BLE001 - never crash the watcher
        log("mpc %s failed: %s" % (" ".join(args), exc))
        return ""


def enabled_outputs():
    names = []
    for line in mpc("outputs").splitlines():
        line = line.strip()
        if not line.startswith("Output ") or " is enabled" not in line:
            continue
        # "Output 2 (Bluetooth (BlueALSA)) is enabled"
        start = line.find("(")
        end = line.rfind(")")
        if start >= 0 and end > start:
            names.append(line[start + 1:end])
    return names


def speaker_mode_active():
    try:
        res = subprocess.run(
            ["systemctl", "is-active", "--quiet", SPEAKER_UNIT], timeout=3
        )
        return res.returncode == 0
    except Exception:  # noqa: BLE001
        return False


_BUS = None


def trusted_audio_addresses():
    """Paired+trusted audio devices. BlueZ does not page them on its own;
    some headsets do not reconnect after the host reboots."""
    global _BUS
    if _BUS is None:
        _BUS = dbus.SystemBus()
    manager = dbus.Interface(
        _BUS.get_object("org.bluez", "/"),
        "org.freedesktop.DBus.ObjectManager",
    )
    found = []
    for path, ifaces in manager.GetManagedObjects().items():
        dev = ifaces.get("org.bluez.Device1")
        if dev is None:
            continue
        if not (dev.get("Paired") and dev.get("Trusted")):
            continue
        cls = int(dev.get("Class", 0))
        uuids = [str(u) for u in dev.get("UUIDs", [])]
        audio = ((cls >> 8) & 0x1F) == 0x04 or any(
            u in A2DP_UUIDS for u in uuids
        )
        if audio:
            found.append(str(dev.get("Address", "")))
    return [addr for addr in found if addr]


def audio_devices():
    global _BUS
    if _BUS is None:
        _BUS = dbus.SystemBus()
    manager = dbus.Interface(
        _BUS.get_object("org.bluez", "/"),
        "org.freedesktop.DBus.ObjectManager",
    )
    found = []
    for path, ifaces in manager.GetManagedObjects().items():
        dev = ifaces.get("org.bluez.Device1")
        if dev is None or not dev.get("Connected"):
            continue
        cls = int(dev.get("Class", 0))
        uuids = [str(u) for u in dev.get("UUIDs", [])]
        audio = ((cls >> 8) & 0x1F) == 0x04 or any(
            u in A2DP_UUIDS for u in uuids
        )
        if audio:
            found.append(str(dev.get("Address", path)))
    return found


def switch_to_bt():
    before = enabled_outputs()
    mpc("enable", BT_OUTPUT)
    time.sleep(1.0)
    if BT_OUTPUT not in enabled_outputs():
        log("Bluetooth output did not open; keeping the current output")
        if not enabled_outputs():
            mpc("enable", ANALOG_OUTPUT)
            mpc("volume", "100")
            mpc("play")
        return
    mpc("disable", ANALOG_OUTPUT)
    log("output -> Bluetooth (%s)" % BT_OUTPUT)
    if not before:
        mpc("play")


def switch_to_analog():
    mpc("enable", ANALOG_OUTPUT)
    mpc("volume", "100")
    mpc("disable", BT_OUTPUT)
    log("output -> analog")


def ensure_output():
    if not enabled_outputs():
        mpc("enable", ANALOG_OUTPUT)
        mpc("volume", "100")
        log("no output was enabled; analog fallback enabled")
        mpc("play")


class Watcher:
    MAX_CONNECT_ATTEMPTS = 10
    CONNECT_RETRY_SECONDS = 15

    def __init__(self):
        self.connected = None
        self.connect_attempts = 0
        self.next_connect = time.monotonic() + 5

    def try_connect(self):
        """Ask BlueZ to page trusted audio devices (headsets often stay put
        after a host reboot and wait to be connected)."""
        if self.connect_attempts >= self.MAX_CONNECT_ATTEMPTS:
            return
        now = time.monotonic()
        if now < self.next_connect:
            return
        self.connect_attempts += 1
        self.next_connect = now + self.CONNECT_RETRY_SECONDS
        for addr in trusted_audio_addresses():
            log("connect attempt %d: %s" % (self.connect_attempts, addr))
            subprocess.Popen(
                ["bluetoothctl", "connect", addr],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                start_new_session=True,
            )

    def tick(self):
        if speaker_mode_active():
            return True
        try:
            devices = audio_devices()
        except Exception as exc:  # noqa: BLE001 - BlueZ may be restarting
            log("cannot query BlueZ: %s" % exc)
            return True

        now = bool(devices)
        if self.connected is None:
            self.connected = now
            if now:
                log("audio device already connected: %s" % ",".join(devices))
                switch_to_bt()
            else:
                ensure_output()
        elif now != self.connected:
            self.connected = now
            if now:
                log("audio device connected: %s" % ",".join(devices))
                self.connect_attempts = 0
                switch_to_bt()
            else:
                log("audio device disconnected")
                switch_to_analog()

        if not now:
            self.try_connect()
        return True


def main():
    DBusGMainLoop(set_as_default=True)
    watcher = Watcher()
    GLib.timeout_add_seconds(1, watcher.tick)
    log("started; MPD_HOST=%s" % MPD_HOST)
    GLib.MainLoop().run()


if __name__ == "__main__":
    main()
