# Omarchy configuration

Private data managed by Omarchy Synchro. Review every diff before committing.

## Custom extras (not handled by Synchro)

Synchro never captures installed plugin working trees, so locally written
plugins live in `extras/`. After restoring on a new laptop:

```bash
# Top Bar plugin (second bar + drag-and-drop between bars)
cp -r extras/plugins/shadowone.top-bar ~/.config/omarchy/plugins/
ln -sf ~/.config/omarchy/plugins/shadowone.top-bar/omarchy-topbar ~/.local/bin/omarchy-topbar
omarchy restart shell
omarchy-topbar list

# omapager -> Notification Center bridge (restored by Synchro to ~/.local/bin
# and ~/.config/systemd/user); enable it once:
chmod +x ~/.local/bin/omapager-nc-bridge
systemctl --user daemon-reload
systemctl --user enable --now omapager-nc-bridge.service

# omapager replaces Omarchy's built-in notifications; keep only one running:
omarchy plugin disable omarchy.notifications
```

To refresh the Top Bar copy after changing it:

```bash
rsync -a --delete ~/.config/omarchy/plugins/shadowone.top-bar/ extras/plugins/shadowone.top-bar/
```
