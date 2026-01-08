#!/usr/bin/env bash
set -euo pipefail

DIST="trixie"

disable_sources() {
  local file="$1"

  if grep -q "^URIs:.*enterprise.proxmox.com" "$file"; then
    if grep -q "^Enabled:" "$file"; then
      sed -i 's/^Enabled:.*/Enabled: false/' "$file"
    else
      echo "Enabled: false" >> "$file"
    fi
    echo "    Disabled enterprise repo in $(basename "$file")"
  fi
}

echo "==> Disabling enterprise repositories (.sources)..."

for f in /etc/apt/sources.list.d/*.sources; do
  [[ -f "$f" ]] && disable_sources "$f"
done

echo "==> Ensuring no-subscription repositories..."

# Proxmox VE
if ! grep -Rqs "pve-no-subscription" /etc/apt/sources.list.d; then
  cat > /etc/apt/sources.list.d/pve-no-subscription.sources <<EOF
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: ${DIST}
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF
  echo "    Added Proxmox no-subscription repo"
else
  echo "    Proxmox no-subscription repo already present"
fi

# Ceph
if ! grep -Rqs "no-subscription" /etc/apt/sources.list.d/ceph; then
  cat > /etc/apt/sources.list.d/ceph-no-subscription.sources <<EOF
Types: deb
URIs: http://download.proxmox.com/debian/ceph-squid
Suites: ${DIST}
Components: no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF
  echo "    Added Ceph no-subscription repo"
else
  echo "    Ceph no-subscription repo already present"
fi

echo "==> Updating package lists..."
apt update

echo
echo "✅ Enterprise repositories disabled via Enabled: false"
echo "✅ No-subscription repositories ensured"
