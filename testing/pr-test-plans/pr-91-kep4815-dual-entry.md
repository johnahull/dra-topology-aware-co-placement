# PR #91 test plan and evidence matrix: KEP-4815

Upstream PR: [ROCm/k8s-gpu-dra-driver#91](https://github.com/ROCm/k8s-gpu-dra-driver/pull/91)

## What this PR is testing

PR #91 changes how the AMD GPU DRA driver advertises and allocates GPUs:

- A compute GPU can be advertised as both `type=amdgpu` and `type=vfio`.
- Shared counters prevent a compute entry and its VFIO sibling from being
  allocated together.
- SR-IOV PFs and VFs share a `vf-slots` counter set.
- VF capacity and partition-profile attributes are published.
- Direct `type=vfio` claims work for devices already suitable for VFIO.
- ResourceSlices remain valid at Kubernetes API size limits.
- Resource publication is synchronized while claims are prepared or released.
- GPU-to-VFIO conversion state is tracked per claim.

The current design enforces sibling exclusion at scheduler allocation time with
counters. The older PR description that removes a sibling only after Prepare
is stale and is not the expected behavior for the current branch.

## Status legend

| Status | Meaning |
|---|---|
| **Complete — automated** | Covered by tests in the PR branch; rerun after the final rebase. |
| **Complete — live** | Observed on hardware or in a live Kubernetes/KubeVirt deployment. |
| **Partial** | A related path was tested, but not the PR #91 behavior end to end. |
| **Not tested** | No evidence is currently recorded. |
| **Not applicable** | The test belongs to another PR or requires infrastructure outside this PR. |

## Test type definitions

| Type | Meaning |
|---|---|
| **Unit** | Tests one helper or algorithm with in-memory inputs and no Kubernetes or hardware. |
| **Component** | Exercises driver discovery, lifecycle, CDI, checkpoint, or ResourceSlice code with fakes. |
| **Scheduler integration** | Runs the Kubernetes DRA allocator against published ResourceSlices. |
| **Kubernetes integration** | Uses a live API server, DRA driver, ResourceClaims, and ResourceSlices. |
| **Live hardware integration** | Uses real GPUs, GIM/SR-IOV VFs, kernel drivers, and device nodes. |
| **Concurrency/race** | Exercises concurrent driver operations and race detection. |
| **End-to-end (KubeVirt)** | Allocates a real claim to a VM and verifies the running guest. |

## Executive status

| Area | Type | Current status | What the evidence shows | Remaining gap |
|---|---|---|---|---|
| Build and static checks | Build/static | **Complete — automated; rerun needed** | The PR reports build, unit tests, vet, and pre-commit checks passing. | Rerun after the latest commits and final rebase. |
| KEP-4815 unit/resource tests | Unit + component | **Complete — automated; rerun needed** | Counter, partition, discovery, lifecycle, chunking, scheduler, and concurrency tests were added. | Confirm the complete suite passes on the final branch. |
| GIM VF discovery and VFIO CDI | Live hardware integration | **Partial live evidence** | GIM VFs were discovered, CDI was generated, and VFs were passed to KubeVirt. | This does not prove PR #91 dual-entry or counter behavior. |
| Dual `amdgpu`/`vfio` advertising | Kubernetes integration | **Not verified live** | No final live ResourceSlice capture is recorded for both sibling entries. | Capture ResourceSlices with the gate enabled and disabled. |
| KEP-4815 counters | Kubernetes integration | **Partial** | Automated assertions exist; an earlier live `dra-verify.sh counters` run found no shared counter sets. | Re-run against the final PR #91 image. |
| Per-VF capacity and profiles | Live hardware + Kubernetes integration | **Not verified PR #91 live** | Earlier VFIO/topology sessions did not validate the final PR #91 attributes. | Test supported VF counts on the available AMD system. |
| Scheduler sibling exclusion | Scheduler integration | **Complete — automated; live pending** | Scheduler allocator tests cover PF/VF and compute/VFIO exclusion. | Verify with real ResourceClaims and ResourceSlices. |
| Direct VFIO claim lifecycle | Component + live hardware integration | **Complete — automated; live pending** | Prepare/Unprepare tests cover direct `type=vfio` claims. | Verify claim, CDI, release, and driver restoration on hardware. |
| ResourceSlice chunking | Unit | **Complete — automated** | Boundary tests cover counter-set and device limits. | Live validation is optional. |
| Publication locking | Concurrency/race | **Complete — automated** | Concurrent publication and claim tests exist, including race-sensitive coverage. | No separate live test is required. |
| KubeVirt integration | End-to-end (KubeVirt) | **Partial live evidence** | GPU VF passthrough and two-GPU guest visibility were demonstrated. | Direct `type=vfio` and sibling-exclusion VM tests remain. |

## Automated test scenarios

| ID | Type | Scenario | How it is tested | Expected result | Evidence/status |
|---|---|---|---|---|---|
| A-01 | Build/static | Build and static validation | Run `go build ./...`, `go test ./...`, `go vet ./...`, and repository pre-commit checks. | All commands pass without generated or race-related failures. | Reported complete; rerun after final commits. |
| A-02 | Unit | Partition profile mapping | Exercise supported VF counts and the partition-mode helper, including the three-VF TPX case. | Each recognized VF count maps to the expected profile; unsupported values do not fabricate one. | Automated coverage reported complete. |
| A-03 | Unit | Per-VF capacity | Divide PF memory, compute, and SIMD totals by configured VF count. | Every VF receives the expected capacity and the PF total is preserved. | Automated coverage reported complete. |
| A-04 | Component | VFIO parent discovery | Resolve PF/VF relationships through `physfn` and validate active/total VF counts. | Parent metadata is correct and VFs are associated with the correct PF. | Automated coverage reported complete. |
| A-05 | Component | Shared-counter publication | Build ResourceSlices containing PF `vf-slots` and device consumption. | Every consumed counter set is published and every reference resolves. | Automated coverage reported complete; live verification pending. |
| A-06 | Scheduler integration | Scheduler sibling exclusion | Run the Kubernetes DRA allocator against published slices with partitionable devices enabled. | Compute/VFIO siblings cannot be allocated together; another GPU can be selected. | Automated coverage reported complete; live verification pending. |
| A-07 | Component | Direct VFIO lifecycle | Prepare and unprepare a direct `type=vfio` claim using a CDI handler and checkpoint manager. | CDI is returned, the device is prepared, and release restores the expected state. | Automated coverage reported complete; live hardware test pending. |
| A-08 | Unit | ResourceSlice limits | Test 9 counter sets, 64/65 counter-consuming devices, 129 non-counter devices, and an empty node. | Slices respect API limits; no devices or counters are duplicated or lost. | Automated coverage reported complete. |
| A-09 | Concurrency/race | Publication concurrency | Run Prepare/Unprepare while slices are rebuilt and run the race detector. | No concurrent map access, stale publication, duplicate device, or lost device. | Automated coverage reported complete; rerun required. |
| A-10 | Component | Per-claim conversion records | Prepare two claims and release them in either order. | One claim cannot overwrite another claim's conversion record. | Automated coverage reported complete; live hardware test pending. |
| A-11 | Scheduler integration | Mixed compute/VFIO VF case | Exercise the synthetic case where both entries share a VF PCI address. | Both entries consume the same function-level counter. | Automated-only coverage; normal discovery does not currently produce this case. |

## Live hardware and Kubernetes scenarios

Run these on an available AMD SR-IOV/GIM-capable system. Record the GPU
model, GIM and AMD driver versions, kernel, Kubernetes version, DRA driver
commit, feature-gate settings, and configured VF counts.

| ID | Type | Scenario | How to verify | Expected result | Status/notes |
|---|---|---|---|---|---|
| L-01 | Live hardware integration | Baseline hardware inventory | Capture PCI devices, GIM-created VFs, VF drivers, IOMMU groups, and PF/VF relationships. | The test inventory is stable and each VF has an unambiguous PCI identity and parent PF. | Prior GIM/VF evidence exists; new PR #91 run required. |
| L-02 | Kubernetes integration | Dual-entry publication | Inspect `kubectl get resourceslices -o yaml` after enabling `VFIOPassthrough`. | Eligible GPUs have matching `amdgpu` and `vfio` entries with the same PCI identity. | Not verified live for the final PR #91 branch. |
| L-03 | Kubernetes integration | Feature-gate negative case | Disable `VFIOPassthrough`, restart/redeploy the driver, and inspect ResourceSlices. | VFIO entries are absent; ordinary compute entries remain correct. | Not tested live. |
| L-04 | Kubernetes integration | PF/VF counter publication | Run `./testing/scripts/dra-verify.sh counters` and inspect ResourceSlices. | PFs publish `vf-slots`; VFs consume one slot; PFs consume the full slot set. | Earlier live run found no shared counter sets; final image must be rechecked. |
| L-05 | Kubernetes integration | Function-level sibling counter | Inspect paired entries and their `consumesCounters` fields. | Both `amdgpu` and `vfio` entries for one GPU consume the same `fn-<pci-bdf>` counter. | Not verified live. |
| L-06 | Kubernetes integration | Compute allocation | Create a normal `amdgpu` ResourceClaim and inspect allocation status and CDI/device result. | The compute entry is allocated and its VFIO sibling remains scheduler-ineligible. | Not verified live for PR #91. |
| L-07 | Live hardware integration | Direct VFIO allocation | Create a `type=vfio` ResourceClaim for a pre-bound or directly usable VF. | The claim allocates, Prepare returns the VFIO CDI device, and the device is usable. | VFIO passthrough was live-tested; direct dual-entry semantics remain pending. |
| L-08 | Scheduler integration | Scheduler conflict | Submit claims for both entries of one GPU, in both allocation orders. | The second conflicting claim remains pending or is rejected; it cannot acquire the sibling. | Automated coverage exists; live test pending. |
| L-09 | Scheduler integration | Alternate-device selection | Request a VFIO device when one GPU's compute sibling is allocated. | The scheduler selects another eligible GPU instead of violating sibling exclusion. | Not tested live. |
| L-10 | Kubernetes integration | Claim release | Delete the claim and inspect ResourceSlices, claims, CDI, and driver binding. | Counters are released, the expected entry returns, and no stale allocation remains. | Automated coverage exists; live test pending. |
| L-11 | Live hardware integration | VF-count matrix | Reconfigure only VF counts supported by GIM on the test platform. Start with 1, 2, 4, and 8 where available; include 3 if TPX is exposed. | `partitionProfile`, per-VF capacity, total `vf-slots`, and allocation limits match the configured count. | Not tested for PR #91; MI355X should be recorded separately from MI300X. |
| L-12 | Live hardware integration | Multi-VF capacity exhaustion | Allocate VFs until the PF's available slots are consumed, then request one more. | Allocations succeed up to the limit and the next request cannot be allocated. | Not tested live. |
| L-13 | Scheduler integration | PF exclusion | Allocate a PF, or the largest PF-level resource available in the test configuration, while VFs are free. | All sibling VF allocations are blocked by the shared counter. | Not tested live. |
| L-14 | Kubernetes integration | Driver restart without active conversion | Restart the driver with no active conversion and inspect ResourceSlices. | Publication returns with stable names, devices, and counters. | Not tested specifically for the latest branch. Active conversion recovery belongs to PR #122. |

### Per-VF attributes to capture

For each tested VF count, save the ResourceSlice fields below and compare them
with the PF's discovered capacity:

| Attribute | Expected evidence |
|---|---|
| `memory` | PF memory divided by configured VF count. |
| `computeUnits` | PF compute total divided by configured VF count. |
| `simdUnits` | PF SIMD total divided by configured VF count. |
| `partitionProfile` | Profile derived from the actual GIM partition mode. |
| `vf-slots` | PF counter total equals the configured VF capacity. |
| `consumesCounters` | Each VF consumes one slot; PF or sibling entries consume the documented set. |

Do not assume MI300X values or VF-count mappings apply to MI355X. Record the
platform-reported supported counts and treat unsupported counts as skipped, not
failed.

## KubeVirt integration scenarios

The existing [MI300X GIM/VF session](../results/xe9680-mi300x-gim-vf-session-2026-06-02.md)
and [MI355X topology session](../results/xe9785l-mi355x-dra-topology-session-2026-06-23.md)
demonstrate related VFIO and topology behavior, but they are not all PR #91
acceptance tests.

| ID | Type | Scenario | Expected result | Status |
|---|---|---|---|---|
| K-01 | End-to-end (KubeVirt) | GPU VF passthrough | VM starts and detects the GPU VF. | Complete — prior live evidence. |
| K-02 | End-to-end (KubeVirt) | Two-GPU VM | Both allocated GPU VFs are visible in the guest. | Complete — prior live evidence. |
| K-03 | End-to-end (KubeVirt) | Direct `type=vfio` VM claim | VM receives the directly claimed VFIO device and its CDI entry. | Not tested for PR #91. |
| K-04 | End-to-end (KubeVirt) | VM sibling exclusion | A compute claim and its VFIO sibling cannot be allocated to conflicting workloads. | Automated coverage exists; live VM test pending. |
| K-05 | End-to-end (KubeVirt) | VM deletion and release | The claim is released, counters are freed, and the original allocatable entry returns. | Not tested for PR #91. |

Guest NUMA and PCIe-topology validation is useful integration evidence, but it
does not by itself prove KEP-4815 dual-entry or counter behavior.

## Evidence package for an AMD review

For each live run, save:

- Host inventory and supported VF-count output.
- Driver image tag and commit.
- Feature-gate configuration.
- DeviceClasses and ResourceSlices before allocation.
- ResourceClaims and allocation results.
- ResourceSlices after allocation and after release.
- `./testing/scripts/dra-verify.sh counters` output.
- Driver logs covering discovery, Prepare, Unprepare, and republish.
- CDI YAML for each VFIO claim.
- VM/VMI YAML and guest `lspci` output, if KubeVirt is tested.
- A row-by-row result table using the IDs in this document.

Useful repository helpers are:

- [`dra-verify.sh`](../scripts/dra-verify.sh)
- [`dra-counters.py`](../scripts/dra-counters.py)
- [`test_dra_counters.py`](../scripts/test_dra_counters.py)
- [`vfio-gpu-test.yaml`](../manifests/claims/vfio-gpu-test.yaml)

## Final assessment

PR #91 has broad automated coverage and prior live evidence for AMD GIM VFIO
passthrough. The remaining approval-critical evidence is live validation of
the final branch's dual entries, `vf-slots` and function-level counters,
sibling exclusion, per-VF capacity across supported VF counts, and direct
VFIO claim release. MI355X should be reported as a separate hardware run; its
partition modes and capacity values must be measured rather than inferred from
the earlier MI300X session.
