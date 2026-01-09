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
# HELPERS
#######################################
file_uri() {
  # Convert /keys/foo.key -> file:///keys/foo.key
  local p="$1"
  echo "file:///${p#/}"
}

set_canmount_off_tree() {
  # Some zfs builds don't support "zfs set -r". Do it manually.
  local ds="$1"
  local child
  while read -r child; do
    [[ -z "$child" ]] && continue
    zfs set canmount=off "$child" || true
  done < <(zfs list -H -o name -r "$ds" 2>/dev/null || true)
}

#######################################
# FUNCTIONS
#######################################
stop_all_vms() {
  echo "[*] Stopping all VMs..."
  local vmid
  while read -r vmid; do
    [[ -z "$vmid" ]] && continue
    echo "  - VM $vmid"
    qm shutdown "$vmid" --timeout 60 || qm stop "$vmid" || true
  done < <(qm list | awk 'NR>1 {print $1}')
}

stop_all_cts() {
  echo "[*] Stopping all containers..."
  local ctid
  while read -r ctid; do
    [[ -z "$ctid" ]] && continue
    echo "  - CT $ctid"
    pct shutdown "$ctid" --timeout 60 || pct stop "$ctid" || true
  done < <(pct list | awk 'NR>1 {print $1}')
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
      chattr +i "$key" 2>/dev/null || true
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

  local mp
  mp="$(zfs get -H -o value mountpoint "$SRC" || echo "-")"

  local SNAP="encmigrate-$$"
  local TMP_PLAIN="${SRC}-plain-$$"

  echo "  - Unmounting (best effort)"
  zfs unmount -f "$SRC" || true

  echo "  - Snapshotting: $SRC@$SNAP"
  zfs snapshot -r "$SRC@$SNAP"

  echo "  - Renaming original dataset out of the way: $SRC -> $TMP_PLAIN"
  zfs rename "$SRC" "$TMP_PLAIN"

  echo "  - Preventing accidental mounts of the plain dataset tree"
  set_canmount_off_tree "$TMP_PLAIN"

  echo "  - Receiving encrypted dataset into original name: $SRC"
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

  echo "  - Loading key for $SRC (best effort)"
  zfs load-key "$SRC" >/dev/null 2>&1 || true

  if [[ "$mp" == "/var/lib/vz" ]]; then
    echo "  - Ensuring /var/lib/vz is empty (overlay=off safety)"
    rm -rf /var/lib/vz/* 2>/dev/null || true
  fi

  echo "  - Destroying old plain dataset tree: $TMP_PLAIN"
  zfs destroy -r "$TMP_PLAIN"

  echo "  - Removing migration snapshot from encrypted dataset: $SRC@$SNAP"
  zfs destroy -r "$SRC@$SNAP" 2>/dev/null || true
}

install_key_loader_service() {
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
}

#######################################
# MAIN
#######################################
echo "======================================"
echo " Proxmox ZFS Encryption Migration"
echo "======================================"

echo "[*] Removing break=mount / rd.break from GRUB defaults if present"
sed -i 's/ break=mount//g; s/ rd.break//g' /etc/default/grub 2>/dev/null || true

# On Proxmox with proxmox-boot-tool, update-grub warnings are normal.
# Best effort refresh:
update-grub 2>/dev/null || true
proxmox-boot-tool refresh 2>/dev/null || true
update-initramfs -u 2>/dev/null || true

echo "[*] Stopping Proxmox services"
systemctl stop pveproxy pvedaemon pvestatd pvescheduler pve-ha-lrm pve-ha-crm 2>/dev/null || true

stop_all_vms
stop_all_cts

create_keys

echo "[*] Enabling autotrim on rpool"
zpool set autotrim=on rpool 2>/dev/null || true

encrypt_dataset "rpool/data" "$DATA_KEY"
encrypt_dataset "rpool/var-lib-vz" "$VZ_KEY"

install_key_loader_service

echo "[*] Remounting datasets"
zfs mount -a 2>/dev/null || true

echo "[*] Starting Proxmox services"
systemctl start pveproxy pvedaemon pvestatd pvescheduler pve-ha-lrm pve-ha-crm 2>/dev/null || true

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
