#!/bin/bash

set -euo pipefail

usage() {
    printf 'Usage: %s --mode MODE --vhdx /path/to/windows.vhdx [OPTIONS]\n' "${0##*/}"
    printf '\nModes (MSHV backend):\n'
    printf '  standard     OpenHCL off, SNP off (supported)\n'
    printf '  openhcl      OpenHCL on, SNP off (not yet supported)\n'
    printf '  snp          OpenHCL off, SNP on (Windows UEFI boot not yet supported)\n'
    printf '  openhcl-snp  OpenHCL on, SNP on (not yet supported)\n'
    printf '\nThe VHDX is opened read/write. Use a copy of the disk for testing.\n'
    printf '\nOptions (override environment defaults):\n'
    printf '  --memory SIZE       Guest RAM (default: 8GB)\n'
    printf '  --processors COUNT  Virtual CPUs (default: 4)\n'
    printf '  --firmware PATH     UEFI firmware (default: /usr/share/openvmm/MSVM.fd)\n'
    printf '  --vnc-port PORT     Local VNC port (default: 5900)\n'
    printf '  --openvmm PATH      OpenVMM executable (default: openvmm)\n'
    printf '  --vtpm              Enable host-emulated vTPM and Windows Secure Boot\n'
    printf '  -h, --help          Show this help\n'
    printf '\nWith --vtpm, OpenVMM must be built with the tpm feature.\n'
    printf 'Firmware/vTPM state is not persistent; do not enable BitLocker.\n'
    printf '\nEnvironment overrides:\n'
    printf '  OPENVMM_BIN            Executable (default: openvmm)\n'
    printf '  OPENVMM_UEFI_FIRMWARE  Firmware (default: /usr/share/openvmm/MSVM.fd)\n'
    printf '  VM_MEMORY              Guest RAM (default: 8GB)\n'
    printf '  VM_PROCESSORS          Virtual CPUs (default: 4)\n'
    printf '  VNC_PORT               Local VNC port (default: 5900)\n'
}

mode=""
disk_path=""
openvmm="${OPENVMM_BIN:-openvmm}"
firmware="${OPENVMM_UEFI_FIRMWARE:-/usr/share/openvmm/MSVM.fd}"
memory="${VM_MEMORY:-8GB}"
processors="${VM_PROCESSORS:-4}"
vnc_port="${VNC_PORT:-5900}"
vtpm=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
        --vtpm)
            vtpm=true
            shift
            ;;
        --mode|--vhdx|--memory|--processors|--firmware|--vnc-port|--openvmm)
            if [[ $# -lt 2 || -z "$2" || "$2" == --* ]]; then
                echo "Error: $1 requires a value." >&2
                exit 1
            fi
            case "$1" in
                --mode) mode="$2" ;;
                --vhdx) disk_path="$2" ;;
                --memory) memory="$2" ;;
                --processors) processors="$2" ;;
                --firmware) firmware="$2" ;;
                --vnc-port) vnc_port="$2" ;;
                --openvmm) openvmm="$2" ;;
            esac
            shift 2
            ;;
        *)
            echo "Error: unknown argument: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

if [[ -z "$mode" || -z "$disk_path" ]]; then
    echo "Error: --mode and --vhdx are required." >&2
    usage >&2
    exit 1
fi

case "$mode" in
    standard) ;;
    openhcl|openhcl-snp)
        echo "Error: mode '$mode' requires OpenHCL/VTL2 support, which the current OpenVMM MSHV backend does not implement." >&2
        echo "No VM was launched. Use 'standard' only if you intend to run without OpenHCL and SNP isolation." >&2
        exit 1
        ;;
    snp)
        echo "Error: mode 'snp' requires SNP-isolated Windows UEFI boot, which the current OpenVMM backend does not support." >&2
        echo "No VM was launched. Use 'standard' only if you intend to run without SNP isolation." >&2
        exit 1
        ;;
    *)
        echo "Error: unknown mode: $mode" >&2
        usage >&2
        exit 1
        ;;
esac

if ! resolved_openvmm="$(command -v "$openvmm")"; then
    echo "Error: OpenVMM executable not found: $openvmm" >&2
    exit 1
fi
openvmm="$resolved_openvmm"

if [[ $EUID -ne 0 ]]; then
    if ! command -v sudo >/dev/null 2>&1; then
        echo "Error: sudo is required to access /dev/mshv." >&2
        exit 1
    fi
    script_args=(--mode "$mode" --vhdx "$disk_path")
    if [[ "$vtpm" == true ]]; then
        script_args+=(--vtpm)
    fi
    exec sudo -- env \
        OPENVMM_BIN="$(realpath -- "$openvmm")" \
        OPENVMM_UEFI_FIRMWARE="$firmware" \
        VM_MEMORY="$memory" \
        VM_PROCESSORS="$processors" \
        VNC_PORT="$vnc_port" \
        /bin/bash "$(realpath -- "${BASH_SOURCE[0]}")" \
        "${script_args[@]}"
fi

if [[ ! -f "$disk_path" || ! -s "$disk_path" || ! -r "$disk_path" || ! -w "$disk_path" ]]; then
    echo "Error: VHDX must be a nonempty, readable, writable file: $disk_path" >&2
    exit 1
fi
disk="$(realpath -- "$disk_path")"

if [[ ! -f "$firmware" || ! -s "$firmware" || ! -r "$firmware" ]]; then
    echo "Error: UEFI firmware not found or unreadable: $firmware. Install the firmware-inclusive openvmm RPM or set OPENVMM_UEFI_FIRMWARE." >&2
    exit 1
fi

if [[ "$disk" == *,* || "$firmware" == *,* ]]; then
    echo "Error: disk and firmware paths cannot contain commas (OpenVMM option separator)." >&2
    exit 1
fi

if [[ ! -c /dev/mshv ]]; then
    echo "Error: /dev/mshv is missing. Boot the MSHV-enabled dom0 kernel." >&2
    exit 1
fi

if [[ ! -r /dev/mshv || ! -w /dev/mshv ]]; then
    echo "Error: /dev/mshv is not accessible even as root. Check device permissions and host security policy." >&2
    exit 1
fi

echo "Starting Windows VM in '$mode' mode: OpenHCL off, SNP off"
echo "Disk: $disk (persistent disk writes)"
echo "Console: VNC at 127.0.0.1:$vnc_port (use an SSH tunnel for remote access)"

vtpm_args=()
if [[ "$vtpm" == true ]]; then
    vtpm_args=(--secure-boot --secure-boot-template windows --tpm)
    echo "Warning: host-emulated vTPM and firmware state are not persistent. Do not enable BitLocker." >&2
fi

exec "$openvmm" \
    --hypervisor mshv \
    --hv \
    --uefi "firmware=$firmware" \
    "${vtpm_args[@]}" \
    --disk "file:$disk" \
    --memory "$memory" \
    --processors "$processors" \
    --net consomme \
    --gfx \
    --vnc-listen 127.0.0.1 \
    --vnc-port "$vnc_port"