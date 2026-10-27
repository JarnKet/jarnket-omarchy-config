# Battery (`shadowone.power`)

Omarchy's bar battery widget and popup (cloned from `omarchy.power` with
`omarchy plugin clone`), plus:

- **Battery care**: a *Conservation mode* switch that stops charging at 80% and
  resumes below 75%, to slow battery wear. A tick on the charge bar marks the
  limit while it is on.
- **Battery health**: capacity left compared with a new battery (e.g. 87%,
  Good ≥ 80 / Fair ≥ 60 / Worn), full and design capacity in Wh, charge cycles
  and wear.

Everything else (power profiles, percentage toggle, `SUPER + CTRL + P`, the
menu's *Battery Percentage* item) works as in the built-in widget, because the
shell routes calls for `omarchy.power` to this clone.

Keys in the popup: `↑`/`↓` move between the conservation switch and the power
profiles, `←`/`→` pick a profile, `Enter` toggles or applies.

For a keybinding, `omarchy-shell omarchy.power toggleConservation` flips the
mode without opening the popup (it reads the current state first), or use the
CLI below.

## How the limit is set

UPower (1.90+) owns the charge limit: `EnableChargeThreshold` on the battery's
`org.freedesktop.UPower.Device`. The active session may call it without a
password (polkit `org.freedesktop.UPower.enable-charging-limit`), UPower
remembers the choice across reboots, and the thresholds come from the
`CHARGE_LIMIT` udev property (UPower's hwdb ships `75,80`).

`bin/battery-conservation` wraps it, and `deploy.sh` links it into
`~/.local/bin`:

```
battery-conservation on | off | toggle | status
battery-conservation --shell    # key<TAB>value lines the popup reads
```

The popup reads it when opened and every 5 s while open; nothing polls while it
is closed.

## Develop

```
node tests/model.test.js
./deploy.sh
```

The shell hot-reloads the plugin on deploy, but Qt's component cache can keep
the old `Panel.qml` (new IPC functions missing, or "Panel.qml: No such file or
directory" in `journalctl --user` and the widget gone from the bar): run
`omarchy restart shell`.

Undo: `omarchy plugin disable shadowone.power` puts the built-in widget back.
