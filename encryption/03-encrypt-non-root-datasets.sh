#!/usr/bin/env bash
set -euo pipefail

require_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "[!] Must be run as root"
    exit 1
  fi
}

ask_yes_no() {
   local prompt="$1"
   local reply
   while true; do
      read -r -p "$prompt [y/N]: " reply
      case "$reply" in
         [yY]|[yY][eE][sS]) return 0 ;;
         ""|[nN]|[nN][oO]) return 1 ;;
         *) echo "Please answer yes or no." ;;
      esac
   done
}

require_root


AUTHORIZED_KEYS=/etc/dropbear/initramfs/authorized_keys
FORCED_CMD='command="/usr/bin/zfsunlock"'
KEY_LINE="no-port-forwarding,no-agent-forwarding,no-x11-forwarding,${FORCED_CMD} ${SSH_KEY}"

echo
if [[ -f "$AUTHORIZED_KEYS" ]]; then
  if ask_yes_no "This will modify authorized_keys?"; then
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

KEYDIR=/keys
DATA_KEY=$KEYDIR/data.key
VZ_KEY=$KEYDIR/var-lib-vz.key

echo "[*] Removing force initramfs..."
sed -i 's/ break=mount//g' /etc/default/grub
update-grub
update-initramfs -u

echo "[*] Stopping VMs and containers..."
qm stopall || true
pct stopall || true

echo "[*] Creating key directory..."
mkdir -p "$KEYDIR"
chmod 700 "$KEYDIR"

openssl rand -base64 48 >"$DATA_KEY"
openssl rand -base64 48 >"$VZ_KEY"

chown root:root "$DATA_KEY" "$VZ_KEY"
chmod 400 "$DATA_KEY" "$VZ_KEY"
chattr +i "$DATA_KEY" "$VZ_KEY"

encrypt_dataset() {
  SRC="$1"
  KEY="$2"
  TMP="${SRC}-copy"

  zfs snapshot -r "$SRC@copy"
  zfs send -R "$SRC@copy" | zfs receive "$TMP"
  zfs destroy -r "$SRC"

  zfs create \
    -o encryption=on \
    -o keyformat=passphrase \
    -o keylocation="file://$KEY" \
    -o acltype=posix \
    -o xattr=sa \
    -o atime=off \
    -o checksum=blake3 \
    -o overlay=off \
    "$SRC"

  zfs send -R "$TMP@copy" | zfs receive -o encryption=on "$SRC"
  zfs destroy -r "$TMP"
}

encrypt_dataset rpool/data "$DATA_KEY"
encrypt_dataset rpool/var-lib-vz "$VZ_KEY"

rm -rf /var/lib/vz/*
zfs mount rpool/var-lib-vz

cat >/etc/systemd/system/zfs-load-key.service <<'EOF'
[Unit]
Description=Load ZFS encryption keys
DefaultDependencies=no
After=zfs-import.target
Before=zfs-mount.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/zfs load-key -a

[Install]
WantedBy=zfs-mount.service
EOF

systemctl daemon-reload
systemctl enable zfs-load-key

echo
echo "=================================================="
echo "ALL DATASETS ENCRYPTED."
echo "You should now reboot the system: reboot"
echo "Connect via ssh -p 4748 root@<IP> after the system has booted."
echo "The system will prompt for password to unlock the root."
echo "After that you can connect via ssh root@<IP> as usual."
echo "=================================================="
