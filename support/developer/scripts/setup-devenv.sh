#!/bin/bash

set -e

#
# Install the packages needed to build and develop the components in this
# repository (openvmm, keylime, rust-keylime) on a Fedora-based environment.
#
# Usage: setup-devenv.sh [--skip-rust]
#
#   --skip-rust   Do not install the Rust toolchain via rustup.
#
# Safe to re-run: packages that are already installed are skipped.
#

#
# Package lists
#

# Common build tooling.
BASE_PKGS=(
    binutils
    clang
    cmake
    curl
    gcc
    gcc-c++
    git
    jq
    make
    openssl-devel
    pciutils
    pkgconf-pkg-config
    procps-ng
    tar
    util-linux
)

# OpenVMM and OpenHCL: architecture-specific build tools.
OPENVMM_PKGS=(
    binutils-aarch64-linux-gnu
    binutils-x86_64-linux-gnu
    gcc-aarch64-linux-gnu
)

# rust-keylime: build dependencies.
RUST_KEYLIME_PKGS=(
    tpm2-tss-devel
    zeromq-devel
)

# keylime: runtime and build dependencies (mirrors keylime's installer.sh for Fedora).
KEYLIME_PKGS=(
    autoconf
    autoconf-archive
    automake
    dbus-devel
    json-c-devel
    libcurl-devel
    libgcrypt-devel
    libtool
    libuuid-devel
    m4
    python3
    python3-alembic
    python3-cryptography
    python3-devel
    python3-gpg
    python3-lark
    python3-pip
    python3-psutil
    python3-pyyaml
    python3-pyzmq
    python3-requests
    python3-setuptools
    python3-tornado
    swig
    tpm2-tools
    yaml-cpp-devel
)

#
# Helpers
#

install_pkgs() {
    local wanted=("$@")
    local missing=()
    local pkg

    for pkg in "${wanted[@]}"; do
        rpm -q --quiet "$pkg" || missing+=("$pkg")
    done

    if [ ${#missing[@]} -eq 0 ]; then
        return 0
    fi

    # Package names vary between Fedora releases; skip any that are unavailable.
    local available
    available="$(dnf repoquery --quiet --available --qf '%{name}\n' "${missing[@]}" | sort -u)"

    local to_install=()
    for pkg in "${missing[@]}"; do
        if grep -qx -- "$pkg" <<<"$available"; then
            to_install+=("$pkg")
        else
            echo "Warning: package not available on this system, skipping: $pkg" >&2
        fi
    done

    if [ ${#to_install[@]} -gt 0 ]; then
        echo "Installing: ${to_install[*]}"
        sudo dnf -y install "${to_install[@]}"
    fi
}

install_rust() {
    if command -v rustc >/dev/null 2>&1 && command -v cargo >/dev/null 2>&1; then
        echo "Rust already installed: $(rustc --version)"
    else
        echo "Installing the Rust toolchain via rustup"
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal
        export PATH="$HOME/.cargo/bin:$PATH"
        echo "Rust installed. Run 'source \"\$HOME/.cargo/env\"' or open a new shell to use it."
    fi

    if ! command -v rustup >/dev/null 2>&1; then
        echo "Error: rustup is required to install the OpenHCL Rust targets." >&2
        return 1
    fi

    rustup component add \
        clippy \
        rustfmt

    rustup target add \
        x86_64-unknown-linux-musl \
        x86_64-unknown-none
}

restore_openvmm_packages() {
    local repo_root stage_dir
    repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
    stage_dir="$repo_root/stage/openvmm"

    if ! command -v cargo >/dev/null 2>&1; then
        echo "Error: cargo is required to restore OpenVMM dependencies. Install Rust or omit --skip-rust." >&2
        exit 1
    fi

    echo "Restoring OpenVMM development dependencies"
    pushd "$repo_root/src/openvmm" >/dev/null
    CARGO_TARGET_DIR="$stage_dir/target" cargo xflowey \
        --out-dir "$stage_dir" \
        --persist-dir "$stage_dir/persist" \
        restore-packages
    popd >/dev/null
}

# Fedora ships kubectl in versioned packages (e.g. kubernetes1.34-client), so
# "kubectl" resolves to the newest. Set KUBECTL_PKG to pick a version that is
# within one minor release of your cluster.
install_kubectl() {
    if command -v kubectl >/dev/null 2>&1; then
        echo "kubectl already installed: $(command -v kubectl)"
        return 0
    fi

    echo "Installing ${KUBECTL_PKG:-kubectl}"
    sudo dnf -y install "${KUBECTL_PKG:-kubectl}"
}

#
# Main
#

skip_rust=false
for arg in "$@"; do
    case "$arg" in
        --skip-rust) skip_rust=true ;;
        *)
            echo "Usage: $0 [--skip-rust]" >&2
            exit 1
            ;;
    esac
done

if [ ! -f /etc/os-release ] || ! grep -qiE '^(ID|ID_LIKE)=.*fedora' /etc/os-release; then
    echo "Error: this script supports Fedora-based distributions only." >&2
    exit 1
fi

if ! command -v dnf >/dev/null 2>&1; then
    echo "Error: dnf not found." >&2
    exit 1
fi

install_pkgs "${BASE_PKGS[@]}" "${OPENVMM_PKGS[@]}" "${RUST_KEYLIME_PKGS[@]}" "${KEYLIME_PKGS[@]}"

install_kubectl

if ! $skip_rust; then
    install_rust
fi

restore_openvmm_packages

echo "Done. The development environment is ready."
