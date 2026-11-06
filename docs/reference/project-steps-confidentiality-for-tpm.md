# Project Steps: Confidentiality for the Windows vTPM

## 1. Goal and Deployment Assumptions

Launch a Windows confidential VM whose virtual TPM implementation, private keys,
and sensitive state are protected from both Azure Linux Dom-0 and the Microsoft
Hypervisor (MSHV), using AMD SEV-SNP and OpenHCL.

| Component | Assumed role |
| --- | --- |
| AMD SEV-SNP hardware | Hardware isolation, protected private memory, and signed attestation reports. |
| Bare-metal MSHV | Creates and schedules isolated child partitions. |
| Azure Linux Dom-0 | Root partition containing host drivers and management services. |
| OpenVMM in Dom-0 | Creates the VM through `/dev/mshv` and loads OpenHCL. |
| OpenHCL in guest VTL2 | Hosts the vTPM and trusted guest platform services. |
| Windows in guest VTL0 | Uses the vTPM for measured boot and TPM-backed operations. |
| Windows VTL1, if enabled | Hosts the Windows secure kernel and VBS-protected services. |
| THIM | Supplies hardware endorsement collateral and the applicable platform baseline; any registrar or AK-certification integration requires an explicit service contract. |
| Microsoft Azure Attestation (MAA) | Verifies supported evidence and issues signed policy-evaluated attestation tokens. |
| Relying party / key-release service | Validates tokens and authorizes secrets only for the intended attested recipient. |

THIM and MAA are assumed attestation dependencies. Their availability does not
establish that a custom bare-metal MSHV/OpenVMM deployment is accepted by the
Azure CVM attestation or certificate-issuance services. Confirm that integration
before treating this plan as deployable.

## 2. Establish the Threat Model and Trust Boundary

Treat MSHV, Dom-0, OpenVMM, host storage, and host-provided network and device
responses as potentially malicious. They may transport evidence but cannot be
trusted to assert its correctness.

The trusted computing base includes the AMD hardware and security firmware,
approved OpenHCL code and configuration, the vTPM implementation, and the
attestation and authorization services. Windows becomes a recipient of secrets
only under the Windows-state policy chosen for the workload.

Distinguish these protections:

- VTL2 separates OpenHCL and vTPM private state from the lower-VTL guest OS.
- SNP protects private guest memory from host and hypervisor access. VTL2 alone
  is not the confidentiality boundary against a malicious hypervisor.
- Authenticated encryption and protected recovery keys protect persisted vTPM
  state. Memory encryption alone does not protect a state file on host storage.
- Freshness and rollback controls are separate from encryption.

The goal does not include availability against the host, protection from every
side channel, or immunity to vulnerabilities in trusted code. Windows can invoke
authorized TPM operations without being able to read the vTPM's private memory.

**Acceptance gate:** Approve the threat model, trusted components, secret owners,
and explicit exclusions before implementation.

## 3. Prove Platform and Service Compatibility

1. Select an SNP-capable AMD platform and establish supported firmware,
   microcode, SNP provisioning, and IOMMU configuration.
2. Select matched MSHV, Azure Linux root-partition kernel, OpenVMM, and OpenHCL
   versions supporting the intended SNP-isolated launch path.
3. Confirm that the bare-metal boot path starts MSHV and Azure Linux runs in its
   root partition. Loading the Linux `mshv` driver alone is insufficient.
4. Confirm `/dev/mshv` access and demonstrate an SNP-isolated test launch.
5. Establish THIM collateral retrieval for the physical platform and report TCB.
   Do not assume Azure's link-local metadata endpoint exists on custom hardware.
6. Confirm the MAA evidence API, protocol version, supported measurements,
   certificate issuers, policy capabilities, and required authentication.
7. Identify the service that registers or certifies the vTPM AK, if used. THIM's
   documented AMD collateral role is not itself a vTPM AK-issuance contract.
8. If VBS is required, confirm VTL1 support in this exact MSHV/OpenHCL/SNP stack.

**Acceptance gate:** Obtain a verifiable SNP report from the test partition and
demonstrate acceptance through the selected service integration. A host log
saying SNP is enabled is a readiness check, not remote proof.

## 4. Build and Approve the Confidential Launch Image

1. Build or obtain the confidential OpenHCL IGVM image, using the `x64-cvm`
   recipe rather than the ordinary `x64` recipe.
2. Record artifact versions, source revisions, build provenance, and file hashes
   for OpenVMM, OpenHCL, and guest firmware.
3. Define approved measured configuration, Secure Boot policy, diagnostic
   settings, and permitted host-supplied runtime inputs.
4. Derive the expected SNP launch measurement for the approved image and launch
   configuration. An IGVM file's SHA-256 hash is an artifact identifier, not the
   SNP launch measurement.
5. Document which components are covered by the launch measurement and how
   later-loaded firmware and Windows components are authenticated and measured.
6. Define update approval, minimum security versions, and removal of vulnerable
   images from the allowlist. Disable debug and secret-exposing diagnostics in
   production; do not assume SNP makes exported logs or dumps confidential.

The repository's OpenHCL build defaults to `x64`. Select the CVM recipe explicitly:

```bash
make build-openhcl OPENHCL_RECIPE=x64-cvm
```

**Acceptance gate:** Maintain a reviewed measurement manifest and verifier policy
for each supported release, rather than accepting arbitrary SNP-protected code.

## 5. Launch OpenHCL in VTL2 Before Windows

1. OpenVMM requests an SNP-isolated child partition through MSHV.
2. OpenVMM follows the IGVM directives to load the OpenHCL components and initial
   execution state into the partition's VTL2 environment.
3. The SNP launch process establishes protected guest state and the hardware
   launch measurement before normal guest execution.
4. Execution begins in `openhcl_boot`, which validates configuration and boots
   OpenHCL's Linux kernel and userspace.
5. OpenHCL initializes trusted platform services, including the vTPM. Configure
   a dedicated TPM worker where supported for additional process isolation.
6. OpenHCL establishes the lower-VTL guest environment and starts guest firmware
   and the Windows boot chain in VTL0. Required VMGS unlocking occurs before any
   dependent vTPM or Windows boot operations.

```text
AMD SEV-SNP hardware
  MSHV on bare metal
    Azure Linux Dom-0
      OpenVMM: partition creation and IGVM loading
    SNP-protected child partition
      VTL2: OpenHCL, vTPM, trusted platform services
      VTL1: Windows secure kernel, only when supported and VBS enabled
      VTL0: guest UEFI, Windows normal kernel, applications
```

VTL2 does not imply Windows VBS is enabled, and VTL numbers are not AMD VMPL
numbers. If VBS is part of the requirement, configure and verify Windows VBS
separately instead of inferring it from OpenHCL or vTPM presence.

**Acceptance gate:** Confirm Windows detects a TPM 2.0 device and the selected
Secure Boot configuration. Verify SNP isolation remotely in the following steps;
`Get-Tpm`, diagnostic output, and launch flags alone are not security proof.

## 6. Authenticate OpenHCL and Bind the vTPM Identity

1. Collect the SNP report and runtime claims through the supported OpenHCL
   attestation path, together with matching AMD endorsement collateral from THIM.
2. Validate the report signature and AMD certificate chain, applicable revocation
   information, and minimum platform TCB requirements through the verifier.
3. Require the approved launch measurement and acceptable guest policy, including
   debug restrictions and explicit migration and SMT policy.
4. Validate the report's expected privilege context and the protocol-defined
   binding between report data and serialized runtime claims.
5. Bind the vTPM AK public key, or the protocol-defined attestation identity, to
   that hardware-attested OpenHCL environment. Approved OpenHCL must generate or
   validate sensitive claims, not blindly endorse host-provided metadata.
6. For certificate-based registration, require the registrar to validate that
   binding before issuance. Validate the resulting AK certificate's issuer,
   chain, validity, and correspondence to the actual quoting key.
7. Maintain the required certificate renewal and re-enrollment paths. Receiving
   certificate bytes through a host agent does not establish certificate trust.

**Acceptance gate:** Reject a TPM identity that cannot be traced to the approved
SNP-protected OpenHCL environment. Independently valid SNP and TPM evidence must
not be accepted without their cryptographic relationship being verified.

## 7. Protect Persistent vTPM State and Boot-Time Key Release

1. Configure authenticated encryption for VM Guest State (VMGS), including
   sensitive vTPM state. Verify the actual encryption policy; do not assume every
   stateless or test configuration enables it.
2. Keep the datastore encryption key out of Dom-0 and MSHV. Configure supported
   hardware sealing, attestation-gated secure key release, or both.
3. If using remote key release, attest OpenHCL before releasing the key needed to
   unlock VMGS. Deliver that key only to a cryptographically bound recipient
   inside the protected environment.
4. Define provisioning, cold restart, recovery, update, and key-rotation behavior.
   Disable unsupported migration, snapshots, and servicing until protected state
   transfer and destination admission have been validated.
5. Define rollback requirements and an authoritative freshness mechanism if
   required, such as a trusted external state/version service. Authenticated
   encryption and a fresh SNP report do not alone reject an old VMGS snapshot.
6. Fail closed when required state protection or key recovery cannot complete.
   Do not silently downgrade to plaintext state or a host-managed TPM.

**Acceptance gate:** Demonstrate restart and recovery without exposing keys to
the host, and test the documented rollback policy. AK certification and VMGS key
release are separate operations.

## 8. Attest Windows Boot State Through MAA

1. Configure guest UEFI Secure Boot and an approved Windows image and boot policy.
2. Enable VBS and required services such as HVCI only if the selected stack
   supports them and the workload policy requires them.
3. Deploy a Windows evidence collector compatible with the selected MAA flow.
4. Collect an AK-signed quote over the required PCRs, Windows measured-boot
   evidence, and supporting certificates in the protocol's expected format.
5. Bind a relying-party challenge into the signed evidence using the supported
   protocol. Merely attaching a nonce as unsigned metadata is insufficient.
6. Require verification of the quote signature, certified or hardware-bound AK,
   freshness, PCR selection, and event-log consistency with quoted PCR values.
7. Evaluate approved boot components, Secure Boot policy and revocations, Windows
   security/update requirements, and restrictions on debugging and test signing.
8. Require authenticated VBS/HVCI evidence where those features are mandatory.
   Confirm which claims MAA actually verifies and emits for this deployment;
   implement missing required checks in a supported verification layer.

**Acceptance gate:** Obtain an MAA token establishing the required connected
hardware, OpenHCL, vTPM, and Windows claims. Neither an SNP report alone nor a
Windows quote from an unbound software TPM is sufficient. Boot evidence does not
prove the absence of all post-boot compromise.

## 9. Authorize and Deliver Workload Secrets

1. The relying party validates the MAA token signature using keys from the
   configured trusted authority, not a token-supplied arbitrary issuer.
2. Validate issuer, validity interval, expected policy identity, required claims,
   and audience where specified by the selected protocol.
3. Check challenge freshness and replay handling. A newly issued token is not
   sufficient if the evidence underlying it can be replayed.
4. Bind the recipient encryption key or secure session to the attested VM using
   the protocol's verified key-binding and possession mechanism.
5. Release workload secrets only after the Windows-state policy passes. This is
   separate from pre-Windows key release used to recover VMGS.
6. Use short-lived authorization and a defined re-attestation policy for long
   running workloads. MAA verification does not itself authorize every secret.

**Acceptance gate:** Evidence from one VM cannot authorize secret delivery to a
different VM, Dom-0, or a host-selected public key.

## 10. Run Adversarial Acceptance Tests

| Test | Required result |
| --- | --- |
| Launch without SNP isolation or with a nonapproved OpenHCL image | Deny protected key and workload-secret release. |
| Enable disallowed debug policy or use a below-policy platform TCB | Reject attestation or deny authorization. |
| Replace the vTPM with a host-emulated TPM | Reject the missing or invalid hardware-to-AK binding. |
| Combine VM A's SNP evidence with VM B's TPM quote | Reject mismatched identities and evidence bindings. |
| Replay an old quote or substitute the recipient key | Reject freshness or recipient-binding validation. |
| Change Windows boot policy or disable required VBS | Reject the applicable measured-state policy. |
| Tamper with encrypted VMGS | Fail authentication and recovery; never fall back to plaintext. |
| Restore an older valid VMGS snapshot | Reject when anti-rollback is required; otherwise record the residual risk explicitly. |
| Inspect host memory, files, diagnostics, and crash outputs | No plaintext vTPM private keys or state-protection keys exposed. |
| Restart, rotate keys, and perform supported recovery | Preserve protection and the intended VM identity. |
| Withhold storage, networking, or CPU scheduling | Fail closed; host denial of service remains possible. |

Host inspection tests complement, but do not replace, hardware attestation and
review of the trusted code and configuration.

**Completion criteria:** Record approved artifacts, measurements, service
contracts, policies, evidence examples, negative-test results, and recovery
procedures. Do not claim end-to-end vTPM confidentiality until the launch,
identity binding, persistence, and secret-delivery gates have passed.

## References

- [MSHV root-partition architecture](mshv.md)
- [Deployment one-pager](../how-to/openhcl-vtpm-windows-cvm-on-azure-linux-mshv-one-pager.md)
- [OpenHCL boot flow](../../src/openvmm/Guide/src/reference/architecture/openhcl/boot.md)
- [OpenHCL IGVM image](../../src/openvmm/Guide/src/reference/architecture/openhcl/igvm.md)
- [OpenHCL attestation and VMGS protection](https://openvmm.dev/guide/reference/architecture/openhcl/attestation.html)
- [OpenHCL AK certification lifecycle](https://openvmm.dev/guide/reference/architecture/openhcl/ak_cert.html)
- [Trusted Hardware Identity Management](https://learn.microsoft.com/en-us/azure/security/fundamentals/trusted-hardware-identity-management)
- [Microsoft Azure Attestation overview](https://learn.microsoft.com/en-us/azure/attestation/overview)
- [Windows CVM guest attestation](https://learn.microsoft.com/en-us/azure/confidential-computing/guest-attestation-confidential-vms)