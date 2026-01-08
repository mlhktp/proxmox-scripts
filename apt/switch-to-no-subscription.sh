#!/usr/bin/env bash

set -euo pipefail

DIST="trixie"

ENTERPRISE_PVE_REPO="https://enterprise.proxmox.com/debian/pve"
ENTERPRISE_CEPH_REPO="https://enterprise.proxmox.com/debian/ceph-squid"

NO_SUB_PVE_REPO="deb http://download.proxmox.com/debian/pve ${DIST} pve-no-subscription"
NO_SUB_CEPH_REPO="deb http://download.proxmox.com/debian/ceph-squid ${DIST} no-subscription"

echo "==> Disabling Proxmox Enterprise repositories..."

# Disable enterprise repos by commenting them out
grep -rl "${ENTERPRISE_PVE_REPO}" /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null | while read -r file; do
    sed -i 's|^[[:space:]]*deb[[:space:]].*enterprise.proxmox.com/debian/pve|# &|' "$file"
done

grep -rl "${ENTERPRISE_CEPH_REPO}" /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null | while read -r file; do
    sed -i 's|^[[:space:]]*deb[[:space:]].*enterprise.proxmox.com/debian/ceph-squid|# &|' "$file"
done

echo "==> Enabling No-Subscription repositories..."

# Proxmox VE no-subscription repo
PVE_NO_SUB_FILE="/etc/apt/sources.list.d/pve-no-subscription.list"
if ! grep -q "^${NO_SUB_PVE_REPO}$" "$PVE_NO_SUB_FILE" 2>/dev/null; then
    echo "$NO_SUB_PVE_REPO" > "$PVE_NO_SUB_FILE"
fi

# Ceph no-subscription repo
CEPH_NO_SUB_FILE="/etc/apt/sources.list.d/ceph-no-subscription.list"
if ! grep -q "^${NO_SUB_CEPH_REPO}$" "$CEPH_NO_SUB_FILE" 2>/dev/null; then
    echo "$NO_SUB_CEPH_REPO" > "$CEPH_NO_SUB_FILE"
fi

echo "==> Updating package lists..."
apt update


echo "✅ Proxmox Enterprise repositories disabled."
echo "✅ No-Subscription repositories enabled."

