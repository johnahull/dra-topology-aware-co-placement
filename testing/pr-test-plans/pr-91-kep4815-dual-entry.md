# PR #91 test plan and evidence matrix: KEP-4815 dual entries

Upstream PR: [ROCm/k8s-gpu-dra-driver#91](https://github.com/ROCm/k8s-gpu-dra-driver/pull/91)

Use the [live runbook](live-runbooks/pr-91-kep4815-live.md) when the lab is
ready. Its command entry point is `TEST_FEATURES=dra make run-tests` in
[`k8s-dra-harness`](https://github.com/johnahull/k8s-dra-harness), with
`DRA_HARNESS_CONFIG` pointing at a copied, mode-specific `examples/pr91` YAML.
Each host-mode or VF-count change needs a new node-local PCI inventory.

## Current contract

- A non-VF amdgpu GPU without active VFs is published as one compute device
  and one direct-VFIO device with the same PCI identity. Their only shared
  counter is capacity-1 `fn-<BDF>` in `pf-<BDF>-counter-set`.
- The Helm chart creates separate `gpu.amd.com` compute and
  `gpu.amd.com-vfio` classes. With AutoPartition it also creates
  `gpu.amd.com-spx` for whole-GPU extended-resource requests.
- A GIM PF is not advertised. Each eligible GIM VF is a distinct VFIO
  device. GIM VFs and pre-bound VFIO PFs consume no shared counter.
  `vf-slots` is not published anywhere.
- VFIO devices omit `partitionProfile`. GIM VF memory, CU, and SIMD
  capacities follow the current PF-source/active-VF-count calculation;
  that is not a claim that the guest's actual CPX profile is known.
- A PF with active VFs or an unreadable `sriov_numvfs` is withheld from
  PF passthrough. Invalid counts are covered with fake sysfs rather than
  by trying to corrupt kernel-maintained sysfs on a live node.
- A direct PF claim records its original binding. Restart while held
  publishes its VFIO entry alone; release returns the PF to amdgpu and
  republishes both entries and their counter. An unreadable checkpoint
  fails startup with VFIO enabled and quarantines publication with it off.

Accurate publication of a GIM VF's actual partition profile remains
[issue #139](https://github.com/ROCm/k8s-gpu-dra-driver/issues/139).
The real Kubernetes allocator test was split into draft PR #133; live
scheduler tests below remain part of PR #91 validation.

## Current run matrix

`PENDING` means the final PR image has not yet been rerun on that case.
Historical runs are listed below and are not a substitute for a run of the
current image.

| ID | Test and method | Required result | Status |
|---|---|---|---|
| A-01 | Run driver `go test ./...`, race tests, vet, Helm DeviceClass script; run harness unit tests and host-inventory self-check. | All pass on pinned commits. | PENDING |
| H-01 | Capture PCI inventory and current ResourceSlices on MI300X with amdgpu and no VFs; harness `mi300x-dual`. | Exactly one compute/VFIO pair per eligible PF, BDF-stable names, matching capacity, one function counter per pair, no `vf-slots`. | PENDING |
| H-02 | Inspect rendered and live DeviceClasses; harness strict class snapshot. | Compute class excludes VFIO; VFIO class excludes compute; guarded `isVF` selector resolves only on VFIO. | PENDING |
| H-03 | Real scheduler allocation in both sibling orders on a PF-safe platform; use PR #133 allocator test with saved MI300X slices as supplemental evidence. | Same-BDF siblings never allocate together; a different eligible GPU can be selected. | PENDING; PF-safe hardware needed |
| H-04 | Harness `mi300x-auto` with both feature gates. | SPX and partition candidates have valid mutex counters, no synthetic VFIO sibling, `gpu.amd.com-spx` exists, all slices stay within API limits. | PENDING |
| H-05 | Harness `mi300x-gim` at one VF and one supported multi-VF count. | GIM PF absent; each eligible VF has `isVF=true`, no counter/profile, stable BDF, capacity divided by active VF count; allocation exhausts at the number of VF devices. | PENDING; multi-VF only if supported |
| H-06 | Drain and configure zero GIM VFs; inspect publication directly. | No GIM PF or VF device is advertised; restoring a supported count and restarting restores VF discovery. | PENDING |
| H-07 | Harness `mi300x-gim-vmi`, with guest SSH verification. | VMI runs, guest sees AMD VF, deletion releases the claim and preserves original VF binding. | PENDING; KubeVirt DRA required |
| H-08 | Back up and corrupt an idle node's checkpoint; restart with VFIO on, then off, then restore. | Gate-on startup fails; gate-off publishes no devices; exact backup restores normal publication. | PENDING; isolated node required |
| H-09 | Harness `mi350p-qualify` on each of two disposable PFs, one at a time. | Direct claim binds VFIO; release returns amdgpu, PCI config remains readable, and both entries/counter return. | CONDITIONAL; MI350P availability and PF safety |
| H-10 | Harness `mi350p-direct` after both PFs qualify. | Both exclusion orders, targeted active-claim restart, and both two-claim release orders pass without stale binding, checkpoint, or ResourceSlice state. | CONDITIONAL; requires H-09 |
| H-11 | Optional `mi350p-prebound` and `mi350p-direct-vmi`. | Pre-bound PF remains VFIO-only without capacity/counter; PF VMI result separates guest aperture/boot from driver Prepare/CDI success. | CONDITIONAL |

The MI300X profile deliberately creates **no full-PF VFIO consumer**.
[Prior MI300X testing](../results/xe9680-mi300x-gim-vf-session-2026-06-02.md)
found that a VFIO reset could leave PCI config space unreadable until reboot.
If MI350P is absent or does not safely rebind, H-03/H-09/H-10 remain
`BLOCKED`; automated tests do not turn that into full live PF coverage.

## Coverage of every PR commit

| Commit(s) | Evidence |
|---|---|
| `c058cbb`, `1afd1b6`, `6437df2` | H-01 dual publication, names, and counters; A-01 component tests. |
| `af74265`, `66f8061`, `a18f7e3` | H-05/H-06 real GIM count and PF suppression; A-01 malformed-count and active-VF fake-sysfs tests. |
| `a9dc084`, `b3e6069` | H-01/H-03 function-only counters and scheduler exclusion; supplemental PR #133 allocator test. |
| `2690589`, `900bff9` | H-02 Helm and live classes, guarded `isVF` selection. |
| `a4790cd`, `ecfd60c`, `16f49dd` | H-05 absent inferred profile and correct MI300X per-VF capacity; A-01 capacity unit tests. |
| `134c99e`, `0f857dc` | H-08/H-09/H-10 checkpoint, direct bind, restart, and release; A-01 rollback/failed-release component tests. |

MI300X GIM PF CU/SIMD inputs in the current table are 304/1216. MI325X
and MI355X have separate mappings; **MI350P is not mapped in this PR**.
For MI350P, record the actual PF PCI ID first. If it is unmapped, the
driver omits CU/SIMD capacity and logs a warning; report that as a
support gap rather than silently passing capacity accuracy.

## Evidence and sign-off

Store each run under
`/home/jhull/dra-test-work/evidence/pr91-<date>-<commit>/` with:
node inventory, feature gates and Helm values, image digest, before/during/after
ResourceSlices, DeviceClasses and ResourceClaims, driver logs, CDI specs,
host binding and VF-count snapshots, counter reports, and VMI/guest output.
For every row record `PASS`, `FAIL`, `BLOCKED`, or `NOT APPLICABLE`, the
reason, and its evidence path. The run is clean only when harness-owned
consumers and claims are gone and host bindings match the phase baseline.

Earlier MI355X and MI300X sessions predate the latest review fixes. Their
raw evidence is referenced in the Git history of this file and in
[`testing/results`](../results/); treat it as background, not a current
acceptance result.
