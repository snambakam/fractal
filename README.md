# fractal
Confidential Computing Framework

## Building

Set up development packages and restore OpenVMM dependencies through
[support/developer/scripts/setup-devenv.sh](support/developer/scripts/setup-devenv.sh)
first. The setup script supports Fedora; OpenHCL requires Linux or WSL2.
Run the following from the repository root:

```bash
./support/developer/scripts/setup-devenv.sh
make build-openvmm
make build-openhcl
```

Build targets do not install development-environment packages. `build-openhcl` uses the
upstream build pipeline to build an IGVM firmware image, defaulting to the `x64` recipe.
The Makefile uses the system `protoc` from Fedora's `protobuf-compiler` package,
installed by the setup script. Override it with `make PROTOC=/path/to/protoc`.
Top-level Cargo outputs and Flowey working files and published artifacts
are written directly under `build/stage/openvmm/` and `build/stage/openhcl/`, without a
post-build copy. Development setup outputs and the shared dependency cache live
under `build/stage/devenv/`, which neither component's clean target removes.
Nested OpenHCL builds still use upstream target-directory
overrides under `src/openvmm/target/`.
The default executable is `build/stage/openvmm/target/debug/openvmm`;
the default firmware is
`build/stage/openhcl/artifacts/build-igvm/debug/x64/openhcl-x64.bin`.
Upstream package restoration still creates dependency files and links under
`src/openvmm/.packages/`.
Override the recipe or pass additional build arguments as needed:

```bash
make build-openvmm OPENVMM_ARGS="--release"
make build-openhcl OPENHCL_RECIPE=x64-cvm OPENHCL_ARGS="--release"
```

### MSHV Kernel

The kernel targets use the `src/linux` LSG-linux-rolling submodule by default,
with its `Microsoft/configs/x86/mshv_defconfig` configuration. Initialize it
before building (access to the Azure DevOps repository is required):

```bash
git submodule update --init src/linux
```

The submodule tracks `user/snambakam/mshv-enable-vsm` for remote updates; normal
submodule initialization uses the commit pinned by this repository.

Build and package the kernel with:

```bash
make -j"$(nproc)" build-kernel-mshv
make -j"$(nproc)" package-kernel-mshv
```

This is an out-of-tree build: configuration, compiled artifacts, and RPM working
files stay under `build/stage/kernel-mshv/`. The `kernel-mshv-local` RPM is
generated under `build/stage/kernel-mshv/rpmbuild/RPMS/`. It contains the boot
image, config, System.map, and modules, without providing the generic `kernel`
capability that conflicts with Azure Linux's installed `kernel-mshv`. It does
not build or replace userspace headers, development packages, or host tools.
An existing kernel with the same kernel release cannot coexist because its
files would overlap; use a distinct `LOCALVERSION` when necessary.

Copy only the `kernel-mshv-local` RPM to dom0, test the transaction with
`sudo rpm -ivh --test ./kernel-mshv-local-*.rpm`, then install with
`sudo rpm -ivh ./kernel-mshv-local-*.rpm`. Do not use `--nodeps` or uninstall
the working distribution kernel. The package script runs depmod but does not
create an initramfs or select a boot default. Distribution RPM triggers may
regenerate GRUB during installation; verify the boot configuration afterward.

For Azure Linux hosts with `05_mariner_mshv_menuentry`, use
[deployment/dom-0/switch-kernel.sh](deployment/dom-0/switch-kernel.sh) to prepare
an installed kernel and retarget the `linux-dom0-with-hyper-v` default without
grubby. It pins the exact kernel and matching initramfs in the existing generator,
preserving the HvLoader.efi launch before Linux and literal `$kernelopts`.
First run its read-only checks, then explicitly apply:

```bash
sudo bash deployment/dom-0/switch-kernel.sh --kernel-release '6.18.34.mshv1+'
sudo bash deployment/dom-0/switch-kernel.sh --kernel-release '6.18.34.mshv1+' \
	--apply --acknowledge-boot-risk
```

If an earlier plain-Linux switch changed the defaults, pass
`--boot-backup /var/lib/fractal/kernel-switch.DIRECTORY` to both commands, using
the known-good backup containing the original `grub.defaults` and `grub.cfg`.
The helper uses those defaults, not the running command line. It rejects copied
`hyperv_resvd` reservations: replaying them does not launch the hypervisor.
Repairing the boot flow is supported even if the requested kernel already runs.

The helper generates the target initramfs and backs up GRUB configuration,
defaults, and the Hyper-V menu generator. It retains the previous Hyper-V entry
as `fractal-dom0-fallback`, and validates loader ordering, exact image paths,
loader options, `$kernelopts`, and the selected default before activation.
An unrecognized generator or missing previous kernel/initramfs fails closed.
Preparation failures restore all three configuration files; success prints
manual restore commands. It requires Secure Boot to be disabled. It does not
reboot, automatically fall back after a failed boot, or prove that the kernel
will start Hyper-V. Without console or remote power access, a failed boot can
leave the host unreachable; arrange recovery before rebooting.

Override `KERNEL_MSHV_SRC` to select another source checkout,
`KERNEL_MSHV_CONFIG` to select another configuration, or `KERNEL_MSHV_ARGS`
to pass kernel make variables such as `LLVM=1`. The selected configuration seeds
the staged `.config`; subsequent builds preserve it unless the input configuration
is newer. Run `make clean-kernel-mshv` before switching configurations or source
checkouts. The clean target removes the entire kernel staging directory,
including its RPMs, without modifying the source checkout.

The development setup script installs kernel build and RPM prerequisites,
including bison, flex, ELF development libraries, GCC plugin headers, and
`dwarves` for BTF, plus ncurses headers for interactive configuration. Run
`./support/developer/scripts/setup-devenv.sh` before building. The make targets
do not install dependencies or install the kernel on the host.

## Native VSM Bring-up

The kernel branch exposes partition-scoped `HvCallEnablePartitionVtl` and
`HvCallEnableVpVtl` through `MSHV_ROOT_HVCALL`. Enablement requires a locked
child-partition FD, exact input sizes, valid VTLs, and zero reserved fields.
VP enablement requires an existing, stopped VP. Host-partition VTL enablement
is not exposed.

OpenVMM's `virt_mshv` crate contains a disposable-partition VTL2 probe and
explicit-VTL register reads. Run the focused unit tests from `src/openvmm`:

```bash
CARGO_TARGET_DIR=../../build/stage/openvmm/target \
	cargo test -p virt_mshv --lib vsm
```

After building, installing, and booting the patched MSHV kernel on a development
host, run the hardware tests from an account with access to `/dev/mshv`:

```bash
CARGO_TARGET_DIR=../../build/stage/openvmm/target \
	cargo test -p virt_mshv --lib vsm -- --ignored --nocapture
```

These tests create disposable, non-SNP child partitions. The positive probe
enables VTL2 at partition and BSP scope and verifies the reported VSM status;
it does not run guest code or prove memory protection. The negative test checks
that malformed enablement requests are rejected by the driver. A failure must
be diagnosed using the reported operation and hypervisor status, not worked
around by removing VTL validation.

This is bring-up infrastructure, not complete VSM support. The MSHV backend
still rejects OpenHCL VTL2 boots. Per-VTL state, memory protection and fault
handling, interrupt routing, guest execution, and lifecycle integration remain
to be implemented and validated before booting Windows through OpenHCL.
SNP confidentiality is a separate, later milestone.

## RPM Packaging

The setup script installs `rpm-build`. Each packaging target first builds its
component, then packages the resulting artifact:

```bash
make package-openvmm
make package-openhcl
```

RPMs are published under `build/out/x86_64/`. Specs are maintained under
[build/package/RPM/openvmm](build/package/RPM/openvmm/openvmm.spec) and
[build/package/RPM/openhcl](build/package/RPM/openhcl/openhcl.spec).
OpenVMM installs to `/usr/bin/openvmm`; OpenHCL installs its IGVM image to
`/usr/share/openhcl/`. OpenVMM's shared-library requirements are detected by RPM;
the package does not bundle those system libraries. Debug symbols are not
packaged separately.

`make package-openvmm` produces both the `openvmm` and `openvmm-diag` RPMs from
the same spec. The separately installable `openvmm-diag` RPM contains
`/usr/bin/ohcldiag-dev` and does not require the `openvmm` RPM. Both executables
are built by `make build-openvmm` using the same profile and staging directory.
The diagnostic CLI is an interactive
development tool with unstable command syntax, not a production automation API.
It requires a running OpenHCL diagnostic server and an exposed transport;
installing it does not enable restricted diagnostics in production confidential VMs.

The default package version comes from OpenVMM's Cargo metadata. Override
`RPM_VERSION` or `RPM_RELEASE` for local package revisions. For release artifacts:

```bash
make package-openvmm OPENVMM_ARGS="--release"
make package-openhcl OPENHCL_RECIPE=x64-cvm OPENHCL_ARGS="--release"
```

Packaging selects the `debug` or `release` artifact directory based on
`--release`. For custom profiles or output layouts, set `OPENVMM_PROFILE` or
`OPENHCL_PROFILE` to the artifact directory name. OpenHCL RPMs require an `x64`
recipe. All three packages contain the upstream OpenVMM license; redistribution of
bundled firmware components may require additional license compliance.

`make clean-openvmm` and `make clean-openhcl` remove the corresponding staging
directory, including RPM working files. They preserve the shared dependency cache
and published RPMs.
