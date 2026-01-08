#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE="/etc/systemd/logind.conf"

require_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "[!] Must be run as root"
    exit 1
  fi
}

set_or_replace() {
  local key="$1"
  local value="$2"

  if grep -Eq "^[#[:space:]]*${key}=" "$CONFIG_FILE"; then
    sed -i "s|^[#[:space:]]*${key}=.*|${key}=${value}|" "$CONFIG_FILE"
  else
    echo "${key}=${value}" >> "$CONFIG_FILE"
  fi
}

require_root

echo "[*] Updating $CONFIG_FILE"

set_or_replace "HandleLidSwitch" "ignore"
set_or_replace "HandleLidSwitchDocked" "ignore"
set_or_replace "HandleLidSwitchExternalPower" "ignore"

echo "[*] Restarting systemd-logind"
systemctl restart systemd-logind

echo "✅ Lid switch handling disabled."

