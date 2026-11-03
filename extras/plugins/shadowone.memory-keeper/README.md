# Memory Keeper

For laptops that only ever sleep. Long-running programs pile up over days of
uptime; this plugin keeps that in check without a restart:

- **Stops Claude Code sessions left idle**, and brings them back with one click.
- **Frees cold cache** only under real memory pressure, or when you press the button.
- **Shows what holds your memory**, including dev servers that outlived their
  terminal, so you can stop them yourself.

The bar shows available memory (`󰍛 13G`). No root is needed.

## When a session stops

A user timer (`memory-keeper.timer`) checks every 5 minutes while the laptop is
awake. A session stops when it has been idle past the limit, and all of this holds:

- its status is `idle` (never `busy`, never `waiting` for your answer)
- it runs nothing besides MCP servers: no background shell, no unknown child
- it runs in a Herdr terminal, and that tab is not the one on screen
- you have not pressed **Keep** on it

| Memory | When | Stops after |
|---|---|---|
| ok | | 12 h idle |
| low | under 20% available, or swap over 70% | 3 h |
| very low | under 10% available, swap over 85%, or all apps stalled over 20% of the time | 1 h |

All of it can be changed under **Settings** in the panel, and **Auto-stop** turns it off.

Idle time is **awake time**: sleep does not count, so opening the lid in the morning
never stops anything. A session first seen starts at zero, so nothing stops in the
first 12 hours after installing or rebooting.

Stopping is one `SIGTERM`, never a forced kill, and nothing is ever typed into
Claude. The conversation stays on disk. Text sitting in the input box is saved first
and shown on the **Stopped** list: plain terminal text cannot tell a draft from a
grey suggestion, and Claude does not restore it on resume.

## What it deliberately does not do

- No `drop_caches`: it empties every cache on the system, and everything then has to
  be read from disk again. **Free cold cache** asks the kernel for at most half of the
  inactive file cache of your apps (`memory.reclaim` with `swappiness=0`, so nothing
  gets pushed to swap). Available memory barely changes, because Linux already counts
  that cache as available. It only helps when memory is really tight.
- No `swapoff`, no `sysctl` changes, no root.
- Never restarts the shell on its own: the lock screen lives in it. A **Restart**
  button appears once the shell passes 1 GB.
- Never stops a leftover on its own: it may be a dev server you still use.

## Install

```sh
./deploy.sh
omarchy plugin enable shadowone.memory-keeper
systemctl --user enable --now memory-keeper.timer
```

## Command line

```
memkeeper tick [--dry-run]        what the timer runs; --dry-run changes nothing
memkeeper scan --json             everything the panel shows
memkeeper stop <session-id>       stop one session
memkeeper stop-idle               stop every session idle over an hour that may safely stop
memkeeper resume <session-id>     bring a stopped session back
memkeeper keep <session-id> [--off]
memkeeper reclaim                 free cold cache now
memkeeper config [set KEY VALUE]
```

State lives in `~/.local/state/memory-keeper` (`history.jsonl` records every action),
settings in `~/.config/memory-keeper/config.json`.

## Tests

```sh
python3 -IB -m unittest discover -s tests/py
node tests/js/model.test.js && node tests/js/wiring.test.js
```

## Credits

The `memory.reclaim` idea comes from [RAM Manager](https://github.com/fstarlike/omarchy-ram-manager) (MIT).
