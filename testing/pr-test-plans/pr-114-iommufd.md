# PR #114 test plan and evidence matrix: IOMMUFD

Upstream PR: [ROCm/k8s-gpu-dra-driver#114](https://github.com/ROCm/k8s-gpu-dra-driver/pull/114)

## What this PR is testing

PR #114 adds per-device IOMMUFD support to the AMD GPU VFIO path while
retaining legacy VFIO support:

- `LegacyOnly`, `PreferIommuFD`, and `RequireIommuFD` backend policies.
- IOMMUFD and legacy VFIO backend selection.
- Backend-consistent CDI generation.
- Validation of real `/dev/iommu`, VFIO cdev, API, and group nodes.
- Fail-closed behavior for `RequireIommuFD`.
- Fallback from IOMMUFD to legacy VFIO for `PreferIommuFD`.
- Rollback after Prepare, CDI, or checkpoint failures.
- Refresh and cleanup of IOMMUFD cdev state.

PR #114 does not by itself fix the longer-lived GPU conversion and restart
tracking issues covered by PR #122.

## Status legend

| Status | Meaning |
|---|---|
| **Complete — automated** | Covered by tests in the PR branch; rerun after the final rebase. |
| **Complete — live** | Observed on a real host or live cluster. |
| **Partial** | A related path was tested, but not the PR #114 behavior end to end. |
| **Not tested** | No evidence is currently recorded. |
| **Blocked** | Requires host or virt-launcher support not currently available. |

## Test type definitions

| Type | Meaning |
|---|---|
| **Unit** | Tests one policy, helper, or validation rule with in-memory inputs. |
| **Component** | Exercises driver, CDI, checkpoint, or fake-sysfs behavior without a real host. |
| **Kubernetes integration** | Uses a live API server, DRA driver, ResourceClaims, and ResourceSlices. |
| **Live hardware integration** | Uses real GPU/VFIO/IOMMUFD device nodes and kernel state. |
| **Concurrency/race** | Exercises concurrent driver operations and race detection. |
| **End-to-end (KubeVirt)** | Starts a VM and verifies the selected backend through the guest lifecycle. |

## Executive status

| Area | Type | Current status | Evidence | Remaining gap |
|---|---|---|---|---|
| Build and static checks | Build/static | **Complete — automated** | On commit `fdd271226e06`, `go build -mod=vendor ./...`, `go vet -mod=vendor ./...`, `go test -mod=vendor ./...`, and `go test -race -mod=vendor ./cmd/gpu-kubeletplugin/` passed. | Rerun only if the branch is rebased or changed. |
| Backend policy validation | Unit + component | **Complete — automated** | All three policies are covered through claim decoding and validation on the tested commit. | Rerun only if the branch changes. |
| CDI backend selection | Component | **Complete — automated and live** | Tests cover IOMMUFD, legacy, fallback, and mixed-backend prevention; active live claims produced backend-consistent CDI. | No remaining backend-selection gap for the tested paths. |
| Real device-node validation | Component + live hardware integration | **Complete — automated and live** | Fake-sysfs tests require real character-device semantics, and the live host exposed/used `/dev/iommu`, VFIO cdevs, API, and group nodes. | No remaining success-path gap. |
| Rollback | Component | **Complete — automated; live fail-closed path verified** | Tests cover invalid policy, missing nodes, CDI failure, checkpoint failure, and multi-device failure; the live unavailable-IOMMUFD Require case restored the PF after NodePrepare failed. | Other injected rollback paths remain appropriately automated-only. |
| IOMMUFD host path | Live hardware integration | **Complete — live** | The PR #114 image used `/dev/iommu`, per-device VFIO cdevs, and the shared `/dev/vfio/vfio` API control device for `PreferIommuFD` and `RequireIommuFD`. | No remaining success-path gap. |
| Legacy VFIO path | Live hardware integration | **Complete — live** | `LegacyOnly` produced `/dev/vfio/vfio` and the device group node, with no IOMMUFD nodes in the CDI; `PreferIommuFD` also fell back to this path when `/dev/iommu` was hidden. | No remaining legacy-path gap for the tested cases. |
| Multi-device backend consistency | Kubernetes integration | **Complete — live** | A two-device `RequireIommuFD` claim used cdevs for both devices, the shared `/dev/iommu` node, and the shared `/dev/vfio/vfio` API control device. | No remaining success-path gap. |
| Fail-closed and fallback | Live hardware integration | **Complete — live** | With only `/dev/iommu` temporarily hidden, `PreferIommuFD` ran through legacy VFIO and `RequireIommuFD` remained unprepared with the expected kubelet error. The node and device node were restored by cleanup. | The KubeVirt fallback VM remains blocked by KubeVirt control-plane state. |
| KubeVirt IOMMUFD path | End-to-end (KubeVirt) | **Complete for host-side VM startup — live** | Single-device `PreferIommuFD` and `RequireIommuFD` VMs reached `Running`/`Ready`; the launcher received `/dev/vfio/vfio`, `/dev/iommu`, and the per-device cdev. | Guest `lspci` and the legacy fallback VM remain separate gaps. |

## Automated test scenarios

| ID | Type | Scenario | What to verify | Status |
|---|---|---|---|---|
| A-01 | Build/static | Build, vet, and repository tests | `go build ./...`, `go vet ./...`, uncached `make test`, and `go test -race ./cmd/gpu-kubeletplugin/` pass. | Reported complete; rerun after final commits. |
| A-02 | Unit | Policy defaults and decoding | Omitted policy defaults correctly; `LegacyOnly`, `PreferIommuFD`, and `RequireIommuFD` decode; removed fields are rejected. | Reported complete. |
| A-03 | Component | Backend selection | One backend decision drives both per-device and common CDI edits. | Reported complete. |
| A-04 | Component | IOMMUFD device detection | `/dev/iommu` and `/dev/vfio/devices/<cdev>` must be real character devices, not only sysfs entries. | Reported complete. |
| A-05 | Component | CDI node generation | IOMMUFD emits `/dev/iommu`, the cdev, and the shared `/dev/vfio/vfio` API control device; legacy emits `/dev/vfio/vfio` and the group node. | Reported complete; updated by driver commit `1ff18ce`. |
| A-06 | Component | CDI metadata | Device nodes contain correct host path, type, major, minor, and permissions. | Reported complete. |
| A-07 | Component | Backend consistency | A cdev-present but `/dev/iommu`-missing case cannot create a mixed CDI specification. | Reported complete. |
| A-08 | Component | Fail-closed policy | `RequireIommuFD` fails Prepare when either required IOMMUFD node is missing. | Reported complete. |
| A-09 | Component | Rollback | Every conversion and bind touched by a failed Prepare is restored. | Reported complete. |
| A-10 | Concurrency/race | Repeated Configure/Unconfigure and race coverage | cdev state is refreshed, cleared, and not reused across retries; race tests pass. | Reported complete; rerun required. |

## Live host prerequisites

Use an available AMD VFIO-capable system; the plan is not tied to a specific
server model. Record the GPU model, kernel, Kubernetes version, DRA driver
commit, and the presence and type of:

- `/dev/iommu`
- `/dev/vfio/vfio`
- `/dev/vfio/devices/<cdev>`
- `/dev/vfio/<group>`

Also record the libvirt version available to any KubeVirt test.

## Live backend-policy matrix

| ID | Type | Policy | Host condition | Expected result | Status |
|---|---|---|---|---|---|
| L-01 | Live hardware integration | `LegacyOnly` | IOMMUFD available | Uses legacy VFIO. | **Complete — live**; CDI contained `/dev/vfio/vfio` and `/dev/vfio/94`. |
| L-02 | Live hardware integration | `LegacyOnly` | IOMMUFD unavailable | Uses legacy VFIO if legacy nodes are valid. | Not tested against PR #114. |
| L-03 | Live hardware integration | `PreferIommuFD` | IOMMUFD available | Uses IOMMUFD. | **Complete — live**; CDI contained `/dev/iommu`, the VFIO cdev, and `/dev/vfio/vfio`. |
| L-04 | Live hardware integration | `PreferIommuFD` | IOMMUFD unavailable | Falls back to legacy VFIO and logs a warning. | **Complete — live**; the pod ran, CDI contained `/dev/vfio/94` and `/dev/vfio/vfio`, and the driver logged `backend=legacy` plus the fallback warning. |
| L-05 | Live hardware integration | `RequireIommuFD` | IOMMUFD available | Prepare succeeds with IOMMUFD. | **Complete — live**. |
| L-06 | Live hardware integration | `RequireIommuFD` | IOMMUFD unavailable | Prepare fails closed. | **Complete — live**; scheduler allocation occurred, but kubelet left the pod `Pending` after NodePrepare reported `/dev/iommu unavailable`; no workload container started and the PF returned to `amdgpu`. |

## IOMMUFD success scenarios

| ID | Type | Scenario | Verification | Expected result | Status |
|---|---|---|---|---|---|
| I-01 | Live hardware integration | IOMMUFD node discovery | Allocate a GPU VF and inspect `/dev/iommu` and `/dev/vfio/devices/<cdev>`. | Both are character devices and correspond to the prepared device. | **Complete — live**. |
| I-02 | Kubernetes integration | IOMMUFD CDI | Inspect the generated claim CDI YAML. | It contains `/dev/iommu`, the per-device cdev, and the shared `/dev/vfio/vfio` API control device, with no legacy group node. | **Complete — live**. |
| I-03 | Kubernetes integration | CDI device metadata | Compare CDI major/minor, host paths, and permissions with the host nodes. | CDI metadata matches the actual nodes the container must open. | **Complete — live**. |
| I-04 | Component + live hardware integration | Repeated lifecycle | Prepare and unprepare the same device repeatedly. | No stale cdev is reused and each CDI spec is internally consistent. | Automated coverage reported; live test pending. |
| I-05 | Live hardware integration | Multi-device IOMMUFD | Prepare two or more GPU VFs. | Every device in the claim uses IOMMUFD and no device falls back independently. | **Complete — live**; two-device `RequireIommuFD` claim passed. |

## Legacy and fallback scenarios

| ID | Type | Scenario | Verification | Expected result | Status |
|---|---|---|---|---|---|
| F-01 | Live hardware integration | Legacy CDI | Use `LegacyOnly` and inspect CDI. | CDI contains `/dev/vfio/vfio` and `/dev/vfio/<group>`, not IOMMUFD nodes. | **Complete — live**. |
| F-02 | Live hardware integration | Prefer fallback | Make IOMMUFD unavailable and use `PreferIommuFD`. | Prepare succeeds with legacy VFIO and logs a fallback warning. | **Complete — live**; the reversible `/dev/iommu`-hidden case passed. |
| F-03 | Live hardware integration | Missing group node | Make `/dev/vfio/<group>` unavailable. | Prepare fails rather than creating an unusable path-only CDI entry. | Not tested. |
| F-04 | Live hardware integration | Missing VFIO API node | Make `/dev/vfio/vfio` unavailable. | Prepare fails rather than generating an unusable CDI entry. | Not tested. |

## Failure and rollback scenarios

| ID | Type | Failure injected | Expected result | Status |
|---|---|---|---|---|
| R-01 | Component | Invalid backend policy | No conversion remains after validation fails. | Automated complete; live pending. |
| R-02 | Component | Missing `/dev/iommu` or IOMMUFD cdev | `RequireIommuFD` fails closed and conversion is undone. | **Complete — automated and live**; the controlled `/dev/iommu`-hidden case failed during NodePrepare and restored the PF. |
| R-03 | Component | Missing `/dev/vfio/vfio` or group node | Legacy Prepare fails and conversion is undone. | Automated complete; live pending. |
| R-04 | Component | CDI write failure | All devices touched by the claim are restored. | Automated complete; live pending. |
| R-05 | Component | Checkpoint write failure | Hardware state is restored and no stale claim state remains. | Automated complete; live pending. |
| R-06 | Component | Failure after multiple conversions | Earlier conversions are rolled back, not only the last device. | Automated complete; live pending. |

Do not induce these failures on a production workload. Use fake sysfs,
isolated test devices, or controlled test doubles for failure injection.

## Multi-device and restart scenarios

| ID | Type | Scenario | Expected result | Status |
|---|---|---|---|---|
| M-01 | Live hardware integration | Two-device allocation | Both devices use the same selected backend. | **Complete — live** for `RequireIommuFD`. |
| M-02 | Component | Re-prepare | A failed or repeated cdev lookup does not reuse stale state. | Automated complete; live pending. |
| M-03 | Component | Unconfigure | cdev state is cleared during Unconfigure. | Automated complete; live pending. |
| M-04 | Kubernetes integration | Plugin restart | CDI/checkpoint state recovers without backend mixing. | **Not tested for PR #114**; active-conversion recovery was tested separately as PR #122 evidence. |

## KubeVirt end-to-end scenarios

The previous live VM used legacy VFIO. That confirms the host can perform
legacy passthrough, but it is not evidence for PR #114's IOMMUFD path.

| ID | Type | Scenario | Expected result | Status |
|---|---|---|---|---|
| K-01 | End-to-end (KubeVirt) | `RequireIommuFD` single-GPU VM | VM starts and the guest detects the GPU using IOMMUFD CDI nodes. | **Partial — live, harness-backed**; the VM reached `Running` and the claim used the IOMMUFD path, but guest `lspci` was not captured. Evidence: `/home/jhull/dra-test-work/evidence/kubevirt-iommufd-gim-require-20261001-pr19296-updated.log`. |
| K-02 | End-to-end (KubeVirt) | `PreferIommuFD` fallback VM | With IOMMUFD unavailable, VM starts through legacy VFIO. | **Blocked — not tested**; temporarily disabling the KubeVirt `IOMMUFD` feature gate was rejected because the validating webhook was unavailable (`connection refused`) while `virt-operator` was intentionally scaled down. The host `/dev/iommu` state and temporary resources were restored. |
| K-03 | End-to-end (KubeVirt) | Two-device VM | Both passed-through devices use the same backend. | **Complete — live, harness-backed**; the two-GPU KubeVirt workload passed with `RequireIommuFD`. Evidence: `/home/jhull/dra-test-work/evidence/harness-multidevice-20261001/run.log` and `/home/jhull/dra-test-work/evidence/kubevirt-iommufd-gim-multidevice-20261001-pr19296-updated.log`. |
| K-04 | End-to-end (KubeVirt) | Guest and host verification | Host CDI/backend state and guest `lspci` agree with the selected path. | **Partial — live**; host-side claim allocation and IOMMUFD CDI/backend checks passed, but guest `lspci` output was not captured in these harness runs. |
| K-05 | End-to-end (KubeVirt) | Large-BAR PCI aperture with IOMMUFD | The VMI starts with the fixed KubeVirt image and libvirt receives the required aperture and IOMMUFD hostdev settings. | **Complete — live, harness-backed**; the domain XML contained `pcihole64=1073741824 KiB`, `cpu mode=host-passthrough`, `<iommufd enabled='yes'>`, and `<driver ... iommufd='yes'>`. Evidence: `/home/jhull/dra-test-work/evidence/pr91-114-122-gim/pci-aperture-explicit-20261002/`. |

The IOMMUFD KubeVirt tests require a virt-launcher image with the libvirt
support required by KubeVirt's IOMMUFD feature gate.

## 2026-10-02 IOMMUFD KubeVirt and PCI-aperture validation

The integrated PR #91/#114/#122 driver branch was rebuilt at commit
`1ff18ce` after correcting the IOMMUFD CDI output. IOMMUFD allocations now
include `/dev/iommu`, the per-device `/dev/vfio/devices/vfioN` cdev, and the
shared `/dev/vfio/vfio` VFIO API control device required by libvirt. The
matching KubeVirt branch was `test/iommufd-vfio-vm-pci-aperture`.

The harness passed both single-device `PreferIommuFD` and `RequireIommuFD`
VMI runs. Each VMI reached `Running`/`Ready=True`; the launcher contained all
three expected device nodes. The explicit aperture run also captured libvirt
domain XML showing a `1073741824 KiB` (`1 TiB`) `pcihole64`,
`host-passthrough` CPU mode, domain IOMMUFD enabled, and an IOMMUFD-backed PCI
hostdev. Evidence is saved under
`/home/jhull/dra-test-work/evidence/pr91-114-122-gim/pci-aperture-explicit-20261002/`.

The remaining PR #114 KubeVirt gaps are guest-side `lspci` capture and the
IOMMUFD-unavailable legacy-fallback VM.

## Evidence package for an AMD review

For each live run, save:

- Host device-node and kernel information.
- GPU model, driver, GIM, and DRA driver commit.
- Backend policy configuration.
- ResourceClaims and allocation status.
- Generated CDI YAML.
- DRA driver logs showing backend selection and fallback.
- ResourceSlices before and after Prepare/Unprepare.
- VM/VMI YAML and guest `lspci`, if KubeVirt is tested.
- A row-by-row result table using the IDs in this document.

Current live evidence is under
`/home/jhull/dra-test-work/evidence/pr114-iommufd/` on the test host. The
tested image was built from commit `fdd271226e06`.

## 2026-09-30 non-GIM MI355X validation addendum

With all eight MI355X PFs booted under `amdgpu`, the harness exercised one-PF
conversion and release with `LegacyOnly`, `PreferIommuFD`, and
`RequireIommuFD`. The driver logs confirmed `backend=legacy` for the legacy
case and `backend=iommufd` for both IOMMUFD policies. A two-PF claim with
`RequireIommuFD` also passed; both devices converted and both were restored to
`amdgpu` during cleanup.

Host prerequisites were present: `/dev/iommu`, `/dev/vfio/vfio`, and the
`iommufd` kernel module. Evidence is saved under
`/home/jhull/dra-test-work/evidence/pr114-122/non-gim-prefer-iommufd`,
`/home/jhull/dra-test-work/evidence/pr114-122/non-gim-require-iommufd`, and
`/home/jhull/dra-test-work/evidence/pr114-122/non-gim-multidevice`.

The harness run verified backend selection through driver logs and successful
lifecycle behavior. The follow-up active-claim capture preserved CDI YAML and
matched the expected host node major/minor values. The subsequent controlled
IOMMUFD-unavailable fallback and fail-closed cases are recorded below.
KubeVirt IOMMUFD success cases now pass; the fallback VM and guest-side
inventory remain open.

## 2026-09-30 recommended-gap validation addendum

The live fallback matrix used a reversible host change: the character device
`/dev/iommu` was moved aside while the node remained schedulable, then
restored by the test trap. No kernel module was unloaded and GIM was not
changed.

For `PreferIommuFD`, the claim reached `Running`; the driver logged
`IOMMUFD preferred ... falling back to legacy VFIO` and `backend=legacy`, and
the active CDI contained `/dev/vfio/94` and `/dev/vfio/vfio` rather than
`/dev/iommu`. For `RequireIommuFD`, the scheduler populated the claim, but
kubelet's NodePrepare step failed closed with `IOMMUFD required ... but
/dev/iommu unavailable`; the pod remained `Pending`, no container started,
and the PF was restored to `amdgpu`.

Evidence is saved under
`/home/jhull/dra-test-work/evidence/pr114-122/iommufd-unavailable/prefer`
and
`/home/jhull/dra-test-work/evidence/pr114-122/iommufd-unavailable/require`.
The node ended `Ready`, `/dev/iommu` was restored as a character device, and
all eight PFs were bound to `amdgpu`.

The remaining PR #114 live gap is the KubeVirt legacy-fallback VM and guest
`lspci` verification. Missing group/API-node injection and other rollback
faults remain covered by automated tests unless a suitable isolated device is
available.

## Final assessment

PR #114 has broad automated coverage and live evidence for `LegacyOnly`,
`PreferIommuFD`, `RequireIommuFD`, CDI node selection, the unavailable-IOMMUFD
fallback/fail-closed behavior, and a two-device IOMMUFD claim. The remaining
approval-critical gap is the KubeVirt fallback and guest-side verification
path. The IOMMUFD success path is live-tested with the compatible virt-launcher
image. Other injected rollback faults can
remain automated-only if the disposable host cannot provide an isolated
reversible setup. Active conversion recovery across plugin restarts belongs
to PR #122 and is covered there.

## 2026-10-01 non-GIM safe-case harness validation

On the GIM-disabled, `amdgpu`-only host, the harness passed the repeated
`LegacyOnly` release cycle, a two-device `RequireIommuFD` claim, and the
single-device `PreferIommuFD` and `RequireIommuFD` policies. The two-device
case selected both PFs and cleaned them up successfully; all cases restored
their PFs to `amdgpu`.

Evidence is saved under
`/home/jhull/dra-test-work/evidence/pr114/non-gim-20261001-legacy-repeat`,
`/home/jhull/dra-test-work/evidence/pr114/non-gim-20261001-multidevice`,
`/home/jhull/dra-test-work/evidence/pr114/non-gim-20261001-prefer`, and
`/home/jhull/dra-test-work/evidence/pr114/non-gim-20261001-require`.

The unavailable-IOMMUFD injection is covered by the earlier live fail-closed
run. The KubeVirt IOMMUFD success cases also passed with the updated
virt-launcher image; the fallback VM remains blocked by the unavailable
validating webhook, and guest `lspci` capture remains pending.
