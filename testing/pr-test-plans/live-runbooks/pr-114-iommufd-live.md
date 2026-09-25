# PR #114 live test runbook: IOMMUFD

Parent evidence matrix: [PR #114 test plan](../pr-114-iommufd.md)

This runbook validates backend selection, CDI contents, fallback, and
fail-closed behavior on a real AMD VFIO-capable system. It does not claim that
the prior legacy-VFIO VM test exercised IOMMUFD.

## Required inputs and safety

```bash
export DRIVER_NAMESPACE="${DRIVER_NAMESPACE:-kube-amd-gpu}"
export DRIVER_RELEASE="${DRIVER_RELEASE:-k8s-gpu-dra-driver}"
export DRA_DRIVER_COMMIT="<commit-under-test>"
export GPU_DRIVER_IMAGE="<registry/image:tag>"
```

Use an isolated GPU/VF and a disposable claim. Do not remove `/dev/iommu`,
`/dev/vfio/vfio`, or group nodes from a production node. If a negative case
requires unavailable nodes, use the automated fake-sysfs tests or an isolated
lab system and mark the live case `NOT RUN`.

## Phase 1: Baseline host capture

```bash
stat -c '%F %t:%T %n' /dev/iommu /dev/vfio/vfio 2>&1 \
  | tee "$RUN_DIR/iommu-nodes.txt"
ls -l /dev/vfio /dev/vfio/devices 2>&1 | tee "$RUN_DIR/vfio-nodes.txt"
lsmod | grep -E 'iommufd|vfio' | tee "$RUN_DIR/iommu-modules.txt" || true
find /sys/kernel/iommu_groups -maxdepth 2 -type l | sort \
  | tee "$RUN_DIR/iommu-groups.txt"
uname -a | tee "$RUN_DIR/uname.txt"
```

Record whether each path exists and whether it is a character device. Locate
the cdev corresponding to the test GPU and save its PCI address and group.

Deploy the PR #114 image through the cluster's normal Helm/chart workflow,
recording the rendered values and image digest:

```bash
helm upgrade --install "$DRIVER_RELEASE" <chart> \
  --namespace "$DRIVER_NAMESPACE" --create-namespace \
  --set image.repository="${GPU_DRIVER_IMAGE%:*}" \
  --set image.tag="${GPU_DRIVER_IMAGE##*:}"
kubectl rollout status daemonset -n "$DRIVER_NAMESPACE" --timeout=5m
kubectl logs -n "$DRIVER_NAMESPACE" -l app.kubernetes.io/name=k8s-gpu-dra-driver \
  --all-containers --tail=-1 | tee "$RUN_DIR/driver-startup.log"
```

## Phase 2: Policy matrix

For each row, create a disposable VFIO claim with the corresponding opaque
`VfioDeviceConfig`, prepare it through the cluster's normal consumer, inspect
the CDI file, then release it.

| ID | Policy | Host condition | Expected backend |
|---|---|---|---|
| P-01 | `LegacyOnly` | IOMMUFD available | Legacy VFIO |
| P-02 | `PreferIommuFD` | IOMMUFD available | IOMMUFD |
| P-03 | `RequireIommuFD` | IOMMUFD available | IOMMUFD |
| P-04 | `PreferIommuFD` | IOMMUFD unavailable | Legacy VFIO with warning |
| P-05 | `RequireIommuFD` | IOMMUFD unavailable | Prepare fails closed |

The unavailable-IOMMUFD rows must use a naturally unavailable or isolated test
environment. Do not simulate them by deleting host device nodes on a shared
node.

For every successful row, save:

```bash
kubectl get resourceclaims -A -o yaml > "$RUN_DIR/resourceclaims-<policy>.yaml"
kubectl get resourceslices -o yaml > "$RUN_DIR/resourceslices-<policy>.yaml"
./testing/scripts/dra-verify.sh vfio > "$RUN_DIR/vfio-<policy>.txt"
find /var/run/cdi -maxdepth 1 -type f -name '*.yaml' -print \
  | tee "$RUN_DIR/cdi-files-<policy>.txt"
```

## Phase 3: Verify IOMMUFD CDI

For `PreferIommuFD` and `RequireIommuFD` when IOMMUFD is available, inspect
the generated CDI YAML and confirm:

- `/dev/iommu` is present.
- `/dev/vfio/devices/<cdev>` is present.
- `/dev/vfio/vfio` is absent.
- `/dev/vfio/<group>` is absent.
- The cdev and common API node are character devices on the host.
- CDI type, major, minor, host path, and permissions match the host nodes.

The CDI specification must use one backend consistently; a cdev plus legacy
API/group nodes is a failure.

## Phase 4: Verify legacy and fallback CDI

For `LegacyOnly`, confirm CDI contains `/dev/vfio/vfio` and
`/dev/vfio/<group>` and contains no IOMMUFD nodes.

For `PreferIommuFD` fallback, confirm the same legacy CDI result plus a clear
driver warning identifying the fallback. Save the driver log and CDI YAML.

If a test environment naturally lacks the legacy API or group node, verify
Prepare fails instead of creating a CDI entry that cannot be opened.

## Phase 5: Multi-device and repeated lifecycle

1. Allocate two or more GPU VFs in one claim.
2. Verify every device uses the same selected backend.
3. Prepare and unprepare the same device repeatedly.
4. Verify cdev state is refreshed on Configure.
5. Verify cdev state is cleared on Unconfigure.
6. Capture CDI and ResourceClaim state after every cycle.

Expected result: no device uses a different backend from the rest of the
claim, and no stale cdev is reused after re-prepare.

## Phase 6: Rollback validation

The automated test suite is the primary evidence for failure injection. If an
isolated live setup permits safe injection, test one failure at a time:

| Failure | Expected result |
|---|---|
| Invalid backend policy | Prepare fails and GPU binding is restored. |
| Missing IOMMUFD node | `RequireIommuFD` fails closed and conversion is restored. |
| Missing legacy node | Legacy Prepare fails and conversion is restored. |
| CDI write failure | Every converted device is restored. |
| Checkpoint write failure | Hardware and claim state are restored. |
| Failure after multiple conversions | Earlier devices are also rolled back. |

Never inject these failures into an active production workload. Attach the
automated fake-sysfs/test output when live injection is unsafe.

## Phase 7: KubeVirt, if supported

KubeVirt IOMMUFD testing is conditional on a virt-launcher image with the
required libvirt support:

1. Use `RequireIommuFD` for a single-GPU VM.
2. Verify the VM starts and the guest detects the GPU.
3. Confirm host CDI contains IOMMUFD nodes, not legacy nodes.
4. Repeat with two devices and verify both use IOMMUFD.
5. If IOMMUFD is unavailable, repeat with `PreferIommuFD` and verify legacy
   fallback.

If the image lacks the required libvirt support, record `BLOCKED` with the
virt-launcher and libvirt versions; do not substitute a legacy VM result.

## Completion criteria

The live PR #114 run is complete when the final image demonstrates successful
IOMMUFD selection, correct legacy fallback, fail-closed `RequireIommuFD`,
backend-consistent CDI, and repeatable Prepare/Unprepare behavior. KubeVirt
results are conditional on the virt-launcher capability.
