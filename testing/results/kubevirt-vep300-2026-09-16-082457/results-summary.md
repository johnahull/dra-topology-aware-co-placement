# VEP-300 live test results

Date: 2026-09-16
Server: `jhull@10.6.62.52`
KubeVirt branch: `feature/vep-300-managed-dra-claims`
KubeVirt image: `localhost:5000/kubevirt/*:vep300`

## Results

| Test | Result | Evidence |
|---|---|---|
| KubeVirt VEP-300 deployment | PASS | KubeVirt reports `Available=True`; image tag is `vep300`. |
| Managed DRA feature gates/controller | PASS | `ManagedDRAClaims`, `GPUsWithDRA`, `NetworkDevicesWithDRA`, `HostDevicesWithDRA`, and `HostDevices` are enabled; managed-claim controller is Ready. |
| GPU + NIC managed claim creation | PASS | The controller created and the scheduler allocated `gpu-vfio-4` and `0000-1d-00-4`. |
| PCI-root co-placement | PASS | Both allocation results map to `resource.kubernetes.io/pcieRoot=pci0000:15`. |
| GPU VFIO configuration | PASS at allocation | The GPU config requests AMD `VfioDeviceConfig` with `backendPolicy: LegacyOnly`. |
| NIC VFIO configuration | PASS at allocation | The NIC config requests SR-IOV `VfConfig` with `driver: vfio-pci`. |
| VMI launch with both devices | BLOCKED at QEMU startup | The rebuilt plugin prepared both VFIO devices and KubeVirt injected both PCI host devices, but QEMU exited with `KVM_SET_USER_MEMORY_REGION ... Invalid argument`. |
| NRI registration and VFIO passthrough | PASS | The plugin registered as `42-dra-driver-sriov`; it skipped CNI attachment for the VFIO NIC with no NAD and returned `/dev/vfio/373`. |
| Cleanup/release | PASS | After deleting the failed VMI, the claim and provisioner were removed, the NIC returned to `mlx5_core`, and the existing GPU VMs remained Running. |

## Important finding

The managed-claim controller and Kubernetes scheduler correctly perform cross-driver PCI-root alignment. After rebuilding the SR-IOV driver, kubelet DRA `NodePrepareResources` succeeded: the NIC VF was bound to `vfio-pci`, `/dev/vfio/373` was exposed, and no NAD lookup or RDMA setup was attempted. NRI also registered normally in `STANDALONE` mode. KubeVirt then generated QEMU host devices for both the GPU VF (`0000:1b:02.0`) and NIC VF (`0000:1d:01.2`). The remaining failure is at QEMU/KVM guest startup, not in DRA allocation, NRI, NAD handling, or VFIO preparation.

## Root cause investigation

The corrective SR-IOV work is on branch `fix/vfio-standalone-no-nad` and was pushed to the fork. Commits: `a6612d3` (allow driver-only VFIO config), `7aadca7` (use NRI identity from environment), and `924b454` (skip RDMA setup for VFIO devices). The deployed image was `localhost:5000/dra-driver-sriov:fix-vfio-standalone`.

The NRI fix is important because NRI is the standard integration path: the Helm environment already supplies `NRI_PLUGIN_NAME` and `NRI_PLUGIN_IDX`, while the old code redundantly set them through stub options and failed with `plugin name already set`. The rebuilt driver now uses the environment-provided identity.

The existing source test run reached 93/94 passing; its one failure is an outdated expectation for empty `Requests` and is separate from this live VFIO path. The remaining live blocker is the QEMU error:

```text
qemu-kvm: kvm_set_user_memory_region: KVM_SET_USER_MEMORY_REGION failed,
slot=4, start=0x400000400000, size=0x2000: Invalid argument
```

The AMD GPU DRA driver was not the failing component in this run. Existing AMD operator `ContainerStatusUnknown`/`ImagePullBackOff` pods were pre-existing environment noise and are captured in the baseline metadata.

## Archived evidence

- `test-plan.md`
- `manifests/managedclaimprovisioner-gpu-nic.yaml`
- `manifests/managed-vmi-gpu-nic.yaml`
- `tests/managed-gpu-nic-*.log`
- `logs/dra-drivers-managed-gpu-nic*.log`
- `snapshots/managed-gpu-nic-rerun.yaml`
- `metadata/cluster-baseline.txt`

## Follow-up live-test evidence

- NRI log: `Created plugin 42-dra-driver-sriov` and `NRI plugin started`.
- SR-IOV log: `GetVFIODeviceFile()` resolved `/dev/vfio/373`; `NetAttachDefConfig:""`; `Skipping CNI attachment for device without NAD config (VFIO passthrough)`.
- KubeVirt launcher log: QEMU received VFIO host devices for `0000:1d:01.2` and `0000:1b:02.0`, then failed during KVM memory registration.
