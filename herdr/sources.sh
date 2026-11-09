# shellcheck shell=bash
# The Herdr mods in mods.tsv: fetch them at their commits, copy them, and
# make or apply my patches. Sourced by install.sh and snapshot.sh, which set
# HERDR_DIR (this folder) and HERDR_CACHE (where checkouts are kept).

HERDR_APP_HOME=${HERDR_APP_HOME:-$HOME/.config/herdr-app}

# What Herdr or a build writes into a mod folder: never part of a patch.
HERDR_GENERATED=(gitview/bin gitview/config.json kolczyk/node-helper/node_modules)

# mods.tsv without comments: repo commit folder mods [more folders]
herdr_sources() { grep -v -e '^#' -e '^[[:space:]]*$' "$HERDR_DIR/mods.tsv"; }

# herdr_fetch <repo> <commit> <folder...>: a checkout of only those folders
# (and the files at the top), kept in the cache. Prints its path.
herdr_fetch() {
  local repo=$1 sha=$2 dir
  shift 2
  dir=$HERDR_CACHE/src/${repo//\//_}
  if [[ ! -d $dir/.git ]]; then
    rm -rf "$dir"
    mkdir -p "$dir"
    git -C "$dir" init -q
    git -C "$dir" remote add origin "https://github.com/$repo.git"
    git -C "$dir" sparse-checkout set --cone "$@" >/dev/null 2>&1
  else
    git -C "$dir" sparse-checkout add "$@" >/dev/null 2>&1
  fi
  if [[ $(git -C "$dir" rev-parse -q --verify HEAD 2>/dev/null) != "$sha" ]]; then
    git -C "$dir" fetch -q --depth 1 --filter=blob:none origin "$sha" &&
      git -C "$dir" checkout -q --detach FETCH_HEAD || return 1
  fi
  printf '%s' "$dir"
}

# herdr_clean_copy <mod folder> <dest>: the mod as it would be installed,
# links followed (gitview's mods share files through links), without what
# Herdr or a build writes into it.
herdr_clean_copy() {
  local src=$1 dest=$2 name g
  name=$(basename "$dest")
  rm -rf "$dest"
  mkdir -p "$(dirname "$dest")"
  cp -RL "$src" "$dest"
  find "$dest" \( -name jsconfig.json -o -name '*.d.ts' -o -name '.*' \) -prune -exec rm -rf {} + 2>/dev/null || true
  for g in "${HERDR_GENERATED[@]}"; do
    [[ $g == "$name"/* ]] && rm -rf "${dest:?}/${g#"$name"/}"
  done
  return 0
}

# herdr_make_patch <pristine mod folder> <live mod folder> <out.patch>:
# my changes as a patch against the commit in mods.tsv; no file when none.
# Prints a warning for a change a text patch can't carry.
herdr_make_patch() {
  local pristine=$1 live=$2 out=$3 name tmp
  name=$(basename "$live")
  tmp=$(mktemp -d)
  herdr_clean_copy "$pristine" "$tmp/a/$name"
  herdr_clean_copy "$live" "$tmp/b/$name"
  if (cd "$tmp" && diff -ruN "a/$name" "b/$name") >"$tmp/patch"; then
    rm -f "$out"
  else
    if grep -q '^Binary files ' "$tmp/patch"; then
      printf '  ! %s: binary changes left out of its patch\n' "$name" >&2
      grep -v '^Binary files ' "$tmp/patch" >"$out"
    else
      # Timestamps would make every snapshot a change.
      sed -E 's/^((---|\+\+\+) [^\t]+)\t.*$/\1/' "$tmp/patch" >"$out"
    fi
  fi
  rm -rf "$tmp"
}

# herdr_apply_patch <dir holding the mod folder> <mod>
herdr_apply_patch() {
  local root=$1 name=$2 p=$HERDR_DIR/patches/$2.patch
  [[ -f $p ]] || return 0
  patch -p1 -s --no-backup-if-mismatch -d "$root" <"$p"
}
