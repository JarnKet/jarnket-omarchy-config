-- Extra autostart processes.
-- o.launch_on_start("my-service")

-- Restore the saved Pointer Feel profile.
o.launch_on_start("/home/shadowone/.local/bin/pointer-feel restore")

-- EasyEffects in the background, applying the Windows (Dolby) speaker tuning to the
-- internal speaker. Only on a machine that has the generated preset (see README).
local dolby_preset = io.open(os.getenv("HOME") .. "/.local/share/easyeffects/output/Dolby-Balanced.json")
if dolby_preset then
  dolby_preset:close()
  o.launch_on_start("easyeffects --service-mode -w")
end
