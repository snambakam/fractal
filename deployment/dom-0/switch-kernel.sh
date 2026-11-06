#!/bin/bash

set -euo pipefail

usage() {
    printf 'Usage: %s --kernel-release RELEASE [--boot-backup DIRECTORY] [--apply --acknowledge-boot-risk]\n' "${0##*/}"
    printf '\nSelect an installed MSHV kernel, including kernel-mshv-local.\n'
    printf 'Uses /boot/grub2/grub.cfg and /etc/default/grub; grubby is not needed.\n'
    printf 'Defaults to a read-only dry run. Does not install RPMs or reboot.\n'
    printf '\nOptions:\n'
    printf '  --kernel-release RELEASE   Exact kernel release, e.g. 6.18.34.mshv1+\n'
    printf '  --boot-backup DIRECTORY    Use known-good grub.defaults and grub.cfg\n'
    printf '  --apply                    Generate initramfs and change the boot default\n'
    printf '  --acknowledge-boot-risk     Accept possible loss of remote access\n'
    printf '  -h, --help                 Show this help\n'
    printf '\nKeep the old kernel installed. Without console or remote power access,\n'
    printf 'a failed boot can leave the machine unreachable. No automatic recovery\n'
    printf 'is provided. Secure Boot must be disabled for this helper.\n'
}

fail() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

quote_setting() {
    local value="$1"
    printf "'"
    while [[ "$value" == *"'"* ]]; do
        printf '%s' "${value%%\'*}" "'\\''"
        value="${value#*\'}"
    done
    printf "%s'" "$value"
}

hyperv_entry() {
    awk -v id="${2:-linux-dom0-with-hyper-v}" '
        /^menuentry / { selected = (index($0, "--id=" id " ") != 0) }
        selected { print }
        /^}/ { selected = 0 }
    ' "$1"
}

pin_generator() {
    awk -v kernel="linux=$(quote_setting "$2")" -v initrd="initrd=$(quote_setting "$3")" '
        $0 == "cat <<\047FRACTAL_MSHV_FALLBACK\047" { fallback = 1; next }
        fallback && $0 == "FRACTAL_MSHV_FALLBACK" { fallback = 0; next }
        fallback { next }
        $0 == "linux=`version_find_latest $list`" || /^linux=\047\/boot\/vmlinuz-/ {
            print kernel; kernels++; next
        }
        $0 == "initrd=`version_find_latest $initrd_list`" || /^initrd=\047\/boot\/initramfs-/ {
            print initrd; initrds++; next
        }
        { print }
        END { if (fallback || kernels != 1 || initrds != 1) exit 1 }
    ' "$1"
}

validate_entry() {
    awk -v image="vmlinuz-$1" -v initrd="initramfs-$1.img" '
        $1 == "chainloader" && $2 == "/HvLoader.efi" && $3 == "lxhvloader.dll" { loader = NR; loaders++ }
        $1 == "boot" { boot = NR; boots++ }
        $1 == "linux" {
            path = $2; sub(/^.*\//, "", path)
            if (path == image && index($0, "$kernelopts") && !index($0, "hyperv_resvd")) linux = NR
            kernels++
        }
        $1 == "initrd" {
            path = $2; sub(/^.*\//, "", path)
            if (path == initrd) ramdisk = NR
            initrds++
        }
        END { exit !(loaders == 1 && boots == 1 && kernels == 1 && initrds == 1 && loader < boot && boot < linux && linux < ramdisk) }
    '
}

main() {
    local release='' boot_backup='' apply=false acknowledged=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --kernel-release|--boot-backup)
                [[ $# -ge 2 && -n "$2" && "$2" != -* ]] || fail "$1 requires a value."
                case "$1" in
                    --kernel-release) release="$2" ;;
                    --boot-backup) boot_backup="$(realpath -- "$2")" ;;
                esac
                shift 2
                ;;
            --apply) apply=true; shift ;;
            --acknowledge-boot-risk) acknowledged=true; shift ;;
            -h|--help) usage; return 0 ;;
            *) fail "Unknown argument: $1" ;;
        esac
    done

    [[ -n "$release" && "$release" != *[!a-zA-Z0-9._+-]* ]] || fail 'Provide a valid --kernel-release.'
    if $apply && ! $acknowledged; then
        fail '--apply requires --acknowledge-boot-risk; a failed boot may require physical recovery.'
    fi

    local tool
    for tool in grub2-mkconfig dracut depmod realpath uname od awk grep sed cp mktemp mv chmod mkdir rm; do
        command -v "$tool" >/dev/null 2>&1 || fail "Required command not found: $tool"
    done

    if [[ $EUID -ne 0 ]]; then
        command -v sudo >/dev/null 2>&1 || fail 'Run as root or install sudo.'
        local args=(--kernel-release "$release")
        if [[ -n "$boot_backup" ]]; then args+=(--boot-backup "$boot_backup"); fi
        if $apply; then args+=(--apply --acknowledge-boot-risk); fi
        exec sudo -- /bin/bash "$(realpath -- "${BASH_SOURCE[0]}")" "${args[@]}"
    fi

    local running image initrd config grub_config grub_defaults generator secure_boot_file secure_boot
    running="$(uname -r)"
    image="/boot/vmlinuz-$release"
    initrd="/boot/initramfs-$release.img"
    config="/boot/config-$release"
    grub_config=/boot/grub2/grub.cfg
    grub_defaults=/etc/default/grub
    generator=/etc/grub.d/05_mariner_mshv_menuentry
    secure_boot_file=/sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c

    [[ -x "$generator" ]] || fail "Required Hyper-V menu generator not found or not executable: $generator"
    [[ -s "$image" && -d "/lib/modules/$release" ]] || fail "Kernel image or modules missing for $release; install its RPM first."
    [[ -s "$config" ]] && grep -qx 'CONFIG_MSHV_ROOT=y' "$config" || fail 'Target kernel config does not enable CONFIG_MSHV_ROOT=y.'
    [[ -s "$grub_config" ]] || fail "Expected GRUB configuration not found: $grub_config"
    [[ -s "/boot/vmlinuz-$running" ]] || fail 'Running kernel image is missing; no boot fallback is available.'
    [[ -f "$grub_defaults" ]] || fail "GRUB defaults not found: $grub_defaults"
    if [[ -f /boot/grub2/grubenv ]] && grep -aqE '^next_entry=.+$' /boot/grub2/grubenv; then
        fail 'A one-shot GRUB entry is pending; clear it before switching kernels.'
    fi

    [[ -r "$secure_boot_file" ]] || fail 'Cannot determine UEFI Secure Boot state; verify the boot environment manually.'
    secure_boot="$(od -An -t u1 -j 4 -N 1 "$secure_boot_file")"
    [[ "$secure_boot" =~ ^[[:space:]]*0[[:space:]]*$ ]] || fail 'Secure Boot is enabled or its state is unknown; this helper does not validate kernel signatures.'

    local defaults_source="$grub_defaults" config_source="$grub_config" expected_loader previous_image previous_initrd previous_release fallback_entry
    if [[ -n "$boot_backup" ]]; then
        defaults_source="$boot_backup/grub.defaults"
        config_source="$boot_backup/grub.cfg"
    fi
    [[ -s "$defaults_source" && -s "$config_source" ]] || fail 'Known-good GRUB defaults or configuration are missing.'
    if grep -q 'hyperv_resvd' "$defaults_source"; then
        fail 'Defaults contain copied hypervisor reservations; provide --boot-backup with the original pre-switch configuration.'
    fi
    expected_loader="$(hyperv_entry "$config_source" | awk '$1 == "chainloader" { sub(/^[[:space:]]*/, ""); print }')"
    [[ -n "$expected_loader" && "$expected_loader" != *$'\n'* ]] || fail 'Known-good configuration must contain exactly one Hyper-V loader entry.'
    fallback_entry="$(hyperv_entry "$config_source")"
    previous_image="$(awk '$1 == "linux" { print $2 }' <<< "$fallback_entry")"
    if [[ "${previous_image##*/}" == "vmlinuz-$release" ]]; then
        fallback_entry="$(hyperv_entry "$config_source" fractal-dom0-fallback)"
        previous_image="$(awk '$1 == "linux" { print $2 }' <<< "$fallback_entry")"
    fi
    previous_initrd="$(awk '$1 == "initrd" { print $2 }' <<< "$fallback_entry")"
    [[ -s "$previous_image" && -s "$previous_initrd" ]] || fail 'The previous Hyper-V kernel or initramfs is missing; preserve a working fallback.'
    previous_release="${previous_image##*/vmlinuz-}"
    validate_entry "$previous_release" <<< "$fallback_entry" || fail 'The previous Hyper-V entry is not a usable kernel/initramfs pair with loader-supplied $kernelopts.'
    fallback_entry="$(sed 's/--id=linux-dom0-with-hyper-v /--id=fractal-dom0-fallback /' <<< "$fallback_entry")"
    pin_generator "$generator" "$image" "$initrd" >/dev/null || fail 'Unrecognized Hyper-V generator; expected exactly one kernel and initramfs selection.'

    printf 'Running kernel: %s\nTarget kernel: %s\n' "$running" "$release"
    printf '\nPlan: pin the Hyper-V loader entry to the target kernel and initramfs.\n'
    printf 'Defaults source: %s\n' "$defaults_source"
    printf 'HvLoader commands and loader-supplied $kernelopts will be preserved.\n'
    printf 'No kernel will be removed. No reboot will be performed.\n'
    printf 'WARNING: a failed boot can require physical recovery; there is no automatic rollback after reboot.\n'

    if ! $apply; then
        printf '\nDry run only. To apply, rerun with --apply --acknowledge-boot-risk.\n'
        return 0
    fi

    printf 'Shut down all guests and stop OpenVMM before rebooting the host.\n'

    local backup candidate='' generator_candidate='' entry
    mkdir -p /var/lib/fractal
    backup="$(mktemp -d /var/lib/fractal/kernel-switch.XXXXXX)"
    cp -p -- "$grub_config" "$backup/grub.cfg"
    cp -p -- "$grub_defaults" "$backup/grub.defaults"
    cp -p -- "$generator" "$backup/05_mariner_mshv_menuentry"
    printf 'Boot configuration backup: %s\n' "$backup"

    rollback() {
        trap - EXIT INT TERM
        printf 'Kernel switch failed; restoring previous GRUB configuration and defaults.\n' >&2
        cp -p -- "$backup/grub.cfg" "$grub_config" || printf 'ERROR: failed to restore GRUB config from %s\n' "$backup" >&2
        cp -p -- "$backup/grub.defaults" "$grub_defaults" || printf 'ERROR: failed to restore GRUB defaults from %s\n' "$backup" >&2
        cp -p -- "$backup/05_mariner_mshv_menuentry" "$generator" || printf 'ERROR: failed to restore Hyper-V generator from %s\n' "$backup" >&2
        if [[ -n "$candidate" ]]; then rm -f -- "$candidate" "${candidate}.new"; fi
        if [[ -n "$generator_candidate" ]]; then rm -f -- "$generator_candidate"; fi
        exit 1
    }
    trap rollback EXIT
    trap 'exit 1' INT TERM

    depmod "$release"
    dracut --force "$initrd" "$release"
    [[ -s "$initrd" ]] || fail "Initramfs was not created: $initrd"
    generator_candidate="$(mktemp /etc/grub.d/.fractal-mshv.XXXXXX)"
    pin_generator "$generator" "$image" "$initrd" > "$generator_candidate"
    {
        printf "\ncat <<'FRACTAL_MSHV_FALLBACK'\n"
        printf '%s\nFRACTAL_MSHV_FALLBACK\n' "$fallback_entry"
    } >> "$generator_candidate"
    /bin/sh -n "$generator_candidate"
    chmod --reference="$generator" "$generator_candidate"
    mv -f -- "$generator_candidate" "$generator"
    generator_candidate=''
    if [[ "$(realpath -- "$defaults_source")" != "$(realpath -- "$grub_defaults")" ]]; then
        cp -p -- "$defaults_source" "$grub_defaults"
    fi
    {
        printf "\nGRUB_DEFAULT='linux-dom0-with-hyper-v'\nGRUB_SAVEDEFAULT=false\n"
    } >> "$grub_defaults"
    candidate="$(mktemp /boot/grub2/grub.cfg.fractal.XXXXXX)"
    grub2-mkconfig -o "$candidate"
    entry="$(hyperv_entry "$candidate")"
    validate_entry "$release" <<< "$entry" || fail 'Hyper-V entry does not launch HvLoader before the exact target kernel and initramfs, or $kernelopts is missing.'
    [[ "$(awk '$1 == "chainloader" { sub(/^[[:space:]]*/, ""); print }' <<< "$entry")" == "$expected_loader" ]] || fail 'Hyper-V loader options changed during generation.'
    [[ "$(hyperv_entry "$candidate" fractal-dom0-fallback)" == "$fallback_entry" ]] || fail 'Generated configuration does not retain the previous Hyper-V entry as a fallback.'
    grep -Fq -- 'set default="linux-dom0-with-hyper-v"' "$candidate" || fail 'Generated configuration does not default to the Hyper-V loader entry.'
    chmod --reference="$grub_config" "$candidate"
    mv -f -- "$candidate" "$grub_config"
    candidate=''
    trap - EXIT INT TERM

    printf '\nNew default: %s\n' "$image"
    printf 'GRUB entry ID: linux-dom0-with-hyper-v\n%s\n' "$entry"
    printf 'Before reboot, ensure someone can recover the host if it becomes unreachable.\n'
    printf 'To revert before reboot:\n'
    printf '  sudo cp -p -- %q %q\n' "$backup/grub.defaults" "$grub_defaults"
    printf '  sudo cp -p -- %q %q\n' "$backup/05_mariner_mshv_menuentry" "$generator"
    printf '  sudo cp -p -- %q %q\n' "$backup/grub.cfg" "$grub_config"
    printf 'After a successful reboot, verify uname -r and /dev/mshv.\n'
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi