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
| Build and race validation | Build/static + concurrency/race | **Complete — automated; rerun needed** | PR reports uncached tests and race tests passing. | Rerun after rebasing onto final PR #114. |
| Per-claim bookkeeping | Unit + component | **Complete — automated** | Tests cover two claims and independent conversion records. | Confirm on final branch. |
| Failed-rebind handling | Component | **Complete — automated** | Failed rebind remains recorded and returns an error. | Controlled live test remains optional. |
| Prepare rollback | Component | **Complete — automated** | Tests cover invalid policy, CDI failure, checkpoint failure, and multi-device failure. | Confirm all failure paths after rebase. |
| Checkpoint persistence | Component | **Complete — automated** | Empty and populated conversion checkpoint cases are covered. | Verify restart behavior on a disposable live device. |
| Restart recovery | Kubernetes integration | **Complete — automated; live pending** | Tests recover converted devices through Unprepare. | Test plugin restart while a conversion is active. |
| ResourceSlice identity | Component + Kubernetes integration | **Complete — automated; live pending** | Converted devices retain original names, types, and attributes. | Verify no collision with a pre-bound VFIO device on hardware. |
| Missing VFIO manager | Component | **Complete — automated; live pending** | Cleanup retains state when restoration cannot be performed. | Verify with an isolated test device or controlled fake. |
| KubeVirt lifecycle | End-to-end (KubeVirt) | **Optional; not tested** | VM passthrough can exercise claim preparation and release. | Not required for core PR #122 acceptance. |

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
| L-01 | Live hardware integration | Single conversion and release | Claim one regular `amdgpu` GPU with VFIO configuration, inspect binding, release the claim, and inspect again. | GPU returns to `amdgpu`; no stale VFIO entry or conversion record remains. | Not tested for PR #122. |
| L-02 | Live hardware integration | Two independent conversions | Prepare claims A and B on different GPUs, then release A and B in both orders. | Releasing one claim does not affect the other; both GPUs eventually return to their original drivers. | Not tested. |
| L-03 | Kubernetes integration | ResourceSlice during conversion | Capture slices before Prepare, during Prepare, after Unprepare, and after republish. | Converted GPU keeps its original name/type and is not advertised as a free duplicate VFIO device. | Not tested. |
| L-04 | Live hardware integration | Active-conversion restart | Prepare a claim, restart the DRA plugin before Unprepare, then release the claim. | Checkpoint recovery prevents the converted GPU from being advertised as free and restores the original driver on release. | Not tested. |
| L-05 | Live hardware integration | Name collision protection | Use a converted GPU alongside a real pre-bound VFIO GPU and inspect device names. | Converted and pre-bound devices have unique names and remain separately addressable. | Not tested. |
| L-06 | Live hardware integration | Failed rebind retry | Use an isolated device or controlled test mechanism to make the original-driver rebind fail, then restore the condition and retry. | Failure leaves the record and error visible; retry restores the GPU and removes the record. | Not tested; perform only if safe. |
| L-07 | Live hardware integration | Missing VFIO manager | Prevent VFIO-manager initialization on an isolated test instance and run cleanup. | Cleanup does not falsely report success; restoration succeeds after the manager returns. | Not tested; fake/component coverage exists. |
| L-08 | Kubernetes integration | Stranded claim | Interrupt or simulate an incomplete claim lifecycle, then invoke cleanup. | Cleanup retries restoration and does not discard state before hardware recovery. | Not tested. |

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
| K-01 | End-to-end (KubeVirt) | VM claim preparation | VM claim converts the expected GPU and the VM starts. | Optional; not tested for PR #122. |
| K-02 | End-to-end (KubeVirt) | VM deletion and release | Deleting the VM/claim restores the original GPU driver. | Optional; not tested. |
| K-03 | End-to-end (KubeVirt) | Restart during VM use | Restarting the DRA plugin does not make the in-use GPU appear free. | Optional; not tested. |

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

## Final assessment

PR #122 has broad automated coverage for claim ownership, rollback,
checkpoint persistence, restart recovery, naming, and missing-manager
behavior. The remaining approval-critical evidence is live validation of one
conversion, multiple claims, active-conversion restart recovery, and stable
ResourceSlice identity on an available AMD VFIO-capable system. Controlled
failure injection should remain isolated or fake-based; it should not disrupt
a production GPU workload.
