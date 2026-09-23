-- BEGIN hyprmoncfg wake settings
-- Shared with Omarchy while hyprmoncfg manages displays.
hl.monitor({ output = "eDP-1", mode = "preferred", position = "1574x1240", scale = 1.5 })
-- END hyprmoncfg wake settings
local omarchy_gdk_scale = 2
hl.env("GDK_SCALE", tostring(omarchy_gdk_scale))



-- -- ຈໍໂນດບຸກ: ຢູ່ກາງ ລຸ່ມຈໍນອກ
-- hl.monitor({
--     output   = "eDP-1",
--     mode     = "1920x1200@60",
--     position = "475x900",
--     scale    = 1.6,
-- })
-- hl.monitor({ output = "eDP-1", mode = "1920x1200@60.00100", position = "475x900", scale = 1.6, transform = 0 })
