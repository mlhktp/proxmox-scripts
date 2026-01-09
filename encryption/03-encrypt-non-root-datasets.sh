#!/usr/bin/env bash
set -euo pipefail

#######################################
# REQUIRE ROOT
#######################################
if [[ $EUID -ne 0 ]]; then
  echo "[!] Must be run as root"
  exit 1
fi

#######################################
# VARIABLES
#######################################
KEYDIR="/keys"
DATA_KEY="$KEYDIR/data.key"
VZ_KEY="$KEYDIR/var-lib-vz.key"

#######################################
# FUNCTIONS
#######################################
stop_all_vms() {
  echo "[*] Stopping all VMs..."
  for vmid in $(qm list | awk 'NR>1 {print $1}'); do
    echo "  - VM $vmid"
    qm shutdown "$vmid" --timeout 60 || qm stop "$vmid"
  done
}

stop_all_cts() {
  echo "[*] Stopping all containers..."
  for ctid in $(pct list | awk 'NR>1 {print $1}'); do
    echo "  - CT $ctid"
    pct shutdown "$ctid" --timeout 60 || pct stop "$ctid"
  done
}

create_keys() {
  echo "[*] Creating encryption keys..."

  mkdir -p "$KEYDIR"
  chmod 700 "$KEYDIR"

  for key in "$DATA_KEY" "$VZ_KEY"; do
    if [[ ! -f "$key" ]]; then
      openssl rand -base64 48 >"$key"
      chown root:root "$key"
      chmod 400 "$key"
      chattr +i "$key"
      echo "  - Created $key"
    else
      echo "  - $key already exists (immutable, skipping)"
    fi
  done
}

encrypt_dataset() {
  SRC="$1"
  KEY="$2"
  TMP="${SRC}-copy"
  ENC="${SRC}-encrypted"

  echo "[*] Processing dataset: $SRC"

  # Skip if already encrypted
  if [[ "$(zfs get -H -o value encryption "$SRC")" != "off" ]]; then
    echo "  - Already encrypted, skipping"
    return
  fi

  # Cleanup leftover temp copy only (never destroy ENC automatically)
  zfs destroy -r "$TMP" 2>/dev/null || true

  # Create encrypted dataset if missing
  if ! zfs list "$ENC" >/dev/null 2>&1; then
    echo "  - Snapshotting"
    zfs snapshot -r "$SRC@copy"

    echo "  - Creating temporary copy"
    zfs send -R "$SRC@copy" | zfs receive "$TMP"

    echo "  - Creating encrypted dataset"
    zfs create \
      -o encryption=on \
      -o keyformat=passphrase \
      -o keylocation="file://$KEY" \
      -o acltype=posix \
      -o xattr=sa \
      -o atime=off \
      -o checksum=blake3 \
      "$ENC"
  fi

  # Load key only if needed
  if [[ "$(zfs get -H -o value keystatus "$ENC")" != "available" ]]; then
    zfs load-key "$ENC"
  fi

  # Restore data only if empty
  if ! zfs list -t snapshot "$ENC@copy" >/dev/null 2>&1; then
    echo "  - Restoring data"
    zfs send -R "$TMP@copy" | zfs receive "$ENC"
  fi

  echo "  - Switching datasets"
  zfs destroy -r "$SRC"
  zfs rename "$ENC" "$SRC"
  zfs destroy -r "$TMP"
}

#######################################
# MAIN
#######################################
echo "======================================"
echo " Proxmox ZFS Encryption Migration"
echo "======================================"

echo "[*] Fixing initramfs/grub (removing break=mount if present)"
sed -i 's/ break=mount//g' /etc/default/grub || true
update-grub
update-initramfs -u

stop_all_vms
stop_all_cts

create_keys

encrypt_dataset "rpool/data" "$DATA_KEY"
encrypt_dataset "rpool/var-lib-vz" "$VZ_KEY"

echo "[*] Remounting datasets"
zfs mount -a

#######################################
# SYSTEMD KEY LOADER
#######################################
echo "[*] Installing ZFS key loader service"

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
systemctl enable zfs-load-key.service

#######################################
# FINAL CHECK
#######################################
echo
echo "Encryption status:"
zfs list -o name,encryption,keylocation

echo
echo "======================================"
echo "ALL DATASETS ENCRYPTED SUCCESSFULLY"
echo
echo "REBOOT REQUIRED"
echo
echo "On boot you will be prompted for the"
echo "ZFS passphrase to unlock rpool."
echo
echo "======================================"
