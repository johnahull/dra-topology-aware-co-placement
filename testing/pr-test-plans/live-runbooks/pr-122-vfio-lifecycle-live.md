# PR #122 live test runbook: VFIO conversion lifecycle

Parent evidence matrix: [PR #122 test plan](../pr-122-vfio-conversion-lifecycle.md)

This runbook validates conversion ownership, restoration, checkpoint recovery,
ResourceSlice identity, and stranded-claim cleanup for regular GPUs converted
from `amdgpu` to `vfio-pci`.

PR #122 is stacked on PR #114. Use the PR #122-only image and record the base
commit. Do not report IOMMUFD backend selection as PR #122 evidence.

## Required inputs and safety

```bash
export DRIVER_NAMESPACE="${DRIVER_NAMESPACE:-kube-amd-gpu}"
export DRIVER_RELEASE="${DRIVER_RELEASE:-k8s-gpu-dra-driver}"
export DRA_DRIVER_COMMIT="<pr-122-commit>"
export GPU_DRIVER_IMAGE="<registry/image:tag>"
```

Use disposable GPUs and claims. At least one test GPU must begin bound to
`amdgpu`, not already bound to `vfio-pci`. Do not disrupt a production GPU to
force a failed rebind or remove the VFIO manager.

## Phase 1: Baseline and deployment

```bash
uname -a | tee "$RUN_DIR/uname.txt"
kubectl version -o yaml | tee "$RUN_DIR/kubernetes-version.yaml"
lspci -D -nn | tee "$RUN_DIR/lspci-before.txt"
kubectl get resourceslices -o yaml | tee "$RUN_DIR/resourceslices-before.yaml"
kubectl get resourceclaims -A -o yaml | tee "$RUN_DIR/resourceclaims-before.yaml"
for bdf in <test-bdf-1> <test-bdf-2>; do
  printf '%s ' "$bdf"
  readlink -f "/sys/bus/pci/devices/$bdf/driver" 2>/dev/null || true
done | tee "$RUN_DIR/original-drivers.txt"
```

Deploy the PR #122 image with the normal chart workflow:

```bash
helm upgrade --install "$DRIVER_RELEASE" <chart> \
  --namespace "$DRIVER_NAMESPACE" --create-namespace \
  --set image.repository="${GPU_DRIVER_IMAGE%:*}" \
  --set image.tag="${GPU_DRIVER_IMAGE##*:}"
kubectl rollout status daemonset -n "$DRIVER_NAMESPACE" --timeout=5m
kubectl logs -n "$DRIVER_NAMESPACE" -l app.kubernetes.io/name=k8s-gpu-dra-driver \
  --all-containers --tail=-1 | tee "$RUN_DIR/driver-startup.log"
```

## Phase 2: Single conversion and release

Use the normal DRA consumer mechanism to prepare a claim for one regular
`amdgpu` GPU with the PR's VFIO configuration.

Capture the device before Prepare:

```bash
readlink -f /sys/bus/pci/devices/<test-bdf>/driver \
  | tee "$RUN_DIR/single-before-driver.txt"
kubectl get resourceslices -o yaml > "$RUN_DIR/single-before-slices.yaml"
```

After the consumer is running, capture:

```bash
readlink -f /sys/bus/pci/devices/<test-bdf>/driver \
  | tee "$RUN_DIR/single-during-driver.txt"
kubectl get resourceclaims -A -o yaml > "$RUN_DIR/single-during-claims.yaml"
kubectl get resourceslices -o yaml > "$RUN_DIR/single-during-slices.yaml"
./testing/scripts/dra-verify.sh vfio > "$RUN_DIR/single-during-vfio.txt"
```

Expected during Prepare: the selected device is bound to `vfio-pci`, the
claim is allocated, and the ResourceSlice does not advertise a duplicate free
VFIO identity.

Delete the consumer and claim, then verify:

```bash
readlink -f /sys/bus/pci/devices/<test-bdf>/driver \
  | tee "$RUN_DIR/single-after-driver.txt"
kubectl get resourceslices -o yaml > "$RUN_DIR/single-after-slices.yaml"
kubectl get resourceclaims -A -o yaml > "$RUN_DIR/single-after-claims.yaml"
```

Expected after release: the GPU is back on its original driver, the original
GPU name/type/attributes are advertised, and no stale conversion state remains.

## Phase 3: Two-claim ownership

Prepare claim A on GPU A and claim B on GPU B before releasing either claim.
Save claims, slices, CDI, driver bindings, and driver logs for each transition.

Run both release orders:

1. Prepare A and B; release A; verify B remains correctly tracked; release B.
2. Prepare A and B; release B; verify A remains correctly tracked; release A.

Expected result: releasing one claim never restores or removes the other
claim's conversion record. Both GPUs end on their original drivers.

## Phase 4: Active-conversion restart

1. Prepare a claim that converts a regular GPU.
2. Confirm the conversion and checkpoint state are present.
3. Restart only the DRA driver plugin, not the host.
4. Wait for the plugin to republish ResourceSlices.
5. Inspect the converted GPU's published name, type, and allocation state.
6. Release the original claim.

Expected result:

- The converted GPU is not advertised as a free pre-bound VFIO device.
- The original device identity is retained.
- Unprepare restores the original driver.
- The conversion record is removed only after successful restoration.

Save plugin logs before and after restart and save the checkpoint through the
plugin's documented data path. If the checkpoint path is container-mounted,
record the pod and host path used to inspect it.

## Phase 5: ResourceSlice identity and collision protection

Use one converted GPU and, if available, one real pre-bound VFIO device.
Compare ResourceSlices before conversion, during conversion, after release,
and after a plugin restart.

Verify:

- The converted GPU retains its original GPU name.
- It does not become `gpu-vfio-0` because an index is missing.
- It does not collide with the real pre-bound VFIO device.
- PCI, NUMA, capacity, and device-type attributes remain stable.
- Every device appears exactly once per driver/pool.

## Phase 6: Stranded claim and missing-manager behavior

These cases are primarily automated/component tests. Only run them live with
an isolated device and a reversible test setup.

| Scenario | Safe live action | Expected result |
|---|---|---|
| Stranded claim | Interrupt or simulate an incomplete claim lifecycle, then invoke cleanup. | Restoration is retried; state is not discarded early. |
| Failed rebind | Use a controlled isolated-device failure, then restore the condition. | Failure remains visible and retry restores the GPU. |
| Missing VFIO manager | Use an isolated plugin instance where manager initialization can be disabled. | Cleanup does not falsely report success and retains retry state. |

Do not unload host modules or alter shared device nodes to create these
failures. If safe injection is unavailable, attach the PR's fake-sysfs and
component-test output instead and mark the live row `NOT RUN`.

## Phase 7: Optional KubeVirt validation

KubeVirt is not required for the core PR #122 driver acceptance criteria. If
performed:

1. Start a VM using a claim that converts a regular GPU.
2. Verify the VM starts and the GPU is visible.
3. Delete the VM and claim.
4. Verify the GPU returns to its original driver.
5. Restart the DRA plugin while the VM is using the GPU, if the VM can be
   safely used as a disposable workload.
6. Verify the in-use GPU is never advertised as free.

Save VM/VMI YAML, ResourceSlices, CDI YAML, host binding state, and guest
`lspci` output.

## Completion criteria

The live PR #122 run is complete when it demonstrates single-claim release,
two-claim ownership, active-conversion restart recovery, stable ResourceSlice
identity, and restoration to the original driver. Failed-rebind and
missing-manager cases may remain automated-only when safe live injection is
not available.
