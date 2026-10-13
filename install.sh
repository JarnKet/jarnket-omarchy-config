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

ALL_STEPS="packages apps config plugins bar theme services"

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
  services  user services the plugins need (hyprmoncfgd)

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

record() { # record plugins-added|themes-added value
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
  # write, so it goes in last.
  local ordered=() last=()
  for rel in "${files[@]}"; do
    if [[ $rel == .config/hypr/hyprland.lua ]]; then last+=("$rel"); else ordered+=("$rel"); fi
  done

  for rel in "${ordered[@]}" "${last[@]}"; do
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

step_config() {
  step "Config files"
  install_tree "$REPO_DIR/portable" "config"

  if [[ -n $MACHINE && -d $REPO_DIR/device/$MACHINE ]]; then
    if confirm "This is a $MACHINE, like mine. Use my monitor layout for it too?" yes; then
      install_tree "$REPO_DIR/device/$MACHINE" "$MACHINE monitor layout"
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

  # The Top Bar's command-line tool.
  local topbar=$PLUGINS_DIR/shadowone.top-bar/omarchy-topbar
  if [[ -x $topbar || $DRY_RUN == 1 ]] && [[ "$(readlink "$HOME/.local/bin/omarchy-topbar" 2>/dev/null)" != "$topbar" ]]; then
    backup "$HOME/.local/bin/omarchy-topbar"
    mkdir -p "$HOME/.local/bin"
    run ln -sfn "$topbar" "$HOME/.local/bin/omarchy-topbar"
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
    ok "installed shell.json (bottom bar + Top Bar, omapager for notifications)"
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

  local tools=$THEMES_DIR/$THEME_NAME/tools
  local bg_dir=$HOME/.config/omarchy/backgrounds/$THEME_NAME
  if [[ -n $(find "$bg_dir" -maxdepth 1 -type f 2>/dev/null | head -n 1) ]]; then
    ok "wallpapers already in ${bg_dir/#"$HOME"/\~}"
  elif [[ -f $tools/make-ascii-wallpaper.py ]] || ((DRY_RUN)); then
    local args out
    for args in "--world 1-ascii-world.png" " 2-ascii-thinkpad.png"; do
      out=$bg_dir/${args##* }
      [[ -f $out ]] && continue
      info "rendering wallpaper ${out##*/} (a few seconds)"
      if ((!DRY_RUN)); then
        mkdir -p "$bg_dir"
        backup "$out"
        # shellcheck disable=SC2086 # unquoted on purpose: the flag, or nothing
        python3 -I "$tools/make-ascii-wallpaper.py" ${args% *} "$out" >/dev/null ||
          problem "couldn't render ${out##*/} (needs python-numpy and python-pillow)"
      fi
    done
  fi

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
  finish
}

bootstrap "$@"
main "$@"
