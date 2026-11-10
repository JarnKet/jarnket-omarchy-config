#!/bin/bash
# Faster sleep and wake on the ThinkPad T14s Gen 6 AMD. Run once with sudo:
#
#   sudo bash install.sh               install / update everything below
#   sudo bash install.sh --no-probe    drop only the temporary resume probe
#   sudo bash install.sh --uninstall   put everything back
#
# - Wi-Fi back in a few seconds after a resume: scan only the channels of known
#   networks instead of waiting ~14 s for NetworkManager's full scan
#   (wifi-quick-reconnect; wpa_supplicant and Wi-Fi Direct casting stay).
# - No fixed 1 s at every wake: the keyboard-backlight hook re-applies its
#   level from a timer instead of sleeping while user.slice is frozen, and
#   amd-debug-tools (its s2idle-hook runs Python on every suspend and resume)
#   is removed.
# - Closing the lid right after opening it sleeps within 10 s, not 30 s.
# - Temporary: resume-probe watches the shell after each resume, and
#   pm_print_times logs each device's suspend time (until the next reboot).
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Run with sudo: sudo bash $0" >&2
  exit 1
fi

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
sleep_dir=/usr/lib/systemd/system-sleep
libexec=/usr/local/libexec
dispatcher=/etc/NetworkManager/dispatcher.d/50-wifi-quick-reconnect
logind_conf=/etc/systemd/logind.conf.d/30-lid-holdoff.conf
backup_dir=/var/lib/fast-resume/backup

say() { printf '  %s\n' "$*"; }

reload_logind() {
  systemctl reload systemd-logind 2>/dev/null || say "logind didn't reload; the lid change applies after a reboot"
}

remove_probe() {
  rm -f "$sleep_dir/resume-probe" "$libexec/resume-probe"
  say "removed resume-probe (its reports stay in /var/log/resume-probe)"
}

uninstall() {
  rm -f "$sleep_dir/wifi-quick-reconnect" "$libexec/wifi-quick-reconnect" "$dispatcher"
  rm -rf /var/lib/wifi-quick-reconnect
  say "removed wifi-quick-reconnect"
  remove_probe
  if [[ -f $backup_dir/thinkpad-kbd-backlight ]]; then
    install -o root -g root -m 0755 "$backup_dir/thinkpad-kbd-backlight" "$sleep_dir/thinkpad-kbd-backlight"
    say "restored the previous thinkpad-kbd-backlight hook"
  fi
  if [[ -f $logind_conf ]]; then
    rm -f "$logind_conf"
    reload_logind
    say "lid hold-off back to logind's 30 s"
  fi
  [[ -w /sys/power/pm_print_times ]] && echo 0 >/sys/power/pm_print_times
  say "amd-debug-tools isn't reinstalled; if you want it: sudo pacman -S amd-debug-tools"
}

case ${1:-} in
  --uninstall)
    uninstall
    exit 0
    ;;
  --no-probe)
    remove_probe
    exit 0
    ;;
  "") ;;
  *)
    echo "usage: sudo bash $0 [--no-probe | --uninstall]" >&2
    exit 2
    ;;
esac

for f in "$here"/system-sleep/* "$here"/libexec/* "$here"/NetworkManager/dispatcher.d/*; do
  bash -n "$f"
done

# Keep the hook this replaces once, so --uninstall can put it back.
if [[ -f $sleep_dir/thinkpad-kbd-backlight && ! -f $backup_dir/thinkpad-kbd-backlight ]]; then
  install -d -m 0755 "$backup_dir"
  cp -p "$sleep_dir/thinkpad-kbd-backlight" "$backup_dir/thinkpad-kbd-backlight"
fi

install -d -o root -g root -m 0755 "$libexec"
for f in "$here"/libexec/*; do
  install -o root -g root -m 0755 "$f" "$libexec/$(basename "$f")"
  say "$libexec/$(basename "$f")"
done
for f in "$here"/system-sleep/*; do
  install -o root -g root -m 0755 "$f" "$sleep_dir/$(basename "$f")"
  say "$sleep_dir/$(basename "$f")"
done
# NetworkManager runs dispatcher scripts only if root owns them and only root can write them.
install -o root -g root -m 0755 "$here/NetworkManager/dispatcher.d/50-wifi-quick-reconnect" "$dispatcher"
say "$dispatcher"
install -d -m 0755 "$(dirname "$logind_conf")"
install -o root -g root -m 0644 "$here/logind/30-lid-holdoff.conf" "$logind_conf"
reload_logind
say "$logind_conf (reloaded logind)"

"$libexec/wifi-quick-reconnect" seed
say "remembered Wi-Fi channels: $(paste -sd' ' /var/lib/wifi-quick-reconnect/freqs 2>/dev/null) MHz"

if pacman -Q amd-debug-tools >/dev/null 2>&1; then
  if pacman -R --noconfirm amd-debug-tools >/dev/null; then
    say "removed amd-debug-tools (and its s2idle-hook)"
  else
    say "couldn't remove amd-debug-tools; its s2idle-hook still runs on every suspend"
  fi
fi

if [[ -w /sys/power/pm_print_times ]]; then
  echo 1 >/sys/power/pm_print_times
  say "pm_print_times on until the next reboot (each device's suspend time goes to the journal)"
fi

echo "Done. Close the lid for a minute, open it, and Wi-Fi should be back in a few seconds."
