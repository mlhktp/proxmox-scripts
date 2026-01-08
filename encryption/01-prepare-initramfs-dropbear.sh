#!/usr/bin/env bash
set -euo pipefail

require_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "[!] Must be run as root"
    exit 1
  fi
}

require_tty() {
  if [[ ! -t 0 ]] && [[ ! -e /dev/tty ]]; then
    echo "[!] No TTY available for interactive input"
    exit 1
  fi
}

ask_yes_no() {
  local prompt="$1"
  local reply
  while true; do
    read -r -p "$prompt [y/N]: " reply </dev/tty
    case "$reply" in
      [yY]|[yY][eE][sS]) return 0 ;;
      ""|[nN]|[nN][oO]) return 1 ;;
      *) echo "Please answer yes or no." ;;
    esac
  done
}

require_root
require_tty

echo "[*] Installing dropbear-initramfs..."
apt-get update
apt-get install -y --no-install-recommends dropbear-initramfs

echo "[*] Configuring dropbear options..."
install -d -m 755 /etc/dropbear/initramfs

DROPBEAR_CONF=/etc/dropbear/initramfs/dropbear.conf
TMP_CONF=$(mktemp)

cat >"$TMP_CONF" <<'EOF'
DROPBEAR_OPTIONS="-p 4748 -s -j -k"
EOF

if [[ ! -f "$DROPBEAR_CONF" ]] || ! cmp -s "$TMP_CONF" "$DROPBEAR_CONF"; then
  install -m 600 "$TMP_CONF" "$DROPBEAR_CONF"
  echo "    updated $DROPBEAR_CONF"
else
  echo "    $DROPBEAR_CONF already up to date"
fi

rm -f "$TMP_CONF"

echo
echo "[*] Paste your SSH PUBLIC key (single line), then press Enter:"
read -r SSH_KEY </dev/tty

if [[ -z "$SSH_KEY" || "$SSH_KEY" != ssh-* ]]; then
  echo "[!] Invalid or empty SSH public key"
  exit 1
fi

AUTHORIZED_KEYS=/etc/dropbear/initramfs/authorized_keys
KEY_LINE="no-port-forwarding,no-agent-forwarding,no-x11-forwarding ${SSH_KEY}"

echo
if [[ -f "$AUTHORIZED_KEYS" ]]; then
  echo "[!] Existing authorized_keys detected:"
  echo "--------------------------------------------------"
  cat "$AUTHORIZED_KEYS"
  echo "--------------------------------------------------"
  echo

  if ask_yes_no "Modify authorized_keys?"; then
    BACKUP="${AUTHORIZED_KEYS}.bak.$(date +%Y%m%d%H%M%S)"
    echo "[*] Backing up existing authorized_keys to $BACKUP"
    mv "$AUTHORIZED_KEYS" "$BACKUP"

    echo "[*] Writing new authorized_keys"
    umask 077
    printf '%s\n' "$KEY_LINE" >"$AUTHORIZED_KEYS"
  else
    echo "[*] Leaving authorized_keys unchanged"
  fi
else
  echo "[*] No authorized_keys found, creating one"
  umask 077
  printf '%s\n' "$KEY_LINE" >"$AUTHORIZED_KEYS"
fi

chmod 600 "$AUTHORIZED_KEYS"
chown root:root "$AUTHORIZED_KEYS"

GRUB_CHANGED=0

echo "[*] Ensuring initramfs networking (ip=dhcp)..."
if ! grep -q 'ip=dhcp' /etc/default/grub; then
  sed -i 's/^\(GRUB_CMDLINE_LINUX_DEFAULT="[^"]*\)"/\1 ip=dhcp"/' \
    /etc/default/grub
  GRUB_CHANGED=1
fi

echo "[*] Ensuring one-time initramfs shell (break=mount)..."
if ! grep -q 'break=mount' /etc/default/grub; then
  sed -i 's/^\(GRUB_CMDLINE_LINUX_DEFAULT="[^"]*\)"/\1 break=mount"/' \
    /etc/default/grub
  GRUB_CHANGED=1
fi

if [[ "$GRUB_CHANGED" -eq 1 ]]; then
  echo "[*] Updating grub..."
  update-grub
else
  echo "[*] Grub already configured"
fi

echo "[*] Updating initramfs..."
update-initramfs -u

echo
echo "=================================================="
echo "READY."
echo "NEXT STEPS:"
echo "  1) reboot"
echo "  2) SSH: ssh -p 4748 root@<IP>"
echo "  3) Run the encrypt root script"
echo "=================================================="
