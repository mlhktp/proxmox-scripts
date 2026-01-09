#!/usr/bin/env bash
set -euo pipefail

#######################################
# REQUIRE ROOT
#######################################
if [[ ${EUID:-0} -ne 0 ]]; then
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
file_uri() {
  # Convert /keys/foo.key -> file:///keys/foo.key
  local p="$1"
  echo "file:///${p#/}"
}

stop_all_vms() {
  echo "[*] Stopping all VMs..."
  local vmid
  while read -r vmid _; do
    [[ -z "$vmid" ]] && continue
    echo "  - VM $vmid"
    qm shutdown "$vmid" --timeout 60 || qm stop "$vmid" || true
  done < <(qm list | awk 'NR>1 {print $1, $2}')
}

stop_all_cts() {
  echo "[*] Stopping all containers..."
  local ctid
  while read -r ctid _; do
    [[ -z "$ctid" ]] && continue
    echo "  - CT $ctid"
    pct shutdown "$ctid" --timeout 60 || pct stop "$ctid" || true
  done < <(pct list | awk 'NR>1 {print $1, $2}')
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
      chattr +i "$key" || true
      echo "  - Created $key"
    else
      echo "  - $key already exists (skipping)"
    fi
  done
}

encrypt_dataset() {
  local SRC="$1"
  local KEY="$2"

  if ! zfs list -H -o name "$SRC" >/dev/null 2>&1; then
    echo "[!] Dataset not found: $SRC"
    exit 1
  fi

  echo "[*] Processing dataset: $SRC"

  # Skip if already encrypted
  local enc
  enc="$(zfs get -H -o value encryption "$SRC")"
  if [[ "$enc" != "off" ]]; then
    echo "  - Already encrypted ($enc), skipping"
    return 0
  fi

  # Capture mountpoint for special handling (overlay=off + /var/lib/vz issue)
  local mp
  mp="$(zfs get -H -o value mountpoint "$SRC" || echo "-")"

  # Make a unique temp name that won't collide
  local TMP_PLAIN="${SRC}-plain-$$"

  if zfs list -H -o name "$TMP_PLAIN" >/dev/null 2>&1; then
    echo "[!] Temp dataset already exists: $TMP_PLAIN"
    exit 1
  fi

  echo "  - Unmounting (best effort)"
  zfs unmount -f "$SRC" || true

  # Snapshot recursively so children (zvols, subvols, etc.) are included
  # Use a unique snapshot name to avoid collisions if rerun
  local SNAP="encmigrate-$$"
  echo "  - Snapshotting: $SRC@$SNAP"
  zfs snapshot -r "$SRC@$SNAP"

  echo "  - Renaming original dataset out of the way: $SRC -> $TMP_PLAIN"
  zfs rename "$SRC" "$TMP_PLAIN"

  # Prevent accidental mounts of the plain dataset tree during the migration
  zfs set -r canmount=off "$TMP_PLAIN" || true

  echo "  - Receiving encrypted dataset into original name: $SRC"
  # Important: destination MUST NOT exist (we freed it by rename above)
  # -u: do not mount during receive
  zfs send -R "$TMP_PLAIN@$SNAP" | zfs receive -u \
    -o encryption=on \
    -o keyformat=passphrase \
    -o keylocation="$(file_uri "$KEY")" \
    -o acltype=posix \
    -o xattr=sa \
    -o atime=off \
    -o checksum=blake3 \
    -o overlay=off \
    "$SRC"

  echo "  - Loading key for $SRC (so mounts will work)"
  zfs load-key "$SRC" || true

  # If overlay=off and mountpoint is /var/lib/vz, ensure directory is empty before mounting
  if [[ "$mp" == "/var/lib/vz" ]]; then
    echo "  - Ensuring /var/lib/vz is empty (overlay=off safety)"
    # Do NOT remove the directory itself; only contents
    rm -rf /var/lib/vz/* || true
  fi

  echo "  - Destroying old plain dataset tree: $TMP_PLAIN"
  zfs destroy -r "$TMP_PLAIN"

  # Optional: remove the @SNAP snapshot from the new encrypted dataset tree
  # (comment out if you want to keep it)
  echo "  - Removing migration snapshot from encrypted dataset: $SRC@$SNAP"
  zfs destroy -r "$SRC@$SNAP" || true
}

#######################################
# MAIN
#######################################
echo "======================================"
echo " Proxmox ZFS Encryption Migration"
echo "======================================"

echo "[*] Fixing initramfs/grub (removing break=mount / rd.break if present)"
sed -i 's/ break=mount//g; s/ rd.break//g' /etc/default/grub || true
update-grub || true
update-initramfs -u || true

# Reduce churn during /var/lib/vz + rpool/data migration
echo "[*] Stopping Proxmox services (best effort)"
systemctl stop pveproxy pvedaemon pvestatd pvescheduler pve-ha-lrm pve-ha-crm 2>/dev/null || true

stop_all_vms
stop_all_cts

create_keys

echo "[*] Enabling autotrim on rpool"
zpool set autotrim=on rpool || true

encrypt_dataset "rpool/data" "$DATA_KEY"
encrypt_dataset "rpool/var-lib-vz" "$VZ_KEY"

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

echo "[*] Remounting datasets (best effort)"
zfs mount -a || true

echo "[*] Starting Proxmox services (best effort)"
systemctl start pveproxy pvedaemon pvestatd pvescheduler pve-ha-lrm pve-ha-crm 2>/dev/null || true

#######################################
# FINAL CHECK
#######################################
echo
echo "Encryption status:"
zfs list -o name,encryption,keylocation

echo
echo "======================================"
echo "ALL DATASETS PROCESSED"
echo
echo "REBOOT REQUIRED"
echo
echo "On boot you will be prompted for the"
echo "ZFS passphrase to unlock ROOT, and"
echo "zfs-load-key will load the file keys."
echo
echo "======================================"
