#!/usr/bin/env bash
# shellcheck disable=SC2088 # "~/..." in messages is meant literally
#
# Install ShadowOne's Omarchy setup on this machine: Hyprland config, terminal
# settings, ~30 shell plugins with the bar layout, the ThinkPad theme with its
# ASCII wallpapers, and the packages that all of this needs.
#
# On a fresh Omarchy install, from a terminal inside the desktop:
#
#   curl -fsSL https://raw.githubusercontent.com/JarnKet/jarnket-omarchy-config/main/install.sh | bash
#
# or from a clone:  ./install.sh
#
# Every file it replaces is backed up first. `./install.sh --undo` puts them
# back and removes the plugins and themes it added.

set -euo pipefail

# Set these to install from a fork or another branch.
REPO_URL="${OMARCHY_CONFIG_REPO:-https://github.com/JarnKet/jarnket-omarchy-config.git}"
REPO_BRANCH="${OMARCHY_CONFIG_BRANCH:-main}"
CLONE_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/jarnket-omarchy-config"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/jarnket-omarchy-config"

THEME_NAME="thinkpad"
# The captured files point at my home directory in a few places.
SOURCE_HOME="/home/shadowone"

PLUGINS_DIR="$HOME/.config/omarchy/plugins"
THEMES_DIR="$HOME/.config/omarchy/themes"
SHELL_JSON="$HOME/.config/omarchy/shell.json"

ALL_STEPS="packages apps config plugins bar theme services herdr"

usage() {
  cat <<'EOF'
Usage: install.sh [options]

Steps, in order:
  packages  packages the config and plugins need (sudo)
  apps      my everyday apps; you pick which ones (sudo)
  config    Hyprland, terminals, hooks, keybindings (backs up what it replaces)
  plugins   clone the shell plugins and run their setup scripts
  bar       bar layout and widget settings (shell.json)
  theme     ThinkPad theme, its ASCII wallpapers, extra themes
  services  user services: hyprmoncfgd, plugin update checks, wallpaper slideshow
  herdr     the Herdr app: orchi layout, mods (herdr/mods.tsv), Lao fonts, and
            their Claude Code hooks (needs the Herdr app, opened once)

Options:
  -y, --yes          don't ask; take the defaults (installs no optional apps)
  -n, --dry-run      show what would change and change nothing
      --only LIST    run only these steps, e.g. --only config,bar
      --skip LIST    skip these steps, e.g. --skip apps,theme
      --apps WHICH   all, none, or ask (default: ask; none with --yes)
      --pinned       check plugins out at the exact versions I last tested
      --boot-logo    also put the theme's logo on the boot/login screen (sudo)
      --undo [DIR]   restore the newest backup (or DIR) and remove what was added
  -h, --help         show this help
EOF
}

# --- output ----------------------------------------------------------------

if [[ -t 1 ]]; then
  BOLD=$'\e[1m' DIM=$'\e[2m' RED=$'\e[31m' GREEN=$'\e[32m' YELLOW=$'\e[33m' RESET=$'\e[0m'
else
  BOLD="" DIM="" RED="" GREEN="" YELLOW="" RESET=""
fi

step() { printf '\n%s==> %s%s\n' "$BOLD" "$*" "$RESET"; }
info() { printf '    %s\n' "$*"; }
ok() { printf '    %s✓%s %s\n' "$GREEN" "$RESET" "$*"; }
warn() { printf '    %s!%s %s\n' "$YELLOW" "$RESET" "$*" >&2; }
die() { printf '%serror:%s %s\n' "$RED" "$RESET" "$*" >&2; exit 1; }

PROBLEMS=()
MANUAL=()
problem() { warn "$*"; PROBLEMS+=("$*"); }
manual() { MANUAL+=("$*"); }

# Mutating commands go through run so --dry-run can show them instead.
run() {
  if ((DRY_RUN)); then
    printf '    %s[dry-run]%s %s\n' "$DIM" "$RESET" "$*"
  else
    "$@"
  fi
}

interactive() { [[ -t 0 && -t 1 ]] && ((!ASSUME_YES)); }

confirm() { # confirm "question" default(yes|no)
  local question=$1 default=${2:-yes}
  if ! interactive; then
    [[ $default == yes ]]
    return
  fi
  if command -v gum >/dev/null; then
    gum confirm --default="$([[ $default == yes ]] && echo true || echo false)" "$question"
  else
    local hint reply
    hint=$([[ $default == yes ]] && echo "Y/n" || echo "y/N")
    read -r -p "    $question [$hint] " reply
    reply=${reply:-$([[ $default == yes ]] && echo y || echo n)}
    [[ $reply == [yY]* ]]
  fi
}

# --- bootstrap: running from curl ------------------------------------------

# With `curl ... | bash` there is no checkout next to this script, so clone the
# repo and run its copy, reattached to the terminal so prompts still work.
bootstrap() {
  local here=""
  if [[ -n ${BASH_SOURCE[0]:-} && -f ${BASH_SOURCE[0]} ]]; then
    here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  fi
  if [[ -n $here && -f $here/manifests/plugins.json ]]; then
    REPO_DIR=$here
    return
  fi

  command -v git >/dev/null || die "git is missing; is this an Omarchy install?"
  if [[ -d $CLONE_DIR/.git ]]; then
    echo "Updating $CLONE_DIR"
    git -C "$CLONE_DIR" pull --ff-only -q || echo "Couldn't update it; using the copy that's there."
  else
    echo "Downloading the config into $CLONE_DIR"
    mkdir -p "$(dirname "$CLONE_DIR")"
    git clone -q --depth 1 --branch "$REPO_BRANCH" "$REPO_URL" "$CLONE_DIR"
  fi
  if [[ ! -t 0 ]] && { : </dev/tty; } 2>/dev/null; then
    exec bash "$CLONE_DIR/install.sh" "$@" </dev/tty
  fi
  exec bash "$CLONE_DIR/install.sh" "$@"
}

# --- checks ----------------------------------------------------------------

in_session() {
  [[ -n ${HYPRLAND_INSTANCE_SIGNATURE:-} ]] && hyprctl version >/dev/null 2>&1
}

omarchy_version() {
  pacman -Q omarchy 2>/dev/null | awk '{ sub(/-[0-9]+$/, "", $2); print $2 }'
}

machine_slug() {
  local name
  name=$(cat /sys/class/dmi/id/product_family 2>/dev/null || true)
  [[ -n ${name// /} ]] || name=$(cat /sys/class/dmi/id/product_name 2>/dev/null || true)
  printf '%s' "$name" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/^-*//; s/-*$//'
}

preflight() {
  step "Checking this machine"
  ((EUID != 0)) || die "run this as your normal user, not root (it asks for sudo when it needs it)"
  command -v omarchy >/dev/null || die "omarchy isn't installed. Install Omarchy first: https://omarchy.org"
  for cmd in git jq; do
    command -v "$cmd" >/dev/null || die "$cmd is missing"
  done

  local have want
  have=$(omarchy_version)
  want=$(cat "$REPO_DIR/manifests/omarchy-version" 2>/dev/null || echo "")
  [[ -n $have ]] || die "can't tell which Omarchy version this is (pacman -Q omarchy failed)"
  if ((${have%%.*} < 4)); then
    die "this config needs Omarchy 4 or newer (Lua Hyprland config); you have $have. Run: omarchy update"
  fi
  if [[ -n $want && $have != "$want" ]]; then
    warn "This config was captured on Omarchy $want; you have $have."
    warn "Newer Omarchy usually works; a plugin may need an update if it doesn't."
    confirm "Continue anyway?" yes || exit 1
  else
    ok "Omarchy $have"
  fi

  if in_session; then
    ok "Running inside Hyprland"
  else
    warn "Not inside a Hyprland session. Files will be installed, but the shell"
    warn "restart and theme switch wait until you log in and run this again."
  fi

  MACHINE=$(machine_slug)
  info "Machine: ${MACHINE:-unknown}"
}

# --- backups ---------------------------------------------------------------

BACKUP_DIR=""
declare -A BACKED_UP=()

start_backup() {
  ((DRY_RUN)) && return
  BACKUP_DIR="$STATE_DIR/backups/$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$BACKUP_DIR/home"
  : >"$BACKUP_DIR/created.txt"
  : >"$BACKUP_DIR/plugins-added.txt"
  : >"$BACKUP_DIR/themes-added.txt"
  : >"$BACKUP_DIR/services-enabled.txt"
  current_theme >"$BACKUP_DIR/previous-theme" || true
}

current_theme() {
  cat "$HOME/.local/state/omarchy/current/theme.name" 2>/dev/null
}

# Save $1 (a path under $HOME) before it's changed, once per run. Paths that
# didn't exist are listed so --undo can delete them.
backup() {
  local path=$1 rel=${1#"$HOME"/}
  ((DRY_RUN)) && return
  [[ -n ${BACKED_UP[$rel]:-} ]] && return
  BACKED_UP[$rel]=1
  if [[ -e $path || -L $path ]]; then
    mkdir -p "$BACKUP_DIR/home/$(dirname "$rel")"
    cp -a "$path" "$BACKUP_DIR/home/$rel"
  else
    printf '%s\n' "$rel" >>"$BACKUP_DIR/created.txt"
  fi
}

record() { # record plugins-added|themes-added|services-enabled value
  ((DRY_RUN)) || printf '%s\n' "$2" >>"$BACKUP_DIR/$1.txt"
}

undo() {
  local dir=${1:-}
  if [[ -z $dir ]]; then
    dir=$(find "$STATE_DIR/backups" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | tail -n 1)
  fi
  [[ -n $dir && -d $dir/home ]] || die "no backup found in $STATE_DIR/backups"

  step "Undoing the install from $(basename "$dir")"
  confirm "Restore your old files and remove the plugins and themes this install added?" yes || exit 1

  local id name rel
  while IFS= read -r id; do
    [[ -n $id && -d $PLUGINS_DIR/$id ]] || continue
    # Pointer Feel set up Hyprland modules and a launcher; let it take them out.
    if [[ $id == ilysorc.pointer-feel && -f $HOME/.local/bin/pointer-feel ]] && in_session; then
      run "$PLUGINS_DIR/$id/install.sh" --uninstall --no-restart >/dev/null 2>&1 ||
        problem "Pointer Feel's uninstall failed; its modules may still be in ~/.local/lib/hyprland"
    fi
    if [[ ! -d $PLUGINS_DIR/$id ]]; then
      ok "removed plugin $id"
    elif run omarchy plugin remove "$id" --yes >/dev/null 2>&1; then
      ok "removed plugin $id"
    else
      problem "couldn't remove plugin $id"
    fi
  done <"$dir/plugins-added.txt"
  while IFS= read -r name; do
    [[ -n $name && -d $THEMES_DIR/$name && ! -L $THEMES_DIR/$name ]] || continue
    run rm -rf "${THEMES_DIR:?}/$name"
    ok "removed theme $name"
  done <"$dir/themes-added.txt"
  local unit
  while IFS= read -r unit; do
    [[ -n $unit ]] || continue
    if run systemctl --user disable --now "$unit" >/dev/null 2>&1; then
      ok "turned off $unit"
    else
      problem "couldn't turn off $unit"
    fi
  done < <(cat "$dir/services-enabled.txt" 2>/dev/null)

  while IFS= read -r rel; do
    [[ -n $rel ]] || continue
    if [[ -e $HOME/$rel || -L $HOME/$rel ]]; then
      run rm -rf "${HOME:?}/$rel"
      ok "removed ~/$rel"
    fi
  done <"$dir/created.txt"
  if [[ -n $(ls -A "$dir/home") ]]; then
    run cp -a "$dir/home/." "$HOME/"
    ok "restored $(find "$dir/home" -type f -o -type l | wc -l) files"
  fi

  local previous
  previous=$(cat "$dir/previous-theme" 2>/dev/null || true)
  if in_session; then
    if [[ -n $previous ]]; then
      run omarchy theme set "$previous" >/dev/null 2>&1 || problem "couldn't switch back to the $previous theme"
    fi
    run omarchy restart shell >/dev/null 2>&1 || true
  fi
  echo
  ok "Done. Packages that were installed are still there."
}

# --- packages --------------------------------------------------------------

# Lines are "package  # what it's for"; blank lines and comments are skipped.
read_list() {
  sed 's/#.*//; s/[[:space:]]*$//; s/^[[:space:]]*//' "$1" | awk 'NF { print $1 }'
}

describe_list() { # "package — description" lines for the picker
  awk -F'#' '/^[[:space:]]*[^#[:space:]]/ {
    gsub(/^[ \t]+|[ \t]+$/, "", $1); gsub(/^[ \t]+|[ \t]+$/, "", $2)
    print $1 (length($2) ? " — " $2 : "")
  }' "$1"
}

SUDO_KEEPALIVE=""
need_sudo() {
  ((DRY_RUN)) && return
  [[ -n $SUDO_KEEPALIVE ]] && return
  info "Some steps need sudo."
  sudo -v || die "sudo failed"
  (while kill -0 "$$" 2>/dev/null; do sudo -n true 2>/dev/null; sleep 50; done) &
  SUDO_KEEPALIVE=$!
  trap 'kill "$SUDO_KEEPALIVE" 2>/dev/null || true' EXIT
}

# Install from the official repos in one go, then the rest from the AUR one by
# one, so a single renamed or missing package doesn't stop everything else.
install_packages() {
  local pkg repo=() aur=() missing=()
  for pkg in "$@"; do
    pacman -Q "$pkg" >/dev/null 2>&1 || missing+=("$pkg")
  done
  if ((${#missing[@]} == 0)); then
    ok "all ${#} already installed"
    return
  fi
  for pkg in "${missing[@]}"; do
    if pacman -Si "$pkg" >/dev/null 2>&1; then repo+=("$pkg"); else aur+=("$pkg"); fi
  done

  need_sudo
  if ((${#repo[@]})); then
    info "pacman: ${repo[*]}"
    if ! run sudo pacman -S --needed --noconfirm "${repo[@]}"; then
      for pkg in "${repo[@]}"; do
        run sudo pacman -S --needed --noconfirm "$pkg" >/dev/null 2>&1 || problem "package $pkg didn't install"
      done
    fi
  fi
  if ((${#aur[@]})); then
    if ! command -v yay >/dev/null; then
      problem "yay is missing, so these AUR packages were skipped: ${aur[*]}"
      return
    fi
    for pkg in "${aur[@]}"; do
      info "AUR: $pkg"
      run yay -S --needed --noconfirm "$pkg" || problem "AUR package $pkg didn't install"
    done
  fi
}

step_packages() {
  step "Packages the config needs"
  local pkgs
  mapfile -t pkgs < <(read_list "$REPO_DIR/manifests/packages.txt")
  install_packages "${pkgs[@]}"
}

step_apps() {
  step "My apps (optional)"
  local list="$REPO_DIR/manifests/apps.txt" chosen=() line
  local mode=$APPS
  [[ $mode == ask ]] && ! interactive && mode=none

  case $mode in
  none)
    info "Skipped. To pick some later: $REPO_DIR/install.sh --only apps"
    return
    ;;
  all)
    mapfile -t chosen < <(read_list "$list")
    ;;
  ask)
    if command -v gum >/dev/null; then
      mapfile -t chosen < <(describe_list "$list" |
        gum choose --no-limit --height 20 --header "Pick apps to install (space to select, enter to confirm)" |
        awk '{ print $1 }') || true
    else
      while IFS= read -r line; do
        confirm "Install ${line}?" no && chosen+=("${line%% *}")
      done < <(describe_list "$list")
    fi
    ;;
  *) die "--apps takes all, none or ask" ;;
  esac

  if ((${#chosen[@]} == 0)); then
    info "No apps picked."
    return
  fi
  install_packages "${chosen[@]}"
}

# --- config files ----------------------------------------------------------

# Copy one file into place, pointing my home-directory paths at yours.
put_file() { # put_file source dest
  local src=$1 dest=$2 tmp mode
  tmp=$(mktemp)
  if grep -qF "$SOURCE_HOME/" "$src" 2>/dev/null && [[ $SOURCE_HOME != "$HOME" ]]; then
    sed "s|$SOURCE_HOME/|$HOME/|g" "$src" >"$tmp"
  else
    cat "$src" >"$tmp"
  fi
  if [[ -f $dest && ! -L $dest ]] && cmp -s "$tmp" "$dest"; then
    rm -f "$tmp"
    return 1
  fi
  mode=$(stat -c %a "$src")
  if ((!DRY_RUN)); then
    backup "$dest"
    mkdir -p "$(dirname "$dest")"
    rm -f "$dest"
    install -m "$mode" "$tmp" "$dest"
  fi
  rm -f "$tmp"
}

install_tree() { # install_tree <dir holding a home/ tree> label
  local root=$1/home label=$2 rel changed=0 files=()
  [[ -d $root ]] || return 0
  mapfile -d '' -t files < <(cd "$root" && find . -type f -printf '%P\0' | sort -z)

  # hyprland.lua requires the other hypr files, and Hyprland reloads on every
  # write, so it goes in last. The xkb layout that input.lua names goes in
  # first, so no reload ever looks for a layout that isn't there yet.
  local first=() ordered=() last=()
  for rel in "${files[@]}"; do
    case $rel in
    .config/xkb/*) first+=("$rel") ;;
    .config/hypr/hyprland.lua) last+=("$rel") ;;
    *) ordered+=("$rel") ;;
    esac
  done

  for rel in "${first[@]}" "${ordered[@]}" "${last[@]}"; do
    if [[ $rel == .config/mimeapps.list ]] && [[ ! -e /usr/share/applications/brave-origin.desktop ]]; then
      info "kept your default apps (mimeapps.list wants Brave Origin, which isn't installed)"
      continue
    fi
    if put_file "$root/$rel" "$HOME/$rel"; then
      changed=$((changed + 1))
      info "~/$rel"
    fi
  done
  ok "$label: $changed file(s) changed, $((${#files[@]} - changed)) already up to date"
}

# The Lao layout's two-character keys (Shift+] = ຫຼ ...) are compose rules in
# ~/.config/xkb/lao.XCompose. ~/.XCompose holds your own name and email, so it
# isn't copied; it gets one include line instead.
setup_lao_keyboard() {
  local xcompose=$HOME/.XCompose line='include "%H/.config/xkb/lao.XCompose"'
  [[ -f $REPO_DIR/portable/home/.config/xkb/lao.XCompose ]] || return 0
  grep -qF "$line" "$xcompose" 2>/dev/null && return 0
  info "~/.XCompose (+ include for the Lao keyboard)"
  ((DRY_RUN)) && return 0
  backup "$xcompose"
  # Without a ~/.XCompose the locale's rules apply; keep them.
  [[ -e $xcompose ]] || printf 'include "%%L"\n' >"$xcompose"
  printf '\n# Lao (Windows) keyboard: keys that type two characters (see the file).\n%s\n' "$line" >>"$xcompose"
  if in_session; then
    omarchy-restart-xcompose >/dev/null 2>&1 ||
      problem "couldn't restart fcitx5; Shift + ] = ຫຼ works after you log in again"
  fi
}

step_config() {
  step "Config files"
  install_tree "$REPO_DIR/portable" "config"
  setup_lao_keyboard
  # New fonts (Lao Term for Kitty) are only seen after fc-cache.
  run fc-cache "$HOME/.local/share/fonts" >/dev/null 2>&1 || true

  if [[ -n $MACHINE && -d $REPO_DIR/device/$MACHINE ]]; then
    if confirm "This is a $MACHINE, like mine. Use my monitor layout for it too?" yes; then
      install_tree "$REPO_DIR/device/$MACHINE" "$MACHINE monitor layout"
    fi
    # System files for faster sleep/wake. Left to you because they go in /usr and /etc.
    if [[ -f $REPO_DIR/device/$MACHINE/root/install.sh && ! -e /usr/local/libexec/wifi-quick-reconnect ]]; then
      info "Faster sleep/wake (Wi-Fi back in seconds): run once: sudo bash $REPO_DIR/device/$MACHINE/root/install.sh"
    fi
  else
    info "Monitor layout: kept yours (set screens up with the Displays widget or hyprmoncfg)"
  fi

  if [[ -d $REPO_DIR/personal/home ]] && confirm "Use my JARNKET screensaver text too?" no; then
    install_tree "$REPO_DIR/personal" "branding"
  fi
}

# --- plugins ---------------------------------------------------------------

# One-time setup a plugin needs after cloning. Keep in sync with README.md.
plugin_setup() {
  local id=$1 dir=$PLUGINS_DIR/$1
  case $id in
  beam)
    # Puts omarchy-beam on PATH; nothing else.
    backup "$HOME/.local/bin/omarchy-beam"
    run "$dir/install.sh" >/dev/null
    ;;
  rblalock.panel-notes)
    # Its own scripts/setup also writes the Super+Alt+E binding, which
    # bindings.lua already has (and it refuses to run because of that).
    backup "$HOME/.local/bin/panel-notes"
    mkdir -p "$HOME/.local/bin"
    run ln -sfn "$dir/panel-notes" "$HOME/.local/bin/panel-notes"
    ;;
  ilysorc.pointer-feel)
    # Builds its Hyprland modules against the running Hyprland, so it needs a
    # live session. Its input.lua/autostart.lua lines are already there.
    if in_session; then
      info "building Pointer Feel's Hyprland modules (takes a minute)"
      run "$dir/install.sh" --yes --no-restart
    else
      manual "Log in, then run: $dir/install.sh --yes"
    fi
    ;;
  esac
}

step_plugins() {
  step "Shell plugins"
  mkdir -p "$PLUGINS_DIR"
  local id source revision added=0 present=0
  while IFS=$'\t' read -r id source revision; do
    if [[ -d $PLUGINS_DIR/$id ]]; then
      present=$((present + 1))
      continue
    fi
    info "adding $id"
    if ((DRY_RUN)); then
      run omarchy plugin add "$source" --yes
      continue
    fi
    # plugin add asks the running shell to rescan at the end; the clone is what
    # matters, so judge it by the folder.
    omarchy plugin add "$source" --yes >/dev/null 2>&1 || true
    if [[ ! -d $PLUGINS_DIR/$id ]]; then
      problem "plugin $id didn't install ($source)"
      continue
    fi
    record plugins-added "$id"
    added=$((added + 1))
    if ((PINNED)) && [[ -n $revision ]]; then
      git -C "$PLUGINS_DIR/$id" -c advice.detachedHead=false checkout -q "$revision" ||
        problem "$id: couldn't check out $revision; left it on the latest version"
    fi
    plugin_setup "$id" || problem "$id: its setup step failed (see the output above)"
  done < <(jq -r '.plugins[] | select(.source) | [.id, .source, (.revision // "")] | @tsv' "$REPO_DIR/manifests/plugins.json")

  # Plugins I wrote that only live in this repo.
  local src
  for src in "$REPO_DIR"/extras/plugins/*/; do
    src=${src%/}
    id=$(basename "$src")
    if [[ -d $PLUGINS_DIR/$id ]] && diff -rq "$src" "$PLUGINS_DIR/$id" >/dev/null; then
      present=$((present + 1))
      continue
    fi
    info "adding $id (from this repo)"
    if ((!DRY_RUN)); then
        if [[ -d $PLUGINS_DIR/$id ]]; then backup "$PLUGINS_DIR/$id"; else record plugins-added "$id"; fi
      rm -rf "${PLUGINS_DIR:?}/$id"
      cp -a "$src" "$PLUGINS_DIR/$id"
    fi
    added=$((added + 1))
  done

  # Command-line tools of my plugins: omarchy-topbar, diskkeeper, memkeeper and ask-claude.
  local tool name
  for tool in "$PLUGINS_DIR/shadowone.top-bar/omarchy-topbar" "$PLUGINS_DIR/shadowone.disk-keeper/bin/diskkeeper" \
    "$PLUGINS_DIR/shadowone.memory-keeper/bin/memkeeper" "$PLUGINS_DIR/shadowone.ask-claude/bin/ask-claude"; do
    name=$(basename "$tool")
    if [[ -x $tool || $DRY_RUN == 1 ]] && [[ "$(readlink "$HOME/.local/bin/$name" 2>/dev/null)" != "$tool" ]]; then
      backup "$HOME/.local/bin/$name"
      mkdir -p "$HOME/.local/bin"
      run ln -sfn "$tool" "$HOME/.local/bin/$name"
    fi
  done

  # Disk Keeper's System items (old packages, journal, snapshots) need a small
  # root helper. It's left to you because it puts files in /usr.
  if [[ -d $PLUGINS_DIR/shadowone.disk-keeper && ! -e /usr/local/libexec/diskkeeper-root ]]; then
    info "Disk Keeper: for its System items, run once: sudo bash ~/.config/omarchy/plugins/shadowone.disk-keeper/root/install.sh"
  fi

  # Ask Claude answers through the Claude Code CLI and your own Claude login.
  if [[ -d $PLUGINS_DIR/shadowone.ask-claude ]] && ! command -v claude >/dev/null; then
    manual "Ask Claude (Super+A) needs Claude Code: curl -fsSL https://claude.ai/install.sh | bash, then run claude once to sign in"
  fi

  ok "$added added, $present already installed"
  ((PINNED)) || info "Plugins are on their latest versions (--pinned uses the ones I tested)."
}

# --- bar layout ------------------------------------------------------------

step_bar() {
  step "Bar layout"
  local src=$REPO_DIR/manifests/shell.json
  if [[ -f $SHELL_JSON ]] && cmp -s "$src" "$SHELL_JSON"; then
    ok "already the same"
    return
  fi
  if ((DRY_RUN)); then
    printf '    %s[dry-run]%s write ~/.config/omarchy/shell.json\n' "$DIM" "$RESET"
  else
    backup "$SHELL_JSON"
    install -D -m 644 "$src" "$SHELL_JSON"
    ok "installed shell.json (bottom bar + Top Bar)"
  fi
  RESTART_SHELL=1
}

# --- theme -----------------------------------------------------------------

clone_theme() { # clone_theme url -> prints the theme name
  local url=$1 name
  name=$(basename -- "$url" .git | sed -E 's/^omarchy-//; s/-theme$//' | tr '[:upper:]' '[:lower:]')
  (LC_ALL=C; [[ $name =~ ^[a-z0-9_][a-z0-9._+-]*$ ]]) || { problem "odd theme URL: $url"; return 1; }
  if [[ -e $THEMES_DIR/$name ]]; then
    return 0
  fi
  info "adding theme $name"
  if ((!DRY_RUN)); then
    mkdir -p "$THEMES_DIR"
    git clone -q --depth 1 -- "$url" "$THEMES_DIR/$name" || { problem "theme $name didn't download"; return 1; }
    record themes-added "$name"
  fi
}

step_theme() {
  step "Theme"
  local url
  while IFS= read -r url; do
    clone_theme "$url" || true
  done < <(read_list "$REPO_DIR/manifests/themes.txt")

  # The ThinkPad theme ships its wallpapers, so there's nothing to render.
  if ! in_session; then
    manual "Log in to the desktop, then run: omarchy theme set $THEME_NAME"
  elif [[ "$(current_theme)" == "$THEME_NAME" ]]; then
    ok "$THEME_NAME is already the current theme"
  elif run omarchy theme set "$THEME_NAME" >/dev/null 2>&1; then
    ok "switched to the $THEME_NAME theme"
  else
    problem "omarchy theme set $THEME_NAME failed"
  fi

  if ((BOOT_LOGO)); then
    need_sudo
    info "putting the ThinkPad logo on the boot and login screens (rebuilds the initramfs)"
    run omarchy plymouth set by theme "$THEME_NAME" || problem "boot logo didn't apply"
    # The post-update hook puts the logo back after Omarchy updates, but only
    # where this marker says the logo was chosen.
    local marker=$HOME/.local/state/omarchy/thinkpad-boot-logo
    if [[ ! -e $marker ]]; then
      backup "$marker"
      run mkdir -p "$(dirname "$marker")"
      run touch "$marker"
    fi
  else
    info "Boot/login logo not changed (add --boot-logo for that)."
  fi
}

# --- services --------------------------------------------------------------

step_services() {
  step "Services"
  if command -v hyprmoncfg >/dev/null && systemctl --user cat hyprmoncfgd.service >/dev/null 2>&1; then
    if systemctl --user is-enabled -q hyprmoncfgd.service 2>/dev/null; then
      ok "hyprmoncfgd already on"
    else
      if run systemctl --user enable --now hyprmoncfgd.service >/dev/null 2>&1; then
        ok "hyprmoncfgd on (switches monitor profiles when screens change)"
      else
        problem "couldn't start hyprmoncfgd"
      fi
    fi
  else
    info "hyprmoncfg isn't installed; skipped hyprmoncfgd"
  fi

  # Checks the plugins for updates every 6 h and notifies; nothing installs on its own.
  if [[ -f $HOME/.config/systemd/user/plugin-updates.timer ]]; then
    systemctl --user daemon-reload >/dev/null 2>&1 || true
    if systemctl --user is-enabled -q plugin-updates.timer 2>/dev/null; then
      ok "plugin-updates.timer already on"
    elif run systemctl --user enable --now plugin-updates.timer >/dev/null 2>&1; then
      record services-enabled plugin-updates.timer
      ok "plugin-updates.timer on (a notification when plugins have updates)"
    else
      problem "couldn't start plugin-updates.timer"
    fi
  fi

  # Stops Claude Code sessions left idle and eases memory pressure every 5 min while awake.
  if [[ -f $HOME/.config/systemd/user/memory-keeper.timer ]]; then
    systemctl --user daemon-reload >/dev/null 2>&1 || true
    if systemctl --user is-enabled -q memory-keeper.timer 2>/dev/null; then
      ok "memory-keeper.timer already on"
    elif run systemctl --user enable --now memory-keeper.timer >/dev/null 2>&1; then
      record services-enabled memory-keeper.timer
      ok "memory-keeper.timer on (stops idle Claude sessions; turn it off in its panel)"
    else
      problem "couldn't start memory-keeper.timer"
    fi
  fi

  # Suspends after 45 min idle, only on battery (~/.config/hypr/hypridle.conf).
  if command -v hypridle >/dev/null && [[ -f $HOME/.config/hypr/hypridle.conf ]]; then
    if systemctl --user is-enabled -q hypridle.service 2>/dev/null; then
      ok "hypridle already on"
    elif run systemctl --user enable --now hypridle.service >/dev/null 2>&1; then
      record services-enabled hypridle.service
      ok "hypridle on (suspends after 45 min idle on battery)"
    else
      problem "couldn't start hypridle"
    fi
  fi

  # The wallpaper slideshow, if its settings say it's on.
  if [[ -f $HOME/.config/systemd/user/wallpaper-slideshow.timer ]] &&
    grep -qx 'enabled=1' "$HOME/.config/wallpaper-slideshow.conf" 2>/dev/null; then
    if systemctl --user is-enabled -q wallpaper-slideshow.timer 2>/dev/null; then
      ok "wallpaper-slideshow.timer already on"
    elif run systemctl --user enable --now wallpaper-slideshow.timer >/dev/null 2>&1; then
      record services-enabled wallpaper-slideshow.timer
      ok "wallpaper-slideshow.timer on (a new background every 15 minutes)"
    else
      problem "couldn't start wallpaper-slideshow.timer"
    fi
  fi
}

# --- herdr -----------------------------------------------------------------

# The Herdr app (herdr.dev): the orchi layout, the mods in herdr/mods.tsv at
# the commits I reviewed with my changes from herdr/patches, the helpers they
# build, the Lao fonts for Herdr's UI and terminals, and the Claude Code side.

HERDR_CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/jarnket-omarchy-config/herdr"
# Geist, the UI font Herdr ships, from its own release (Geist Lao is built on it).
GEIST_ZIP_URL="https://github.com/vercel/geist-font/releases/download/v1.9.2/geist-font-v1.9.2.zip"
GEIST_ZIP_SHA256="15f066d58dcb99fb10014a49913009fdaf41e464cfb8851a44b44e593c95d3d8"
FONT_TOOLS=("uharfbuzz==0.57.0" "fonttools==4.68.0")
RECAP_SRC=""

herdr_app() {
  command -v herdr-app 2>/dev/null && return
  [[ -x $HOME/.local/bin/herdr-app ]] && printf '%s' "$HOME/.local/bin/herdr-app"
}

# Same mod, apart from what Herdr writes into it and the built helper.
herdr_same() {
  diff -rq --exclude=jsconfig.json --exclude='*.d.ts' --exclude=node_modules --exclude=bin "$1" "$2" >/dev/null 2>&1
}

# Each mod is put together in a hidden folder (Herdr doesn't watch those),
# checked, and swapped in with one rename, only when it differs from the one
# installed: Herdr reloads a mod on every file it sees change.
herdr_mods() {
  local app=$1 mods_dir=$HERDR_APP_HOME/mods stage repo sha folder mods more m dir gitview="" changed=0 same=0
  stage=$mods_dir/.jarnket-stage
  rm -rf "$stage"
  mkdir -p "$stage"
  info "fetching the mods at their commits…"
  while IFS=$'\t' read -r repo sha folder mods more; do
    # shellcheck disable=SC2086 # word lists
    if ! dir=$(herdr_fetch "$repo" "$sha" "$folder" $more); then
      problem "Herdr: couldn't fetch $repo at ${sha:0:7}"
      continue
    fi
    [[ $repo == */herdr-gitview ]] && gitview=$dir
    [[ $repo == */herdr-recap ]] && RECAP_SRC=$dir
    for m in $mods; do
      herdr_clean_copy "$dir/$folder/$m" "$stage/$m"
      herdr_apply_patch "$stage" "$m" || problem "Herdr: my changes to $m didn't apply"
    done
  done < <(herdr_sources)
  # My own mods, kept whole in herdr/mods.
  for dir in "$HERDR_DIR"/mods/*/; do
    [[ -d $dir ]] || continue
    herdr_clean_copy "${dir%/}" "$stage/$(basename "$dir")"
  done

  if [[ -d $stage/gitview && -n $gitview ]]; then
    info "building gitview's helper (cargo)…"
    if (cd "$gitview" && cargo build --release --locked --quiet) >/dev/null 2>&1; then
      install -D -m 755 "$gitview/target/release/herdr-gitview" "$stage/gitview/bin/herdr-gitview"
      printf '{\n  "bin": "%s",\n  "herdr_app": "%s",\n  "hc": "%s"\n}\n' \
        "$mods_dir/gitview/bin/herdr-gitview" "$app" "$(command -v hc || printf '%s' "$HOME/.local/bin/hc")" \
        >"$stage/gitview/config.json"
    else
      problem "Herdr: gitview's helper didn't build (cargo build in $gitview)"
    fi
  fi
  if [[ -d $stage/kolczyk/node-helper ]]; then
    # Only the packages in its lockfile, and no install scripts.
    (cd "$stage/kolczyk/node-helper" && npm ci --ignore-scripts --no-audit --no-fund --silent) >/dev/null 2>&1 ||
      problem "Herdr: Kolczyk's image helper didn't install, so its Image mode won't work"
  fi

  for dir in "$stage"/*/; do
    dir=${dir%/}
    m=$(basename "$dir")
    if ! "$app" check "$dir" >/dev/null 2>&1; then
      problem "Herdr: $m failed herdr-app check; left as it was"
      continue
    fi
    if [[ -d $mods_dir/$m ]] && herdr_same "$dir" "$mods_dir/$m"; then
      same=$((same + 1))
      continue
    fi
    backup "$mods_dir/$m"
    rm -rf "${mods_dir:?}/$m"
    mv "$dir" "$mods_dir/$m"
    changed=$((changed + 1))
    info "~/.config/herdr-app/mods/$m"
  done
  rm -rf "$stage"
  ok "Herdr mods: $changed installed or updated, $same already up to date"
}

# The recap mod downloads its helper when it's missing; build it from the
# reviewed commit instead, where the mod looks for it.
herdr_recap() {
  local ver dest
  [[ -n $RECAP_SRC && -f $HERDR_APP_HOME/mods/recap/main.js ]] || return 0
  ver=$(sed -n 's/^export const RECAP_VERSION = "\(.*\)";/\1/p' "$HERDR_APP_HOME/mods/recap/main.js")
  [[ -n $ver ]] || return 0
  dest=$HOME/.local/share/herdr-recap/app/$ver/herdr-recap
  [[ -x $dest ]] && return 0
  info "building herdr-recap $ver (go)…"
  backup "$HOME/.local/share/herdr-recap"
  mkdir -p "$(dirname "$dest")"
  if (cd "$RECAP_SRC" && CGO_ENABLED=0 go build -mod=readonly -trimpath -ldflags "-s -w" -o "$dest" .) >/dev/null 2>&1; then
    ok "herdr-recap $ver built"
  else
    problem "herdr-recap didn't build; the recap mod would download it itself"
  fi
}

# font and ui_font from herdr/settings.json; the rest of Herdr's settings stay yours.
herdr_settings() {
  local f=$HERDR_APP_HOME/settings.json tmp
  tmp=$(mktemp)
  if [[ -s $f ]]; then
    if ! jq -s '.[0] * .[1]' "$f" "$HERDR_DIR/settings.json" >"$tmp" 2>/dev/null; then
      rm -f "$tmp"
      problem "Herdr: settings.json isn't valid JSON, so its fonts weren't set"
      return 0
    fi
  else
    cp "$HERDR_DIR/settings.json" "$tmp"
  fi
  if [[ -f $f ]] && cmp -s <(jq -S . "$f") <(jq -S . "$tmp"); then
    rm -f "$tmp"
    return 0
  fi
  backup "$f"
  install -m 644 "$tmp" "$f"
  rm -f "$tmp"
  info "~/.config/herdr-app/settings.json (font, ui_font)"
}

# GPUI on Linux drops the offsets that put Lao vowels and tone marks on their
# consonant, so Herdr gets fonts with every cluster precomposed: JetBrains Mono
# Lao for terminals and Geist Lao for the UI (generators in ~/.local/share/lao-term).
herdr_fonts() {
  local fonts=$HERDR_APP_HOME/fonts gen=$HOME/.local/share/lao-term venv=$HOME/.cache/lao-term/venv
  local py w out ttf geist=$HERDR_CACHE/geist need=0
  for w in JetBrainsMonoLao-Regular JetBrainsMonoLao-Bold GeistLao-Regular GeistLao-Medium GeistLao-SemiBold GeistLao-Bold; do
    [[ -f $fonts/$w.ttf ]] || need=1
  done
  ((need)) || return 0
  if [[ ! -f $gen/make-jbm-lao.py || ! -f $gen/make-ui-lao.py ]]; then
    problem "Herdr: the Lao font generators aren't in ~/.local/share/lao-term (the config step puts them there)"
    return 0
  fi
  py=$venv/bin/python
  if ! "$py" -c 'import uharfbuzz, fontTools' >/dev/null 2>&1; then
    info "font tools (${FONT_TOOLS[*]}) into ~/.cache/lao-term/venv…"
    if ! { python3 -m venv "$venv" && "$py" -m pip install -q "${FONT_TOOLS[@]}"; } >/dev/null 2>&1; then
      problem "Herdr: couldn't set up the font tools, so Lao stays broken in Herdr"
      return 0
    fi
  fi
  mkdir -p "$fonts"
  info "building the Lao fonts for Herdr (a few minutes)…"
  for w in Regular Bold; do
    out=$fonts/JetBrainsMonoLao-$w.ttf
    [[ -f $out ]] && continue
    backup "$out"
    "$py" "$gen/make-jbm-lao.py" "/usr/share/fonts/TTF/JetBrainsMonoNerdFont-$w.ttf" \
      "$HOME/.local/share/fonts/LaoTerm-$w.ttf" "$out" "$w" >/dev/null 2>&1 ||
      problem "Herdr: JetBrains Mono Lao $w didn't build"
  done
  if [[ ! -d $geist/x ]]; then
    mkdir -p "$geist"
    if ! { curl -fsSL -o "$geist/geist.zip" "$GEIST_ZIP_URL" &&
      printf '%s  %s\n' "$GEIST_ZIP_SHA256" "$geist/geist.zip" | sha256sum -c --quiet &&
      unzip -q -o "$geist/geist.zip" -d "$geist/x"; } >/dev/null 2>&1; then
      rm -rf "$geist"
      problem "Herdr: couldn't download Geist ($GEIST_ZIP_URL), so Geist Lao wasn't built"
      return 0
    fi
  fi
  ttf=$geist/x/geist-font/Geist/ttf
  # Noto Sans Lao has no SemiBold; SemiBold takes its Medium.
  for w in Regular:Regular Medium:Medium SemiBold:Medium Bold:Bold; do
    out=$fonts/GeistLao-${w%%:*}.ttf
    [[ -f $out ]] && continue
    backup "$out"
    "$py" "$gen/make-ui-lao.py" "$ttf/Geist-${w%%:*}.ttf" "/usr/share/fonts/noto/NotoSansLao-${w##*:}.ttf" \
      "$out" "${w%%:*}" >/dev/null 2>&1 || problem "Herdr: Geist Lao ${w%%:*} didn't build"
  done
  ok "Lao fonts for Herdr in ~/.config/herdr-app/fonts"
}

herdr_links() {
  local link=$HOME/.local/bin/opengpui target=$HERDR_APP_HOME/mods/opengpui/cli/opengpui
  [[ -f $target ]] || return 0
  [[ $(readlink "$link" 2>/dev/null) == "$target" ]] && return 0
  backup "$link"
  mkdir -p "$(dirname "$link")"
  ln -sfn "$target" "$link"
  info "~/.local/bin/opengpui"
}

# What the mods add to Claude Code, through their own installers (each finds
# its own entries again, so a rerun changes nothing).
herdr_claude() {
  local mods=$HERDR_APP_HOME/mods
  if [[ ! -d $HOME/.claude ]]; then
    manual "Install Claude Code, then run: $REPO_DIR/install.sh --only herdr (revive, the to-do list and the usage line hook into it)"
    return 0
  fi
  confirm "Set up the Claude Code side too (revive's session hooks, the to-do rule and hook, the usage status line, the OpenUI rule)?" yes || return 0
  local f
  for f in .claude/settings.json .claude/CLAUDE.md .codex/AGENTS.md .pi/agent/AGENTS.md .local/bin/todo; do
    backup "$HOME/$f"
  done
  node "$mods/revive/revive.mjs" install --no-shell --no-codex --no-pi --no-omp --no-droid --no-cursor >/dev/null 2>&1 ||
    problem "revive's Claude Code hooks didn't install"
  sh "$mods/over9k-usage/setup.sh" status on "$mods/over9k-usage/claude-statusline.sh" >/dev/null 2>&1 ||
    problem "the usage status line didn't install"
  sh "$mods/over9k-todos/setup.sh" todo on "$mods" >/dev/null 2>&1 ||
    problem "the to-do rule and hook didn't install"
  # When to show answers as OpenUI panels; added once, between its markers.
  if ! grep -q 'herdr:openui -->' "$HOME/.claude/CLAUDE.md" 2>/dev/null; then
    { [[ -s $HOME/.claude/CLAUDE.md ]] && printf '\n'; cat "$HERDR_DIR/claude-openui.md"; } >>"$HOME/.claude/CLAUDE.md"
  fi
  ok "Claude Code: revive's hooks, the to-do rule and hook, the usage status line, the OpenUI rule"
}

step_herdr() {
  step "Herdr app: orchi layout, mods, Lao fonts"
  HERDR_DIR=$REPO_DIR/herdr
  # shellcheck source=herdr/sources.sh
  source "$HERDR_DIR/sources.sh"
  local app t missing=()
  app=$(herdr_app || true)
  if [[ -z $app ]]; then
    info "skipped: the Herdr app isn't installed"
    manual "Install the Herdr app (https://herdr.dev), open it once, then run: $REPO_DIR/install.sh --only herdr"
    return 0
  fi
  if [[ ! -d $HERDR_APP_HOME ]]; then
    info "skipped: ~/.config/herdr-app doesn't exist yet"
    manual "Open the Herdr app once (it creates ~/.config/herdr-app), then run: $REPO_DIR/install.sh --only herdr"
    return 0
  fi
  for t in git cargo go node npm patch python3 jq curl unzip sha256sum; do
    command -v "$t" >/dev/null 2>&1 || missing+=("$t")
  done
  if ((${#missing[@]})); then
    problem "Herdr step skipped: ${missing[*]} missing (the packages step installs them)"
    return 0
  fi
  if ((DRY_RUN)); then
    info "would fetch the mods in herdr/mods.tsv at their commits, apply herdr/patches, build gitview's and herdr-recap's helpers and the Lao fonts, and set up the Claude Code side"
    install_tree "$REPO_DIR/herdr" "Herdr layout, keys and helpers"
    return 0
  fi
  herdr_mods "$app"
  herdr_recap
  install_tree "$REPO_DIR/herdr" "Herdr layout, keys and helpers"
  herdr_settings
  herdr_fonts
  herdr_links
  herdr_claude
  if "$app" status >/dev/null 2>&1; then
    "$app" do layout.switch --name orchi >/dev/null 2>&1 && ok "Herdr shows the orchi layout"
  else
    manual "Open Herdr and press Ctrl+Shift+L until it shows the orchi layout"
  fi
}

# --- main ------------------------------------------------------------------

want() { # want <step>
  local s=$1
  [[ " $ONLY " == *" $s "* ]] && [[ " $SKIP " != *" $s "* ]]
}

finish() {
  if ((RESTART_SHELL)) && ((!DRY_RUN)); then
    if in_session; then
      step "Restarting the shell"
      if omarchy restart shell >/dev/null 2>&1; then ok "shell restarted"; else problem "omarchy restart shell failed"; fi
    else
      manual "Log in to the desktop (or run: omarchy restart shell)"
    fi
  fi

  if in_session && ((!DRY_RUN)); then
    local errors
    errors=$(hyprctl configerrors 2>/dev/null | grep -v '^[[:space:]]*$' || true)
    if [[ -n $errors ]]; then
      problem "Hyprland reports config errors:"
      printf '      %s\n' "$errors" >&2
    fi
  fi

  step "Done"
  if [[ -n $BACKUP_DIR ]]; then
    info "Backup of everything replaced: $BACKUP_DIR"
    info "Undo with: $REPO_DIR/install.sh --undo"
  fi
  if ((${#PROBLEMS[@]})); then
    echo
    warn "${#PROBLEMS[@]} thing(s) need a look:"
    printf '      - %s\n' "${PROBLEMS[@]}" >&2
  fi
  if ((${#MANUAL[@]})); then
    echo
    info "Still to do:"
    printf '      - %s\n' "${MANUAL[@]}"
  fi
}

main() {
  ASSUME_YES=0 DRY_RUN=0 PINNED=0 BOOT_LOGO=0 RESTART_SHELL=0
  APPS=ask ONLY=$ALL_STEPS SKIP="" UNDO="" UNDO_DIR=""

  while (($#)); do
    case $1 in
    -y | --yes) ASSUME_YES=1 ;;
    -n | --dry-run) DRY_RUN=1 ;;
    --only) ONLY=${2:?--only needs a list of steps}; ONLY=${ONLY//,/ }; shift ;;
    --skip) SKIP=${2:?--skip needs a list of steps}; SKIP=${SKIP//,/ }; shift ;;
    --apps) APPS=${2:?--apps takes all, none or ask}; shift ;;
    --pinned) PINNED=1 ;;
    --boot-logo) BOOT_LOGO=1 ;;
    --undo)
      UNDO=1
      if [[ -n ${2:-} && $2 != -* ]]; then UNDO_DIR=$2; shift; fi
      ;;
    -h | --help) usage; exit 0 ;;
    *) usage >&2; die "unknown option: $1" ;;
    esac
    shift
  done

  local s
  for s in $ONLY $SKIP; do
    [[ " $ALL_STEPS " == *" $s "* ]] || die "unknown step: $s (steps: $ALL_STEPS)"
  done

  if [[ -n $UNDO ]]; then
    undo "$UNDO_DIR"
    exit 0
  fi

  echo "${BOLD}ShadowOne's Omarchy setup${RESET}"
  ((DRY_RUN)) && echo "${DIM}Dry run: nothing will be changed.${RESET}"
  preflight
  if ! ((ASSUME_YES)) && interactive; then
    echo
    info "Steps: $(for s in $ALL_STEPS; do want "$s" && printf '%s ' "$s"; done)"
    confirm "Start?" yes || exit 0
  fi
  start_backup

  want packages && step_packages
  want apps && step_apps
  want config && step_config
  want plugins && step_plugins
  want bar && step_bar
  want theme && step_theme
  want services && step_services
  want herdr && step_herdr
  finish
}

bootstrap "$@"
main "$@"
