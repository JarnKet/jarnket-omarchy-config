#!/usr/bin/env bash
# shellcheck disable=SC2088 # "~/..." in messages is meant literally
#
# Copy this machine's live Omarchy setup into the repo so install.sh can put it
# on another machine. It only writes inside the repo; review `git diff` before
# committing, because the repo is public.
#
#   ./snapshot.sh

set -euo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PLUGINS_DIR="$HOME/.config/omarchy/plugins"
THEMES_DIR="$HOME/.config/omarchy/themes"
MANIFESTS="$REPO_DIR/manifests"

warn() { printf '  ! %s\n' "$*" >&2; }

machine_slug() {
  local name
  name=$(cat /sys/class/dmi/id/product_family 2>/dev/null || true)
  [[ -n ${name// /} ]] || name=$(cat /sys/class/dmi/id/product_name 2>/dev/null || true)
  printf '%s' "$name" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/^-*//; s/-*$//'
}

# --- config files ----------------------------------------------------------

copy_into() { # copy_into <tree root> <path relative to ~>
  local root=$1 rel=$2
  if [[ -d $HOME/$rel ]]; then
    mkdir -p "$root/$rel"
    # Leave out the backups that Omarchy and plugins scatter next to configs.
    rsync -a --exclude='*.bak*' --exclude='*.orig' --exclude='*~' --exclude='* (Backup)*' \
      "$HOME/$rel/" "$root/$rel/"
  elif [[ -f $HOME/$rel ]]; then
    install -D -m "$(stat -c %a "$HOME/$rel")" "$HOME/$rel" "$root/$rel"
  else
    warn "~/$rel doesn't exist; left out"
  fi
}

snapshot_files() {
  local slug scope rel root
  slug=$(machine_slug)
  [[ -n $slug ]] || slug=unknown
  rm -rf "$REPO_DIR/portable/home" "$REPO_DIR/personal/home" "$REPO_DIR/device/$slug/home"

  while IFS=$'\t' read -r scope rel; do
    [[ -z $scope || $scope == \#* ]] && continue
    case $scope in
    portable) root=$REPO_DIR/portable/home ;;
    personal) root=$REPO_DIR/personal/home ;;
    device) root=$REPO_DIR/device/$slug/home ;;
    *) warn "unknown scope '$scope' for $rel"; continue ;;
    esac
    copy_into "$root" "$rel"
  done <"$MANIFESTS/files.tsv"
  echo "Config files: portable/, personal/, device/$slug/"
}

# --- plugins ---------------------------------------------------------------

snapshot_plugins() {
  local dir id entries=() entry source revision
  for dir in "$PLUGINS_DIR"/*/; do
    dir=${dir%/}
    [[ -f $dir/manifest.json ]] || continue
    id=$(jq -r '.id' "$dir/manifest.json")

    if [[ -d $dir/.git ]]; then
      source=$(git -C "$dir" remote get-url origin 2>/dev/null || true)
      revision=$(git -C "$dir" rev-parse HEAD)
      if [[ -n $(git -C "$dir" status --porcelain) ]]; then
        warn "$id has local edits that a fresh clone won't have:"
        git -C "$dir" status --short | sed 's/^/      /' >&2
      fi
    else
      # A plugin I wrote: it lives in this repo instead of being cloned.
      source="" revision=""
      mkdir -p "$REPO_DIR/extras/plugins"
      rsync -a --delete "$dir/" "$REPO_DIR/extras/plugins/$id/"
    fi

    entry=$(jq -n --slurpfile m "$dir/manifest.json" --arg source "$source" --arg revision "$revision" '
      $m[0] as $m | {
        id: $m.id,
        name: ($m.name // $m.id),
        version: ($m.version // null),
        source: (if $source == "" then null else $source end),
        revision: (if $revision == "" then null else $revision end),
        local: ($source == "")
      }')
    entries+=("$entry")
  done

  # Drop copies of local plugins that are no longer installed.
  local copy
  for copy in "$REPO_DIR"/extras/plugins/*/; do
    copy=${copy%/}
    if [[ -d $copy && ! -d $PLUGINS_DIR/$(basename "$copy") ]]; then rm -rf "$copy"; fi
  done

  printf '%s\n' "${entries[@]}" | jq -s '{plugins: (sort_by(.id))}' >"$MANIFESTS/plugins.json"
  cp "$HOME/.config/omarchy/shell.json" "$MANIFESTS/shell.json"
  echo "Plugins: ${#entries[@]} in manifests/plugins.json, bar layout in manifests/shell.json"
}

# --- themes ----------------------------------------------------------------

snapshot_themes() {
  local current dir url lines=()
  current=$(cat "$HOME/.local/state/omarchy/current/theme.name" 2>/dev/null || true)
  for dir in "$THEMES_DIR"/*/; do
    dir=${dir%/}
    url=$(git -C "$dir" remote get-url origin 2>/dev/null) || continue
    lines+=("$url")
  done
  {
    echo "# Themes install.sh clones into ~/.config/omarchy/themes/. thinkpad is the one it applies."
    printf '%s\n' "${lines[@]}" | sort
  } >"$MANIFESTS/themes.txt"
  echo "Themes: ${#lines[@]} in manifests/themes.txt (current: ${current:-?})"
}

# --- packages --------------------------------------------------------------

# The package lists are written by hand (packages.txt = needed, apps.txt =
# optional), so this only points out what's drifted.
check_packages() {
  local base listed extra gone
  base=$(cat /usr/share/omarchy/install/omarchy-*.packages 2>/dev/null | sed 's/#.*//' | tr -s ' \t' '\n' | sort -u)
  listed=$(sed 's/#.*//' "$MANIFESTS/packages.txt" "$MANIFESTS/apps.txt" | awk 'NF { print $1 }' | sort -u)
  # Kernel, firmware, Omarchy itself and hardware tools belong to the machine.
  local machine='^(linux.*|mkinitcpio|sudo|omarchy.*|amd-.*|intel-.*|.*-ucode|fwupd|fprintd|libfprint.*|usbutils|.*-debug)$'
  extra=$(comm -23 <(pacman -Qqe | grep -vE "$machine" | sort -u) <(printf '%s\n%s\n' "$base" "$listed" | sort -u) | tr '\n' ' ')
  gone=$(comm -23 <(sed 's/#.*//' "$MANIFESTS/apps.txt" | awk 'NF { print $1 }' | sort -u) <(pacman -Qq | sort -u) | tr '\n' ' ')
  if [[ -n ${extra// /} ]]; then
    echo "Installed here but in neither list (add to manifests/apps.txt if wanted): $extra"
  fi
  if [[ -n ${gone// /} ]]; then
    echo "In apps.txt but not installed here: $gone"
  fi
}

# --- privacy check ---------------------------------------------------------

check_secrets() {
  local hits
  hits=$(cd "$REPO_DIR" && grep -rIniE --exclude-dir=.git --exclude=snapshot.sh \
    'BEGIN [A-Z ]*PRIVATE KEY|api[_-]?key|secret|password|passwd|token|@gmail\.com|bearer ' \
    portable personal device manifests extras 2>/dev/null |
    grep -viE 'allow_token_by_default|password-store' || true)
  if [[ -n $hits ]]; then
    warn "These lines look sensitive. Check them before you commit:"
    printf '      %s\n' "$hits" >&2
  fi
}

main() {
  command -v jq >/dev/null || { echo "jq is missing" >&2; exit 1; }
  command -v rsync >/dev/null || { echo "rsync is missing (omarchy pkg add rsync)" >&2; exit 1; }
  snapshot_files
  snapshot_plugins
  snapshot_themes
  pacman -Q omarchy | awk '{ sub(/-[0-9]+$/, "", $2); print $2 }' >"$MANIFESTS/omarchy-version"
  echo "Omarchy: $(cat "$MANIFESTS/omarchy-version")"
  check_packages
  check_secrets
  echo
  git -C "$REPO_DIR" status --short
  echo
  echo "Review with: git -C $REPO_DIR diff"
}

main "$@"
