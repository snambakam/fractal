# Windows CVM with an OpenHCL-Isolated vTPM and MAA

**Objective:** Run a Windows confidential VM (CVM) on native Azure Linux with
MSHV, protecting its virtual TPM from the host and hypervisor through AMD
SEV-SNP and OpenHCL. Use **MAA (Microsoft Azure Attestation)** for remote
attestation before releasing workload secrets.

## Architecture and Trust Boundary

| Layer | Responsibility |
| --- | --- |
| AMD SEV-SNP hardware | Protects private guest memory with encryption and integrity checks. |
| Azure Linux + MSHV | Root partition and hypervisor; provide `/dev/mshv` and the required virtual trust levels. |
| OpenVMM | Creates and monitors the confidential partition; loads the OpenHCL IGVM image. |
| OpenHCL in VTL2 | Hosts the vTPM and guest firmware services, isolated from Windows in VTL0. |
| Windows in VTL0 | Uses a standard TPM 2.0 interface for measured boot and TPM-backed operations. |
| MAA + relying party | Verify attestation evidence and enforce policy before authorizing secret release. |

The host and hypervisor remain outside the CVM's confidentiality trust boundary.
Windows can use the vTPM but cannot directly read its private VTL2 state. This
design requires MSHV's VTL support; KVM is not the backend for this deployment.

## Deployment Sequence

1. **Prepare the host.** Use an SNP-capable AMD EPYC platform with SEV-SNP and
   IOMMU enabled. Install the Azure Linux ISO containing MSHV and the dom0 kernel.
   Confirm the hypervisor boot path, `/dev/mshv`, and active SNP support.
2. **Stage matched artifacts.** Obtain OpenVMM, the `x64-cvm` OpenHCL IGVM,
   guest UEFI firmware, `ohcldiag-dev`, and a UEFI-capable Windows VHDX. Record
   artifact versions and hashes for reproducibility.
3. **Launch the CVM.** Configure the MSHV backend, SNP isolation, VTL2/OpenHCL,
   the vTPM, guest Secure Boot, and VTL2 device relay. Use the detailed guide's
   launch example, checking flags against the selected OpenVMM build.
4. **Validate locally.** Inspect OpenHCL logs and the TPM device with
   `ohcldiag-dev`. In Windows, run `Get-Tpm` and `Confirm-SecureBootUEFI`.
   Device presence and logs are readiness checks, not remote proof of isolation.
5. **Attest and authorize.** Complete the MAA flow below before provisioning
   disk-encryption keys, credentials, or other protected workload secrets.

## MAA Attestation and Secret Release

**Flow:** Guest evidence collector -> MAA -> signed attestation token -> relying
party / key-release service -> authorized CVM.

- Collect SNP evidence and the supporting data required by the chosen MAA
  attestation flow. Bind the evidence to a fresh challenge and a guest-held key
  or secure session to prevent replay and misdelivery of secrets.
- Configure MAA policy and relying-party checks for approved launch measurements,
  platform security version, debug restrictions, and other required claims.
  Validate guest measured-boot evidence where the selected flow supports it.
- Validate the returned token's signature, trusted issuer, validity period,
  required claims, and challenge/key binding. The relying party, not MAA alone,
  decides whether to release secrets. Reject failed or incomplete verification.
- Pin expected **SNP launch measurements** derived for the approved launch
  configuration. An IGVM file's SHA-256 hash identifies the artifact; it is not
  interchangeable with the SNP report's launch measurement.

## Readiness and Limits

This is an integration design, not a claim of turnkey MAA support for a custom
bare-metal MSHV/OpenVMM deployment. Validate evidence format, endorsements,
vTPM-to-SNP binding, MAA policy/claims, and secure secret delivery end to end.
Confirm protected vTPM-state persistence and recovery before relying on BitLocker
across restarts. Isolation does not provide availability against a malicious host.

**References:** [Full deployment guide](openhcl-vtpm-windows-cvm-on-azure-linux-mshv.md)
| [OpenHCL architecture](https://openvmm.dev/guide/reference/architecture/openhcl.html)
| [Microsoft Azure Attestation](https://learn.microsoft.com/en-us/azure/attestation/overview)