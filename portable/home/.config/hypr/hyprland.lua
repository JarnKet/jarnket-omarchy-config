-- Learn how to configure Hyprland: https://wiki.hypr.land/Configuring/Start/

-- Omarchy's bootstrap keeps path setup out of this user config.
dofile((os.getenv("OMARCHY_PATH") or "/usr/share/omarchy") .. "/default/hypr/bootstrap.lua")

-- Disable all Omarchy default bindings. Add your own in hypr/bindings.lua.
-- omarchy_default_bindings = false
--
-- Or disable only bindings for Omarchy's preinstalled apps/web apps while
-- keeping core window-manager bindings:
-- omarchy_preinstalled_bindings = false

-- Load Omarchy defaults.
require("default.hypr.omarchy")

-- Put your personal overrides in these files. They're loaded after Omarchy's
-- defaults so package updates can improve the defaults without rewriting your
-- ~/.config/hypr files.
require("hypr.monitors")
require("hypr.input")
require("hypr.bindings")
require("hypr.looknfeel")
require("hypr.titlebars")
require("hypr.autostart")

-- Toggle config flags dynamically.
require("default.hypr.toggles")

-- Add any other personal Hyprland configuration below.
-- o.window("qemu", { workspace = "5" })

-- Password picker (rbw-picker): float it and keep it out of screen shares, as
-- Omarchy does for the Bitwarden app.
o.window("org\\.omarchy\\.rbw-picker", { no_screen_share = true, tag = "+floating-window" })

-- Herdr (herdr-app) opens an opaque window and has no transparency setting of
-- its own, so set it here: active, then inactive.
o.window("herdr-app", { tag = "-default-opacity", opacity = "0.92 0.86" })

-- JetBrains Toolbox (an XWayland tray popup) places itself at the very top
-- of the screen, so the bar covers its header and settings button. It sets
-- that position after mapping, which beats a window rule's `move`, so nudge
-- it below the bar once it has settled.
hl.on("window.open", function(window)
  if not window or window.class ~= "jetbrains-toolbox" then return end
  hl.timer(function()
    local monitor = window.monitor
    if not (window.mapped and monitor) then return end
    local reserved = monitor.reserved or {}
    local top = monitor.y + (reserved.top or 26) + 8
    local y = window.at.y or window.at[2]
    if y and y < top then
      hl.dispatch(hl.dsp.window.move({ x = 0, y = top - y, relative = true, window = window }))
    end
  end, { type = "oneshot", timeout = 300 })
end)

-- Blur behind the see-through drop-down terminal (SUPER+`).
hl.layer_rule({ match = { namespace = "kitty-quick-access" }, blur = true })


-- Load settings written by OmaSettings (omasettings:managed).
require("hypr.omasettings")

-- Added by hyprmoncfg: its generated monitor rules load last, so nothing before this can override the applied layout.
do local path = os.getenv("HOME") .. "/.config/hypr/hyprmoncfg-monitors.lua"; local file = io.open(path, "r"); if file then file:close(); dofile(path) end end
