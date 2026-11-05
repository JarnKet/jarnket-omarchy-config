-- Title bars with a look of their own for each theme, drawn by the plugin
-- Omarchy ships for its floating workspaces (omarchy-hyprland-titlebars, a
-- hyprbars fork kept in step with Hyprland by its package). It reloads the
-- config once it's in, and that's the pass where the block below runs.
--
-- hyprbars draws each button as a filled circle with an optional glyph on
-- it; a transparent fill leaves just the glyph. The title's font, size,
-- weight, color and alignment are free.

-- Apps that draw their own title bar or tab strip, by window class (Lua
-- pattern for Hyprland's regex). They get no bar, so there's never two.
local own_title_bar = {
  "^brave-origin$", "^brave-browser$", "^chromium$", "^google-chrome$",
  "^com\\.microsoft\\.VSCode$", "^code(-oss)?$",
  "^Claude$",
  "^io\\.github\\.lgse\\.Strata",
  "^com\\.thisisgm\\.flea",
  "^openidea", "^jetbrains-",
}

local titlebars_plugin = "/usr/lib/omarchy-hyprland-titlebars/titlebars.so"
local plugin_file = io.open(titlebars_plugin, "r")
if plugin_file then
  plugin_file:close()
  hl.plugin.load(titlebars_plugin)
end

if hl.plugin.hyprbars then
  -- Follow the current Omarchy theme; Omarchy reloads Hyprland on theme change.
  local colors, _, theme = require("hypr.theme_mode").read()
  local function rgb(key, fallback)
    return "rgb(" .. (colors[key] or fallback) .. ")"
  end
  local clear = "rgba(00000000)"

  -- The plugin puts the clicked window's address in place of %WINDOW%.
  local close = [[hyprctl dispatch 'hl.dsp.window.close({ window = "address:%WINDOW%" })']]
  local minimize = os.getenv("HOME") .. "/.local/bin/window-minimize %WINDOW%"
  local maximize = [[hyprctl dispatch 'hl.dsp.window.fullscreen({ mode = "maximized", action = "toggle", window = "address:%WINDOW%" })']]

  -- VS Code's own window controls (codicons from the Nerd Font) in quiet
  -- gray glyphs on the right, the title centred. Min Dark is a VS Code
  -- theme, so its windows match the editor; other themes get it in their
  -- own colors.
  local function editor()
    local glyph = rgb("light_foreground", "888888")
    return {
      bar = {
        bar_height = 30,
        bar_color = rgb("background", "1f1f1f"),
        col = { text = glyph },
        bar_text_font = "Noto Sans",
        bar_text_size = 11,
        bar_text_weight = "normal",
        bar_text_align = "center",
        bar_buttons_alignment = "right",
        bar_padding = 8,
        bar_button_padding = 6,
        icon_on_hover = false,
        inactive_button_color = clear,
      },
      unfocused_title = rgb("dark_foreground", "484848"),
      buttons = {
        { action = close, icon = "\u{eab8}", bg = clear, fg = glyph, size = 24 },
        { action = maximize, icon = "\u{eab9}", bg = clear, fg = glyph, size = 24 },
        { action = minimize, icon = "\u{eaba}", bg = clear, fg = glyph, size = 24 },
      },
    }
  end

  local styles = {
    -- Black and bold like the lid: the title in heavy mono on the left, and
    -- on the right two charcoal dots beside one TrackPoint-red dot. As in
    -- the rest of the theme, red marks focus: unfocused windows go all gray.
    thinkpad = {
      bar = {
        bar_height = 26,
        bar_color = "rgb(000000)",
        col = { text = "rgb(ececec)" },
        bar_text_font = "JetBrainsMono Nerd Font",
        bar_text_size = 10,
        bar_text_weight = "bold",
        bar_text_align = "left",
        bar_buttons_alignment = "right",
        bar_padding = 12,
        bar_button_padding = 9,
        icon_on_hover = true,
        inactive_button_color = "rgb(262626)",
      },
      unfocused_title = "rgb(5c5c5c)",
      buttons = {
        { action = close, icon = "×", bg = "rgb(e3241a)", fg = "rgb(ffffff)", size = 12 },
        { action = maximize, icon = "+", bg = "rgb(333333)", fg = "rgb(ececec)", size = 12 },
        { action = minimize, icon = "−", bg = "rgb(333333)", fg = "rgb(ececec)", size = 12 },
      },
    },

    -- A drawing sheet: the title lettered in blueprint-blue mono on the
    -- left, and the controls as circled callouts ⊖ ⊕ ⊗ in the same ink.
    blueprint = {
      bar = {
        bar_height = 30,
        bar_color = "rgb(ffffff)",
        col = { text = "rgb(104bff)" },
        bar_text_font = "JetBrainsMono Nerd Font",
        bar_text_size = 10,
        bar_text_weight = "medium",
        bar_text_align = "left",
        bar_buttons_alignment = "right",
        bar_padding = 10,
        bar_button_padding = 2,
        icon_on_hover = false,
        inactive_button_color = clear,
      },
      unfocused_title = "rgb(a1a1aa)",
      buttons = {
        { action = close, icon = "⊗", bg = clear, fg = "rgb(104bff)", size = 26 },
        { action = maximize, icon = "⊕", bg = clear, fg = "rgb(104bff)", size = 26 },
        { action = minimize, icon = "⊖", bg = clear, fg = "rgb(104bff)", size = 26 },
      },
    },
  }

  local style = styles[theme] or editor()

  -- Off by default in this fork. No workspace tag: bars on every window, tiled ones too.
  style.bar.enabled = true
  style.bar.workspace_tag = ""
  style.bar.bar_part_of_window = true
  style.bar.bar_precedence_over_border = true
  style.bar.on_double_click = maximize
  hl.config({ plugin = { hyprbars = style.bar } })

  -- Buttons are added in order from the aligned edge: close sits outermost.
  for _, b in ipairs(style.buttons) do
    hl.plugin.hyprbars.add_button({ bg_color = b.bg, fg_color = b.fg, size = b.size, icon = b.icon, action = b.action })
  end

  -- The title fades on windows that don't have focus.
  o.window({ focus = false }, { ["hyprbars:title_color"] = style.unfocused_title })

  for _, class in ipairs(own_title_bar) do
    o.window(class, { ["hyprbars:no_bar"] = true })
  end
  -- Omarchy's floating pickers and dialogs stay bare too.
  o.window({ tag = "floating-window" }, { ["hyprbars:no_bar"] = true })

  -- Omarchy styles this same plugin when a workspace floats, later in this
  -- config load or on Super + L: its own colors and three more buttons, and
  -- bars on floating windows only. Keep the look above by ignoring those calls.
  hl.plugin.hyprbars.add_button = function() end
  local set_config = hl.config
  hl.config = function(settings)
    if settings.plugin then
      settings.plugin.hyprbars = nil
    end
    return set_config(settings)
  end
end
