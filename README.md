# ShadowOne's Omarchy setup

My [Omarchy](https://omarchy.org) desktop, ready to install on another machine:
Hyprland config, terminal settings, 35 shell plugins with my bar layout (a
bottom bar and a second Top Bar), the
[ThinkPad theme](https://github.com/JarnKet/omarchy-thinkpad-theme) with its
ASCII wallpapers, my [Min Dark theme](https://github.com/JarnKet/omarchy-min-dark-theme)
(VS Code's Min Dark for the whole desktop), my light
[Blueprint theme](https://github.com/JarnKet/omarchy-blueprint-theme) for coding
in sunlight, and the packages it all needs.

![ThinkPad theme](https://raw.githubusercontent.com/JarnKet/omarchy-thinkpad-theme/main/preview.png)

## How this was made

The ideas and decisions in this setup are mine: how the desktop looks, how the
mouse, touchpad and scrolling should feel, and which plugins and apps stay. The
code was written by Claude (Anthropic's AI) in Claude Code, from what I asked
for: the config files, scripts, my `shadowone.*` plugins and the changes to
other plugins. I tried every change on my own machine, kept only what felt
right, and take responsibility for what's here. Plugins by other people are
their work and link to their repos below.

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
| `apps` | Lets you pick from my apps: Brave Origin, VS Code, Claude, KDE Connect and more ([list](manifests/apps.txt)). Picks none unless you choose |
| `config` | Hyprland (`~/.config/hypr`), Kitty as the default terminal (plus Alacritty/Ghostty/foot settings), `~/.bashrc` with the Oh My Posh prompt, atuin and yazi, lazygit, VS Code settings, Omarchy hooks and theme templates. On a ThinkPad T14s Gen 6 it offers my monitor layout too |
| `plugins` | Clones every plugin in [plugins.json](manifests/plugins.json) and runs the setup the few need (beam, Panel Notes, Pointer Feel) |
| `bar` | Installs my `shell.json`: bar layout and widget settings |
| `theme` | Clones the ThinkPad, Min Dark and Blueprint themes plus 5 others and switches to ThinkPad (it ships its 13 ASCII wallpapers) |
| `services` | Turns on `hyprmoncfgd`, which switches monitor profiles when you plug screens in, the plugin update check and the wallpaper slideshow |
| `herdr` | The [Herdr app](https://herdr.dev) the way I use it: the orchi layout and the mods in [herdr/mods.tsv](herdr/mods.tsv), each fetched at the commit I reviewed with my changes from [herdr/patches](herdr/patches); it builds their helpers (gitview, herdr-recap), fonts that draw Lao right in Herdr (Geist Lao, JetBrains Mono Lao), and sets up their Claude Code side (session hooks, to-do list, usage line). Install the Herdr app and open it once first; Claude Code is optional |

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
  (`~/.local/share/lao-term`, SIL OFL). Lao Term is only for Kitty: in other
  apps it pulls vowels and tone marks apart ("ລາ ວ"), so
  `~/.config/fontconfig/conf.d/50-lao-term-kitty-only.conf` makes them fall
  back to Noto Sans Lao.
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
- **Soft windows:**
  - 12 px squircle corners and a soft shadow that falls a little below each
    window, darker under the focused one. Corners can differ per theme: the
    `corners` table in `~/.config/hypr/looknfeel.lua` keeps ThinkPad and
    Blueprint square, and a theme-set hook makes the shell's menus follow.
  - The same faint 1 px hairline on every window instead of a colored focus
    border, whatever the theme.
  - Light themes (like Blueprint) get a dark hairline and lighter shadows;
    `~/.config/hypr/theme_mode.lua` reads the current theme's mode and name,
    and a theme switch reloads Hyprland.
  - Rounding, shadow size and the gap between windows live in the Omaland
    block of `~/.config/hypr/looknfeel.lua`, so Omaland can still tune them.
    Omarchy's menus and popups follow the rounding.
  - The outer gap is 6 px above and below and 12 px at the sides. The bars are
    see-through, so their own padding already reads as space; this way it
    looks even all round. It's set in the block after Omaland's, because
    Omaland's slider takes one number.
- **Title bars styled per theme** (the `styles` table in
  `~/.config/hypr/titlebars.lua`); buttons are minimize, maximize, close from
  left to right on the right side, and the title fades on unfocused windows:
  - **ThinkPad:** black, the title in bold mono on the left, two charcoal dots
    and one TrackPoint-red dot that only the focused window shows.
  - **Blueprint:** white, the title in blueprint-blue mono, the buttons as
    circled callouts ⊖ ⊕ ⊗ like on a drawing.
  - **Min Dark and any other theme:** VS Code's own window controls in gray,
    the title centred, in the theme's colors.

  Double-click a bar to maximize. Apps that draw their own title bar or tabs
  (Brave, VS Code…) get none; the list is at the top of the same file.
- **Minimize:** the − button or **Super + M** hides the focused
  window and remembers its workspace; **Super + Alt + M** puts the last one back
  there and focuses it (again for the one before). Scripts: `window-minimize`,
  `window-restore` in `~/.local/bin`.
  - On a floating workspace it goes to Omarchy's dock instead, which brings it back.
  - The bars come from `omarchy-hyprland-titlebars`, the plugin Omarchy 4.5 ships
    for its floating workspaces, so there's nothing to build. `titlebars.lua` keeps
    this look on every window and ignores the styling Omarchy gives that plugin
    when a workspace floats.
- **Touchpad scrolling:** on Linux each app does its own glide after you lift
  your fingers, so it's tuned per app. Brave, VS Code and Obsidian scroll at
  0.6 (other apps 0.4, terminals 1.5) in `~/.config/hypr/input.lua`. Kitty's
  `momentum_scroll 0.975` glides about as long as Brave, and `repaint_delay 5`
  keeps it smooth on 120 Hz+ screens. VS Code's editor gets its own glide from
  `editor.inertialScroll`, with `editor.mouseWheelScrollSensitivity 0.55` so it
  doesn't run ahead of your fingers (Hyprland gives the mouse wheel that speed
  back). VS Code's file lists have no glide; it has no setting for that.
- **Print Screen** copies a screenshot to the clipboard and doesn't save a file.
- **Super + Alt + E** opens Panel Notes.
- **Super + Shift + /** opens a Bitwarden picker (`rbw-picker`, built on `rbw`):
  search the vault, then Enter copies the password, Ctrl-U the username and
  Ctrl-T the 2FA code. Copies stay out of the clipboard history and clear after
  30 seconds, and the window stays out of screen shares. The first run asks for
  your account email.
- **Super + A** (or the sparkle in the bar, or the first row of Super + Space)
  opens Ask Claude: type a question, the answer streams in from Claude Sonnet,
  follow-ups keep the conversation. It goes through the Claude Code CLI and your
  own Claude login, so install Claude Code and run `claude` once to sign in. In
  Super + Space, `ask <question>` sends it straight away, and any typed text gets
  an **Ask Claude here** row. `ask-claude "question"` works in a terminal. Put a
  line or two about yourself (city, languages) in `~/.config/ask-claude/context.md`
  for local answers. **Ctrl+H** in the panel searches your past Ask Claude
  conversations (only those, not other Claude Code sessions); Enter reopens one
  and follow-ups continue it. In a terminal: `ask-claude --history <words>`.
- **Battery:** on battery the laptop suspends after 45 minutes idle
  (`hypridle` + `~/.local/bin/suspend-if-on-battery`), never while Stay Awake
  is on or an app keeps the screen awake. Three more changes need sudo, so the
  installer leaves them to you:
  - Omarchy 4.5 rescans every app each time any file in `~` is saved.
    [The patch](extras/patches/omarchy-4.5-AppLibrary.qml.diff) only rescans
    when the app list really changes; apply it to
    `/usr/share/omarchy/shell/services/AppLibrary.qml` and run it again after
    each Omarchy update.
  - `sudo powerprofilesctl configure-action amdgpu_panel_power --enable` dims
    the panel a little on battery below 50%.
  - `kernel.nmi_watchdog = 0` in `/etc/sysctl.d/90-nmi-watchdog.conf`.
- **Plugin updates** are checked every 6 hours. When a plugin has new commits
  you get a notification and a puzzle icon in the middle of the bar; click
  either to go through the changes and pick what to install
  (`plugin-updates review`). Nothing updates on its own.
- **Wallpaper slideshow:** every theme's backgrounds take turns, a new one
  every 15 minutes in shuffled order, like the Windows slideshow; switch
  themes and it moves on to that theme's set. Picking a background yourself
  restarts the wait, and nothing changes while the screen is locked. Turn it
  on or off from the launcher (**Wallpaper Slideshow**) or with
  `wallpaper-slideshow on|off`; `wallpaper-slideshow every 30` and
  `wallpaper-slideshow order in-order` change it.
- **Notifications:** the bell next to the battery. Left-click for Do Not
  Disturb, right-click for recent notifications and history.
- **Two bars:** the Omarchy bar at the bottom, and the Top Bar (my plugin) for
  extra widgets. Drag widgets between them, or use `omarchy-topbar list`.
- **Launcher icon:** the menu button at the left of the bar is the TrackPoint
  red dot under the ThinkPad theme and the Omarchy logo under every other
  theme (`themeIcons` in Keystroke's entry in `shell.json`). It needs my local
  patch to Keystroke's `BarWidget.qml`; without it you get the stock logo.
- **Hardware plugins** only do something if you have the hardware: fingerprint
  (Biometric HUD), webcam, Miracast (Wireless Display Cast), printers.
- **Pointer Feel** builds two small Hyprland modules on your machine. If the
  mouse feel stops working after a Hyprland update, rebuild them with
  `~/.config/omarchy/plugins/ilysorc.pointer-feel/install.sh --yes`.
- **Disk Keeper** never deletes on its own: click the disk icon, check what it
  found, then clean. Its System items (old packages, journal, snapshots) need a
  root helper, installed once with
  `sudo bash ~/.config/omarchy/plugins/shadowone.disk-keeper/root/install.sh`.
- **Memory Keeper** does act on its own: every 5 minutes while awake it stops Claude
  Code sessions left idle for 12 hours (sooner when memory is short; sleep doesn't
  count). Busy, waiting and on-screen sessions, and ones running something, are left
  alone. Resume them from its panel, or turn this off there.
- Plugins install at their newest versions. If one breaks after an Omarchy
  update, `--pinned` gets the versions this was tested with, or
  `omarchy plugin update` gets the fixes.
- **The \*craft office apps** (wordcraft, deckcraft, gridcraft, pdfcraft)
  come from the AUR as `-bin` packages. The Omarchy repo now ships wordcraft
  and gridcraft too, but often a version behind, and yay skips anything a repo
  owns. A post-update hook builds the AUR copy whenever it is newer, so
  `omarchy update` keeps all four current. It also runs `openidea-update` if
  you have that script.
- **Brave Origin is on the accessibility bus**, so desktop-automation tools
  such as `agent-desktop` can read and click its pages. Hyprland doesn't turn
  the bus on for browsers, so a small `brave-origin` wrapper in `~/.local/bin`
  adds the two settings it needs, and a copy of Brave's desktop entry points
  at it. Electron apps such as VS Code are left alone, since the same settings
  would slow them down. Delete both files to undo it.
- Not in this repo on purpose: SSH/GPG keys, browser profiles, passwords,
  tokens, keyrings, shell history (atuin's `~/.atuin/data`), my personal
  wallpaper.

## Plugins

| Plugin | What it does |
|--------|--------------|
| [Top Bar](extras/plugins/shadowone.top-bar) | A second bar opposite the Omarchy bar for third-party widgets (mine) |
| [Disk Keeper](extras/plugins/shadowone.disk-keeper) | Free space in the bar, a warning before the disk fills up, and a panel to clean caches, old packages, build folders and Docker leftovers (mine) |
| [Memory Keeper](extras/plugins/shadowone.memory-keeper) | Available memory in the bar; stops Claude Code sessions left idle and resumes them with a click, frees cold cache under pressure, shows what holds memory (mine) |
| [Ask Claude](extras/plugins/shadowone.ask-claude) | Quick questions to Claude Sonnet from the bar or Super + A, through the Claude Code CLI, with a searchable history (mine) |
| [Plugin Updates](extras/plugins/shadowone.plugin-updates) | A bar icon while plugin updates are waiting; click to review them (mine) |
| [Battery](extras/plugins/shadowone.power) | Omarchy's battery panel plus an 80% charge limit switch and battery health (mine) |
| [Keystroke](https://github.com/evindor/keystroke) | Raycast-style command palette instead of the Omarchy menu |
| [Exposé](https://github.com/kristofferR/omarchy-expose) | All windows at once; 3-finger swipe up/down |
| [Mirador](https://github.com/sanjyay/Mirador) | Overview of workspaces and their windows |
| [Omarchy Zones](https://github.com/shivam-g10/omarchy-zones) | FancyZones-style window zones (Super + Shift + drag) |
| [Workspace name](https://github.com/jankeesvw/omarchy-workspace-name) | Name and icon of the current workspace. With more than one monitor, apply [the patch](extras/patches/jankeesvw.workspace-name-Panel.qml.omarchy45.diff) for Omarchy 4.5's per-monitor workspaces and layout icon (`git apply` in the plugin folder) |
| [Bar Folder](https://github.com/arikisonfire/omarchy-bar-folder) | Folds bar icons into one folder |
| [Hardwarchy](https://github.com/tymurbogach/hardwarchy) | CPU, GPU, memory, network, disk, fan in the top bar |
| [Cursor Accent](https://github.com/SmoothPixels/cursor-accent) | Cursor in the theme's colors; its hooks recolor it on every theme change |
| [OmaConnect](https://github.com/jitendradara12/omaconnect) | KDE Connect for your phone (in the Bar Folder; needs `kdeconnect`) |
| [OmaProton VPN](https://github.com/grichard99/omaproton-vpn) | Proton VPN in the top bar (checks the link every 30 s) |
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
| [Lock Screen Explorer](https://github.com/SirJul1337/omarchy-lock-explorer) | Lock screen designs with a preview picker and a designer (replaces the built-in lock screen) |
| [Flare](https://github.com/melonamin/omarchy-flare) | Click highlights for demos and recordings |
| [Plugin Manager](https://github.com/fross100/omaplug) | Enable, disable, update, install from git and remove plugins |
| [OmaDoctor](https://github.com/Davedes83/OmaDoctor) | Health check of the system: services, disk, audio, display |

## What's in here

```text
install.sh         the installer
snapshot.sh        copies my live setup back into this repo
portable/home/     files copied into ~ on every machine
device/<model>/    monitor layout, only for that laptop model
  root/            T14s Gen 6 only: faster sleep/wake (sudo bash .../root/install.sh)
personal/home/     my JARNKET screensaver text (asked for, default no)
manifests/
  files.tsv        which files snapshot.sh and install.sh handle
  plugins.json     every plugin: git source and tested revision
  shell.json       bar layout and widget settings
  packages.txt     packages the setup needs
  apps.txt         my optional apps
  themes.txt       themes to clone
extras/plugins/    plugins I wrote (shadowone.*): top bar, disk keeper, memory keeper,
                   plugin updates, battery
herdr/
  mods.tsv         Herdr mods: repo and the commit I reviewed
  patches/         my changes to those mods
  mods/            mods of my own (oui-window), kept whole
  claude-openui.md when agents show answers as OpenUI panels (added to ~/.claude/CLAUDE.md)
  home/            Herdr layout and keys, and the mods' helper files
  files.txt        which files snapshot.sh copies into home/
  settings.json    the fonts merged into Herdr's settings
  sources.sh       fetching the mods and making or applying the patches
```

### Faster sleep and wake (ThinkPad T14s Gen 6)

`device/thinkpad-t14s-gen-6/root/` holds system files the normal installer
doesn't touch. Install them once with
`sudo bash device/thinkpad-t14s-gen-6/root/install.sh` (`--uninstall` puts
everything back):

- **Wi-Fi back in a few seconds after opening the lid.** NetworkManager drops
  Wi-Fi for every suspend and waits for a full scan before it reconnects; this
  laptop's Wi-Fi card is stuck on the "world" regulatory domain, where every
  5 GHz channel is scanned passively, so that took ~16 s. A NetworkManager
  dispatcher script remembers the channels of the networks you join, and a
  resume hook has wpa_supplicant scan only those. wpa_supplicant stays, so
  Wi-Fi Direct casting to a TV keeps working.
- **No fixed 1 s at every wake.** The keyboard-backlight hook re-applies its
  level from a timer instead of sleeping while the session is still frozen, and
  `amd-debug-tools` is removed (its hook ran Python on every suspend and resume).
- **Closing the lid right after opening it** sleeps within 10 s, not 30 s.
- **Temporary diagnostics:** `resume-probe` records what the shell does for 12 s
  after each resume (in `/var/log/resume-probe/`; `--no-probe` removes it), and
  `pm_print_times` logs each device's suspend time until the next reboot.

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
them). For Herdr it rewrites `herdr/patches/` from the live mods, and warns about
mods that aren't in `herdr/mods.tsv`; a new mod or a newer commit goes into
`mods.tsv` by hand, after a review. To record which monitor layout goes with a new laptop model, run it on
that laptop: device files land in `device/<its model>/`.

The `laptop` branch is an old battery-saving snapshot from 2026-09-24 and isn't
maintained. `main` is the current setup.
