#!/bin/bash

set -e

#
# Main
#

[ -d /sys/firmware/efi ] && echo "UEFI OK" || echo "NOT booted in UEFI mode"

if ! command -v efibootmgr >/dev/null 2>&1; then
    sudo dnf -y install efibootmgr
fi

efibootmgr -v