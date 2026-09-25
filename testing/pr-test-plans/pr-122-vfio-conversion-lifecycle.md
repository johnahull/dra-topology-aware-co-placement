# PR #122 test plan: VFIO conversion lifecycle

Upstream PR: [ROCm/k8s-gpu-dra-driver#122](https://github.com/ROCm/k8s-gpu-dra-driver/pull/122)

PR #122 is stacked on PR #114. Review and test the PR #122-only diff after
the PR #114 base has been accepted; do not count PR #114's IOMMUFD tests as
tests of the lifecycle fixes.

## Scope

PR #122 fixes GPU-to-VFIO conversion state for a claim across multiple
claims, failed rebinds, Prepare failures, plugin restarts, missing
VFIO-manager conditions, ResourceSlice republishing, and checkpoint
persistence.

## Automated tests

### Reported complete

- Uncached `make test`.
- `go test -race ./cmd/gpu-kubeletplugin/`.
- Failed-rebind rollback.
- Retry after a failed rebind.
- Two claims preserving independent conversion records.
- Stranded-claim Unprepare.
- Restart recovery through Unprepare.
- Original device names and types before, during, and after conversion.
- No-VFIO-manager cleanup behavior.
- Checkpoint omission when no conversions exist.
- Checkpoint round-trip when conversions exist.
- Mutation checks showing that each fix is covered by a failing test when
  removed.

### Required rerun

Rerun the complete suite after rebasing PR #122 onto the final PR #114 base.
Verify that the race tests cover both concurrent claims and concurrent
ResourceSlice publication.

## Hardware-independent lifecycle tests

### Two simultaneous conversions

1. Prepare claim A on GPU A.
2. Prepare claim B on GPU B.
3. Release A.
4. Verify B remains tracked and usable.
5. Release B.
6. Verify both GPUs return to their original drivers.

Repeat with the release order reversed.

### Failed rebind

1. Convert a GPU to VFIO.
2. Force rebinding to the original driver to fail.
3. Verify the conversion record remains persisted.
4. Verify Prepare or Unprepare reports an error.
5. Correct the rebind failure.
6. Retry cleanup.
7. Verify the device and record are restored.

### Restart recovery

1. Prepare a claim that converts a GPU.
2. Restart the plugin before Unprepare.
3. Verify the conversion is recovered from the checkpoint.
4. Verify the converted device is not advertised as an unused pre-bound VFIO
   GPU.
5. Unprepare the claim.
6. Verify the original driver is restored.

### ResourceSlice naming and attributes

Verify that a converted GPU:

- Retains its original GPU name.
- Does not become `gpu-vfio-0`.
- Does not collide with a real pre-bound VFIO device.
- Retains its original device type.
- Retains its PCI, NUMA, and capacity attributes.
- Keeps stable naming across republish and restart.

### Missing VFIO manager

1. Prepare a converted claim.
2. Make VFIO-manager initialization unavailable.
3. Verify cleanup does not report success.
4. Verify the conversion record remains available for retry.
5. Restore the manager.
6. Verify cleanup succeeds and the original driver is restored.

### Stranded claim cleanup

Interrupt the normal claim lifecycle and invoke cleanup for the stranded
claim. Verify the device returns to its original driver and the record is
removed only after successful restoration.

## Checkpoint compatibility

1. Load a checkpoint created by an older driver without `vfioConversions`.
2. Verify it remains readable.
3. Verify an empty conversion map is omitted.
4. Verify a populated conversion map round-trips.
5. Verify downgrade behavior is documented and fails safely when conversions
   are present.

## Live hardware validation

No hardware validation is currently complete for PR #122. On the available
AMD VFIO-capable system, perform the following with disposable claims and
VFs:

- Convert and release one regular GPU.
- Prepare two independent conversions and release them in both orders.
- Restart the plugin while a conversion is active.
- Verify no converted GPU is advertised as free.
- Verify ResourceSlice names do not collide with pre-bound VFIO devices.
- Exercise retry after a controlled rebind failure if the system permits it
  safely.

Do not intentionally disrupt a production workload to induce a rebind or
VFIO-manager failure; use fake sysfs or an isolated test device for those
cases.

## KubeVirt integration

KubeVirt is optional for the core PR #122 acceptance criteria. If performed,
use it only to confirm that a VM claim can be prepared and released without
leaving the GPU bound to VFIO or incorrectly advertised afterward.

## Acceptance criteria

PR #122 is ready when the PR #122-only automated tests pass after rebasing and
live testing confirms correct conversion ownership, rollback, restart
recovery, ResourceSlice naming, and original-driver restoration.
