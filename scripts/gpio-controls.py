#!/usr/bin/env python3
"""GPIO-to-MPD controller: physical pins 13/14 next, 15/14 previous, 11/9 pause."""
import logging
import os
import subprocess
import threading
from gpiozero import Button
from gpiozero.pins.lgpio import LGPIOFactory
from signal import pause

LOG = logging.getLogger("vika-gpio")
MPD_HOST = os.environ.get("MPD_HOST", "/run/vika-audio/mpd.sock")
_lock = threading.Lock()

def mpc(action: str) -> None:
    if not _lock.acquire(blocking=False):
        return
    try:
        result = subprocess.run(
            ["/usr/bin/mpc", action],
            env={**os.environ, "MPD_HOST": MPD_HOST},
            timeout=6, capture_output=True, text=True, check=False,
        )
        if result.returncode:
            LOG.error("%s failed: %s", action, (result.stderr or result.stdout).strip())
        else:
            LOG.info("GPIO -> mpc %s", action)
    except Exception:
        LOG.exception("Cannot run MPC")
    finally:
        _lock.release()

def main() -> None:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(name)s %(levelname)s %(message)s")
    controls = ((27, "next"), (22, "prev"), (17, "toggle"))
    factory = LGPIOFactory(chip=0)
    buttons = []
    for gpio, action in controls:
        button = Button(gpio, pull_up=True, bounce_time=0.12, pin_factory=factory)
        button.when_pressed = lambda command=action: mpc(command)
        buttons.append(button)
        LOG.info("ready GPIO%d -> %s", gpio, action)
    try:
        pause()
    finally:
        for button in buttons:
            button.close()
        factory.close()

if __name__ == "__main__":
    main()
