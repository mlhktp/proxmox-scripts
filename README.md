# proxmox-scripts

Small helper scripts for Proxmox VE. Run individually as needed.

🚨 **DATA DESTRUCTION WARNING** 🚨

These scripts perform destructive operations. **ALL DATA WILL BE DELETED AND RECREATED AS ENCRYPTED DATASETS.**

Do NOT run on systems with data you cannot afford to lose. Ensure you have verified backups and local console access before proceeding.

The encryption scripts are only tested on Proxmox VE 9.11 on a fresh install and it is a work in progress. Use at your own risk.

---

## No-Subscription Repos (`apt/switch-to-no-subscription.sh`)

Disables Proxmox **enterprise** repositories and enables the official **no-subscription** repositories for PVE and Ceph.

Use this if you do not have a Proxmox subscription and want to avoid update errors.

```bash
curl -fsSL https://raw.githubusercontent.com/mlhktp/proxmox-scripts/main/apt/switch-to-no-subscription.sh | bash
```

---

## Disable Laptop Lid Sleep (optional) (`utils/laptop_lid.sh`)

Disables lid-close handling via `systemd-logind`, preventing suspend or shutdown when closing the laptop lid.

```bash
curl -fsSL https://raw.githubusercontent.com/mlhktp/proxmox-scripts/main/utils/laptop_lid.sh | bash
```

---

## ZFS Full Disk Encryption

End-to-end encryption for Proxmox using **ZFS native encryption**, with **remote unlock via Dropbear in initramfs**.

This process is **destructive** and rewrites all datasets.

### 1. Prepare initramfs + Dropbear (`01-prepare-initramfs-dropbear.sh`)

Installs and configures Dropbear SSH inside initramfs to allow **remote unlocking of the root pool during boot**.

* Installs `dropbear-initramfs`
* Configures SSH on port `4748`
* Sets up `authorized_keys`
* Enables networking and initramfs break

```bash
curl -fsSL https://raw.githubusercontent.com/mlhktp/proxmox-scripts/main/encryption/01-prepare-initramfs-dropbear.sh | bash
```

---

### 2. Encrypt Root Pool (`02-initramfs-encrypt-root.sh`)

Encrypts the **root ZFS pool** (`rpool/ROOT`) while preserving system data.

* Snapshots and copies the root dataset
* Destroys the unencrypted root
* Recreates it with ZFS encryption enabled
* Requires passphrase entry

```bash
wget https://raw.githubusercontent.com/mlhktp/proxmox-scripts/main/encryption/02-initramfs-encrypt-root.sh
chmod +x 02-initramfs-encrypt-root.sh
./02-initramfs-encrypt-root.sh
```

---

### 3. Encrypt Non-Root Datasets (`03-encrypt-non-root-datasets.sh`)

Encrypts remaining datasets such as:

* `rpool/data`
* `rpool/var-lib-vz`

Also:

* Generates and stores encryption keys
* Removes initramfs break
* Sets up a systemd service to auto-load ZFS keys at boot

```bash
curl -fsSL https://raw.githubusercontent.com/mlhktp/proxmox-scripts/main/encryption/03-encrypt-non-root-datasets.sh | bash
```

---
## References

This approach is based on the method described by Robin W. Hunter:

[1] Robin W. Hunter, *Securing Proxmox using ZFS' native encryption*, June 15, 2025  
    https://bitgrounds.tech/posts/proxmox-zfs-encryption

---

## License

MIT License
