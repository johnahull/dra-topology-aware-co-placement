# PR #114 test plan: IOMMUFD support

Upstream PR: [ROCm/k8s-gpu-dra-driver#114](https://github.com/ROCm/k8s-gpu-dra-driver/pull/114)

## Scope

PR #114 covers `LegacyOnly`, `PreferIommuFD`, and `RequireIommuFD` policies,
IOMMUFD and legacy VFIO backend selection, CDI generation, real device-node
validation, backend consistency, rollback after Prepare failures, and cdev
refresh and cleanup.

## Automated tests

### Reported complete

- `go build ./...`
- `go vet ./...`
- Uncached `make test`.
- `go test -race ./cmd/gpu-kubeletplugin/`.
- Claim decode, normalization, and validation.
- CDI generation for pre-bound and converted GPUs.
- Prepare/Unprepare lifecycle with a CDI handler and checkpoint manager.
- Fake-sysfs backend selection.
- Backend consistency.
- `RequireIommuFD` policy behavior.
- Real-device-node validation.
- Rollback after Prepare failures.
- Legacy VFIO group-node validation.

### Required rerun

Rerun the complete suite after the latest review commits and after rebasing
onto the intended base branch.

## Live host prerequisites

Use an available AMD VFIO-capable system. Record the kernel version,
Kubernetes version, and the presence and type of `/dev/iommu`,
`/dev/vfio/vfio`, VFIO device cdevs, and VFIO group nodes. Also record the
libvirt version available to any KubeVirt test.

## Live backend-policy matrix

| Policy | IOMMUFD available | Expected result |
|---|---:|---|
| `LegacyOnly` | Yes | Legacy VFIO |
| `LegacyOnly` | No | Legacy VFIO or expected host failure |
| `PreferIommuFD` | Yes | IOMMUFD |
| `PreferIommuFD` | No | Legacy fallback with warning |
| `RequireIommuFD` | Yes | IOMMUFD |
| `RequireIommuFD` | No | Prepare fails closed |

## IOMMUFD success tests

For `PreferIommuFD` and `RequireIommuFD` when IOMMUFD is available:

1. Allocate a GPU VF.
2. Verify `/dev/iommu` is a character device.
3. Verify `/dev/vfio/devices/<cdev>` is a character device.
4. Verify CDI contains `/dev/iommu` and the per-device VFIO cdev.
5. Verify CDI does not contain legacy group nodes.
6. Verify CDI major/minor values match the host.
7. Verify the device can be prepared and unprepared repeatedly.

## Legacy and fallback tests

For `LegacyOnly`, and `PreferIommuFD` when IOMMUFD is unavailable:

1. Verify CDI contains `/dev/vfio/vfio` and `/dev/vfio/<group>`.
2. Verify CDI does not contain IOMMUFD nodes.
3. Verify fallback produces a warning.
4. Remove `/dev/vfio/<group>` and verify Prepare fails.
5. Remove `/dev/vfio/vfio` and verify Prepare fails.

## Failure and rollback tests

Verify rollback after invalid policy, missing `/dev/iommu`, missing IOMMUFD
cdev, missing `/dev/vfio/vfio`, missing legacy group node, CDI write failure,
checkpoint write failure, and failure after multiple GPUs have been
converted. After every failure, verify the GPU is restored to its original
driver and no stale conversion or CDI state remains.

## Multi-device and restart tests

1. Allocate two or more GPU VFs.
2. Verify every device uses the same selected backend.
3. Re-prepare the same device and verify stale cdev state is not reused.
4. Unconfigure the device and verify the cdev state is cleared.
5. Restart the plugin and verify CDI and checkpoint recovery.

## KubeVirt integration

### Current status

Not completed. Earlier host checks confirmed that `/dev/iommu` and the
`iommufd` module were available, but the live VM used legacy VFIO and did not
exercise this PR's IOMMUFD path.

### Required test

With a virt-launcher image containing the required libvirt support:

1. Start a VM using `RequireIommuFD`.
2. Verify the VM starts successfully.
3. Verify the guest sees the GPU.
4. Confirm the host uses IOMMUFD rather than legacy VFIO.
5. Repeat with two devices and verify both use the same backend.

## Acceptance criteria

PR #114 is ready when automated tests pass and the live system demonstrates
successful IOMMUFD use, correct legacy fallback, fail-closed behavior for
`RequireIommuFD`, backend-consistent CDI, and rollback on every tested failure
path. KubeVirt validation remains conditional on the virt-launcher/libvirt
version.
