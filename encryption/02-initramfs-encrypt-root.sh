#!/bin/sh
set -e

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

echo
echo "=================================================="
echo "ROOT ENCRYPTED."
echo
echo "NEXT:"
echo "  reboot -f"
echo
echo "On reboot:"
echo "  1) SSH to initramfs: ssh -p 4748 root@<IP>"
echo "  2) Run: /usr/bin/zfsunlock"
echo "  3) System will continue booting"
echo "=================================================="
