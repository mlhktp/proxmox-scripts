#!/usr/bin/env bash
set -euo pipefail

DIST="trixie"

ENTERPRISE_DOMAINS="enterprise.proxmox.com"

echo "==> Disabling Proxmox Enterprise repositories..."

# Comment out enterprise repos in .list files
grep -rl "$ENTERPRISE_DOMAINS" /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null | while read -r file; do
  sed -i 's|^[[:space:]]*deb|# deb|' "$file"
  sed -i 's|^[[:space:]]*URIs:.*enterprise.proxmox.com|# &|' "$file"
done

echo "==> Checking for existing no-subscription sources..."

PVE_SOURCES="/etc/apt/sources.list.d/proxmox.sources"
CEPH_SOURCES="/etc/apt/sources.list.d/ceph.sources"

if [[ ! -f "$PVE_SOURCES" ]]; then
  echo "==> Creating Proxmox no-subscription source"
  cat > /etc/apt/sources.list.d/pve-no-subscription.list <<EOF
deb http://download.proxmox.com/debian/pve ${DIST} pve-no-subscription
EOF
else
  echo "    Proxmox no-subscription source already present"
fi

if [[ ! -f "$CEPH_SOURCES" ]]; then
  echo "==> Creating Ceph no-subscription source"
  cat > /etc/apt/sources.list.d/ceph-no-subscription.list <<EOF
deb http://download.proxmox.com/debian/ceph-squid ${DIST} no-subscription
EOF
else
  echo "    Ceph no-subscription source already present"
fi

echo "==> Updating package lists..."
apt update

echo
echo "✅ Enterprise repositories disabled"
echo "✅ No-subscription repositories enabled"
