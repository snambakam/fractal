# How-to: Run a Windows CVM with a host-isolated vTPM using OpenHCL on Azure Linux + MSHV (AMD SEV-SNP)

**Audience:** Platform engineers (command-level detail).
**Goal:** Natively install Azure Linux with the Microsoft Hypervisor (MSHV) on an
AMD SEV-SNP host, use OpenVMM to create and monitor VMs, and launch a Windows
guest whose virtual TPM (vTPM) is protected from both the host and the
hypervisor by running it inside OpenHCL (VTL2).

This guide implements the design described in
[OpenHCL Architecture](https://openvmm.dev/guide/reference/architecture/openhcl.html).

## Initial milestone — Windows + host-emulated vTPM, without SEV-SNP

Start here for functional bring-up on the MSHV test machine using the installed
`openvmm`, `openvmm-diag`, and `openhcl` RPMs. This milestone does **not** use
OpenHCL, VTL2, or SNP; the vTPM runs in the host OpenVMM process and is not
protected from the host. The installed `/usr/share/openhcl/openhcl-x64.bin`
is not needed for this step.

The OpenVMM binary must be built with the `openvmm/tpm` Cargo feature; the
repository's `build-openvmm` and `package-openvmm` targets enable it.
If startup reports `no resolver for chipset_device_handle:tpm`, rebuild and
redeploy the OpenVMM RPM from the build VM with this feature enabled. The
`--tpm` runtime flag alone cannot enable a device omitted at compile time.

> **Implementation boundary:** The current source's `virt_mshv` backend rejects
> VTL2 configuration with `vtl2 not supported`. Therefore, the OpenHCL/SNP
> stages below are a follow-up design, not a working deployment path for this
> backend yet. Removing only `--isolation snp` from the later launch command
> does not bypass this limitation.

On the **test machine**, confirm the MSHV device and installed executable:

```bash
ls -l /dev/mshv
/usr/bin/openvmm --version
```

Use an account with permission to access `/dev/mshv`. Point `DISK` at a prepared,
UEFI-bootable Windows VHDX that the account can read and write:

The repository's
[`create-windows-vm.sh`](../../support/developer/scripts/create-windows-vm.sh)
defaults to this VTL0-only configuration using the installed RPM firmware.
Select the launch mode explicitly with `--mode`:

```bash
DISK="$HOME/images/windows.vhdx" ./support/developer/scripts/create-windows-vm.sh --mode vtl0
# Follow-up modes; require MSHV VTL2 support:
DISK="$HOME/images/windows.vhdx" ./support/developer/scripts/create-windows-vm.sh --mode vtl2
DISK="$HOME/images/windows.vhdx" ./support/developer/scripts/create-windows-vm.sh --mode snp
```

`vtl2` uses `/usr/share/openhcl/openhcl-x64.bin`; `snp` uses
`/usr/share/openhcl/openhcl-x64-cvm.bin` and requires SNP-capable hardware.
Override `IGVM` for a different image built with the corresponding recipe.
These options select launch arguments; they do not add backend support.
`DIAG_SOCKET` overrides the OpenHCL socket path, which defaults to
`$XDG_RUNTIME_DIR/openvmm-windows-<mode>.sock` (or under `$HOME` if
`XDG_RUNTIME_DIR` is unset). This is a socket, not the `ohcldiag-dev` executable.

Alternatively, run OpenVMM directly:

```bash
DISK="$HOME/images/windows.vhdx"

/usr/bin/openvmm \
  --hv \
  --uefi firmware=/usr/share/openvmm/MSVM.fd \
  --secure-boot \
  --secure-boot-template windows \
  --tpm \
  --disk "file:${DISK}" \
  -m 8GB --processors 4 \
  --gfx
```

The disk is writable: use a disposable copy for initial testing. Do not add
`--vtl2`, `--igvm`, `--isolation snp`, or the VTL2 device-relay options for this
milestone. `ohcldiag-dev` is not used because no OpenHCL instance is running.
Use OpenVMM's graphical-console/VNC access for Windows. Press `Ctrl-Q`, then
`q`, to quit OpenVMM.

In an elevated Windows PowerShell session, check:

```powershell
Get-Tpm | Format-List TpmPresent,TpmReady,TpmEnabled,TpmActivated
Confirm-SecureBootUEFI
```

Expect `TpmPresent` to be `True`; provisioning may be needed before `TpmReady`
becomes `True`. Secure Boot should report `True`.

**Smoke-test state only:** Without `--vmgs`, guest firmware and vTPM state are
stored in memory and do not persist across OpenVMM restarts, even though disk
writes persist. Do not enable BitLocker or rely on TPM-sealed secrets in this
configuration. Persistent VMGS must be configured and restart-tested before
using those features.

---

## 0. How this stack protects the vTPM

Traditional virtualization emulates the vTPM in the host VMM. In that model the
host (and the hypervisor) can read vTPM state — unacceptable for a confidential
VM (CVM) where the host is untrusted.

OpenHCL moves the vTPM *inside* the guest's trust boundary:

- **OpenHCL is a paravisor** — "virtual firmware" that runs inside the guest
  partition at a higher privilege level than the guest OS.
- It uses **Virtual Trust Levels (VTLs)**:
  - **VTL2** — OpenHCL runs here. Hosts the emulated vTPM and enforces Secure
    Boot policy. Isolated from VTL0.
  - **VTL0** — the Windows guest OS. Cannot read VTL2 memory, so it cannot read
    the vTPM's secrets directly.
- On AMD **SEV-SNP** hardware the whole partition (VTL0 + VTL2) is memory-encrypted
  and integrity-protected, so the **host and hypervisor cannot read guest or
  paravisor memory**. The vTPM lives in encrypted VTL2 memory.
- For defense-in-depth, the vTPM can run in a **separate VTL2 worker process**
  (isolated-pool), so a compromise elsewhere in OpenHCL does not expose it.

```mermaid
flowchart TB
    subgraph host["AMD SEV-SNP host (untrusted by the CVM)"]
        mshv["MSHV — Microsoft Hypervisor (/dev/mshv)"]
        subgraph root["Azure Linux root partition (dom0)"]
            ovmm["OpenVMM (VMM) + ohcldiag-dev"]
        end
        subgraph cvm["Confidential VM partition (SEV-SNP encrypted)"]
            subgraph vtl2["VTL2 — OpenHCL paravisor"]
                tpm["vTPM (isolated worker)"]
                sb["Secure Boot enforcement"]
            end
            subgraph vtl0["VTL0 — Windows guest"]
                win["Windows + TPM driver"]
            end
        end
    end
    ovmm -- "loads OpenHCL IGVM + builds partition" --> mshv
    mshv --> cvm
    win -. "TPM 2.0 cmds via VMBus" .-> tpm
    vtl0 -. "cannot read VTL2 memory" .-x tpm
    root -. "cannot read encrypted CVM memory" .-x cvm
```

> **Why MSHV and not KVM?** OpenHCL requires Hyper-V-style VTLs. The openvmm.dev
> note that "OpenHCL cannot be used on Linux hosts" refers specifically to **KVM**,
> which lacks the required VTL/VMPL primitives. **MSHV (the Microsoft Hypervisor)
> provides these**, so Azure Linux + MSHV is the correct Linux foundation for this
> scenario. This deployment uses no KVM.

---

## 1. Prerequisites

### Machine roles
- **Build VM:** An x86_64 Linux VM used to build OpenVMM, ohcldiag-dev, and
  OpenHCL. It does not need SEV-SNP hardware or `/dev/mshv`. Use a distribution
  compatible with the test machine's runtime libraries (preferably the same
  Azure Linux release).
- **Test machine:** The SEV-SNP-capable Azure Linux + MSHV host. Copy the built
  artifacts here; Rust and the build toolchain are not needed to run them.
- Run Stages 1–2 and 5 onward on the **test machine**. Stages 3–4 explicitly
  distinguish build, transfer, and installation commands.

### Test-machine hardware
- AMD EPYC CPU with **SEV-SNP** support (3rd Gen "Milan" or newer).
- SEV-SNP enabled and provisioned in platform firmware (see §3).
- Sufficient RAM/cores; reserve headroom for VTL2 (OpenHCL needs its own slice of
  guest memory, typically a few hundred MB per CVM).
- A removable/virtual media path for the installer ISO (BMC/iDRAC/iLO virtual
  media, or a USB stick).

### Software / artifacts you will produce or download
- **Azure Linux installer ISO that already bundles MSHV** — produced by the ADO
  pipeline run
  [2610.3.1-ci.159380829](https://microsoft.visualstudio.com/LSG/_build/results?buildId=159380829&view=artifacts&pathAsName=false&type=publishedArtifacts).
  Booting and installing from this ISO installs the Microsoft Hypervisor and a
  dom0-capable kernel for you — no separate MSHV package install is required.
- **OpenVMM** binary (`openvmm`) — built on the build VM or downloaded from CI.
- **OpenHCL IGVM** image, CVM recipe (`openhcl-x64-cvm.bin`) — built on the build VM.
- **ohcldiag-dev** — diagnostics tool for OpenHCL.
- A **Windows guest image** (VHDX) prepared for Trusted Launch / CVM (UEFI +
  Secure Boot + TPM-aware).

### Host accounts / access
- Physical or BMC console access for the bare-metal install.
- Root on the installed host.

---

## 2. Stage 1 — Install Azure Linux (with MSHV) natively from the ISO

This stage uses the pipeline-produced ISO, which already includes MSHV and a
dom0 kernel. Installing from it gives you an Azure Linux root partition with the
Microsoft Hypervisor in place.

0. **Download the ISO** from the ADO build artifacts for run
   [2610.3.1-ci.159380829](https://microsoft.visualstudio.com/LSG/_build/results?buildId=159380829&view=artifacts&pathAsName=false&type=publishedArtifacts)
   (Artifacts tab → published artifacts → the `*.iso`). You must be signed in to
   the Microsoft ADO org to access it.

1. **Attach the ISO** via BMC virtual media (or write it to USB with
   `dd if=<downloaded>.iso of=/dev/sdX bs=4M status=progress && sync`).

2. **Boot the installer.** In firmware/BIOS set boot mode to **UEFI** (required
   for Secure Boot and for the CVM guest path), and boot the ISO.

3. **Run the installer.** Azure Linux ships a text/graphical installer
   (`mariner-installer`). Choose:
   - **Image type:** a full/CLI image (not the minimal container image).
   - **Disk layout:** standard GPT + EFI System Partition. Prefer a layout that
     leaves room for guest disk images (e.g. a dedicated `/var/lib/openvmm`
     filesystem or LVM volume).
   - **Hostname, user, SSH** as appropriate for a headless host.

4. **First boot & update:**
   ```bash
   sudo tdnf -y update
   sudo tdnf -y install vim git curl tar jq pciutils util-linux
   ```

5. **Confirm UEFI boot and firmware vars are present:**
   ```bash
   [ -d /sys/firmware/efi ] && echo "UEFI OK" || echo "NOT booted in UEFI mode"
   sudo tdnf -y install efibootmgr
   efibootmgr -v
   ```

> If you require a measured/attested host as well (host integrity, not just guest
> CVM isolation), enable host Secure Boot and TPM-based measured boot here. That
> is independent of the guest vTPM isolation this guide focuses on.

---

## 3. Stage 2 — Enable SEV-SNP and verify MSHV

The guest's vTPM protection ultimately rests on two things being active on the
host: **SEV-SNP** (memory encryption/integrity) and **MSHV** (the hypervisor that
provides VTLs). MSHV was already installed by the Stage 1 ISO, so here you enable
SEV-SNP in firmware/kernel and then confirm MSHV is live.

### 3a. Enable SEV-SNP in platform firmware
Reboot into BIOS/UEFI setup and enable (names vary by OEM):
- **SMEE** / Secure Memory Encryption.
- **SEV-SNP** support / "SNP Memory Coverage" (often set to *Enabled* or a
  specific RMP size).
- **SEV-ES ASID space** / minimum SEV ASID as required by your platform.
- **IOMMU** enabled.

Save and boot back into Azure Linux.

### 3b. Kernel command line for SEV-SNP (host side)
Ensure IOMMU and (if required by your kernel) the SNP host options are set. Edit
the bootloader config and append to the kernel cmdline:

```bash
# Azure Linux uses systemd-boot or GRUB depending on the image.
# For GRUB:
sudo vim /etc/default/grub
#   GRUB_CMDLINE_LINUX="... iommu=pt amd_iommu=on"
sudo grub2-mkconfig -o /boot/grub2/grub.cfg
```

Verify SEV/SNP after reboot:
```bash
sudo dmesg | grep -iE "SEV|SNP|ccp|RMP"
# Expect lines indicating SEV-SNP is enabled and the CCP/RMP initialized.
ls -l /dev/sev 2>/dev/null && echo "/dev/sev present"
```

### 3c. Confirm MSHV (the Microsoft Hypervisor) and dom0 kernel from the ISO
The Stage 1 ISO already installed the Microsoft Hypervisor and a dom0
(root-partition) kernel, so the Linux install acts as the **root partition** of
MSHV, analogous to the Hyper-V parent partition. The hypervisor is chain-loaded
before the Linux root partition; confirm the boot entry launches the hypervisor
loader and then the dom0 kernel. On systemd-boot, inspect the loader entries:

```bash
bootctl status
ls /boot/loader/entries/
cat /boot/loader/entries/*mshv*.conf 2>/dev/null
```

If the MSHV boot entry is not the default, set it so the host always boots the
hypervisor + dom0 kernel. (Only if the ISO did not pre-select it.)

### 3d. Verify MSHV is live and exposes VTL support
After rebooting into the MSHV + dom0 kernel:

```bash
# The MSHV user interface device must be present:
ls -l /dev/mshv && echo "MSHV root partition active"

# Confirm the running kernel is the dom0/mshv variant:
uname -r

# Confirm hypervisor presence and VSM/VTL capability in the logs:
sudo dmesg | grep -iE "microsoft hypervisor|hyperv|mshv|VSM|VTL"
```

You now have: an SEV-SNP host, running MSHV, with Azure Linux as the root
partition exposing `/dev/mshv`. This is the substrate OpenVMM targets.

> **Checkpoint.** Do not proceed until `/dev/mshv` exists **and** `dmesg` confirms
> SEV-SNP is initialized. The vTPM isolation guarantee is void without both.

---

## 4. Stage 3 — Install and configure OpenVMM

OpenVMM is the VMM that builds the VM partition, loads the OpenHCL IGVM into VTL2,
and monitors the guest. On Linux it supports the **MSHV** backend.

### Option A — Download a pre-built OpenVMM binary (fastest)
From the [OpenVMM CI](https://github.com/microsoft/openvmm/actions/workflows/openvmm-ci.yaml),
pick a green run and download the `*-openvmm` artifact for **x86_64 Linux**. Then:

```bash
sudo mkdir -p /opt/openvmm && cd /opt/openvmm
# unzip the downloaded artifact here
chmod +x ./openvmm
./openvmm --version
```

### Option B — Build OpenVMM on the build VM
Run from the `fractal` repository root on the **build VM**:

```bash
./support/developer/scripts/setup-devenv.sh
make build-openvmm OPENVMM_ARGS="--release"
# Binaries:
#   build/stage/openvmm/target/release/openvmm
#   build/stage/openvmm/target/release/ohcldiag-dev
```

Setup restores dependencies on the build VM, including guest UEFI firmware.
Transfer the binaries and firmware to the **test machine** (replace the SSH
destination below):

```bash
# Build VM, from the fractal repository root:
TEST_HOST=user@snp-test-machine
ssh "$TEST_HOST" 'mkdir -p "$HOME/openvmm-deploy"'
scp build/stage/openvmm/target/release/{openvmm,ohcldiag-dev} \
    src/openvmm/.packages/hyperv.uefi.mscoreuefi.x64.RELEASE/MsvmX64/RELEASE_VS2022/FV/MSVM.fd \
    "$TEST_HOST:openvmm-deploy/"
```

On the **test machine**, install the transferred files:

```bash
sudo install -d /opt/openvmm
sudo install -m 0755 "$HOME/openvmm-deploy/openvmm" \
    "$HOME/openvmm-deploy/ohcldiag-dev" /opt/openvmm/
sudo install -m 0644 "$HOME/openvmm-deploy/MSVM.fd" /opt/openvmm/MSVM.fd
ldd /opt/openvmm/openvmm
ldd /opt/openvmm/ohcldiag-dev
/opt/openvmm/openvmm --version
```

Install any runtime libraries reported as `not found` using the test machine's
package manager before continuing. If the loader reports incompatible GLIBC
versions, rebuild on a VM matching the test machine's distribution and release.

### Configure runtime assets (test machine)
For the CI-download option, also obtain the matching guest UEFI firmware and
install it as `/opt/openvmm/MSVM.fd`.
Export it so you don't pass `firmware=` every time (needed when running the
`openvmm` binary directly rather than via `cargo run`):

```bash
export X86_64_OPENVMM_UEFI_FIRMWARE=/opt/openvmm/MSVM.fd
```

Create a working directory for guest images and sockets:
```bash
sudo mkdir -p /var/lib/openvmm/{images,run}
```

> **Quitting OpenVMM:** COM1 is wired to your terminal, so `Ctrl-C` goes to the
> guest. Press **`Ctrl-Q`** to reach the interactive console, then **`q`** to quit.

---

## 5. Stage 4 — Obtain the OpenHCL IGVM (CVM recipe)

OpenHCL is delivered as an **IGVM** file: it tells the VMM how to load the
paravisor into VTL2, at which physical addresses, and carries the measurements
used for attestation. For a confidential (SEV-SNP) guest you need the **CVM**
recipe.

> **Build host note:** Build OpenHCL on the separate Linux build VM. SNP
> hardware is required for confidential guest execution, not for compilation.

### Option A — Download a pre-built IGVM
From [OpenVMM CI](https://github.com/microsoft/openvmm/actions/workflows/openvmm-ci.yaml),
download the appropriate `*-openhcl-igvm` artifact (x64 CVM).

### Option B — Build the CVM IGVM on the build VM
```bash
# Build VM, from the fractal repository root after Stage 3 setup:
make build-openhcl OPENHCL_RECIPE=x64-cvm OPENHCL_ARGS="--release"

# Output:
#   build/stage/openhcl/artifacts/build-igvm/release/x64-cvm/openhcl-x64-cvm.bin
scp build/stage/openhcl/artifacts/build-igvm/release/x64-cvm/openhcl-x64-cvm.bin \
    "$TEST_HOST:openvmm-deploy/"
```

On the **test machine**, install the transferred IGVM (or the CI-downloaded one):

```bash
sudo install -d /var/lib/openvmm
sudo install -m 0644 "$HOME/openvmm-deploy/openhcl-x64-cvm.bin" \
    /var/lib/openvmm/openhcl-x64-cvm.bin
```

**ohcldiag-dev** was built and deployed alongside OpenVMM in Stage 3; it talks
to OpenHCL over a VTL2 vsock.

> **Measurement & attestation note:** The IGVM encodes the launch measurement of
> VTL2. In production you pin/verify this measurement (and, where used, a CoRIM
> endorsement via `igvmfilegen`) as part of guest attestation. Record the digest
> of the exact `openhcl-x64-cvm.bin` you deploy — it is part of your trust base.
> ```bash
> sha256sum /var/lib/openvmm/openhcl-x64-cvm.bin
> ```

---

## 6. Stage 5 — Launch the Windows guest with an OpenHCL-isolated vTPM

### 6a. Prepare the Windows guest disk
Place a UEFI + Secure Boot + TPM-aware Windows image as VHDX:
```bash
# Copy your prepared image in:
cp /path/to/windows.vhdx /var/lib/openvmm/images/windows.vhdx
# Dynamic/differencing VHD1 must be converted to VHDX first:
#   qemu-img convert -f vpc -O vhdx dynamic.vhd windows.vhdx
```

Use `memdiff:` while iterating (writes are discarded each run) and switch to
`file:` for persistent storage.

### 6b. Launch command (Windows in VTL0, OpenHCL + vTPM in VTL2)

The key points of this launch:
- `--hv --vtl2` + `--igvm firmware=openhcl-x64-cvm.bin,personality=openhcl`
  loads OpenHCL into VTL2.
- `--uefi` boots the Windows guest via the `mu_msvm` firmware, with Secure Boot.
- `--tpm` provides the vTPM; because OpenHCL is present and owns VTL2, the vTPM is
  serviced inside VTL2, isolated from VTL0 and the host.
- `--vmbus-redirect` lets OpenHCL act as the VMBus server and relay host devices
  to VTL0 (storage/net translation).
- `--vmbus-vtl2-vsock-path` exposes the diagnostics socket for `ohcldiag-dev`.

```bash
cd /opt/openvmm   # or the repo; adjust the openvmm path accordingly
IGVM=/var/lib/openvmm/openhcl-x64-cvm.bin
DISK=/var/lib/openvmm/images/windows.vhdx
DIAG=/var/lib/openvmm/run/ohcldiag-dev

./openvmm \
  --hv --vtl2 \
  --igvm "firmware=${IGVM},personality=openhcl" \
  --isolation snp \
  --uefi --secure-boot --secure-boot-template windows \
  --tpm \
  --vmbus-scsi id=scsi0,vtl2 \
  --openhcl-controller id=relay0,type=scsi \
  --disk "file:${DISK},on=scsi0,relay=relay0" \
  --vmbus-redirect \
  -m 8GB --processors 4 \
  --gfx \
  --com3 "term,name=VTL2 OpenHCL" \
  --vmbus-vtl2-vsock-path "${DIAG}"
```

Notes and tuning:
- `--isolation snp` requests the SEV-SNP isolated partition. On hardware without
  SNP active this will fail — that failure is the host doing its job. (Exact flag
  spelling can vary by OpenVMM version; run `./openvmm --help | grep -i isol` to
  confirm, and `--help | grep -i tpm` for the vTPM option.)
- `--gfx` enables the graphical console; see OpenVMM's Graphical Console docs for
  connecting a VNC viewer. Drop it for headless/serial-only installs.
- Memory: give the guest enough that VTL2 reservation still leaves your target
  VTL0 size. If VTL2 fails to initialize, raise `-m`.
- Storage/networking are shown using the VTL2-assigned + relay pattern so OpenHCL
  performs the storage translation; adjust `--disk`/`--net` to your environment.

### 6c. What to expect at boot
1. OpenVMM builds the SNP-isolated partition and loads OpenHCL into VTL2.
2. OpenHCL (VTL2) initializes, brings up the vTPM worker and Secure Boot policy,
   then starts VTL0.
3. The `mu_msvm` UEFI firmware runs in VTL0, measures boot into the vTPM, and
   boots Windows.
4. Inside Windows, the TPM appears as a standard TPM 2.0 device — but its state
   lives in encrypted VTL2 memory, unreadable by VTL0, the host, or MSHV.

---

## 7. Stage 6 — Verify the vTPM is present and isolated

### 7a. Confirm OpenHCL is running in VTL2 (from the host root partition)
```bash
# Kernel log from VTL2/OpenHCL:
./ohcldiag-dev /var/lib/openvmm/run/ohcldiag-dev kmsg

# Inspect running OpenHCL processes (the vTPM should run in its own worker):
./ohcldiag-dev /var/lib/openvmm/run/ohcldiag-dev inspect
```
Look for the TPM worker/device and a healthy VTL2 boot with no attestation errors.

### 7b. Confirm the vTPM inside Windows (VTL0)
In the Windows guest:
```powershell
Get-Tpm
Get-PnpDevice -Class SecurityDevices
# TPM 2.0 should be Present, Ready, Owned; Secure Boot should be On:
Confirm-SecureBootUEFI
```

### 7c. Confirm the host/hypervisor cannot read guest memory (isolation holds)
On the host, verify the partition is SNP-isolated and that guest RAM is encrypted
(host tooling cannot meaningfully dump it):
```bash
sudo dmesg | grep -iE "SNP|SEV|RMP"      # SNP active
./ohcldiag-dev /var/lib/openvmm/run/ohcldiag-dev inspect | grep -i isolation
```
The negative test is structural: with `--isolation snp`, host-side memory of the
CVM is encrypted/integrity-protected by hardware and the vTPM state is in VTL2 —
there is no host API that returns plaintext vTPM secrets.

### 7d. Attest the platform + paravisor (the real proof)
The authoritative verification is a **remote attestation** of the SEV-SNP report,
which includes the launch measurement covering the OpenHCL IGVM you pinned in §5:
- Retrieve the SNP attestation report from the guest (via the guest's attestation
  agent / Microsoft Azure Attestation flow, or your own verifier).
- Check the report's measurement against the **known-good digest** of
  `openhcl-x64-cvm.bin` and your expected VTL0 firmware/config.
- Only release vTPM-dependent secrets (e.g. disk encryption keys) after the
  measurement matches.

Record the expected values in your deployment config:
```bash
sha256sum /var/lib/openvmm/openhcl-x64-cvm.bin   # pin this
```

---

## 8. Monitoring & day-2 operations

- **Live diagnostics:** `ohcldiag-dev <socket> kmsg` (stream VTL2 log),
  `inspect` (component/device tree), and the other subcommands (`./ohcldiag-dev --help`).
- **Serial consoles:** `--com3 "term,name=VTL2 OpenHCL"` gives VTL2 kernel output;
  wire VTL0 serial via `--vmbus-com1-serial` if you need guest serial.
- **Lifecycle:** manage each VM as an OpenVMM process; for fleets, script launches
  and supervise with systemd units (one unit per CVM) so MSHV/OpenVMM restarts are
  controlled.

---

## 9. Troubleshooting

| Symptom | Likely cause | Action |
| --- | --- | --- |
| `/dev/mshv` missing | Not booted into MSHV/dom0 kernel | Fix boot entry so the hypervisor loader runs before the dom0 kernel; `bootctl status`, `uname -r`. |
| `--isolation snp` fails to start | SNP not enabled in firmware/kernel | Re-check BIOS SEV-SNP/SMEE/IOMMU; `dmesg | grep -i snp`; confirm `/dev/sev`. |
| VTL2 won't initialize / OOM | Not enough memory for VTL2 reservation | Increase `-m`; verify you built the **x64-cvm** recipe, not plain `x64`. |
| `must provide uefi firmware` | Running `openvmm` binary without env var | Set `X86_64_OPENVMM_UEFI_FIRMWARE` or pass `--uefi firmware=/path/MSVM.fd`. |
| vTPM absent in Windows | vTPM flag/personality mismatch | Confirm `--tpm` and `personality=openhcl`; check `ohcldiag-dev inspect` for the TPM worker. |
| Can't type / stuck console | COM1 is wired to the guest | `Ctrl-Q` then `q` to reach OpenVMM's console / quit. |
| Build failed on missing dep | First IGVM build needs toolchains | Re-run with `cargo xflowey build-igvm x64-cvm --install-missing-deps`. |

OpenVMM/OpenHCL troubleshooting references:
[OpenVMM](https://openvmm.dev/guide/user_guide/openvmm/troubleshooting.html) ·
[OpenHCL](https://openvmm.dev/guide/user_guide/openhcl/troubleshooting.html).

> **Maturity caveat (verify against your versions).** OpenVMM's fully-isolated
> SEV-SNP path on MSHV is evolving; exact flag names (`--isolation`, `--tpm`,
> `--secure-boot`) and device wiring can change between releases. Always confirm
> with `./openvmm --help` and the CI artifact's docs for the build you deploy.
> The production reference for this exact scenario (Windows CVM + OpenHCL vTPM) is
> Azure/Hyper-V; this guide reproduces that architecture on native Azure Linux +
> MSHV + OpenVMM.

---

## 10. References

- OpenHCL Architecture — https://openvmm.dev/guide/reference/architecture/openhcl.html
- Virtual Trust Levels (VSM) — https://learn.microsoft.com/en-us/virtualization/hyper-v-on-windows/tlfs/vsm
- OpenHCL (user guide) — https://openvmm.dev/guide/user_guide/openhcl.html
- Running OpenHCL — https://openvmm.dev/guide/user_guide/openhcl/run.html
- Building OpenHCL — https://openvmm.dev/guide/dev_guide/getting_started/build_openhcl.html
- IGVM image — https://openvmm.dev/guide/reference/architecture/openhcl/igvm.html
- Running OpenVMM — https://openvmm.dev/guide/user_guide/openvmm/run.html
- OpenVMM (supported hosts incl. MSHV) — https://openvmm.dev/guide/user_guide/openvmm.html
- AMD SEV-SNP white paper — https://www.amd.com/content/dam/amd/en/documents/epyc-business-docs/white-papers/SEV-SNP-strengthening-vm-isolation-with-integrity-protection-and-more.pdf
- Azure Linux — https://github.com/microsoft/azurelinux
- IGVM specification — https://github.com/microsoft/igvm
