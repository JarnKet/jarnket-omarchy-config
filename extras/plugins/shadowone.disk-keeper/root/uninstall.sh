#!/bin/bash
# Remove the Disk Keeper root helper and its polkit policy.
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Run with sudo: sudo bash $0" >&2
  exit 1
fi

rm -f /usr/local/libexec/diskkeeper-root /usr/share/polkit-1/actions/io.github.shadowone.diskkeeper.policy
echo "Removed the Disk Keeper root helper and policy"
