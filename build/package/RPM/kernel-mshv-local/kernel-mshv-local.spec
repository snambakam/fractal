%global debug_package %{nil}
%global __os_install_post %{nil}

Name:           kernel-mshv-local
Version:        %(echo '%{kernel_release}' | tr '-' '_')
Release:        %{package_release}%{?dist}
Summary:        Locally built MSHV host kernel
License:        GPL-2.0-only
ExclusiveArch:  x86_64
Requires:       kmod

%description
A locally built MSHV host kernel and its modules. This package does not provide
the generic kernel capability, replace distribution headers, or select a boot
default. Keep the distribution kernel installed as a fallback. Boot entries
and an initramfs must be prepared separately before booting this kernel.

%prep
test -s "%{kernel_stage}/arch/x86/boot/bzImage"
test -s "%{kernel_stage}/System.map"
test -s "%{kernel_stage}/.config"
test "$(cat '%{kernel_stage}/include/config/kernel.release')" = '%{kernel_release}'

%build

%install
make -C "%{kernel_stage}" INSTALL_MOD_PATH="%{buildroot}" DEPMOD=true modules_install
rm -f "%{buildroot}/lib/modules/%{kernel_release}/build" "%{buildroot}/lib/modules/%{kernel_release}/source"
install -D -m 0644 "%{kernel_stage}/arch/x86/boot/bzImage" "%{buildroot}/boot/vmlinuz-%{kernel_release}"
install -D -m 0644 "%{kernel_stage}/System.map" "%{buildroot}/boot/System.map-%{kernel_release}"
install -D -m 0644 "%{kernel_stage}/.config" "%{buildroot}/boot/config-%{kernel_release}"

%post
depmod '%{kernel_release}'

%files
/boot/vmlinuz-%{kernel_release}
/boot/System.map-%{kernel_release}
/boot/config-%{kernel_release}
/lib/modules/%{kernel_release}