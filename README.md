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

The kernel targets use a sibling `../LSG-linux-rolling` checkout by default,
with its `Microsoft/configs/x86/mshv_defconfig` configuration:

```bash
make -j"$(nproc)" build-kernel-mshv
make -j"$(nproc)" package-kernel-mshv
```

This is an out-of-tree build: configuration, compiled artifacts, and RPM working
files stay under `build/stage/kernel-mshv/`. Binary RPMs are generated under
`build/stage/kernel-mshv/rpmbuild/RPMS/` by the kernel's native `binrpm-pkg`
target. These upstream packages are named `kernel`, `kernel-headers`, and
`kernel-devel`, not the Azure Linux distribution's `kernel-mshv` package.

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

The default package version comes from OpenVMM's Cargo metadata. Override
`RPM_VERSION` or `RPM_RELEASE` for local package revisions. For release artifacts:

```bash
make package-openvmm OPENVMM_ARGS="--release"
make package-openhcl OPENHCL_RECIPE=x64-cvm OPENHCL_ARGS="--release"
```

Packaging selects the `debug` or `release` artifact directory based on
`--release`. For custom profiles or output layouts, set `OPENVMM_PROFILE` or
`OPENHCL_PROFILE` to the artifact directory name. OpenHCL RPMs require an `x64`
recipe. Both packages contain the upstream OpenVMM license; redistribution of
bundled firmware components may require additional license compliance.

`make clean-openvmm` and `make clean-openhcl` remove the corresponding staging
directory, including RPM working files. They preserve the shared dependency cache
and published RPMs.
