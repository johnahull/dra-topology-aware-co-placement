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
| GIM VF discovery and VFIO CDI | Live hardware integration | **Complete — live for pre-bound VFIO** | On the MI355X GIM configuration, VFs were discovered, CDI was generated, and VFIO resource/release checks passed. | This does not prove PR #91 dual-entry or counter behavior. |
| Dual `amdgpu`/`vfio` advertising | Kubernetes integration | **Complete — live** | The non-GIM MI355X ResourceSlices published 16 devices: paired `amdgpu` and `vfio` entries sharing each PF PCI identity. | No remaining dual-entry publication gap. |
| KEP-4815 counters | Kubernetes integration | **Complete — live** | `dra-verify.sh counters` resolved both logical siblings to the same function-level counter and showed one active claim consuming the shared capacity once. | No remaining live counter gap for the SPX/one-VF configuration. |
| Per-VF capacity and profiles | Live hardware + Kubernetes integration | **Partial — live for SPX/one-VF configuration** | The harness captured eight MI355X GIM VFs with `partitionProfile=spx`, `computeUnits=256`, and `simdUnits=1Ki` per VF. | Re-run after switching the host to NPS2/DPX to validate multi-VF profiles and capacities. |
| Scheduler sibling exclusion | Scheduler integration | **Complete — automated and live** | Both allocation orders left the compute/VFIO sibling pending, and an unqualified VFIO request selected another PCI identity when the first GPU was occupied. | No remaining live scheduler gap for the dual-entry configuration. |
| Direct VFIO claim lifecycle | Component + live hardware integration | **Complete — automated and live** | Prepare/Unprepare tests and the non-GIM harness run covered direct dual-entry VFIO claims, CDI, release, and restoration to `amdgpu`. | KubeVirt direct-claim coverage remains separate. |
| ResourceSlice chunking | Unit | **Complete — automated** | Boundary tests cover counter-set and device limits. | Live validation is optional. |
| Publication locking | Concurrency/race | **Complete — automated** | Concurrent publication and claim tests exist, including race-sensitive coverage. | No separate live test is required. |
| KubeVirt integration | End-to-end (KubeVirt) | **Partial live evidence** | GPU VF passthrough and two-GPU guest visibility were demonstrated. | Direct `type=vfio` and sibling-exclusion VM tests remain for this PR branch. |

## Automated test scenarios

| ID | Type | Scenario | How it is tested | Expected result | Evidence/status |
|---|---|---|---|---|---|
| A-01 | Build/static | Build and static validation | Run `go build ./...`, `go test ./...`, `go vet ./...`, and repository pre-commit checks. | All commands pass without generated or race-related failures. | Reported complete; rerun after final commits. |
| A-02 | Unit | Partition profile mapping | Exercise supported VF counts and the partition-mode helper, including the three-VF TPX case. | Each recognized VF count maps to the expected profile; unsupported values do not fabricate one. | Automated coverage reported complete. |
| A-03 | Unit | Per-VF capacity | Divide PF memory, compute, and SIMD totals by configured VF count. | Every VF receives the expected capacity and the PF total is preserved. | Automated coverage reported complete. |
| A-04 | Component | VFIO parent discovery | Resolve PF/VF relationships through `physfn` and validate active/total VF counts. | Parent metadata is correct and VFs are associated with the correct PF. | Automated coverage reported complete. |
| A-05 | Component | Shared-counter publication | Build ResourceSlices containing PF `vf-slots` and device consumption. | Every consumed counter set is published and every reference resolves. | Automated and live coverage complete. |
| A-06 | Scheduler integration | Scheduler sibling exclusion | Run the Kubernetes DRA allocator against published slices with partitionable devices enabled. | Compute/VFIO siblings cannot be allocated together; another GPU can be selected. | Automated and live coverage complete. |
| A-07 | Component | Direct VFIO lifecycle | Prepare and unprepare a direct `type=vfio` claim using a CDI handler and checkpoint manager. | CDI is returned, the device is prepared, and release restores the expected state. | Automated coverage complete; live pre-bound-VFIO path also passed. |
| A-08 | Unit | ResourceSlice limits | Test 9 counter sets, 64/65 counter-consuming devices, 129 non-counter devices, and an empty node. | Slices respect API limits; no devices or counters are duplicated or lost. | Automated coverage reported complete. |
| A-09 | Concurrency/race | Publication concurrency | Run Prepare/Unprepare while slices are rebuilt and run the race detector. | No concurrent map access, stale publication, duplicate device, or lost device. | Automated coverage reported complete; rerun required. |
| A-10 | Component | Per-claim conversion records | Prepare two claims and release them in either order. | One claim cannot overwrite another claim's conversion record. | Automated and live coverage complete. |
| A-11 | Scheduler integration | Mixed compute/VFIO VF case | Exercise the synthetic case where both entries share a VF PCI address. | Both entries consume the same function-level counter. | Automated-only coverage; normal discovery does not currently produce this case. |

## Live hardware and Kubernetes scenarios

Run these on an available AMD SR-IOV/GIM-capable system. Record the GPU
model, GIM and AMD driver versions, kernel, Kubernetes version, DRA driver
commit, feature-gate settings, and configured VF counts.

| ID | Type | Scenario | How to verify | Expected result | Status/notes |
|---|---|---|---|---|---|
| L-01 | Live hardware integration | Baseline hardware inventory | Capture PCI devices, GIM-created VFs, VF drivers, IOMMU groups, and PF/VF relationships. | The test inventory is stable and each VF has an unambiguous PCI identity and parent PF. | **Complete — live** on XE9785L; eight GIM VFs and their VFIO bindings were inventoried. |
| L-02 | Kubernetes integration | Dual-entry publication | Inspect `kubectl get resourceslices -o yaml` after enabling `VFIOPassthrough`. | Eligible GPUs have matching `amdgpu` and `vfio` entries with the same PCI identity. | **Complete — live**; all eight PFs published paired entries with matching PCI identities. |
| L-03 | Kubernetes integration | Feature-gate negative case | Disable `VFIOPassthrough`, restart/redeploy the driver, and inspect ResourceSlices. | VFIO entries are absent; ordinary compute entries remain correct. | **Complete — live for the GIM-only configuration**; the gate-off ResourceSlice had no VFIO devices, while ordinary `amdgpu` entries were not applicable because all PFs were owned by GIM. |
| L-04 | Kubernetes integration | PF/VF counter publication | Run `./testing/scripts/dra-verify.sh counters` and inspect ResourceSlices. | PFs publish `vf-slots`; VFs consume one slot; PFs consume the full slot set. | **Complete — live** for the non-GIM dual-entry publication. |
| L-05 | Kubernetes integration | Function-level sibling counter | Inspect paired entries and their `consumesCounters` fields. | Both `amdgpu` and `vfio` entries for one GPU consume the same `fn-<pci-bdf>` counter. | **Complete — live**; the active claim reduced the shared counter from `1/1` to `0/1` once. |
| L-06 | Kubernetes integration | Compute allocation | Create a normal `amdgpu` ResourceClaim and inspect allocation status and CDI/device result. | The compute entry is allocated and its VFIO sibling remains scheduler-ineligible. | **Complete — live**; the harness held the compute entry and rejected the same-PCI VFIO sibling. |
| L-07 | Live hardware integration | Direct VFIO allocation | Create a `type=vfio` ResourceClaim for a pre-bound or directly usable VF. | The claim allocates, Prepare returns the VFIO CDI device, and the device is usable. | **Complete — live** for both the prior pre-bound VF path and the non-GIM directly advertised PF sibling. |
| L-08 | Scheduler integration | Scheduler conflict | Submit claims for both entries of one GPU, in both allocation orders. | The second conflicting claim remains pending or is rejected; it cannot acquire the sibling. | **Complete — live, harness-backed**; both allocation orders passed. |
| L-09 | Scheduler integration | Alternate-device selection | Request a VFIO device when one GPU's compute sibling is allocated. | The scheduler selects another eligible GPU instead of violating sibling exclusion. | **Complete — live, harness-backed**; the second claim received a different PCI identity. |
| L-10 | Kubernetes integration | Claim release | Delete the claim and inspect ResourceSlices, claims, CDI, and driver binding. | Counters are released, the expected entry returns, and no stale allocation remains. | **Complete — live for the GIM/pre-bound-VFIO path**. |
| L-11 | Live hardware integration | VF-count matrix | Reconfigure only VF counts supported by GIM on the test platform. Start with 1, 2, 4, and 8 where available; include 3 if TPX is exposed. | `partitionProfile`, per-VF capacity, total `vf-slots`, and allocation limits match the configured count. | **Partial — live**; SPX/`vf_num=1` passed. GIM rejected `vf_num=2` with `VF number 2 ... exceeds the vf limit 1`; NPS2/DPX reconfiguration is deferred. |
| L-12 | Live hardware integration | Multi-VF capacity exhaustion | Allocate VFs until the PF's available slots are consumed, then request one more. | Allocations succeed up to the limit and the next request cannot be allocated. | **Complete — live for the current node capacity**; the harness allocated all eight one-VF devices, left the next allocation unavailable, restarted the driver, and cleaned up. Per-PF multi-VF exhaustion remains deferred with NPS2/DPX. |
| L-13 | Scheduler integration | PF exclusion | Allocate a PF, or the largest PF-level resource available in the test configuration, while VFs are free. | All sibling VF allocations are blocked by the shared counter. | **Complete — live** for the dual PF-entry configuration; the same-PCI sibling was blocked. |
| L-14 | Kubernetes integration | Driver restart without active conversion | Restart the driver with no active conversion and inspect ResourceSlices. | Publication returns with stable names, devices, and counters. | **Complete — live, harness-backed**; the post-reboot capacity/restart run republished all eight devices and completed cleanly. Active conversion recovery belongs to PR #122. |

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

The current GIM/pre-bound-VFIO evidence was collected on the test host under
`/home/jhull/dra-test-work/evidence/pr91-114-122-gim/`. It includes the
gate-negative capture, capacity/restart run, two-device topology run, and
`PreferIommuFD`/`RequireIommuFD` claim-config runs. It does not include the
dual-entry publication that requires a different host driver configuration.

Useful repository helpers are:

- [`dra-verify.sh`](../scripts/dra-verify.sh)
- [`dra-counters.py`](../scripts/dra-counters.py)
- [`test_dra_counters.py`](../scripts/test_dra_counters.py)
- [`vfio-gpu-test.yaml`](../manifests/claims/vfio-gpu-test.yaml)

## 2026-09-30 non-GIM MI355X validation addendum

The server was rebooted into an `amdgpu`-only configuration: GIM was
blacklisted, `sriov_numvfs=0`, and all eight MI355X PFs initialized under
`amdgpu`. The harness used the existing PR #122 driver deployment and the
combined non-GIM profile.

The following live cases passed through the harness:

- Dual `amdgpu`/`vfio` publication with 16 devices and eight shared
  function-level counter sets.
- Shared-counter verification, compute/VFIO sibling exclusion, eight-device
  compute capacity exhaustion, claim release, and a driver restart with no
  active conversion.
- Direct selection of an advertised `type=vfio` PF sibling, followed by
  successful restoration to `amdgpu`.

Evidence is saved under
`/home/jhull/dra-test-work/evidence/pr91-114-122/non-gim` and
`/home/jhull/dra-test-work/evidence/pr91/non-gim-direct-vfio`. After every
case, all eight PFs were bound to `amdgpu` and no ResourceClaims remained.

The feature-gate-negative case, GIM VF-count matrix, and KubeVirt VM cases
were not run in this `amdgpu` pass. KubeVirt PF passthrough remains deferred
until the VFIO aperture issue is revisited.

## 2026-09-30 recommended-gap validation addendum

The extended harness run used the non-GIM `amdgpu` configuration and
verification-repository commit `5db44ee1ed94133b4fea6752bacef31885dbd06a`.
It passed reverse-order sibling exclusion, alternate-device selection, and
the two independent release orders. The active counter capture showed both
logical entries resolving to the same PCI/function counter, with one active
claim reducing that shared capacity once. The active-conversion restart was
also run through the harness as supplemental PR #122 evidence.

Evidence is saved under
`/home/jhull/dra-test-work/evidence/pr91-114-122/non-gim-extended`,
`/home/jhull/dra-test-work/evidence/pr91-114-122/non-gim-release-orders`, and
`/home/jhull/dra-test-work/evidence/pr122-vfio-lifecycle/non-gim-restart-active`.
The harness cleaned each namespace and claim; the final host state had all
eight PFs bound to `amdgpu`.

The remaining PR #91 items are optional KubeVirt direct/sibling cases and the
NPS2/DPX multi-VF profile matrix. The host's supported SPX/one-VF setting was
not changed for this run.

## Final assessment

PR #91 has broad automated coverage and current MI355X live evidence for GIM
VFIO discovery, direct pre-bound-VF claims, CDI, release, gate behavior,
capacity at the supported SPX/one-VF setting, node-level exhaustion, and
restart recovery. The non-GIM validation now also proves the PR #91
dual-entry (`amdgpu` plus `vfio`) view, shared counters, sibling exclusion in
both orders, alternate-device selection, and independent release ordering.
Remaining optional work is the KubeVirt direct/sibling matrix and
multi-VF profile/capacity coverage after switching the host to NPS2/DPX;
MI355X values must be measured on that configuration rather than inferred
from MI300X.
