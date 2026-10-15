# Kernel Parameters

Reference notes on kernel command line parameters used in developer and CI
host setups.

## IOMMU

```
iommu=pt amd_iommu=on
```

These options configure the AMD IOMMU (I/O Memory Management Unit), which is
required for device passthrough (VFIO/PCI passthrough) to VMs and for DMA
protection.

### `amd_iommu=on`

- Explicitly enables the AMD IOMMU hardware in the kernel.
- The IOMMU translates device-visible (DMA) addresses to physical addresses and
  enforces isolation, so a device can only touch memory it has been granted.
  Without it, you cannot safely assign a physical device to a guest, and
  VFIO/passthrough will not work.
- The IOMMU must also be enabled in firmware/BIOS (often labeled "AMD-Vi",
  "IOMMU", or "SVM"). The kernel option alone is not enough.
- On recent kernels the IOMMU is auto-enabled when firmware advertises it, so
  this option is often redundant — but it is harmless and makes the requirement
  explicit, which is good for a reproducible setup.

### `iommu=pt` (pt = "passthrough")

- Puts the IOMMU in passthrough/identity-mapping mode for devices used by the
  *host*.
- In this mode, host-owned devices bypass DMA translation (they use a 1:1
  identity map), which avoids the per-transaction translation overhead and
  restores near-native I/O performance for the host.
- Devices you actually assign to a guest still get a proper (isolating) IOMMU
  domain — `iommu=pt` only relaxes translation for the devices that remain with
  the host.

### Why both together

- `amd_iommu=on` turns the feature on; `iommu=pt` tunes its default behavior so
  you get isolation where you need it (passed-through devices) without paying the
  DMA-translation performance cost on host devices.
- These are the standard prerequisites for PCI/device passthrough into guests
  (VFIO) and for the DMA protection / isolation required by confidential-VM and
  secure-device scenarios.

> On an Intel platform, the equivalent would be `intel_iommu=on iommu=pt`.
