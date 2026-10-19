#!/bin/bash
# Install the Disk Keeper root helper and its polkit policy.
# Run once with sudo:  sudo bash <plugin>/root/install.sh
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Run with sudo: sudo bash $0" >&2
  exit 1
fi

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
helper_src="$here/diskkeeper-root"
policy_src="$here/io.github.shadowone.diskkeeper.policy"

/usr/bin/python3 -IB -c 'import ast, sys; ast.parse(open(sys.argv[1]).read())' "$helper_src"

install -d -o root -g root -m 0755 /usr/local/libexec
install -o root -g root -m 0755 "$helper_src" /usr/local/libexec/diskkeeper-root
install -o root -g root -m 0644 "$policy_src" /usr/share/polkit-1/actions/io.github.shadowone.diskkeeper.policy

echo "Installed /usr/local/libexec/diskkeeper-root"
echo "Installed /usr/share/polkit-1/actions/io.github.shadowone.diskkeeper.policy"
