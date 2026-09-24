# Omarchy configuration

My Omarchy desktop: Hyprland config, terminals, the shell bar layout, 50+
shell plugins, package lists and a few custom extras. Captured with
[Omarchy Synchro](https://github.com/harel/omarchy-synchro). Review every diff
before committing.

## Branches

| Branch   | Use it for | What's different |
|----------|------------|------------------|
| `main`   | Desktop / plugged-in machines | Full setup, every plugin on |
| `laptop` | Running on battery | Battery-heavy plugins turned off (see below) |

Plugins turned off on `laptop`, and why (measured on a T14s Gen 6 AMD):

| Plugin | Cost when on |
|--------|--------------|
| `io.github.chris.snitch` | ~40% of a CPU core, all the time |
| `onlyvishesh.power-manager` | Starts 2 extra shell processes every 5 s |
| `meviusisback.mouse-settings`, `ilysorc.pointer-feel` | Constant status polling |
| `io.github.pjgeutjens.seismic-atlas`, `costafot.markets` | Network polling |
| `io.github.tymurbogach.modular-hw-monitor` | ~7 processes per second |
| `dev.reuk.ports` | Repeated port scans |
| `io.github.tallsam.navbar-cat` | Redraws the bar 30 times a second |

Every plugin is still listed in `manifests/plugins.json` on both branches;
the turned-off ones just have `"enabled": false`.

## What's in here

```text
portable/home/     Files copied into ~ on any machine (hypr, terminals, hooks, menu, ...)
device/omarchy/    Monitor + input config for the ThinkPad (hostname "omarchy")
manifests/
  shell.json       Bar layout, widget settings, plugin list, idle timers
  plugins.json     Every plugin: git source, revision, enabled, placement
  native.txt       pacman packages
  aur.txt          AUR packages
policy/            Synchro allowlist: which paths get captured
extras/
  plugins/         Plugins I wrote (not on GitHub): shadowone.top-bar
  patches/         Local fixes to third-party plugins
```

Not saved here (on purpose): SSH/GPG keys, browser profiles, passwords,
tokens, keyrings, caches.

---

## Set up a new PC

Takes about 30 minutes, mostly package downloads. Run the steps in order.

### 1. Install Omarchy

Install Omarchy from [omarchy.org](https://omarchy.org), log in, and run
`omarchy update` once so the shell is up to date.

### 2. Sign in to GitHub and clone this repo

The repo is private and this setup uses HTTPS through the `gh` CLI (no SSH
key).

```bash
omarchy pkg add github-cli
gh auth login            # GitHub.com → HTTPS → log in with browser
gh auth setup-git
mkdir -p ~/Work
git clone https://github.com/JarnKet/jarnket-omarchy-config.git ~/Work/omarchy-config
cd ~/Work/omarchy-config
git switch laptop        # or stay on main for a desktop
```

### 3. Install packages

```bash
cd ~/Work/omarchy-config
omarchy pkg add $(cat manifests/native.txt)
omarchy pkg aur add $(cat manifests/aur.txt)
```

If one package is no longer in the repos, the whole command stops. Remove that
name from the list, or install the rest in smaller groups.

### 4. Install Omarchy Synchro

```bash
omarchy plugin add https://github.com/harel/omarchy-synchro.git --yes
S=~/.config/omarchy/plugins/harel.omarchy-synchro/bin/omarchy-synchro
$S config select ~/Work/omarchy-config
$S seed --stage check     # confirms Omarchy + repo are compatible
```

### 5. Restore config files

Always preview first. Synchro backs up any file it replaces.

```bash
$S restore                # preview: lists files that would change
$S restore --apply        # copy portable/ into ~
```

The monitor and input files in `device/omarchy/` only restore when the new
PC's hostname is `omarchy`. On other hardware, set up monitors fresh
(`hyprmoncfg`) and copy `device/omarchy/home/.config/hypr/input.lua` by hand
if you want the same touchpad settings:

```bash
$S restore --include-device          # preview, same hostname only
$S restore --include-device --apply
```

### 6. Install the plugins

Clone every plugin that's turned on in this branch from its saved git source:

```bash
cd ~/Work/omarchy-config
jq -r '.plugins[] | select(.enabled and .source) | .source' manifests/plugins.json |
  while read -r url; do omarchy plugin add "$url" --yes; done
```

To install every plugin, including the ones turned off on `laptop`, drop
`.enabled and` from the filter. `plugins.json` also records the exact
`revision` each plugin was at, in case a newer version breaks.

Then install my own Top Bar plugin, which isn't on GitHub:

```bash
cp -r extras/plugins/shadowone.top-bar ~/.config/omarchy/plugins/
mkdir -p ~/.local/bin
ln -sf ~/.config/omarchy/plugins/shadowone.top-bar/omarchy-topbar ~/.local/bin/omarchy-topbar
```

### 7. Apply the bar layout

This step turns the plugins on and puts every widget in its place.

```bash
cp ~/.config/omarchy/shell.json ~/.config/omarchy/shell.json.bak.$(date +%s)
cp manifests/shell.json ~/.config/omarchy/shell.json
omarchy restart shell
omarchy-topbar list       # check the second bar came up
```

`shell.json` also keeps `omarchy.notifications` disabled so it doesn't fight
omapager (running both gives blank notification toasts).

### 8. Reapply local plugin fixes

Omarchy 4.0.4 broke two plugins; these patches fix them. Run them again after
any `omarchy plugin update` of these plugins.

```bash
cd ~/.config/omarchy/plugins/ashuttl.linecast && git apply ~/Work/omarchy-config/extras/patches/ashuttl.linecast.patch
# navbar-cat is off on the laptop branch; only needed if you turn it on:
cd ~/.config/omarchy/plugins/io.github.tallsam.navbar-cat && git apply ~/Work/omarchy-config/extras/patches/io.github.tallsam.navbar-cat.patch
```

- **linecast:** its panel couldn't be closed (Esc, click, IPC).
- **navbar-cat:** assets failed to load and its size setting was ignored.

### 9. Plugin extra setup steps

Some plugins need a one-time step after cloning:

| Plugin | Step | Branch |
|--------|------|--------|
| `beam` | `~/.config/omarchy/plugins/beam/install.sh` | both |
| `io.github.chris.snitch` | `cd ~/.config/omarchy/plugins/io.github.chris.snitch && ./build.sh` (Rust) | main only |
| `ilysorc.pointer-feel` | `cd ~/.config/omarchy/plugins/ilysorc.pointer-feel && ./install.sh` | main only |
| `bredda.localsend` | `cd ~/.config/omarchy/plugins/bredda.localsend && ./scripts/build-controller` | main only |
| `onlyvishesh.power-manager` | `sudo ~/.config/omarchy/plugins/onlyvishesh.power-manager/extras/install.sh` (root backend; without it, Apply silently fails) | main only |

### 10. Services and system tweaks

```bash
# omapager → Notification Center bridge (files restored in step 5)
chmod +x ~/.local/bin/omapager-nc-bridge
systemctl --user daemon-reload
systemctl --user enable --now omapager-nc-bridge.service
```

ThinkPad only, not stored in this repo (needs root):

- `/usr/lib/systemd/system-sleep/thinkpad-kbd-backlight`: keeps the keyboard
  backlight off after lid close/resume. This systemd only runs sleep hooks
  from `/usr/lib/systemd/system-sleep/`, not `/etc/`.
- Battery charge limit: write to
  `/sys/class/power_supply/BAT0/charge_control_end_threshold`.

### 11. Check it worked

```bash
$S seed --stage plugins   # plugins installed vs. missing
$S seed --stage report    # manual steps left over
hyprctl configerrors      # should print nothing
```

---

## Everyday use

After changing something on the live system:

```bash
cd ~/Work/omarchy-config
git branch --show-current            # make sure you're on the branch you mean
$S snapshot                          # preview
$S snapshot --apply
git diff                             # review; nothing secret should appear
git commit -am "Describe the change"
git push
```

Synchro saves whatever is running **now**. Switching git branches does
**not** change your desktop. To actually move the live system to the other
branch's setup:

```bash
git switch main                      # or laptop
$S restore --apply
cp manifests/shell.json ~/.config/omarchy/shell.json
omarchy restart shell
```

After changing the Top Bar plugin, refresh its copy here:

```bash
rsync -a --delete ~/.config/omarchy/plugins/shadowone.top-bar/ extras/plugins/shadowone.top-bar/
```

After changing a local plugin fix, re-export its patch:

```bash
(cd ~/.config/omarchy/plugins/ashuttl.linecast && git diff) > extras/patches/ashuttl.linecast.patch
```

## Known issues

- `shell.json` references `io.github.mshareef-git.omavibes` (bar center) and
  `io.github.alexanderpuschkinberlin.keyboard-backlight` (Bar Folder), but
  neither plugin is installed and neither has a saved source. Their slots stay
  empty.
- Print Screen is rebound in `hypr/bindings.lua` to copy screenshots to the
  clipboard only.
