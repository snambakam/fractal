%global debug_package %{nil}
%global __strip /bin/true

Name:           openvmm
Version:        %{package_version}
Release:        %{package_release}%{?dist}
Summary:        OpenVMM virtual machine monitor
License:        MIT
URL:            https://github.com/microsoft/openvmm
Source0:        openvmm
ExclusiveArch:  x86_64

%description
OpenVMM is a modular virtual machine monitor.
This package contains the executable built by the fractal build targets.

%prep

%build

%install
install -D -m 0755 %{SOURCE0} %{buildroot}%{_bindir}/openvmm
install -D -m 0644 %{repo_root}/src/openvmm/LICENSE %{buildroot}%{_licensedir}/%{name}/LICENSE

%files
%{_bindir}/openvmm
%license %{_licensedir}/%{name}/LICENSE