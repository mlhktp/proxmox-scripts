# proxmox-scripts

Small helper scripts for Proxmox VE. Run individually as needed.

🚨 **DATA DESTRUCTION WARNING** 🚨

These scripts perform destructive operations. **ALL DATA WILL BE DELETED AND RECREATED AS ENCRYPTED DATASETS.**

Do NOT run on systems with data you cannot afford to lose. Ensure you have verified backups and local console access before proceeding.

## No-Subscription Repos

Disables enterprise repositories and enables the official no-subscription repos.

```bash
curl -fsSL https://raw.githubusercontent.com/mlhktp/proxmox-scripts/main/apt/switch-to-no-subscription.sh | sudo bash
```

## Disable Laptop Lid Sleep (optional)

Prevents suspend or shutdown when the laptop lid is closed.

```bash
curl -fsSL https://raw.githubusercontent.com/mlhktp/proxmox-scripts/main/encryption/utils/laptop_lid.sh | sudo bash
```

## ZFS Full Disk Encryption

Enables full disk encryption with ZFS and remote unlock via initramfs.

```bash
curl -fsSL https://raw.githubusercontent.com/mlhktp/proxmox-scripts/main/encryption/01-prepare-initramfs-dropbear.sh | sudo bash
curl -fsSL https://raw.githubusercontent.com/mlhktp/proxmox-scripts/main/encryption/02-initramfs-encrypt-root.sh | sudo bash
curl -fsSL https://raw.githubusercontent.com/mlhktp/proxmox-scripts/main/encryption/03-encrypt-non-root-datasets.sh | sudo bash
```

## License

MIT License
