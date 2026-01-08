#!/bin/sh
set -e


require_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "[!] Must be run as root"
    exit 1
  fi
}

require_root

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
echo "Reboot now: reboot -f"
echo "On reboot, initramfs will be open you should connect to it via ssh -p 4748 root@<IP>"
echo "run /usr/bin/zfsunlock to unlock the root filesystem."
echo "Then the root filesystem will be mounted and the boot will continue."
echo "Connect via ssh root@<IP> after the system has booted."
echo "Run the encrypt non-root datasets script to encrypt other datasets and complete the setup."
echo "=================================================="

