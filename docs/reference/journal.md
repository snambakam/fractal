# Journal

## Changes to the AMD SEV-SNP Host

### Ocotober 15, 2026

1. Added kernel command line parameters for IOMMU

```bash
snambakam@azurelinux-cc-1 [ ~ ]$ cat /proc/cmdline
BOOT_IMAGE=/boot/vmlinuz-6.18.34.mshv3-1000.g59706f1e.lv3 root=PARTUUID=f01a098b-b9a9-4f8c-8275-e3d21bcb76ca amd_iommu=on iommu=pt selinux=0 rd.auto=1 net.ifnames=0 lockdown=integrity sysctl.kernel.unprivileged_bpf_disabled=1 init=/lib/systemd/systemd ro audit=0 console=tty1 console=ttyS0,115200n8 amd_iommu=off intel_iommu=off no5lvl crashkernel=512M-32G:256M,32G-:512M hyperv_resvd_new=0x1000!0x38b000,0x200000!0x100200000,0x400000!0x100400000,0x400000!0x100800000,0x400000!0x100c00000,0x400000!0x101000000,0x200000!0x181600000,0x200000!0x181e00000,0x200000!0x182200000,0x1b1600000!0x182400000,0x200000!0x333a00000,0x200000!0x333c00000,0x1000!0x80000,0x200000!0x101400000,0x80000000!0x101600000,0x400000!0x181800000,0x200000!0x181c00000,0x200000!0x182000000,0x80000000!0x8000000000,0x80000000!0x10000000000,0x4000000!0x18000000000
```
1. Installed msr-tools

```bash
sudo dnf install -y msr-tools
```

### October 14, 2026

1. Created a bootable USB with the ISO from [this](https://microsoft.visualstudio.com/LSG/_build/results?buildId=159380829&view=artifacts&pathAsName=false&type=publishedArtifacts) build.
1. Imaged the AMD SEV-SNP Host in the SCHIE lab using the USB.
1. Configured the Glacier Peak Overlake Card to provide an IPV4 Address.