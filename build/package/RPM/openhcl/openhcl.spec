%global debug_package %{nil}
%global __strip /bin/true

Name:           openhcl
Version:        %{package_version}
Release:        %{package_release}%{?dist}
Summary:        OpenHCL IGVM firmware
License:        MIT
URL:            https://github.com/microsoft/openvmm
Source0:        openhcl-%{recipe}.bin
ExclusiveArch:  x86_64

%description
OpenHCL firmware for the %{recipe} recipe, packaged as an IGVM image.

%prep

%build

%install
install -D -m 0644 %{SOURCE0} %{buildroot}%{_datadir}/%{name}/openhcl-%{recipe}.bin
install -D -m 0644 %{repo_root}/src/openvmm/LICENSE %{buildroot}%{_licensedir}/%{name}/LICENSE

%files
%dir %{_datadir}/%{name}
%{_datadir}/%{name}/openhcl-%{recipe}.bin
%license %{_licensedir}/%{name}/LICENSE