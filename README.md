# fractal
Confidential Computing Framework

## Building

Set up development packages and restore OpenVMM dependencies through
[support/developer/scripts/setup-devenv.sh](support/developer/scripts/setup-devenv.sh)
first. The setup script supports Fedora; OpenHCL requires Linux or WSL2.
Run the following from the repository root:

```bash
./support/developer/scripts/setup-devenv.sh
make openvmm
make openhcl
```

Build targets do not install development-environment packages. `openhcl` uses the
upstream build pipeline to build an IGVM firmware image, defaulting to the `x64` recipe.
Top-level Cargo outputs and Flowey working files, caches, and published artifacts
are written directly under `stage/openvmm/` and `stage/openhcl/`, without a
post-build copy. Nested OpenHCL builds still use upstream target-directory
overrides under `src/openvmm/target/`.
The default executable is `stage/openvmm/target/debug/openvmm`;
the default firmware is
`stage/openhcl/artifacts/build-igvm/debug/x64/openhcl-x64.bin`.
Upstream package restoration still creates dependency files and links under
`src/openvmm/.packages/`.
Override the recipe or pass additional build arguments as needed:

```bash
make openvmm OPENVMM_ARGS="--release"
make openhcl OPENHCL_RECIPE=x64-cvm OPENHCL_ARGS="--release"
```
