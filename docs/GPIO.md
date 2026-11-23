# GPIO contacts instead of push-buttons

> **Status: verified on hardware (2026-11-23).** All three contacts work on the Pi 3 A+ (`vika-audio-gpio.service` enabled and active).

Raspberry Pi 3 Model A+ 40-pin header. Numbers below are physical header pin numbers, not BCM GPIO numbers.

| Briefly connect physical pins | Action |
| --- | --- |
| 13 (GPIO27) and 14 (GND) | Next track |
| 15 (GPIO22) and 14 (GND) | Previous track |
| 11 (GPIO17) and 9 (GND) | Pause/play |

To test without a button, briefly bridge only the chosen pair with an insulated jumper or a paperclip and release. Do not touch other pins, especially 3.3 V or 5 V. Disconnect power when installing permanent wires. Use insulated leads if possible.

The systemd service runs gpiozero with input pull-up and debounce and sends commands via the local MPD Unix socket. Offline operation: no Wi-Fi required. The wired JBL jack does not receive inline button signals.

Install after MPD using:
    sudo install -m 0755 scripts/gpio-controls.py /usr/local/lib/vika-audio/gpio-controls.py
    sudo install -m 0644 systemd/vika-audio-gpio.service /etc/systemd/system/vika-audio-gpio.service
    sudo systemctl daemon-reload
    sudo systemctl enable --now vika-audio-gpio.service

Prerequisite: user `vika` must be in the `gpio` group to open `/dev/gpiochip0`
(installer >= 2026-11-23 adds it; check manually with `groups vika | grep gpio`,
otherwise: `sudo usermod -aG gpio vika` and log in again).

Verify:
    systemctl is-active vika-audio-gpio.service
    journalctl -u vika-audio-gpio -n 15 --no-pager
