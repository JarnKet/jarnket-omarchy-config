-- Keep only your personal keybinding overrides here. Add new bindings or
-- unbind defaults before replacing them.

-- See current bindings and descriptions:
--   omarchy menu keybindings --print

-- To disable every Omarchy default binding, set this in
-- ~/.config/hypr/hyprland.lua before require("default.hypr.omarchy"), then add
-- only the bindings you want below:
--   omarchy_default_bindings = false

-- To disable all preinstalled app/webapp bindings, set:
--   omarchy_preinstalled_bindings = false

-- Add a new binding.
-- o.bind("SUPER + SHIFT + R", "SSH", "alacritty -e ssh your-server")

-- Change an existing binding by unbinding it first, then binding the key again.
-- This example changes SUPER+SPACE from the launcher to the Omarchy root menu.
-- hl.unbind("SUPER + SPACE")
-- o.bind("SUPER + SPACE", "Omarchy menu", "omarchy-menu toggle root")

-- Disable a default binding without replacing it.
-- hl.unbind("SUPER + SHIFT + B")

-- Logitech MX Keys examples:
-- o.bind("SUPER + SHIFT + S", nil, "omarchy-capture-screenshot")
-- o.bind("SUPER + H", nil, "voxtype record toggle")
-- o.bind("SUPER + PERIOD", nil, "omarchy-shell shell toggle omarchy.emojis")

-- omalang:binds begin (managed by Omalang — do not edit)
pcall(require, "hypr.omalang_binds")
-- omalang:binds end

-- Use Strata instead of Nautilus for Omarchy's file-manager shortcuts.
hl.unbind("SUPER + SHIFT + F")
hl.unbind("SUPER + ALT + SHIFT + F")
o.bind("SUPER + SHIFT + F", "File manager", { launch = "strata" })
o.bind("SUPER + ALT + SHIFT + F", "File manager (cwd)", "uwsm-app -- strata \"$(omarchy-cmd-terminal-cwd)\"")

-- Panel Notes shortcut
o.bind("SUPER + ALT + E", "Panel Notes", "omarchy-shell panel-notes toggle")

-- Screenshots go to the clipboard only; no file is saved.
hl.unbind("PRINT")
o.bind("PRINT", "Screenshot (clipboard only)", "omarchy-capture-screenshot smart copy")

-- BEGIN io.github.chris.snitch
o.bind("SUPER + SHIFT + ALT + S", "Snitch", "omarchy-shell shell toggle io.github.chris.snitch '{}'")
-- END io.github.chris.snitch

-- Claude Code session history (all projects); Enter resumes in the session's folder.
o.bind("SUPER + ALT + C", "Claude history", "omarchy-launch-tui claude-history")

-- Touchpad feels heavy? Press, move one finger for 3 s; report in ~/.local/state/touchpad-lag/.
o.bind("SUPER + ALT + T", "Touchpad lag capture", "$HOME/.local/bin/touchpad-lag-capture")

-- Ask Claude quick-ask panel (shadowone.ask-claude bar plugin).
o.bind("SUPER + A", "Ask Claude", "omarchy-shell shadowone.ask-claude toggle")

-- Drop-down Kitty from the top edge; the same key hides it (~/.config/kitty/quick-access-terminal.conf).
o.bind("SUPER + grave", "Drop-down terminal", "kitten quick-access-terminal")

-- Minimize like macOS: Super + M hides the focused window (as the yellow
-- title-bar button does), Super + Alt + M brings the last one back.
o.bind("SUPER + M", "Minimize window", "$HOME/.local/bin/window-minimize")
o.bind("SUPER + ALT + M", "Restore minimized window", "$HOME/.local/bin/window-restore")
