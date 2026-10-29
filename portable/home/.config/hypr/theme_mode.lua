-- The current Omarchy theme's colors, whether it's light or dark, and its
-- name, read fresh on every call. looknfeel.lua and titlebars.lua use it
-- so the hairline, shadows and title bars suit any theme; `omarchy theme set`
-- reloads Hyprland, which calls this again.

local M = {}

function M.read()
  local colors = {}
  local file = io.open(os.getenv("HOME") .. "/.local/state/omarchy/current/theme/colors.toml")
  if file then
    local text = file:read("a")
    file:close()
    for key, hex in text:gmatch('([%w_]+)%s*=%s*"#(%x%x%x%x%x%x)"') do
      colors[key] = hex
    end
    colors.mode = text:match('mode%s*=%s*"(%a+)"')
  end

  local name
  local name_file = io.open(os.getenv("HOME") .. "/.local/state/omarchy/current/theme.name")
  if name_file then
    name = (name_file:read("l") or ""):match("^%s*(.-)%s*$")
    name_file:close()
  end

  local mode = colors.mode
  if mode ~= "light" and mode ~= "dark" then
    -- No mode line: judge by how bright the background is.
    local bg = colors.background or "000000"
    local r, g, b = tonumber(bg:sub(1, 2), 16), tonumber(bg:sub(3, 4), 16), tonumber(bg:sub(5, 6), 16)
    mode = (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255 > 0.5 and "light" or "dark"
  end
  return colors, mode, name
end

return M
