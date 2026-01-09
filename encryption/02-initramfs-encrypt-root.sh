#!/bin/sh
set -e

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

# --- root check (POSIX safe) ---
if [ "$(id -u)" -ne 0 ]; then
  echo "[!] Must be run as root"
  exit 1
fi

echo "[*] Loading ZFS module..."
modprobe zfs

echo "[*] Importing pool..."
zpool import -f rpool

echo "[*] Snapshotting ROOT..."
zfs snapshot -r rpool/ROOT@copy

echo "[*] Copying ROOT to temporary dataset..."
zfs send -R rpool/ROOT@copy | zfs receive rpool/copyroot

echo "[*] Destroying unencrypted ROOT..."
zfs destroy -r rpool/ROOT

echo "[*] Enabling autotrim..."
zpool set autotrim=on rpool

echo "[*] Creating encrypted ROOT (you WILL be prompted)..."
zfs create \
  -o encryption=on \
  -o keyformat=passphrase \
  -o acltype=posix \
  -o xattr=sa \
  -o atime=off \
  -o checksum=blake3 \
  -o overlay=off \
  rpool/ROOT

echo "[*] Restoring ROOT/pve-1..."
zfs send -R rpool/copyroot/pve-1@copy | zfs receive -o encryption=on rpool/ROOT/pve-1

echo "[*] Cleaning up..."
zfs destroy -r rpool/copyroot

echo "[*] Setting mountpoint..."
zfs set mountpoint=/ rpool/ROOT/pve-1

echo "[*] Exporting pool..."
zpool export rpool

echo "[*] Re-importing pool for GRUB cleanup..."
zpool import | grep -q "^  pool: rpool" && zpool import -N rpool || true

echo "[*] Loading encryption key..."
if zfs get -H -o value keystatus rpool/ROOT | grep -q unavailable; then
    echo ">> Enter ZFS passphrase for rpool/ROOT"
    zfs load-key rpool/ROOT
else
    echo ">> Key already loaded"
fi

echo "[*] Mounting new ROOT temporarily..."

zfs set mountpoint=/mnt rpool/ROOT/pve-1

mkdir -p /mnt
if ! mount | grep -q "on /mnt "; then
    zfs set mountpoint=/mnt rpool/ROOT/pve-1
    zfs mount rpool/ROOT/pve-1 || true
else
    echo "[*] Root already mounted at /mnt"
fi

echo "[*] Binding pseudo-filesystems..."
mount -t proc proc /mnt/proc
mount -t sysfs sys /mnt/sys
mount -o bind /dev /mnt/dev
mount -t devpts devpts /mnt/dev/pts

echo "[*] Removing break=mount / rd.break from GRUB..."

chroot /mnt /bin/sh <<'EOF'
set -e

echo "[*] Cleaning GRUB break options..."
if grep -q "break=mount\|rd.break" /etc/default/grub; then
  sed -i \
    -e "s/break=mount//g" \
    -e "s/rd.break//g" \
    /etc/default/grub
  sed -i "s/  */ /g" /etc/default/grub
  update-grub
  echo "[+] GRUB cleaned"
else
  echo "[+] No break options found"
fi

AUTHORIZED_KEYS="/etc/dropbear/initramfs/authorized_keys"
FORCED_CMD='command="/usr/bin/zfsunlock",'

if [ ! -f "$AUTHORIZED_KEYS" ]; then
  echo "[!] $AUTHORIZED_KEYS not found, have you run 01-prepare-initramfs-dropbear.sh?"
  exit 1
fi

echo "[*] Forcing zfsunlock command on all Dropbear keys..."

tmp="$(mktemp)"

awk -v cmd="$FORCED_CMD" '
/^[[:space:]]*$/ || /^[[:space:]]*#/ {
    print
    next
}

$0 ~ /^command="/ {
    print
    next
}

{
    print cmd $0
}
' "$AUTHORIZED_KEYS" > "$tmp"

if ! cmp -s "$AUTHORIZED_KEYS" "$tmp"; then
  cp "$tmp" "$AUTHORIZED_KEYS"
  echo "[+] Forced command applied"
else
  echo "[=] No changes needed"
fi

rm -f "$tmp"

chmod 600 "$AUTHORIZED_KEYS"
chown root:root "$AUTHORIZED_KEYS"

update-initramfs -u
EOF

echo "[*] Restoring correct mountpoint..."

umount /mnt/dev/pts 2>/dev/null || true
umount /mnt/dev      2>/dev/null || true
umount /mnt/proc     2>/dev/null || true
umount /mnt/sys      2>/dev/null || true

zfs unmount rpool/ROOT/pve-1

zfs set mountpoint=/ rpool/ROOT/pve-1

echo
echo "=================================================="
echo "READY."
echo "NEXT STEPS:"
echo "  1) reboot -f"
echo "  2) SSH: ssh -p 4748 root@<IP>"
echo "  3) Enter the ZFS passphrase when prompted"
echo "  4) The system will boot normally afterwards, SSH: ssh root@<IP>"
echo "  5) Run the encrypt non-root datasets script"
echo "=================================================="
