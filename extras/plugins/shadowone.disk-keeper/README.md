# Disk Keeper

An Omarchy bar widget that keeps the root disk from filling up.

- **Bar:** free space on `/` (`󰋊 26G`). Turns red below the warning threshold (20 GB by default) and shows an alert icon below the critical one (10 GB).
- **Notifications:** sent when the level gets worse; a critical one repeats at most every 6 hours. With Omarchy's own notifications a click opens the panel. omapager only runs allowlisted click commands, so there you click the disk icon instead.
- **Panel**, with three tabs:
  - **Clean up:** developer caches (yay, npm, npx, pnpm, mise, bun…), app caches (Brave, IntelliJ, VS Code, Claude Desktop, only while the app is closed), downloaded tools, system items (old packages, journal, crash dumps, snapshots), Docker, old Downloads and the Trash.
  - **Explore:** the biggest folders and files in `$HOME`. You can move them to the Trash, open them, or add them to a keep list.
  - **Projects:** `node_modules`, `.next`, `.turbo`, `dist`… in `~/Projects` and `~/Work`.

## Keys

| Key | Action |
|---|---|
| `j` / `k` / arrows | Move |
| `Space` | Select |
| `Enter` / `l` | Open details |
| `h` | Close details |
| `Tab` / `1` `2` `3` | Switch tabs |
| `c` or `x` | Clean the selection |
| `d` | Preview (dry run): see what would be removed, nothing is deleted |
| `r` | Rescan |
| `Esc` | Close |
| `x` (Explore) | Move to Trash |
| `o` (Explore) | Open |
| `p` (Explore) | Keep |
| `m` (Projects) | Measure precisely, with btrfs exclusive sizes |

Toggle the panel from a keybind with `omarchy-shell shell toggle shadowone.disk-keeper`.

## Safety

- **The panel never sends paths.** It sends `category:key`. The backend rebuilds the candidate list at clean time and only acts on keys it finds there.
- **Deletes never follow symlinks.** Every path component is opened with `O_NOFOLLOW` from `$HOME`. The target is renamed to a tombstone, then removed with `shutil.rmtree(dir_fd=…)`.
- **Things in use are skipped:** anything a running process uses (cwd, exe, open files, maps), and caches of apps that are running.
- **Build folders inside git need git's confirmation:** they must be ignored and contain no tracked file. Outside git, only always-generated names qualify, and only next to a project file.
- **Explore and old Downloads never delete.** They only move to the Trash.
- **Docker:** containers are never pruned, and volumes are never pruned in bulk. Unused volumes are removed one by one by name, after a second confirmation.
- **Root work** goes through `/usr/local/libexec/diskkeeper-root`, through `pkexec` with `auth_admin`. All system items of one clean share a single fingerprint prompt. The helper accepts only a fixed list of tokens.
- **Nothing is written into the plugin folder.** The shell reloads every plugin on any change there. Python always runs with `-IB`.

## Files

| Path | Holds |
|---|---|
| `~/.config/diskkeeper/config.json` | Keep list, project roots, ages and sizes |
| `~/.local/state/diskkeeper/` | `scan.json`, `projects.json`, `history.jsonl`, `jobs/` |
| `/usr/local/libexec/diskkeeper-root` + `/usr/share/polkit-1/actions/io.github.shadowone.diskkeeper.policy` | The root helper and its policy |

## Setup

```sh
ln -sf ~/.config/omarchy/plugins/shadowone.disk-keeper/bin/diskkeeper ~/.local/bin/diskkeeper
sudo bash ~/.config/omarchy/plugins/shadowone.disk-keeper/root/install.sh   # once, for the System items
```

`root/uninstall.sh` removes the helper and policy again.

## Command line

```sh
diskkeeper status
diskkeeper scan
diskkeeper clean --dry-run yay-builds npm-cache
diskkeeper projects
diskkeeper explore --path .cache
diskkeeper history
```

## Development

The source lives in `~/Projects/disk-keeper`. `./deploy.sh` copies it into the plugin folder.

- **After adding a new QML file:** run `omarchy restart shell`. Never use `omarchy refresh shell`, because it resets `shell.json`.
- **Tests:**

  ```sh
  python3 -IB -m unittest discover -s tests/py -t tests/py
  node tests/js/model.test.js && node tests/js/wiring.test.js
  ```
