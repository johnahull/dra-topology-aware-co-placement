# PR #91 test plan: KEP-4815 dual-entry advertising

Upstream PR: [ROCm/k8s-gpu-dra-driver#91](https://github.com/ROCm/k8s-gpu-dra-driver/pull/91)

## Scope

PR #91 covers dual `amdgpu`/`vfio` entries, KEP-4815 shared counters,
scheduler-visible sibling exclusion, per-VF capacity and partition
attributes, direct `type=vfio` claims, ResourceSlice chunking, publication
locking, and per-claim GPU-to-VFIO conversion tracking.

The latest implementation uses scheduler-visible counters for sibling
exclusion. The older description of withdrawing the sibling after Prepare is
stale and must not be used as the expected behavior for the current branch.

## Automated tests

### Reported complete

- `go build ./...`
- `go test ./...`
- `go vet ./...`
- Pre-commit checks.
- Partition-mode mapping, including TPX.
- Per-VF capacity calculation.
- VFIO parent discovery and metadata.
- Shared-counter publication and consumption.
- Direct `type=vfio` Prepare/Unprepare lifecycle.
- ResourceSlice chunking.
- Scheduler allocator sibling exclusion.
- Concurrent Prepare/Unprepare and ResourceSlice publication.
- Per-claim conversion tracking.
- Synthetic mixed compute/VFIO VF coverage.

### Required rerun

Rerun the complete build, test, vet, and race-sensitive test set after the
latest commits and before final approval. Confirm that the scheduler allocator
tests run with partitionable devices enabled.

## Live driver tests

Run these tests on the available AMD SR-IOV/GIM-capable system.

### Hardware matrix

The previous live evidence used an MI300X system. MI355X validation should
be recorded as a separate hardware run because supported VF counts, partition
profiles, and capacity values must be discovered from that platform rather
than assumed from MI300X behavior. PR #91's final hardware validation should
include MI355X when an MI355X system is available.

For each GPU platform, record the GPU model, GIM and driver versions, kernel,
Kubernetes version, DRA driver commit, and the supported VF counts. Test each
supported count; begin with 1, 2, 4, and 8 where available, and include 3 if
the platform exposes TPX.

For every tested VF count, verify:

- `partitionProfile` matches the platform's partition mode.
- Per-VF memory, compute, and SIMD capacity equals the PF capacity divided by
  the configured VF count.
- The PF publishes the correct total `vf-slots` capacity.
- Each VF consumes one slot.
- Allocation succeeds up to the configured VF limit.
- PF allocation blocks all VFs.
- Release restores the expected allocatable state.
- Direct VFIO claims and release/rebinding continue to work.

Do not treat a VF count as supported until the GIM/driver configuration reports
it as available on the test platform.

### Discovery and advertising

1. Verify GPU discovery and ResourceSlice publication.
2. Verify each eligible GPU is advertised as both `type=amdgpu` and
   `type=vfio`.
3. Disable `VFIOPassthrough` and verify dual-entry publication is disabled.
4. Verify non-SR-IOV GPUs do not publish SR-IOV `vf-slots` counters.
5. Verify published device names are unique and stable.

### KEP-4815 counters

1. Verify each SR-IOV PF publishes a `vf-slots` counter set.
2. Verify a VF consumes one slot.
3. Verify a PF consumes all VF slots.
4. Verify all consumed counter sets and counters are present in ResourceSlices.
5. Verify counter state is correct after claim release.
6. Verify different VFs from one PF remain allocatable until all slots are
   consumed.

### Per-VF attributes

Verify ResourceSlices publish correct values for `memory`, `computeUnits`,
`simdUnits`, and `partitionProfile`. Test both valid VRAM metadata and
malformed VRAM metadata; malformed metadata must produce a warning and zero
capacity rather than fabricated capacity.

### ResourceSlice limits

Exercise sufficiently large synthetic or live inventories to verify:

- More than 8 counter sets are split across slices.
- 64 and 65 counter-consuming devices are handled correctly.
- More than 128 devices without counters are handled correctly.
- An empty node still receives a valid empty device slice.
- No device is duplicated or lost.
- No counter set is omitted.

### Allocation and lifecycle

1. Allocate a normal `amdgpu` claim and verify the compute result.
2. Allocate a direct `type=vfio` claim and verify VFIO CDI generation.
3. Verify a converted compute GPU returns to `amdgpu` after release.
4. Allocate compute and VFIO siblings and verify the scheduler refuses both
   together.
5. Verify a VFIO claim can be placed on another GPU when the first GPU is
   unavailable.
6. Prepare two independent claims and release them in both orders.
7. Verify no conversion record or stale VFIO publication remains.
8. Restart the driver with no active conversion and verify ResourceSlices are
   republished consistently. Active-conversion checkpoint recovery is covered
   by PR #122.

### Concurrency

Run concurrent Prepare/Unprepare operations while ResourceSlices are being
rebuilt. Verify there are no stale snapshots, duplicate devices, lost
devices, or race detector failures.

## KubeVirt integration

### Previously completed evidence

- GPU VF allocation.
- VFIO CDI generation.
- GPU VF passthrough to a KubeVirt VM.
- Two-GPU VM allocation.
- GPU visibility inside the guest.

### Still required for this PR

1. Create a VM using a direct `type=vfio` claim.
2. Verify scheduler-level sibling exclusion for the VM claim.
3. Release the VM claim and confirm that the original compute entry returns.
4. Confirm ResourceSlices remain valid through the VM lifecycle.

Guest NUMA and PCIe-topology validation is useful integration evidence, but
it is not required to prove the core KEP-4815 behavior.

## Acceptance criteria

PR #91 is ready when the automated tests pass after the latest commits and the
live system demonstrates dual entries, correct counters, sibling exclusion,
per-VF attributes, direct VFIO lifecycle, and stable ResourceSlice publication.
