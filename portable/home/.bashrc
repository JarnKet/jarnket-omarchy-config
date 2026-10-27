# Omarchy environment (OMARCHY_PATH + PATH), needed even for non-interactive shells
[[ -r /usr/share/omarchy/default/bash/env-bootstrap ]] && source /usr/share/omarchy/default/bash/env-bootstrap

# If not running interactively, don't do anything else (leave this above the rc source)
[[ $- != *i* ]] && return

# All the default Omarchy aliases and functions
# (don't mess with these directly, just overwrite them here!)
source "$OMARCHY_PATH/default/bash/rc"

# Add your own exports, aliases, and functions here.
#
# Make an alias for invoking commands you use constantly
# alias p='python'

# Hyprland isn't in Chromium's desktop-environment allowlist, so Electron falls back
# to the plaintext "basic" password store and won't persist the Claude sign-in.
alias claude-desktop='/usr/bin/claude-desktop --password-store=gnome-libsecret'

# Oh My Posh prompt instead of Omarchy's starship, which the rc above has already started.
# Its colors follow the Omarchy theme: ~/.config/omarchy/themed/oh-my-posh.omp.json.tpl
# is rendered into the current theme on every `omarchy theme set`.
omp_config="$HOME/.local/state/omarchy/current/theme/oh-my-posh.omp.json"
if command -v oh-my-posh &>/dev/null && [[ -f $omp_config ]]; then
  for i in "${!PROMPT_COMMAND[@]}"; do
    [[ ${PROMPT_COMMAND[i]} == starship_precmd ]] && unset 'PROMPT_COMMAND[i]'
  done
  [[ $PS0 == *starship_preexec_ps0* ]] && PS0=
  eval "$(oh-my-posh init bash --config "$omp_config")"
fi
unset omp_config i

# Atuin: Ctrl+R searches all shell history (kept locally, see ~/.atuin/config.toml).
# The Up arrow stays plain bash. Load it after Oh My Posh: its bundled bash-preexec has to
# be the last thing that touches PROMPT_COMMAND.
if command -v atuin &>/dev/null; then
  eval "$(atuin init bash --disable-up-arrow)"
fi

# Yazi: `y` opens the file manager and leaves you in the folder you quit from.
y() {
  local tmp cwd
  tmp=$(mktemp -t "yazi-cwd.XXXXXX")
  yazi "$@" --cwd-file="$tmp"
  IFS= read -r -d '' cwd <"$tmp"
  [[ -n $cwd && $cwd != "$PWD" ]] && builtin cd -- "$cwd"
  rm -f -- "$tmp"
}
