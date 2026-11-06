%global debug_package %{nil}
%global __strip /bin/true
%{!?uefi_firmware:%global uefi_firmware %{repo_root}/build/stage/devenv/persist/flowey_lib_hvlite__download_uefi_mu_msvm/extracted/firmware-RELEASE-X64-CLANGPDB.tar.gz/FV/MSVM.fd}

Name:           openvmm
Version:        %{package_version}
Release:        %{package_release}%{?dist}
Summary:        OpenVMM virtual machine monitor
License:        MIT AND BSD-2-Clause-Patent
URL:            https://github.com/microsoft/openvmm
Source0:        openvmm
Source1:        ohcldiag-dev
ExclusiveArch:  x86_64

%description
OpenVMM is a modular virtual machine monitor.
This package contains the executable built by the fractal build targets and
the restored x64 mu_msvm UEFI firmware for booting guest operating systems.

%package diag
Summary:        OpenHCL diagnostic tools
License:        MIT

%description diag
Host-side diagnostic tools for inspecting and troubleshooting OpenHCL.
Contains ohcldiag-dev, an interactive development tool with no CLI stability
guarantees. Available operations depend on the OpenHCL image's diagnostic policy;
production confidential VMs restrict access to sensitive operations.

%prep
test -s "%{uefi_firmware}" || {
	echo "Missing x64 UEFI firmware: %{uefi_firmware}. Run setup-devenv.sh to restore dependencies or define uefi_firmware." >&2
	exit 1
}

%build

%install
install -D -m 0755 %{SOURCE0} %{buildroot}%{_bindir}/openvmm
install -D -m 0755 %{SOURCE1} %{buildroot}%{_bindir}/ohcldiag-dev
install -D -m 0644 %{repo_root}/src/openvmm/LICENSE %{buildroot}%{_licensedir}/%{name}/LICENSE
install -D -m 0644 %{repo_root}/src/openvmm/LICENSE %{buildroot}%{_licensedir}/%{name}-diag/LICENSE
install -D -m 0644 "%{uefi_firmware}" %{buildroot}%{_datadir}/%{name}/MSVM.fd
install -D -m 0644 %{repo_root}/build/package/RPM/openvmm/mu_msvm.LICENSE %{buildroot}%{_licensedir}/%{name}/mu_msvm.LICENSE

%files
%{_bindir}/openvmm
%dir %{_datadir}/%{name}
%{_datadir}/%{name}/MSVM.fd
%license %{_licensedir}/%{name}/LICENSE
%license %{_licensedir}/%{name}/mu_msvm.LICENSE

%files diag
%{_bindir}/ohcldiag-dev
%license %{_licensedir}/%{name}-diag/LICENSE