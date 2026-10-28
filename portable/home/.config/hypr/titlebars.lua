-- macOS-style title bars: traffic lights on the left, the title centred, the
-- bar in the current theme's background so it reads as part of the window.
-- Drawn by the hyprbars plugin, which ~/.local/bin/hyprbars-build compiles for
-- the installed Hyprland and ~/.local/bin/hyprbars-load loads at login. Until
-- it's loaded, nothing below runs.

-- Apps that draw their own title bar or tab strip, by window class (Lua
-- pattern for Hyprland's regex). They get no bar, so there's never two.
local own_title_bar = {
  "^brave-origin$", "^brave-browser$", "^chromium$", "^google-chrome$",
  "^com\\.microsoft\\.VSCode$", "^code(-oss)?$",
  "^Claude$",
  "^io\\.github\\.lgse\\.Strata",
  "^openidea", "^jetbrains-",
}

if hl.plugin.hyprbars then
  -- Follow the current Omarchy theme; Omarchy reloads Hyprland on theme change.
  local colors = {}
  local file = io.open(os.getenv("HOME") .. "/.local/state/omarchy/current/theme/colors.toml")
  if file then
    for key, hex in file:read("a"):gmatch('([%w_]+)%s*=%s*"#(%x%x%x%x%x%x)"') do
      colors[key] = hex
    end
    file:close()
  end

  hl.config({
    plugin = {
      hyprbars = {
        bar_height = 26,
        bar_color = "rgb(" .. (colors.background or "1f1f1f") .. ")",
        col = { text = "rgb(" .. (colors.light_foreground or colors.foreground or "888888") .. ")" },
        bar_text_font = "Noto Sans",
        bar_text_size = 11,
        bar_text_weight = "medium",
        bar_text_align = "center",
        bar_buttons_alignment = "left",
        bar_padding = 12,
        bar_button_padding = 8,
        bar_part_of_window = true,
        bar_precedence_over_border = true,
        icon_on_hover = true,
        inactive_button_color = "rgba(ffffff26)",
        on_double_click = [[hyprctl dispatch 'hl.dsp.window.fullscreen({ mode = "maximized", action = "toggle" })']],
      },
    },
  })

  -- Close, minimize (to the scratchpad; SUPER+S brings it back) and zoom.
  local function button(color, icon, action)
    hl.plugin.hyprbars.add_button({ bg_color = color, fg_color = "rgba(00000099)", size = 12, icon = icon, action = action })
  end
  button("rgb(ff5f57)", "×", [[hyprctl dispatch 'hl.dsp.window.close()']])
  button("rgb(febc2e)", "−", [[hyprctl dispatch 'hl.dsp.window.move({ workspace = "special:scratchpad", follow = false })']])
  button("rgb(28c840)", "+", [[hyprctl dispatch 'hl.dsp.window.fullscreen({ mode = "maximized", action = "toggle" })']])

  for _, class in ipairs(own_title_bar) do
    o.window(class, { ["hyprbars:no_bar"] = true })
  end
  -- Omarchy's floating pickers and dialogs stay bare too.
  o.window({ tag = "floating-window" }, { ["hyprbars:no_bar"] = true })
end
