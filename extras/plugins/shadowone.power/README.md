# Battery (`shadowone.power`)

Omarchy's bar battery widget and popup (cloned from `omarchy.power` with
`omarchy plugin clone`), plus:

- **Battery care**: a *Conservation mode* switch that stops charging at 80% and
  resumes below 75%, to slow battery wear. A tick on the charge bar marks the
  limit while it is on.
- **Battery health**: capacity left compared with a new battery (e.g. 87%,
  Good ≥ 80 / Fair ≥ 60 / Worn), full and design capacity in Wh, charge cycles
  and wear.
- **Sleep**: a *Hibernate after long sleep* switch. Closing the lid sleeps
  first, then hibernates after 30 min, 1, 2, 3 or 6 h on battery (or below 5%),
  like Windows Modern Standby. On the charger it keeps sleeping.

Everything else (power profiles, percentage toggle, `SUPER + CTRL + P`, the
menu's *Battery Percentage* item) works as in the built-in widget, because the
shell routes calls for `omarchy.power` to this clone.

Keys in the popup: `↑`/`↓` move between the conservation switch, the
hibernation switch, its delay and the power profiles, `←`/`→` pick a delay or a
profile, `Enter` toggles or applies.

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

## How hibernation is switched

Turning it on makes a 16 GB swapfile in its own Btrfs subvolume (`/swap/swapfile`,
needs 24 GB free), adds the `resume` hook and `resume=`/`resume_offset=` to the
boot entry (rebuilt with `limine-mkinitcpio`, about a minute), and sets lid close
to logind's `sleep` with `SleepOperation=suspend-then-hibernate suspend`: when
the memory in use would not fit in the swapfile, it falls back to plain sleep
instead of refusing. Turning it off removes all of it. The paths match
`omarchy-hibernation-setup`, so Omarchy's own *Hibernate* menu item and
`omarchy-hibernation-remove` keep working.

That needs root, so `bin/hibernate-mode` reads the state without it and runs
`/usr/local/libexec/hibernate-mode-root` through `pkexec` (polkit
`io.github.shadowone.hibernate-mode`, fingerprint or password). The helper only
accepts `on DELAY`, `off` and `delay DELAY`. Install it once; the switch opens a
terminal for this when the helper is missing or changed:

```
sudo bash ~/.config/omarchy/plugins/shadowone.power/root/install.sh
```

```
hibernate-mode on [30min|1h|2h|3h|6h] | off | delay DELAY | status
hibernate-mode --shell          # key<TAB>value lines the popup reads
```

After turning it on, restart once so the new boot entry is in use; the switch
says so until then. When Linux is hibernated, don't boot another OS that
writes to a partition Linux has mounted.

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
