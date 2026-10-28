-- Change the default Omarchy look'n'feel.

-- https://wiki.hypr.land/Configuring/Basics/Variables/#general
-- hl.config({
--   general = {
--     -- No gaps between windows or borders.
--     gaps_in = 0,
--     gaps_out = 0,
--     border_size = 0,
--
--     -- Change to niri-like side-scrolling layout.
--     layout = "scrolling",
--   },
-- })

-- https://wiki.hypr.land/Configuring/Basics/Variables/#decoration
-- hl.config({
--   decoration = {
--     -- Use round window corners.
--     rounding = 8,
--
--     -- Dim unfocused windows (0.0 = no dim, 1.0 = fully dimmed).
--     dim_inactive = true,
--     dim_strength = 0.15,
--   },
-- })

-- https://wiki.hypr.land/Configuring/Basics/Variables/#animations
-- hl.config({
--   animations = {
--     -- Disable all animations.
--     enabled = false,
--   },
-- })

-- https://wiki.hypr.land/Configuring/Basics/Variables/#layout
-- hl.config({
--   layout = {
--     -- Avoid overly wide single-window layouts on wide screens.
--     single_window_aspect_ratio = { 1, 1 },
--   },
-- })

-- https://wiki.hypr.land/Configuring/Layouts/Scrolling-Layout/
-- hl.config({
--   scrolling = {
--     -- See only one column per screen instead of two.
--     column_width = 0.97,
--   },
-- })

-- >>> omamotion managed block >>>
hl.curve("linear", { type = "bezier", points = { { 0, 0 }, { 1, 1 } } })
hl.curve("easeOutQuint", { type = "bezier", points = { { 0.23, 1 }, { 0.32, 1 } } })
hl.curve("easeInOutCubic", { type = "bezier", points = { { 0.65, 0.05 }, { 0.36, 1 } } })
hl.curve("almostLinear", { type = "bezier", points = { { 0.5, 0.5 }, { 0.75, 1 } } })
hl.curve("quick", { type = "bezier", points = { { 0.15, 0 }, { 0.1, 1 } } })
hl.animation({ leaf = "global", enabled = true, speed = 12, bezier = "default" })
hl.animation({ leaf = "border", enabled = true, speed = 9.16, bezier = "easeOutQuint" })
hl.animation({ leaf = "windows", enabled = true, speed = 6.44, bezier = "easeInOutCubic" })
hl.animation({ leaf = "windowsIn", enabled = true, speed = 6.97, bezier = "easeOutQuint", style = "popin 92%" })
hl.animation({ leaf = "windowsOut", enabled = true, speed = 2.53, bezier = "linear", style = "popin 87%" })
hl.animation({ leaf = "fadeIn", enabled = true, speed = 2.94, bezier = "almostLinear" })
hl.animation({ leaf = "fadeOut", enabled = true, speed = 2.48, bezier = "almostLinear" })
hl.animation({ leaf = "fade", enabled = true, speed = 5.15, bezier = "quick" })
hl.animation({ leaf = "fadeSwitch", enabled = false })
hl.animation({ leaf = "layers", enabled = true, speed = 6.48, bezier = "easeOutQuint" })
hl.animation({ leaf = "layersIn", enabled = true, speed = 6, bezier = "easeOutQuint", style = "fade" })
hl.animation({ leaf = "layersOut", enabled = true, speed = 2.55, bezier = "linear", style = "fade" })
hl.animation({ leaf = "fadeLayersIn", enabled = true, speed = 3.04, bezier = "almostLinear" })
hl.animation({ leaf = "fadeLayersOut", enabled = true, speed = 2.36, bezier = "almostLinear" })
hl.animation({ leaf = "workspaces", enabled = true, speed = 4.5, bezier = "easeInOutCubic", style = "slide" })
-- <<< omamotion managed block <<<

-- Glyph's motion (github.com/Nebelung-cloud/glyph-rice, hypr/hyprland/animations.lua), on top of
-- the omamotion block above: windows and panels appear with a fast start and a long soft
-- landing, leave quickly, and move or fade on Material's standard curve. Leaves Glyph left to
-- inherit are set here too, because the omamotion block set them explicitly.
-- Workspaces keep the swipe fix below (Glyph slides them vertically).
hl.curve("emphasizedDecel", { type = "bezier", points = { { 0.05, 0.7 }, { 0.1, 1 } } })
hl.curve("emphasizedAccel", { type = "bezier", points = { { 0.3, 0 }, { 0.8, 0.15 } } })
hl.curve("standard", { type = "bezier", points = { { 0.2, 0 }, { 0, 1 } } })
hl.animation({ leaf = "global", enabled = true, speed = 8, bezier = "default" })
hl.animation({ leaf = "windows", enabled = true, speed = 8, bezier = "default", style = "" })
hl.animation({ leaf = "windowsIn", enabled = true, speed = 5, bezier = "emphasizedDecel", style = "" })
hl.animation({ leaf = "windowsOut", enabled = true, speed = 3, bezier = "emphasizedAccel", style = "" })
hl.animation({ leaf = "windowsMove", enabled = true, speed = 6, bezier = "standard" })
hl.animation({ leaf = "layers", enabled = true, speed = 8, bezier = "default", style = "" })
hl.animation({ leaf = "layersIn", enabled = true, speed = 5, bezier = "emphasizedDecel", style = "slide" })
hl.animation({ leaf = "layersOut", enabled = true, speed = 4, bezier = "emphasizedAccel", style = "slide" })
hl.animation({ leaf = "fade", enabled = true, speed = 6, bezier = "standard" })
hl.animation({ leaf = "fadeIn", enabled = true, speed = 6, bezier = "standard" })
hl.animation({ leaf = "fadeOut", enabled = true, speed = 6, bezier = "standard" })
hl.animation({ leaf = "fadeSwitch", enabled = true, speed = 6, bezier = "standard" })
hl.animation({ leaf = "fadeDim", enabled = true, speed = 6, bezier = "standard" })
hl.animation({ leaf = "fadeLayers", enabled = true, speed = 5, bezier = "standard" })
hl.animation({ leaf = "fadeLayersIn", enabled = true, speed = 5, bezier = "standard" })
hl.animation({ leaf = "fadeLayersOut", enabled = true, speed = 5, bezier = "standard" })
hl.animation({ leaf = "border", enabled = true, speed = 6, bezier = "standard" })
hl.animation({ leaf = "specialWorkspace", enabled = true, speed = 4, bezier = "emphasizedDecel", style = "slidefadevert 15%" })

-- Smooth workspace swipe: when you lift your fingers mid-swipe, the slide
-- finishes with an ease-out (fast start, soft landing) instead of
-- easeInOutCubic, which stalls right after release before speeding up.
hl.curve("swipeOut", { type = "bezier", points = { { 0.25, 0.9 }, { 0.3, 1 } } })
hl.animation({ leaf = "workspaces", enabled = true, speed = 3.5, bezier = "swipeOut", style = "slide" })

-- >>> omaland managed block >>>
-- Written by Omaland. Safe to hand-edit: Omaland re-reads this block
-- every time it opens, and only ever rewrites what's between the fences.
hl.config({
  decoration = {
    border_part_of_window = false,
    rounding = 12,
    rounding_power = 4,

    shadow = {
      enabled = true,
      range = 28,
      render_power = 3,
    },
  },

  general = {
    border_size = 1,
    gaps_in = 6,
  },
})
-- <<< omaland managed block <<<

-- macOS look: what Omaland can't set. Shadows fall a little below the window,
-- darker under the focused one, and every window gets the same faint hairline
-- instead of a colored focus border, whatever the theme. Rounding, shadow size
-- and the border width live in the Omaland block above.
hl.config({
  decoration = {
    shadow = {
      color = "rgba(000000a6)",
      color_inactive = "rgba(00000059)",
      offset = "0 6",
    },
  },

  general = {
    -- The bars are see-through, so their own padding already reads as space:
    -- 4 above and below looks like the 12 at the sides. (Omaland's Outer gaps
    -- slider takes one number, so this lives here.)
    gaps_out = { top = 4, right = 12, bottom = 4, left = 12 },

    col = {
      active_border = "rgba(ffffff14)",
      inactive_border = "rgba(ffffff14)",
    },
  },

  group = {
    col = {
      border_active = "rgba(ffffff14)",
      border_inactive = "rgba(ffffff14)",
    },
  },
})
