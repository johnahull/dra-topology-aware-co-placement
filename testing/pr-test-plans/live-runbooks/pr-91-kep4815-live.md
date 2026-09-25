# PR #91 live test runbook: KEP-4815

Parent evidence matrix: [PR #91 test plan](../pr-91-kep4815-dual-entry.md)

This runbook validates dual GPU entries, shared counters, sibling exclusion,
per-VF capacity, direct VFIO claims, and release behavior on a real AMD
SR-IOV/GIM system.

## Required inputs

Set these before execution:

```bash
export DRIVER_NAMESPACE="${DRIVER_NAMESPACE:-kube-amd-gpu}"
export DRIVER_RELEASE="${DRIVER_RELEASE:-k8s-gpu-dra-driver}"
export DRA_DRIVER_COMMIT="<commit-under-test>"
export GPU_DRIVER_IMAGE="<registry/image:tag>"
```

The tester must have:

- An AMD GPU system with GIM-created VFs or another supported SR-IOV setup.
- No important workloads using the selected GPU/PF/VF.
- `VFIOPassthrough` and Kubernetes partitionable-device support configured as
  required by the PR branch.
- A driver image built from the PR #91 branch or an image whose digest is
  recorded in the evidence directory.

## Phase 1: Host and driver baseline

Record the physical GPU/VF state before changing Kubernetes:

```bash
lspci -D -nn | tee "$RUN_DIR/lspci-before.txt"
find /sys/kernel/iommu_groups -maxdepth 2 -type l | sort \
  | tee "$RUN_DIR/iommu-groups.txt"
for bdf in $(lspci -D -d 1002: | awk '{print $1}'); do
  printf '%s ' "$bdf"
  readlink -f "/sys/bus/pci/devices/$bdf/driver" 2>/dev/null || true
done | tee "$RUN_DIR/gpu-drivers.txt"
```

Capture GIM's supported VF counts and partition modes using the platform's
normal GIM/AMD management tool. Do not assume MI300X values apply to MI355X.
Save the output as `$RUN_DIR/vf-counts-before.txt`.

Deploy or upgrade the driver using the image and chart selected for the test
system. The exact Helm values depend on the cluster, but the deployment must
enable VFIO discovery:

```bash
helm upgrade --install "$DRIVER_RELEASE" <chart> \
  --namespace "$DRIVER_NAMESPACE" --create-namespace \
  --set image.repository="${GPU_DRIVER_IMAGE%:*}" \
  --set image.tag="${GPU_DRIVER_IMAGE##*:}" \
  --set featureGates.VFIOPassthrough=true
kubectl rollout status daemonset -n "$DRIVER_NAMESPACE" --timeout=5m
kubectl get pods -n "$DRIVER_NAMESPACE" -o wide | tee "$RUN_DIR/driver-pods.txt"
kubectl logs -n "$DRIVER_NAMESPACE" -l app.kubernetes.io/name=k8s-gpu-dra-driver \
  --all-containers --tail=-1 | tee "$RUN_DIR/driver-discovery.log"
```

If the chart uses a different release label or feature-gate value, record the
actual command and rendered values rather than silently changing the test.

## Phase 2: Verify dual entries and attributes

```bash
kubectl get resourceslices -o yaml | tee "$RUN_DIR/resourceslices-gate-on.yaml"
./testing/scripts/dra-verify.sh attributes -a | tee "$RUN_DIR/attributes-gate-on.txt"
```

For every eligible GPU, confirm in the YAML that:

- A compute entry has `type=amdgpu`.
- A VFIO sibling has `type=vfio`.
- The two entries identify the same PCI function.
- The device names are unique.
- The VFIO entry carries the expected `isVF`, PCI, NUMA, and parent metadata.

Record `PASS` only when the final PR #91 image is the image publishing these
entries.

Run the negative gate check in an isolated deployment:

```bash
helm upgrade "$DRIVER_RELEASE" <chart> \
  --namespace "$DRIVER_NAMESPACE" \
  --set featureGates.VFIOPassthrough=false
kubectl rollout status daemonset -n "$DRIVER_NAMESPACE" --timeout=5m
kubectl get resourceslices -o yaml | tee "$RUN_DIR/resourceslices-gate-off.yaml"
```

Expected result: VFIO entries are absent while normal compute entries remain
published. Restore the gate before continuing:

```bash
helm upgrade "$DRIVER_RELEASE" <chart> \
  --namespace "$DRIVER_NAMESPACE" \
  --set featureGates.VFIOPassthrough=true
kubectl rollout status daemonset -n "$DRIVER_NAMESPACE" --timeout=5m
```

## Phase 3: Verify KEP-4815 counters

```bash
./testing/scripts/dra-verify.sh counters | tee "$RUN_DIR/counters-before.txt"
kubectl get resourceslices -o yaml | tee "$RUN_DIR/resourceslices-counters.yaml"
```

For each SR-IOV PF, verify:

- A `vf-slots` shared counter set is present.
- A VF consumes one slot.
- A PF consumes all configured VF slots.
- Every `consumesCounters.counterSet` refers to a published counter set.
- Function-level sibling entries consume the same `fn-<pci-bdf>` counter when
  the device is dual-advertised.

If `dra-verify.sh counters` reports no shared counter sets, mark this test
`FAIL` or `BLOCKED` with the exact ResourceSlice output; do not infer success
from a CDI file or from VFIO binding alone.

## Phase 4: Test VF counts and capacity

For every VF count supported by GIM on the test platform, repeat discovery and
the ResourceSlice capture. Begin with 1, 2, 4, and 8 where available, and add
3 when TPX is supported.

For each count, compare the PF values with every VF:

| Field | Check |
|---|---|
| `partitionProfile` | Matches the platform-reported partition mode. |
| `memory` | PF memory divided by configured VF count. |
| `computeUnits` | PF compute total divided by configured VF count. |
| `simdUnits` | PF SIMD total divided by configured VF count. |
| `vf-slots` | PF counter capacity equals the configured VF capacity. |

Save one ResourceSlice YAML and one summarized result row per VF count. A
platform that does not support a count should be recorded as `SKIPPED`, not
`FAIL`.

## Phase 5: Test allocation and sibling exclusion

Use disposable ResourceClaims and the cluster's existing DRA consumer
mechanism. Applying a claim alone may not invoke Prepare; use the same Pod or
VM consumer pattern already used by the cluster.

Run these scenarios in both allocation orders:

1. Allocate the compute `amdgpu` entry, then request its VFIO sibling.
2. Allocate the VFIO entry, then request its compute sibling.
3. Allocate one GPU and request VFIO on another GPU.
4. Allocate VFs from one PF until the `vf-slots` capacity is exhausted.
5. Request one additional VF after exhaustion.
6. Allocate a PF-level resource while its VFs are free, if the platform
   exposes that resource.

Expected results:

- Compute and VFIO siblings cannot be allocated together.
- The scheduler can select another eligible GPU.
- Allocation succeeds only within the published slot capacity.
- PF allocation blocks the sibling VFs.

After every scenario, save:

```bash
kubectl get resourceclaims -A -o yaml > "$RUN_DIR/resourceclaims-<scenario>.yaml"
kubectl get resourceslices -o yaml > "$RUN_DIR/resourceslices-<scenario>.yaml"
./testing/scripts/dra-verify.sh counters > "$RUN_DIR/counters-<scenario>.txt"
```

## Phase 6: Direct VFIO claim and release

Use a direct `type=vfio` selector for a pre-bound or directly usable VF. The
claim must exercise the PR #91 direct-VFIO path rather than a legacy explicit
driver shortcut. Capture:

- Claim allocation status.
- Prepare result and CDI YAML.
- Host driver binding before and after Prepare.
- ResourceSlice state while allocated.
- State after claim release.

Expected result: the VFIO device is usable, the claim's CDI is present, and
release restores the expected allocatable entry without a stale sibling or
conversion record.

## Phase 7: KubeVirt integration

This phase is supplemental to the driver tests. Run it only after the driver
and counter phases pass:

1. Create a VM using a direct `type=vfio` claim.
2. Verify the VM starts and the guest sees the GPU VF.
3. Verify a conflicting compute/VFIO sibling claim cannot be allocated.
4. Delete the VM and claim.
5. Verify counters are released and the original entry returns.

Save VM/VMI YAML, CDI YAML, `lspci` output, and the final ResourceSlice state.

## Completion criteria

Mark the live PR #91 run complete only when the final image demonstrates:

- Dual entries in ResourceSlices.
- Correct `vf-slots` and function-level counters.
- Scheduler-level sibling exclusion.
- Correct capacity across supported VF counts.
- Direct VFIO allocation and release.
- No duplicate, missing, or stale ResourceSlice devices.
