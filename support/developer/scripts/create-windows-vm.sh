#!/bin/bash

IGVM=/usr/share/openhcl/openhcl-x64.bin
DISK=$HOME/images/26100.8169.amd64fre.wir_26h2_ge_release_svc_refresh.260406-0618_client_professional_en-us.vhdx
DIAG=/usr/bin/ohcldiag-dev

openvmm \
  --hv --vtl2 \
  --igvm "firmware=${IGVM},personality=openhcl" \
  --isolation snp \
  --uefi --secure-boot \
  --tpm \
  --vmbus-scsi id=scsi0,vtl2 \
  --openhcl-controller id=relay0,type=scsi \
  --disk "file:${DISK},on=scsi0,relay=relay0" \
  --vmbus-redirect \
  -m 8GB --processors 4 \
  --gfx \
  --com3 "term,name=VTL2 OpenHCL" \
  --vmbus-vtl2-vsock-path "${DIAG}"
