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
| Build and static checks | Build/static | **Complete — automated; rerun needed** | PR reports build, vet, uncached tests, and race tests passing. | Rerun after the latest review commits and final rebase. |
| Backend policy validation | Unit + component | **Complete — automated** | All three policies are covered through claim decoding and validation. | Confirm on the final branch. |
| CDI backend selection | Component | **Complete — automated** | Tests cover IOMMUFD, legacy, fallback, and mixed-backend prevention. | Live CDI inspection remains. |
| Real device-node validation | Component | **Complete — automated** | Fake-sysfs tests require real character-device semantics. | Validate against a real host. |
| Rollback | Component | **Complete — automated** | Tests cover invalid policy, missing nodes, CDI failure, checkpoint failure, and multi-device failure. | Controlled live failure test is optional and pending. |
| IOMMUFD host path | Live hardware integration | **Not tested end to end** | `/dev/iommu` and the module were observed previously, but the VM used legacy VFIO. | Deploy PR #114 and exercise IOMMUFD policies. |
| Legacy fallback | Live hardware integration | **Not tested against PR #114** | Legacy VFIO was used by an earlier VM, but not the PR #114 branch. | Verify policy selection and CDI contents. |
| KubeVirt IOMMUFD path | End-to-end (KubeVirt) | **Blocked** | Requires a virt-launcher image with suitable libvirt support. | Test when the required image is available. |

## Automated test scenarios

| ID | Type | Scenario | What to verify | Status |
|---|---|---|---|---|
| A-01 | Build/static | Build, vet, and repository tests | `go build ./...`, `go vet ./...`, uncached `make test`, and `go test -race ./cmd/gpu-kubeletplugin/` pass. | Reported complete; rerun after final commits. |
| A-02 | Unit | Policy defaults and decoding | Omitted policy defaults correctly; `LegacyOnly`, `PreferIommuFD`, and `RequireIommuFD` decode; removed fields are rejected. | Reported complete. |
| A-03 | Component | Backend selection | One backend decision drives both per-device and common CDI edits. | Reported complete. |
| A-04 | Component | IOMMUFD device detection | `/dev/iommu` and `/dev/vfio/devices/<cdev>` must be real character devices, not only sysfs entries. | Reported complete. |
| A-05 | Component | CDI node generation | IOMMUFD emits `/dev/iommu` and the cdev; legacy emits `/dev/vfio/vfio` and the group node. | Reported complete. |
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
| L-01 | Live hardware integration | `LegacyOnly` | IOMMUFD available | Uses legacy VFIO. | Not tested against PR #114. |
| L-02 | Live hardware integration | `LegacyOnly` | IOMMUFD unavailable | Uses legacy VFIO if legacy nodes are valid. | Not tested against PR #114. |
| L-03 | Live hardware integration | `PreferIommuFD` | IOMMUFD available | Uses IOMMUFD. | Not tested. |
| L-04 | Live hardware integration | `PreferIommuFD` | IOMMUFD unavailable | Falls back to legacy VFIO and logs a warning. | Not tested. |
| L-05 | Live hardware integration | `RequireIommuFD` | IOMMUFD available | Prepare succeeds with IOMMUFD. | Not tested. |
| L-06 | Live hardware integration | `RequireIommuFD` | IOMMUFD unavailable | Prepare fails closed. | Not tested. |

## IOMMUFD success scenarios

| ID | Type | Scenario | Verification | Expected result | Status |
|---|---|---|---|---|---|
| I-01 | Live hardware integration | IOMMUFD node discovery | Allocate a GPU VF and inspect `/dev/iommu` and `/dev/vfio/devices/<cdev>`. | Both are character devices and correspond to the prepared device. | Not tested. |
| I-02 | Kubernetes integration | IOMMUFD CDI | Inspect the generated claim CDI YAML. | It contains `/dev/iommu` and the per-device cdev, with no legacy group nodes. | Not tested. |
| I-03 | Kubernetes integration | CDI device metadata | Compare CDI major/minor, host paths, and permissions with the host nodes. | CDI metadata matches the actual nodes the container must open. | Not tested. |
| I-04 | Component + live hardware integration | Repeated lifecycle | Prepare and unprepare the same device repeatedly. | No stale cdev is reused and each CDI spec is internally consistent. | Automated coverage reported; live test pending. |
| I-05 | Live hardware integration | Multi-device IOMMUFD | Prepare two or more GPU VFs. | Every device in the claim uses IOMMUFD and no device falls back independently. | Not tested. |

## Legacy and fallback scenarios

| ID | Type | Scenario | Verification | Expected result | Status |
|---|---|---|---|---|---|
| F-01 | Live hardware integration | Legacy CDI | Use `LegacyOnly` and inspect CDI. | CDI contains `/dev/vfio/vfio` and `/dev/vfio/<group>`, not IOMMUFD nodes. | Not tested against PR #114. |
| F-02 | Live hardware integration | Prefer fallback | Make IOMMUFD unavailable and use `PreferIommuFD`. | Prepare succeeds with legacy VFIO and logs a fallback warning. | Not tested. |
| F-03 | Live hardware integration | Missing group node | Make `/dev/vfio/<group>` unavailable. | Prepare fails rather than creating an unusable path-only CDI entry. | Not tested. |
| F-04 | Live hardware integration | Missing VFIO API node | Make `/dev/vfio/vfio` unavailable. | Prepare fails rather than generating an unusable CDI entry. | Not tested. |

## Failure and rollback scenarios

| ID | Type | Failure injected | Expected result | Status |
|---|---|---|---|---|
| R-01 | Component | Invalid backend policy | No conversion remains after validation fails. | Automated complete; live pending. |
| R-02 | Component | Missing `/dev/iommu` or IOMMUFD cdev | `RequireIommuFD` fails closed and conversion is undone. | Automated complete; live pending. |
| R-03 | Component | Missing `/dev/vfio/vfio` or group node | Legacy Prepare fails and conversion is undone. | Automated complete; live pending. |
| R-04 | Component | CDI write failure | All devices touched by the claim are restored. | Automated complete; live pending. |
| R-05 | Component | Checkpoint write failure | Hardware state is restored and no stale claim state remains. | Automated complete; live pending. |
| R-06 | Component | Failure after multiple conversions | Earlier conversions are rolled back, not only the last device. | Automated complete; live pending. |

Do not induce these failures on a production workload. Use fake sysfs,
isolated test devices, or controlled test doubles for failure injection.

## Multi-device and restart scenarios

| ID | Type | Scenario | Expected result | Status |
|---|---|---|---|---|
| M-01 | Live hardware integration | Two-device allocation | Both devices use the same selected backend. | Not tested. |
| M-02 | Component | Re-prepare | A failed or repeated cdev lookup does not reuse stale state. | Automated complete; live pending. |
| M-03 | Component | Unconfigure | cdev state is cleared during Unconfigure. | Automated complete; live pending. |
| M-04 | Kubernetes integration | Plugin restart | CDI/checkpoint state recovers without backend mixing. | PR #122 owns active-conversion recovery; PR #114 restart test remains pending. |

## KubeVirt end-to-end scenarios

The previous live VM used legacy VFIO. That confirms the host can perform
legacy passthrough, but it is not evidence for PR #114's IOMMUFD path.

| ID | Type | Scenario | Expected result | Status |
|---|---|---|---|---|
| K-01 | End-to-end (KubeVirt) | `RequireIommuFD` single-GPU VM | VM starts and the guest detects the GPU using IOMMUFD CDI nodes. | Blocked/not tested. |
| K-02 | End-to-end (KubeVirt) | `PreferIommuFD` fallback VM | With IOMMUFD unavailable, VM starts through legacy VFIO. | Not tested. |
| K-03 | End-to-end (KubeVirt) | Two-device VM | Both passed-through devices use the same backend. | Not tested. |
| K-04 | End-to-end (KubeVirt) | Guest and host verification | Host CDI/backend state and guest `lspci` agree with the selected path. | Not tested. |

The IOMMUFD KubeVirt tests require a virt-launcher image with the libvirt
support required by KubeVirt's IOMMUFD feature gate.

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

## Final assessment

PR #114 has broad automated coverage for policy handling, CDI generation,
device-node validation, and rollback. The approval-critical missing evidence
is live use of IOMMUFD, live legacy fallback, fail-closed behavior on a real
host, and a KubeVirt IOMMUFD VM when the required libvirt support is
available. Active conversion recovery across plugin restarts belongs to PR
#122 and should not be counted as PR #114 coverage.
