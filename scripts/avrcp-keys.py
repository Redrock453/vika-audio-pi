#!/usr/bin/env python3
"""AVRCP headset buttons -> MPD, via BlueZ's uinput fallback.

On this hardware BlueZ registers a virtual keyboard named "HD-610 (AVRCP)"
(/dev/input/eventN) and injects key events for headset buttons. A registered
MPRIS player is consulted first, but in practice bluetoothd consumes the
command without delivering it to a dbus-python object, so this service uses
the uinput path that is confirmed to work:

    KEY_NEXTSONG 163, KEY_PREVIOUSSONG 165,
    KEY_PLAYCD 200, KEY_PAUSECD 201, KEY_PLAYPAUSE 164

The device appears with every headset (re)connect and may get a new eventN,
so sysfs is rescanned periodically. No extra packages and no root: the
service runs as vika and reads /dev/input/* through the input group.
"""

import os
import select
import struct
import subprocess
import sys
import time

EV_KEY = 1

# linux/input-event-codes.h
KEY_NEXTSONG = 163
KEY_PREVIOUSSONG = 165
KEY_PLAYPAUSE = 164
KEY_STOPCD = 166
KEY_PLAYCD = 200
KEY_PAUSECD = 201
KEY_PLAY = 207
KEY_REWIND = 168
KEY_FASTFORWARD = 208
KEY_VOLUMEUP = 115
KEY_VOLUMEDOWN = 114

MPD_HOST = os.environ.get("MPD_HOST", "/run/vika-audio/mpd.sock")
EVENT_FMT = "llHHi"
EVENT_SIZE = struct.calcsize(EVENT_FMT)
TOGGLE_DEBOUNCE = 0.6  # seconds; some headsets send PAUSE+PLAY for one press


def log(msg):
    print("avrcp-keys: %s" % msg, file=sys.stderr, flush=True)


def mpc(*args):
    env = dict(os.environ)
    env["MPD_HOST"] = MPD_HOST
    try:
        subprocess.run(
            ["mpc", *args],
            env=env,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=5,
        )
    except Exception as exc:  # noqa: BLE001 - never crash the listener
        log("mpc %s failed: %s" % (" ".join(args), exc))


def action_for(code):
    if code in (KEY_PLAYCD, KEY_PAUSECD, KEY_PLAYPAUSE, KEY_PLAY):
        return "toggle", True
    if code == KEY_NEXTSONG:
        return "next", False
    if code == KEY_PREVIOUSSONG:
        return "prev", False
    if code == KEY_STOPCD:
        return "stop", False
    if code == KEY_VOLUMEUP:
        return "volume", "+5%"
    if code == KEY_VOLUMEDOWN:
        return "volume", "-5%"
    if code == KEY_REWIND:
        return "seek", "-30"
    if code == KEY_FASTFORWARD:
        return "seek", "+30"
    return None, None


def find_avrcp_devices():
    found = {}
    try:
        names = os.listdir("/dev/input")
    except OSError:
        return found
    for entry in names:
        if not entry.startswith("event"):
            continue
        try:
            name = open(
                "/sys/class/input/%s/device/name" % entry, encoding="utf-8"
            ).read().strip()
        except OSError:
            continue
        if "AVRCP" in name:
            path = "/dev/input/" + entry
            try:
                found[path] = open(path, "rb", buffering=0)
                log("listening on %s (%s)" % (path, name))
            except OSError as exc:
                log("cannot open %s: %s" % (path, exc))
    return found


def main():
    fds = {}
    last_toggle = 0.0
    last_scan = 0.0

    while True:
        now = time.monotonic()
        if now - last_scan >= 2.0 or not fds:
            for path, fd in list(fds.items()):
                if os.path.exists(path):
                    continue
                fd.close()
                del fds[path]
            for path, fd in find_avrcp_devices().items():
                fds[path] = fd
            last_scan = now

        if not fds:
            time.sleep(1)
            continue

        try:
            ready, _, _ = select.select(list(fds.values()), [], [], 1.0)
        except InterruptedError:
            continue

        for fd in ready:
            data = fd.read(EVENT_SIZE)
            if not data or len(data) < EVENT_SIZE:
                for path, other in list(fds.items()):
                    if other is fd:
                        other.close()
                        del fds[path]
                        log("device closed: %s" % path)
                        break
                continue
            _sec, _usec, ev_type, code, value = struct.unpack(EVENT_FMT, data)
            if ev_type != EV_KEY or value != 1:
                continue

            action, arg = action_for(code)
            if action is None:
                continue

            if arg == "toggle":
                now = time.monotonic()
                if now - last_toggle < TOGGLE_DEBOUNCE:
                    continue
                last_toggle = now
                log("play/pause")
                mpc("toggle")
            elif action == "seek":
                log("seek %s" % arg)
                mpc("seek", arg)
            elif action == "volume":
                log("volume %s" % arg)
                mpc("volume", arg)
            else:
                log(action)
                mpc(action)


if __name__ == "__main__":
    main()
