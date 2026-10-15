# MSHV: Azure Linux as the Root Partition of the Microsoft Hypervisor

Azure Linux can serve as the **root partition of the Microsoft Hypervisor on bare metal**.

> **The Microsoft Hypervisor runs underneath Azure Linux, not inside it. Azure Linux provides the host operating system and management stack above the hypervisor.**

This separates two things often collectively called "the host": the hypervisor that enforces isolation, and the operating system that manages the machine and its VMs.

## 1. Stack overview

```text
           Root partition                   Child partition
+----------------------------------+    +------------------------+
| Azure Linux userspace            |    | Guest applications     |
|                                  |    |                        |
| VMM, such as Cloud Hypervisor    |    | Guest operating system |
|          |                       |    |                        |
|          | ioctl(/dev/mshv)      |    |                        |
|          v                       |    |                        |
| Azure Linux kernel               |    |                        |
| - mshv driver                    |    |                        |
| - Physical device drivers        |    |                        |
+---------------|------------------+    +------------------------+
                | Hypercalls
+---------------v------------------------------------------------+
| Microsoft Hypervisor — L0                                      |
| Partition isolation, virtual processors, memory virtualization |
+----------------------------------------------------------------+
| Physical hardware: AMD CPUs, RAM, interrupt controllers, devices|
+----------------------------------------------------------------+
```

The root and child partitions are **both above the same hypervisor**. The root partition has additional privileges and management responsibilities; it is not another hypervisor layer.

## 2. What "root partition" means

A Hyper-V **partition** is an execution environment with its own processors, memory mappings, and operating system.

The **root partition** is the privileged management partition. In this configuration, Azure Linux occupies that role.

It typically:

- Runs the management services and userspace virtual machine monitor (**VMM**).
- Uses physical-device drivers to manage storage, networking, and other assigned hardware.
- Allocates resources and requests creation of child partitions.
- Provides virtual-device backends and I/O services for guests, depending on the VMM and device configuration.

The Microsoft Hypervisor underneath it enforces partition boundaries and controls the hardware virtualization mechanisms.

**"Root partition" here has nothing to do with Linux's `/` filesystem or a disk's root partition.**

## 3. What `mshv` refers to

| Component | What it is |
|---|---|
| **Microsoft Hypervisor**, sometimes called MSHV | The actual L0, type-1 hypervisor running on the hardware. |
| **Linux `mshv` driver and `/dev/mshv`** | The kernel interface through which Linux userspace manages VMs on that hypervisor. |
| **Cloud Hypervisor or another compatible VMM** | A userspace program that configures guest memory, virtual CPUs, devices, and VM lifecycle. |

The `mshv` Linux driver is **not** itself the L0 hypervisor. It is a bridge to the hypervisor.

Creating a guest conceptually follows this path:

```text
VMM in Azure Linux
    -> ioctl on /dev/mshv
        -> Linux mshv driver
            -> Hyper-V hypercalls
                -> Microsoft Hypervisor creates/configures a child partition
```

Guest instructions normally execute directly on the CPU using hardware virtualization, not through a userspace instruction interpreter.

## 4. Bare-metal installation and boot flow

"Installed on bare metal" describes how the physical machine was provisioned. It does not require the Linux kernel to remain the lowest software layer at runtime.

Conceptually, the boot flow establishes:

```text
Firmware / boot environment
    -> Microsoft Hypervisor initialized
        -> Azure Linux executes as the root partition
            -> Linux management stack starts child VMs
```

The exact loader sequence depends on the image. A specialized boot path loads and initializes the hypervisor and arranges for Linux to execute as its root partition. **Installing or loading the `mshv` driver alone does not establish this stack.**

This resembles the architectural split in Xen (hypervisor underneath a privileged management domain), although Hyper-V's interfaces and implementation are different.

## 5. Why this is L0, not nested virtualization

```text
L0: Microsoft Hypervisor
    ├── Azure Linux root partition
    └── Guest child partitions
```

Azure Linux being an operating system above L0 **does not make it an L1 hypervisor**.

Nested virtualization would occur if, for example, a child partition itself ran KVM or another hypervisor and used it to host additional guests. Running a userspace VMM in the root partition does not introduce nesting: that VMM asks the existing L0 hypervisor to execute the guest.

## 6. Comparison with KVM

```text
KVM:   Userspace VMM -> /dev/kvm  -> Linux/KVM    -> hardware
MSHV:  Userspace VMM -> /dev/mshv -> Linux driver -> Microsoft Hypervisor -> hardware
```

In both cases Linux provides a familiar host-management environment. The important difference is **where the core hypervisor resides**.

## 7. Observations from this host

The [journal](./journal.md) records a kernel named:

```text
vmlinuz-6.18.34.mshv3-1000.g59706f1e.lv3
```

and boot arguments including `hyperv_resvd_new=...`.

These are consistent with a specialized MSHV-enabled image and boot-time memory reservations. They do **not**, on their own, establish the precise loader sequence or prove the active partition role.

## Summary

The physical server runs the Microsoft Hypervisor as L0. Azure Linux runs as its privileged root partition and supplies the drivers, services, and VMM used to operate the server and create guest partitions. No Windows root partition is required.

## References

- [Cloud Hypervisor MSHV documentation](https://github.com/cloud-hypervisor/cloud-hypervisor/blob/main/docs/mshv.md)
- [Hyper-V architecture (Microsoft Learn)](https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/architecture)
- [Introduce /dev/mshv root partition driver (LWN)](https://lwn.net/Articles/1012202/)
