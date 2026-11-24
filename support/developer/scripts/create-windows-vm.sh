#!/bin/bash

set -eu

usage() {
    cat <<'EOF'
Usage: create-windows-vm.sh [--mode vtl0|vtl2|snp]

  vtl0  Windows with a host-emulated vTPM, without OpenHCL or SNP (default).
  vtl2  Windows with OpenHCL in VTL2, without SNP.
  snp   Windows with OpenHCL in VTL2 and SNP isolation.

Environment overrides:
  DISK         Windows VHDX path.
  IGVM         OpenHCL image (vtl2/snp only; defaults to the matching RPM path).
  DIAG_SOCKET  OpenHCL diagnostics socket (vtl2/snp only).

VTL2/SNP require backend and kernel support; SNP also requires SNP hardware.
Guest firmware/vTPM state is not persistent; do not enable BitLocker.
EOF
}

mode=vtl0
while (($#)); do
    case "$1" in
        --mode)
            if (($# < 2)); then
                echo "Error: --mode requires vtl0, vtl2, or snp." >&2
                exit 2
            fi
            mode=$2
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Error: unknown argument: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

case "$mode" in
    vtl0|vtl2|snp) ;;
    *)
        echo "Error: invalid mode '$mode'; expected vtl0, vtl2, or snp." >&2
        exit 2
        ;;
esac

DISK=${DISK:-$HOME/images/26100.8169.amd64fre.wir_26h2_ge_release_svc_refresh.260406-0618_client_professional_en-us.vhdx}

args=(
    --hv
    --uefi firmware=/usr/share/openvmm/MSVM.fd
    --secure-boot
    --secure-boot-template windows
    --tpm
    -m 8GB --processors 4
    --gfx
)

if [[ "$mode" == vtl0 ]]; then
    args+=(--disk "file:${DISK}")
else
    if [[ "$mode" == snp ]]; then
        IGVM=${IGVM:-/usr/share/openhcl/openhcl-x64-cvm.bin}
        args+=(--isolation snp)
    else
        IGVM=${IGVM:-/usr/share/openhcl/openhcl-x64.bin}
    fi
    DIAG_SOCKET=${DIAG_SOCKET:-${XDG_RUNTIME_DIR:-$HOME}/openvmm-windows-${mode}.sock}
    echo "Warning: $mode mode requires MSHV VTL2 support; the current backend may reject this launch." >&2
    args+=(
        --vtl2
        --igvm "firmware=${IGVM},personality=openhcl"
        --vmbus-scsi id=scsi0,vtl2
        --openhcl-controller id=relay0,type=scsi
        --disk "file:${DISK},on=scsi0,relay=relay0"
        --vmbus-redirect
        --com3 "term,name=VTL2 OpenHCL"
        --vmbus-vtl2-vsock-path "$DIAG_SOCKET"
    )
fi

exec openvmm "${args[@]}"
