#!/bin/bash

set -e

#
# Ensure the IOMMU kernel command line parameters are present.
#
# See docs/reference/kernel-parameters.md for why these are needed.
#

PARAMS=("iommu=pt" "amd_iommu=on")
GRUB_DEFAULT=/etc/default/grub

#
# Main
#

if [ ! -f "$GRUB_DEFAULT" ]; then
    echo "Error: $GRUB_DEFAULT not found; cannot update kernel command line." >&2
    exit 1
fi

to_add=()
pending=()
active=()
for param in "${PARAMS[@]}"; do
    if grep -qw -- "$param" /proc/cmdline; then
        echo "Active (running kernel): $param"
        active+=("$param")
    elif sudo grep -qw -- "$param" "$GRUB_DEFAULT"; then
        echo "Configured in $GRUB_DEFAULT, pending reboot: $param"
        pending+=("$param")
    else
        echo "Missing: $param"
        to_add+=("$param")
    fi
done

if [ ${#to_add[@]} -eq 0 ]; then
    if [ ${#pending[@]} -gt 0 ]; then
        echo "All IOMMU parameters are configured but not yet active; reboot required."
    else
        echo "All IOMMU parameters already set on the running kernel."
    fi
    exit 0
fi

echo "Adding missing parameters to $GRUB_DEFAULT: ${to_add[*]}"
sudo cp -a "$GRUB_DEFAULT" "$GRUB_DEFAULT.bak.$(date +%Y%m%d%H%M%S)"

for param in "${to_add[@]}"; do
    sudo sed -i -E "s/^(GRUB_CMDLINE_LINUX=\")/\1$param /" "$GRUB_DEFAULT"
done

if command -v grub2-mkconfig >/dev/null 2>&1; then
    GRUB_CFG=/boot/grub2/grub.cfg
    [ -f /boot/efi/EFI/azurelinux/grub.cfg ] && GRUB_CFG=/boot/efi/EFI/azurelinux/grub.cfg
    sudo grub2-mkconfig -o "$GRUB_CFG"
elif command -v update-grub >/dev/null 2>&1; then
    sudo update-grub
else
    echo "Error: no grub config generator found (grub2-mkconfig/update-grub)." >&2
    exit 1
fi

echo "Done. Reboot for the IOMMU parameters to take effect."
