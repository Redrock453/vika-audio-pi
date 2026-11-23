#!/usr/bin/env python3
"""AVRCP (headset buttons) -> MPD bridge for Vika Audio Pi.

BlueZ's AVRCP Target forwards headset button commands (play/pause/next/prev/
stop) to the single player registered through org.bluez.Media1.RegisterPlayer.
That object must implement org.mpris.MediaPlayer2.Player. This script exports
such an object and translates its methods into `mpc` calls against the local
MPD UNIX socket.

Run as root (system service); it does not need the network.
"""

import os
import re
import subprocess
import sys

import dbus
import dbus.service
import dbus.mainloop.glib
from gi.repository import GLib

SERVICE = "org.bluez"
ADAPTER_IFACE = "org.bluez.Adapter1"
MEDIA_IFACE = "org.bluez.Media1"
PLAYER_IFACE = "org.mpris.MediaPlayer2.Player"
PROPS_IFACE = "org.freedesktop.DBus.Properties"
OBJ_PATH = dbus.ObjectPath("/org/vika/mpris")

MPD_HOST = os.environ.get("MPD_HOST", "/run/vika-audio/mpd.sock")


def log(msg):
    print("avrcp-mpd: %s" % msg, file=sys.stderr, flush=True)


def mpc(*args):
    env = dict(os.environ)
    env["MPD_HOST"] = MPD_HOST
    try:
        res = subprocess.run(
            ["mpc", *args],
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=5,
        )
        return res.stdout
    except Exception as exc:  # noqa: BLE001 - never crash the bridge
        log("mpc %s failed: %s" % (" ".join(args), exc))
        return ""


def to_us(value):
    try:
        parts = [int(x) for x in value.split(":")]
    except Exception:  # noqa: BLE001
        return 0
    seconds = 0
    for part in parts:
        seconds = seconds * 60 + part
    return seconds * 1000000


def parse_status(text):
    state, elapsed, total, title = "Stopped", 0, 0, ""
    lines = [line for line in text.splitlines() if line.strip()]
    for index, line in enumerate(lines):
        match = re.search(r"\[(playing|paused|stopped)\]", line)
        if not match:
            continue
        state = match.group(1).capitalize()
        times = re.search(r"(\d+:\d+)/(\d+:\d+)", line)
        if times:
            elapsed = to_us(times.group(1))
            total = to_us(times.group(2))
        if index > 0:
            title = lines[index - 1]
        break
    return state, elapsed, total, title


class MprisPlayer(dbus.service.Object):
    def __init__(self, bus):
        super().__init__(bus, OBJ_PATH)
        self.bus = bus
        self.state = "Stopped"
        self.position = 0
        self.length = 0
        self.title = ""

    # --- org.mpris.MediaPlayer2.Player methods -------------------------
    @dbus.service.method(PLAYER_IFACE)
    def Play(self):
        log("method Play")
        mpc("play")

    @dbus.service.method(PLAYER_IFACE)
    def Pause(self):
        log("method Pause")
        mpc("pause")

    @dbus.service.method(PLAYER_IFACE)
    def PlayPause(self):
        log("method PlayPause")
        mpc("toggle")

    @dbus.service.method(PLAYER_IFACE)
    def Stop(self):
        log("method Stop")
        mpc("stop")

    @dbus.service.method(PLAYER_IFACE)
    def Next(self):
        log("method Next")
        mpc("next")

    @dbus.service.method(PLAYER_IFACE)
    def Previous(self):
        log("method Previous")
        mpc("prev")

    @dbus.service.method(PLAYER_IFACE, in_signature="x", out_signature="x")
    def Seek(self, offset):
        mpc("seek", "%+d" % int(int(offset) / 1000000))
        return dbus.Int64(0)

    @dbus.service.method(PLAYER_IFACE, in_signature="ox", out_signature="")
    def SetPosition(self, track, position):
        mpc("seek", str(int(int(position) / 1000000)))

    @dbus.service.method(PLAYER_IFACE, in_signature="s", out_signature="")
    def OpenUri(self, uri):
        pass

    # --- org.freedesktop.DBus.Properties ------------------------------
    def _metadata(self):
        return dbus.Dictionary(
            {
                "mpris:trackid": dbus.ObjectPath("/org/vika/track/0"),
                "xesam:title": dbus.String(self.title),
                "xesam:artist": dbus.Array([], signature="s"),
                "xesam:album": dbus.String(""),
                "mpris:length": dbus.Int64(self.length),
            },
            signature="sv",
        )

    def _props(self):
        return {
            "PlaybackStatus": dbus.String(self.state),
            "LoopStatus": dbus.String("None"),
            "Rate": dbus.Double(1.0),
            "Shuffle": dbus.Boolean(False),
            "Metadata": self._metadata(),
            "Volume": dbus.Double(1.0),
            "Position": dbus.Int64(self.position),
            "MinimumRate": dbus.Double(1.0),
            "MaximumRate": dbus.Double(1.0),
            "CanGoNext": dbus.Boolean(True),
            "CanGoPrevious": dbus.Boolean(True),
            "CanPlay": dbus.Boolean(True),
            "CanPause": dbus.Boolean(True),
            "CanSeek": dbus.Boolean(True),
            "CanControl": dbus.Boolean(True),
        }

    @dbus.service.method(PROPS_IFACE, in_signature="ss", out_signature="v")
    def Get(self, interface, prop):
        return self._props().get(prop, dbus.String(""))

    @dbus.service.method(PROPS_IFACE, in_signature="s", out_signature="a{sv}")
    def GetAll(self, interface):
        return dbus.Dictionary(self._props(), signature="sv")

    @dbus.service.method(PROPS_IFACE, in_signature="ssv", out_signature="")
    def Set(self, interface, prop, value):
        pass

    @dbus.service.signal(PROPS_IFACE, signature="sa{sv}as")
    def PropertiesChanged(self, interface, changed, invalidated):
        pass

    def refresh(self):
        state, pos, total, title = parse_status(mpc("status"))
        changed = {}
        if state != self.state:
            self.state = state
            changed["PlaybackStatus"] = dbus.String(state)
        if pos != self.position:
            self.position = pos
            changed["Position"] = dbus.Int64(pos)
        if total != self.length or title != self.title:
            self.length = total
            self.title = title
            changed["Metadata"] = self._metadata()
        if changed:
            self.PropertiesChanged(
                PLAYER_IFACE,
                dbus.Dictionary(changed, signature="sv"),
                dbus.Array([], signature="s"),
            )
        return True


def find_adapter(bus):
    manager = dbus.Interface(
        bus.get_object(SERVICE, "/"), "org.freedesktop.DBus.ObjectManager"
    )
    for path, ifaces in manager.GetManagedObjects().items():
        if ADAPTER_IFACE in ifaces:
            return dbus.ObjectPath(path)
    return None


class Bridge:
    def __init__(self, bus, player):
        self.bus = bus
        self.player = player
        self.registered = False

    def register(self):
        if self.registered:
            return False
        adapter = find_adapter(self.bus)
        if adapter is None:
            log("no Bluetooth adapter yet; will retry")
            return True
        media = dbus.Interface(self.bus.get_object(SERVICE, adapter), MEDIA_IFACE)
        try:
            media.RegisterPlayer(OBJ_PATH, {})
            self.registered = True
            log("registered MPRIS player on %s" % adapter)
            return False
        except dbus.exceptions.DBusException as exc:
            log("RegisterPlayer failed: %s" % exc)
            return True

    def on_owner_changed(self, owner):
        # BlueZ restarted: the player registration is gone.
        self.registered = False
        if owner:
            log("org.bluez owner changed; re-registering soon")
            GLib.timeout_add_seconds(3, self.register)


def main():
    dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
    bus = dbus.SystemBus()
    player = MprisPlayer(bus)
    bridge = Bridge(bus, player)

    GLib.timeout_add_seconds(2, bridge.register)
    GLib.timeout_add_seconds(1, player.refresh)
    bus.watch_name_owner(SERVICE, bridge.on_owner_changed)

    log("started; MPD_HOST=%s" % MPD_HOST)
    GLib.MainLoop().run()


if __name__ == "__main__":
    main()
