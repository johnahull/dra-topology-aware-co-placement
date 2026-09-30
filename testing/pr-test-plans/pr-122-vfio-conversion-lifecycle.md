# PR #122 test plan and evidence matrix: VFIO conversion lifecycle

Upstream PR: [ROCm/k8s-gpu-dra-driver#122](https://github.com/ROCm/k8s-gpu-dra-driver/pull/122)

## What this PR is testing

PR #122 fixes the state of a regular AMD GPU that the driver temporarily
converts from `amdgpu` to `vfio-pci` for a claim. It covers:

- Keeping conversion records separate for multiple claims.
- Preserving records when rebinding fails.
- Rolling back every device touched by a failed Prepare.
- Persisting conversions in the checkpoint.
- Recovering conversions after a plugin restart.
- Keeping converted GPUs advertised under their original names and types.
- Cleaning up stranded claims when the VFIO manager is unavailable.

PR #122 is stacked on PR #114. Review and test the PR #122-only diff after the
PR #114 base is accepted; do not count PR #114's IOMMUFD backend tests as
coverage for this lifecycle PR.

## Status legend

| Status | Meaning |
|---|---|
| **Complete — automated** | Covered by tests in the PR branch; rerun after the final rebase. |
| **Complete — live** | Observed with real GPU and kernel state. |
| **Partial** | A related lifecycle was tested, but not the PR #122 failure or restart path. |
| **Failed — live** | The live scenario was attempted and did not meet its expected result. |
| **Not tested** | No evidence is currently recorded. |
| **Optional** | Useful integration evidence but not required for the PR's driver behavior. |

## Test type definitions

| Type | Meaning |
|---|---|
| **Unit** | Tests bookkeeping, serialization, or state transitions with in-memory inputs. |
| **Component** | Exercises driver lifecycle, fake sysfs, CDI, or checkpoint behavior. |
| **Kubernetes integration** | Uses a live API server, DRA driver, claims, and ResourceSlices. |
| **Live hardware integration** | Uses real GPU bindings, VFIO devices, and kernel state. |
| **Concurrency/race** | Exercises multiple claims or publication concurrently under the race detector. |
| **End-to-end (KubeVirt)** | Prepares and releases a real VM claim and verifies the host and guest result. |

## Executive status

| Area | Type | Current status | Evidence | Remaining gap |
|---|---|---|---|---|
| Build and race validation | Build/static + concurrency/race | **Complete — automated** | On commit `c6ebfe8b89c3`, `go build -mod=vendor ./...`, `go vet -mod=vendor ./...`, `go test -mod=vendor ./...`, and `go test -race -mod=vendor ./cmd/gpu-kubeletplugin/` passed. | Rerun only if the branch is rebased or changed. |
| Per-claim bookkeeping | Unit + component | **Complete — automated** | Tests cover two claims and independent conversion records. | Confirm on final branch. |
| Failed-rebind handling | Component | **Complete — automated** | Failed rebind remains recorded and returns an error. | Controlled live test remains optional. |
| Prepare rollback | Component | **Complete — automated** | Tests cover invalid policy, CDI failure, checkpoint failure, and multi-device failure. | Confirm all failure paths after rebase. |
| Checkpoint persistence | Component + Kubernetes integration | **Complete — automated and live** | Empty and populated conversion checkpoint cases are covered; the active-conversion restart preserved and recovered the populated checkpoint. | No remaining core persistence gap. |
| Restart recovery | Kubernetes integration | **Complete — automated and live** | Tests recover converted devices through Unprepare; the live restart test recovered the checkpoint and restored the GPU after release. | No remaining core restart gap. |
| ResourceSlice identity | Component + Kubernetes integration | **Complete — live** | During conversion and restart, the original GPU identity was retained, the discovered duplicate VFIO entry was suppressed, and an independent pre-bound VFIO device remained separately addressable. | No remaining core identity gap. |
| Missing VFIO manager | Component | **Complete — automated; live pending** | Cleanup retains state when restoration cannot be performed. | Verify with an isolated test device or controlled fake. |
| KubeVirt lifecycle | End-to-end (KubeVirt) | **Optional; complete live (GIM VF)** | The harness-backed GIM SR-IOV VF path completed VM allocation, release, and restart-during-use coverage. The separate PF passthrough attempt failed when the host hit PCIe AER/NMI errors during VFIO GPU reset. | No remaining GIM VF lifecycle gap. Do not retry PF passthrough on this host. |

## Automated test scenarios

| ID | Type | Scenario | What to verify | Status |
|---|---|---|---|---|
| A-01 | Build/static + concurrency/race | Build and race validation | `make test`, `go test -race ./cmd/gpu-kubeletplugin/`, build, and vet pass. | Reported complete; rerun after final rebase. |
| A-02 | Unit | Per-claim conversion records | Preparing claim B does not erase claim A's conversion record. | Reported complete. |
| A-03 | Component | Failed rebind | A failed restore remains recorded, surfaces an error, and can be retried. | Reported complete. |
| A-04 | Component | Prepare rollback | Invalid policy, IOMMUFD failure, CDI failure, checkpoint failure, and later-group failure restore every device touched by the claim. | Reported complete. |
| A-05 | Component | Checkpoint persistence | Empty conversion state is omitted; populated state round-trips through the checkpoint. | Reported complete. |
| A-06 | Component | Restart recovery | A recovered conversion is rebuilt under the allocated device name and the duplicate discovered VFIO entry is removed. | Reported complete. |
| A-07 | Component | ResourceSlice identity | A converted GPU retains its original name, type, PCI, NUMA, and capacity attributes. | Reported complete. |
| A-08 | Component | Missing VFIO manager | Cleanup does not report success or drop the record when the original driver cannot be restored. | Reported complete. |
| A-09 | Component | Stranded claim cleanup | Unprepare of a claim that was not fully prepared retries restoration and removes state only after success. | Reported complete. |
| A-10 | Unit + component | Checkpoint compatibility | Older checkpoints without `vfioConversions` remain readable; downgrade behavior with active conversions is safe and documented. | Reported complete. |
| A-11 | Concurrency/race | Concurrent claims and publication | Multiple Prepare/Unprepare calls and ResourceSlice rebuilds do not lose records or leave incorrect device types. | Reported complete; rerun required. |
| A-12 | Unit + component | Mutation coverage | Removing each lifecycle fix causes at least one test to fail. | Reported complete. |

## Live hardware and Kubernetes scenarios

Use an available AMD VFIO-capable system with disposable claims and devices.
Record the GPU model, kernel, AMD/GIM driver versions, Kubernetes version, DRA
driver commit, original GPU driver, and the PCI addresses used. Do not use a
production workload for failure injection.

| ID | Type | Scenario | How to verify | Expected result | Status |
|---|---|---|---|---|---|
| L-01 | Live hardware integration | Single conversion and release | Claim one regular `amdgpu` GPU with VFIO configuration, inspect binding, release the claim, and inspect again. | GPU returns to `amdgpu`; no stale VFIO entry or conversion record remains. | **Complete — live**; `gpu-1-128` converted to `vfio-pci` and returned to `amdgpu`. |
| L-02 | Live hardware integration | Two independent conversions | Prepare claims A and B on different GPUs, then release A and B in both orders. | Releasing one claim does not affect the other; both GPUs eventually return to their original drivers. | **Complete — live**; both release orders passed for `gpu-1-128` and `gpu-17-144`. |
| L-03 | Kubernetes integration | ResourceSlice during conversion | Capture slices before Prepare, during Prepare, after Unprepare, and after republish. | Converted GPU keeps its original name/type and is not advertised as a free duplicate VFIO device. | **Complete — live**; the clean post-reboot rerun published all 8 GPUs before, during, and after the test, and the harness confirmed the final 8-device topology. |
| L-04 | Live hardware integration | Active-conversion restart | Prepare a claim, restart the DRA plugin before Unprepare, then release the claim. | Checkpoint recovery prevents the converted GPU from being advertised as free and restores the original driver on release. | **Complete — live**; distinct old/new plugin UIDs were verified and checkpoint recovery restored the GPU. |
| L-05 | Live hardware integration | Name collision protection | Use a converted GPU alongside a real pre-bound VFIO GPU and inspect device names. | Converted and pre-bound devices have unique names and remain separately addressable. | **Complete — live**; `gpu-1-128` and independent `gpu-vfio-0` remained distinct. |
| L-06 | Live hardware integration | Failed rebind retry | Use an isolated device or controlled test mechanism to make the original-driver rebind fail, then restore the condition and retry. | Failure leaves the record and error visible; retry restores the GPU and removes the record. | **Complete — live**; `amdgpu` bind mode `000` retained the conversion checkpoint, and restoring mode `200` let kubelet retry and return `gpu-1-128` to `amdgpu`. |
| L-07 | Live hardware integration | Missing VFIO manager | Prevent VFIO-manager initialization on an isolated test instance and run cleanup. | Cleanup does not falsely report success; restoration succeeds after the manager returns. | Not tested; fake/component coverage exists. |
| L-08 | Kubernetes integration | Stranded claim | Interrupt or simulate an incomplete claim lifecycle, then invoke cleanup. | Cleanup retries restoration and does not discard state before hardware recovery. | **Complete — live**; deleting the consumer while the plugin was unavailable left the claim recoverable, and the replacement plugin restored `gpu-1-128` and cleared the checkpoint. |

## Checkpoint compatibility scenarios

| ID | Type | Scenario | Expected result | Status |
|---|---|---|---|---|
| C-01 | Component | Load an older checkpoint with no `vfioConversions`. | Checkpoint remains readable and starts with no recovered conversions. | Automated complete. |
| C-02 | Component | Load a checkpoint with an empty conversion map. | Field is omitted or treated as empty without changing behavior. | Automated complete. |
| C-03 | Component | Round-trip a populated conversion map. | Claim UID, PCI address, original driver, and device identity survive serialization. | Automated complete. |
| C-04 | Component | Downgrade while a conversion is active. | Checksum/compatibility behavior fails safely and does not silently lose recovery state. | Automated complete; operational validation pending. |

## KubeVirt end-to-end scenarios

KubeVirt is optional for PR #122. These tests verify that a VM lifecycle does
not leave the underlying GPU incorrectly bound or advertised, but they do not
replace driver-level lifecycle tests.

| ID | Type | Scenario | Expected result | Status |
|---|---|---|---|---|
| K-01 | End-to-end (KubeVirt) | VM claim preparation | VM claim prepares the expected GPU and the VM starts. | **Complete — live, harness-backed (GIM VF)**; the harness selected `gpu-vfio-0`, the VFIO claim was reserved for the virt-launcher pod, and the VMI reached `Running`/`Ready=True`. The separate PF passthrough attempt remains a live failure because the host rebooted during GPU reset. |
| K-02 | End-to-end (KubeVirt) | VM deletion and release | Deleting the VM/claim releases the selected device without disturbing PF ownership. | **Complete — live, harness-backed (GIM VF)**; the harness deleted the VMI and claim, the temporary namespace became absent, all eight PFs remained bound to `gim`, all eight VFs remained bound to `vfio-pci`, and the DRA checkpoint was empty. |
| K-03 | End-to-end (KubeVirt) | Restart during VM use | Restarting the DRA plugin does not make the in-use GPU appear free. | **Complete — live, harness-backed (GIM VF)**; the harness held a `Running`/`Ready=True` VMI and its allocated `gpu-vfio-0` claim while the DRA pod changed from UID `96b18fa9-3b4d-4b89-88d2-834179fcae9c` to replacement UID `1f9c1e9f-2f81-4197-a053-321a0858fa9b`. The claim stayed reserved for the same virt-launcher, the VMI stayed running, and normal cleanup left an empty checkpoint and all eight PFs/VFs bound to `gim`/`vfio-pci`. |

## Evidence package for an AMD review

For each live run, save:

- Host hardware, kernel, driver, GIM, and DRA driver commit.
- PCI address and original driver for every test GPU.
- ResourceClaims and allocation results.
- ResourceSlices before conversion, during conversion, and after release.
- DRA driver logs for Prepare, Unprepare, rollback, and restart recovery.
- Checkpoint contents before and after Prepare, Unprepare, and restart.
- CDI YAML and device binding information.
- VM/VMI YAML and guest output, if KubeVirt is tested.
- A row-by-row result table using the IDs in this document.

Current live evidence is under
`/home/jhull/dra-test-work/evidence/pr122-vfio-lifecycle/live/` on the test
host. The PR #122 image was `localhost/k8s-gpu-dra-driver:pr122-vfio-lifecycle-c6ebfe8b89c3`.
The clean restart evidence is in `live/restart-clean/`; the post-reboot
harness output is `harness-amdgpu-clean.log`.
The independent pre-bound-device collision evidence is in
`live/collision-clean/`.
The stranded-claim evidence is in `live/stranded-clean/`; the failed-rebind
evidence is in `live/failed-rebind-verified/`. The KubeVirt attempt and host
reboot evidence are in `live/kubevirt-verified/`. The initial successful GIM
VF KubeVirt lifecycle evidence is in `live/kubevirt-gim-vf/`. The
harness-backed lifecycle evidence is in `live/kubevirt-harness-gim-vf/`,
including the harness log and before/after PF/VF binding and checkpoint state.
The K-03 restart-during-use harness log is
`/home/jhull/dra-test-work/evidence/pr122-vfio-lifecycle/k03-harness.log`.

## 2026-09-30 non-GIM MI355X validation addendum

The node was booted directly into `amdgpu` with GIM disabled. The harness
passed single-PF conversion and release for `LegacyOnly`, `PreferIommuFD`, and
`RequireIommuFD`; the driver restored the PF to `amdgpu` after each claim was
deleted. Direct allocation of the advertised `type=vfio` PF sibling also
passed and restored the original `amdgpu` entry.

A two-PF `RequireIommuFD` claim passed as supplemental multi-device evidence:
both PFs were converted, logged `backend=iommufd`, and were independently
restored to `amdgpu`. The combined non-GIM harness run also passed resource
publication, counters, sibling exclusion, capacity exhaustion, release, and
driver restart with no active conversion.

Evidence is saved under
`/home/jhull/dra-test-work/evidence/pr122-vfio-lifecycle/non-gim-release`,
`/home/jhull/dra-test-work/evidence/pr114-122/non-gim-prefer-iommufd`,
`/home/jhull/dra-test-work/evidence/pr114-122/non-gim-require-iommufd`, and
`/home/jhull/dra-test-work/evidence/pr114-122/non-gim-multidevice`.

Still outstanding are independent simultaneous claims released in both
orders, restart while a conversion is active, controlled rebind-failure and
missing-manager cases, and the optional KubeVirt lifecycle tests. KubeVirt
PF passthrough remains deferred pending the VFIO aperture work.

## Final assessment

PR #122 has broad automated coverage and live evidence for single conversion
and release, independent multi-claim ownership in both release orders,
checkpoint persistence, active-conversion plugin restart recovery, stable
converted-device identity, and collision protection with an independent
pre-bound VFIO device. Live stranded-claim cleanup and failed-rebind retry
also passed. Missing-VFIO-manager behavior remains live-unverified because
disabling the manager is host-wide on the only test node. The optional
KubeVirt PF passthrough attempt failed when the host encountered PCIe AER/NMI
errors during GPU reset and rebooted. The GIM VF KubeVirt lifecycle then
passed through the harness: the VMI reached `Running`/`Ready=True`, the VMI
and claim were deleted, the temporary namespace disappeared, all eight PFs
remained on `gim`, all eight VFs remained on `vfio-pci`, and the checkpoint was
empty. The harness then held a running GIM VF-backed VMI across a DRA plugin
restart; the claim remained reserved and cleanup again left the checkpoint
empty with all PFs/VFs intact.
