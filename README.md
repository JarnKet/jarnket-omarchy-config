# ShadowOne's Omarchy setup

My [Omarchy](https://omarchy.org) desktop, ready to install on another machine:
Hyprland config, terminal settings, 34 shell plugins with my bar layout (a
bottom bar and a second Top Bar), the
[ThinkPad theme](https://github.com/JarnKet/omarchy-thinkpad-theme) with its
ASCII wallpapers, and the packages it all needs.

![ThinkPad theme](https://raw.githubusercontent.com/JarnKet/omarchy-thinkpad-theme/main/preview.png)

## Install

You need a working Omarchy 4 install (this was captured on 4.0.4), an internet
connection, and sudo. Open a terminal **inside the desktop** and run:

```bash
curl -fsSL https://raw.githubusercontent.com/JarnKet/jarnket-omarchy-config/main/install.sh | bash
```

It downloads this repo to `~/.local/share/jarnket-omarchy-config`, shows the
steps, and asks before it starts. Most of the time goes to downloads. Or
clone it yourself:

```bash
git clone https://github.com/JarnKet/jarnket-omarchy-config.git
cd jarnket-omarchy-config
./install.sh --dry-run   # see what would change
./install.sh
```

Run it again any time; it skips what's already in place.

### What it does

| Step | What happens |
|------|--------------|
| `packages` | Installs what the plugins and terminal need: `hyprmoncfg-bin`, `gnome-network-displays` (AUR), build tools for Pointer Feel, Kitty, Oh My Posh, atuin, yazi, and a few libraries ([list](manifests/packages.txt)) |
| `apps` | Lets you pick from my apps: Brave Origin, VS Code, IntelliJ, Claude, KDE Connect and more ([list](manifests/apps.txt)). Picks none unless you choose |
| `config` | Hyprland (`~/.config/hypr`), Kitty as the default terminal (plus Alacritty/Ghostty/foot settings), `~/.bashrc` with the Oh My Posh prompt, atuin and yazi, lazygit, Omarchy hooks and theme templates. On a ThinkPad T14s Gen 6 it offers my monitor layout too |
| `plugins` | Clones every plugin in [plugins.json](manifests/plugins.json) and runs the setup the few need (beam, Panel Notes, Pointer Feel) |
| `bar` | Installs my `shell.json`: bar layout, widget settings, omapager instead of the built-in notifications |
| `theme` | Clones the ThinkPad theme plus 5 others, renders the ASCII wallpapers with **your** username, switches to it |
| `services` | Turns on `hyprmoncfgd`, which switches monitor profiles when you plug screens in |

Before it changes a file it copies the old one to
`~/.local/state/jarnket-omarchy-config/backups/<time>/`.

### Options

```text
-y, --yes          don't ask; take the defaults (installs no optional apps)
-n, --dry-run      show what would change and change nothing
    --only LIST    run only these steps, e.g. --only config,bar
    --skip LIST    skip these steps, e.g. --skip apps,theme
    --apps WHICH   all, none, or ask (default: ask)
    --pinned       check plugins out at the exact versions I last tested
    --boot-logo    also put the ThinkPad logo on the boot/login screen (sudo)
    --undo [DIR]   restore the newest backup and remove what was added
```

With `curl | bash`, pass options after `bash -s --`:

```bash
curl -fsSL https://raw.githubusercontent.com/JarnKet/jarnket-omarchy-config/main/install.sh | bash -s -- --dry-run
```

### Undo

```bash
~/.local/share/jarnket-omarchy-config/install.sh --undo
```

This puts back every file it replaced, deletes the ones it created, removes
the plugins and themes it added, and switches back to your old theme. Packages
stay installed.

## Good to know

- **Keyboard:** two layouts, US and Lao (`us,lao`), switched with Alt + Shift.
  The Lao one is the Windows Lao layout key for key
  (`~/.config/xkb/symbols/lao`), including the keys that type two characters:
  Shift + ] = ຫຼ, Shift + = = ໍ່, and Shift + Q, Y, U, A, B, N = the vowel
  with ້. Those come from `~/.config/xkb/lao.XCompose`, which install.sh
  includes from your `~/.XCompose`. In Lao, Right Alt is AltGr
  (AltGr + 1…0 = ໑…໐) and Shift + Space types a zero-width space. Change it in
  `~/.config/hypr/input.lua`.
- **Terminal:** Kitty opens on Super + Return, with a caret cursor that fades
  in and out and leaves a short trail when it jumps. Lao uses Lao Term, Noto
  Sans Lao refitted to the terminal cell so wide letters like ໝ aren't shrunk
  (`~/.local/share/lao-term`, SIL OFL).
  **Super + `** drops a Kitty down from the top of the screen; the same key
  hides it. To go back to foot: `omarchy default terminal foot`.
- **Prompt:** Oh My Posh instead of starship: folder, git status, language
  versions in projects, how long a command took, the exit code when it fails,
  battery and time. Its colors follow the Omarchy theme, rendered from
  `~/.config/omarchy/themed/oh-my-posh.omp.json.tpl` on every theme change.
- **Ctrl + R** searches all your shell history with atuin (it stays on your
  machine; the Up arrow is unchanged). **`y`** opens yazi, a terminal file
  manager with image previews, and leaves you in the folder you quit from.
- **Animations:** windows and panels open with a fast start and a soft landing
  (curves from the Glyph rice, in `~/.config/hypr/looknfeel.lua`).
- **Print Screen** copies a screenshot to the clipboard and doesn't save a file.
- **Super + Alt + E** opens Panel Notes.
- **Super + A** (or the sparkle in the bar, or the first row of Super + Space)
  opens Ask Claude: type a question, the answer streams in from Claude Sonnet,
  follow-ups keep the conversation. It goes through the Claude Code CLI and your
  own Claude login, so install Claude Code and run `claude` once to sign in. In
  Super + Space, `ask <question>` sends it straight away, and any typed text gets
  an **Ask Claude here** row. `ask-claude "question"` works in a terminal. Put a
  line or two about yourself (city, languages) in `~/.config/ask-claude/context.md`
  for local answers.
- **Plugin updates** are checked every 6 hours. When a plugin has new commits
  you get a notification and a puzzle icon in the middle of the bar; click
  either to go through the changes and pick what to install
  (`plugin-updates review`). Nothing updates on its own.
- **Notifications:** the bell next to the battery. Left-click for Do Not
  Disturb, right-click for recent notifications and history.
- **Two bars:** the Omarchy bar at the bottom, and the Top Bar (my plugin) for
  extra widgets. Drag widgets between them, or use `omarchy-topbar list`.
- **Hardware plugins** only do something if you have the hardware: fingerprint
  (Biometric HUD), webcam, Miracast (Wireless Display Cast), printers.
- **Pointer Feel** builds two small Hyprland modules on your machine. If the
  mouse feel stops working after a Hyprland update, rebuild them with
  `~/.config/omarchy/plugins/ilysorc.pointer-feel/install.sh --yes`.
- **Disk Keeper** never deletes on its own: click the disk icon, check what it
  found, then clean. Its System items (old packages, journal, snapshots) need a
  root helper, installed once with
  `sudo bash ~/.config/omarchy/plugins/shadowone.disk-keeper/root/install.sh`.
- Plugins install at their newest versions. If one breaks after an Omarchy
  update, `--pinned` gets the versions this was tested with, or
  `omarchy plugin update` gets the fixes.
- Not in this repo on purpose: SSH/GPG keys, browser profiles, passwords,
  tokens, keyrings, shell history (atuin's `~/.atuin/data`), Ask Claude's
  `context.md`, my personal wallpaper.

## Plugins

| Plugin | What it does |
|--------|--------------|
| [Top Bar](extras/plugins/shadowone.top-bar) | A second bar opposite the Omarchy bar for third-party widgets (mine) |
| [Disk Keeper](extras/plugins/shadowone.disk-keeper) | Free space in the bar, a warning before the disk fills up, and a panel to clean caches, old packages, build folders and Docker leftovers (mine) |
| [Ask Claude](extras/plugins/shadowone.ask-claude) | Quick questions to Claude Sonnet from the bar or Super + A, through the Claude Code CLI (mine) |
| [Plugin Updates](extras/plugins/shadowone.plugin-updates) | A bar icon while plugin updates are waiting; click to review them (mine) |
| [Clock](extras/plugins/shadowone.clock) | Omarchy's clock with your Google Calendar events and reminders; `omacal setup` explains the one-time Google setup (mine) |
| [Battery](extras/plugins/shadowone.power) | Omarchy's battery panel plus an 80% charge limit switch and battery health (mine) |
| [Omapager](https://github.com/njpatel/omapager) | Notifications that stack and group (replaces the built-in ones) |
| [Keystroke](https://github.com/evindor/keystroke) | Raycast-style command palette instead of the Omarchy menu |
| [Exposé](https://github.com/kristofferR/omarchy-expose) | All windows at once; 3-finger swipe up/down |
| [Mirador](https://github.com/sanjyay/Mirador) | Overview of workspaces and their windows |
| [Omarchy Zones](https://github.com/shivam-g10/omarchy-zones) | FancyZones-style window zones (Super + Shift + drag) |
| [Workspace name](https://github.com/jankeesvw/omarchy-workspace-name) | Name and icon of the current workspace |
| [Bar Folder](https://github.com/arikisonfire/omarchy-bar-folder) | Folds bar icons into one folder |
| [Hardwarchy](https://github.com/tymurbogach/hardwarchy) | CPU, GPU, memory, network, disk, fan in the bar |
| [Linecast](https://github.com/ashuttl/omarchy-linecast) | Weather, sun, moon and tides |
| [hyprmoncfg](https://github.com/crmne/omarchy-hyprmoncfg) | Monitor profiles that come back when you plug in |
| [OmaSettings](https://github.com/twiking/omasettings) | One window for every Omarchy setting |
| [Omaland](https://github.com/bobby-nicholas/omaland) | Edit Hyprland's look with a live preview |
| [Pointer Feel](https://github.com/ilysorc/omarchy-pointer-feel) | Windows- or Mac-style mouse acceleration |
| [Advanced Audio Control](https://github.com/ssupt/omarchy-audio-control) | PipeWire mixer (replaces the built-in audio widget) |
| [Advanced Bluetooth Audio](https://github.com/ssupt/omarchy-bluetooth-audio) | Bluetooth codecs and per-device settings |
| [Omavoice](https://github.com/gigasolo/omavoice) | Clean virtual microphone for calls |
| [Removable Drives](https://github.com/Wian47/omarchy-removable-drives) | Mount and eject USB drives, SD cards, phones |
| [Downloads](https://github.com/roymelgarv/omarchy-downloads) | Recent downloads in the bar |
| [LocalSend](https://github.com/cryptobredda/omarchy-localsend) | AirDrop-style sharing with nearby devices |
| [NetNeighbors](https://github.com/i12bp8/omarchy-netneighbours) | Every device on your Wi-Fi |
| [Omarchy X-Ray](https://github.com/RandaZraik/omarchy-xray) | Trace a window, port or file to the process behind it |
| [Panel Notes](https://github.com/rblalock/omarchy-panel-notes) | Markdown notes per app |
| [Omarchy Beam](https://github.com/TouchWorkStation/Omarchy-Beam-) | Turn a link into a QR code |
| [Radio Atlas](https://github.com/AksharP5/omarchy-radio-atlas) | Live radio on a globe |
| [Printers](https://github.com/segersb/omarchy-printers) | Printer settings and print previews |
| [Webcam Controls](https://github.com/kristoferlund/omarchy-webcam) | Webcam settings with a live preview |
| [Wireless Display Cast](https://github.com/shadyuop/omarchy-wireless-display-cast) | Cast to a Miracast screen |
| [Reboot into](https://github.com/07dcolem/omarchy-target-boot) | Reboot straight into Windows or another OS |
| [Biometric HUD](https://github.com/GruperTal/omarchy-biometric-hud) | Windows Hello-style tile for fingerprint/face unlock |
| [Flare](https://github.com/melonamin/omarchy-flare) | Click highlights for demos and recordings |
| [Plugin Manager](https://github.com/juancasanueva/omarchy-plugin-manager) | Browse, install, update and remove plugins from the bar |
| [OmaDoctor](https://github.com/Davedes83/OmaDoctor) | Health check of the system: services, disk, audio, display |

## What's in here

```text
install.sh         the installer
snapshot.sh        copies my live setup back into this repo
portable/home/     files copied into ~ on every machine
device/<model>/    monitor layout, only for that laptop model
personal/home/     my JARNKET screensaver text (asked for, default no)
manifests/
  files.tsv        which files snapshot.sh and install.sh handle
  plugins.json     every plugin: git source and tested revision
  shell.json       bar layout and widget settings
  packages.txt     packages the setup needs
  apps.txt         my optional apps
  themes.txt       themes to clone
extras/plugins/    plugins I wrote (shadowone.*): top bar, disk keeper, ask claude,
                   plugin updates, clock, battery
```

Paths to my home folder (`/home/shadowone/...`) in the config files are
rewritten to yours when they're installed.

## Updating this repo (for me)

After changing something on the live system:

```bash
cd ~/Work/omarchy-config
./snapshot.sh            # copies the live files, plugin list, bar layout, themes
git diff                 # this repo is public: check nothing private got in
git commit -am "Describe the change"
git push
```

`snapshot.sh` also lists packages I installed that aren't in `packages.txt` or
`apps.txt`, and warns about plugins with local edits (a fresh clone won't have
them). To record which monitor layout goes with a new laptop model, run it on
that laptop: device files land in `device/<its model>/`.

The `laptop` branch is an old battery-saving snapshot from 2026-09-24 and isn't
maintained. `main` is the current setup.
