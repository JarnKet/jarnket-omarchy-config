#!/bin/bash
# Install the Hibernation switch's root helper and its polkit policy.
# Run once with sudo:  sudo bash <plugin>/root/install.sh
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Run with sudo: sudo bash $0" >&2
  exit 1
fi

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

bash -n "$here/hibernate-mode-root"
install -d -o root -g root -m 0755 /usr/local/libexec
install -o root -g root -m 0755 "$here/hibernate-mode-root" /usr/local/libexec/hibernate-mode-root
install -o root -g root -m 0644 "$here/io.github.shadowone.hibernate-mode.policy" \
  /usr/share/polkit-1/actions/io.github.shadowone.hibernate-mode.policy

echo "Installed /usr/local/libexec/hibernate-mode-root"
echo "Installed /usr/share/polkit-1/actions/io.github.shadowone.hibernate-mode.policy"
