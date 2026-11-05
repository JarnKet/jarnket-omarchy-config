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
o.rebind("SUPER + A", "Ask Claude", "omarchy-shell shadowone.ask-claude toggle")

-- Drop-down Kitty from the top edge; the same key hides it (~/.config/kitty/quick-access-terminal.conf).
o.rebind("SUPER + grave", "Drop-down terminal", "kitten quick-access-terminal")

-- Omarchy's Quake console (it wanted Super + `). Its first open starts the default agent.
o.bind("SUPER + ALT + grave", "Toggle Quake console", hl.dsp.workspace.toggle_special("qconsole"))

-- Super + M hides the focused window, as the title-bar button does. On a
-- floating workspace it goes to Omarchy's dock; on a tiled one Super + Alt + M
-- brings the last one back.
o.rebind("SUPER + M", "Minimize window", "$HOME/.local/bin/window-minimize")
o.bind("SUPER + ALT + M", "Restore minimized window", "$HOME/.local/bin/window-restore")

-- Bitwarden picker through rbw. Was: Omarchy's 1Password launcher, which isn't installed here.
hl.unbind("SUPER + SHIFT + SLASH")
o.bind("SUPER + SHIFT + SLASH", "Passwords", "omarchy-launch-tui --app-id=org.omarchy.rbw-picker rbw-picker")

-- flea --default: begin. Written by `flea --default`; `flea --default off` removes the block whole.
hl.unbind("SUPER + SHIFT + F")
o.bind("SUPER + SHIFT + F", "File manager", { launch = 'flea --gui' })
hl.unbind("SUPER + ALT + SHIFT + F")
o.bind("SUPER + ALT + SHIFT + F", "File manager (cwd)", { launch = 'flea --gui "$(omarchy-cmd-terminal-cwd)"' })
-- flea --default: end.

-- flea --picker: begin. Written by `flea --picker`; `flea --picker off` removes the block whole.
o.window("com.thisisgm.flea.picker", { tag = "+floating-window" })
-- flea --picker: end.

-- Right Alt stays AltGr for typing Lao. Omarchy holds it for push-to-talk dictation,
-- and binds resolve against the first layout (us), so it would fire while typing Lao.
hl.unbind("ALT + Alt_R")

-- Dictation keys from before Alt + Space and Right Alt became the defaults.
-- Remove these lines to give the keys back to applications.
if o.dictation_installed and o.dictation_installed() then
  o.bind("SUPER + CTRL + X", "Toggle dictation", "omarchy-dictation toggle")
  o.bind_hold("F9", "Start dictation (push-to-talk)", "omarchy-dictation start", "Stop dictation (push-to-talk)", "omarchy-dictation stop")
end
