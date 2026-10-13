#!/bin/bash
# Managed by Omalang — cycles to the next keyboard layout on physical keyboards.
set -euo pipefail

hyprctl -j devices | python3 -c '
import json, subprocess, sys

skip_prefixes = (
    "hl-virtual-keyboard",
    "power-button",
    "sleep-button",
    "lid-switch",
    "video-bus",
)
skip_substrings = ("consumer-control", "system-control")

devices = json.load(sys.stdin)
for keyboard in devices.get("keyboards", []):
    name = keyboard.get("name") or ""
    if name.startswith(skip_prefixes) or any(part in name for part in skip_substrings):
        continue
    if "," not in str(keyboard.get("layout") or ""):
        continue
    subprocess.run(["hyprctl", "switchxkblayout", name, "next"], check=False)
'
