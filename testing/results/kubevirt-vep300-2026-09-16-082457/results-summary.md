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
| VMI launch with both devices | BLOCKED | The deployed SR-IOV DRA plugin, in `STANDALONE` mode, attempts to read `default/` as a NetworkAttachmentDefinition even though the claim has no `netAttachDefName`. The cluster does not install the NetworkAttachmentDefinition CRD. |
| Cleanup/release | PASS | After deleting the failed VMI, the claim was removed and NIC `0000:1d:00.4` returned to `mlx5_core`; existing VMs remained Running. |

## Important finding

The managed-claim controller and Kubernetes scheduler correctly perform cross-driver PCI-root alignment. The failure is later, during kubelet DRA `NodePrepareResources`, in the deployed SR-IOV driver. The driver logs show the claim config as only `driver: vfio-pci`, but still issue `getNetAttachDefRawConfig(default/)`. This is independent of the successful GPU/NIC allocation and should be fixed or rebuilt in the SR-IOV driver before treating end-to-end VM launch as passing.

The AMD GPU DRA driver was not the failing component in this run. Existing AMD operator `ContainerStatusUnknown`/`ImagePullBackOff` pods were pre-existing environment noise and are captured in the baseline metadata.

## Archived evidence

- `test-plan.md`
- `manifests/managedclaimprovisioner-gpu-nic.yaml`
- `manifests/managed-vmi-gpu-nic.yaml`
- `tests/managed-gpu-nic-*.log`
- `logs/dra-drivers-managed-gpu-nic*.log`
- `snapshots/managed-gpu-nic-rerun.yaml`
- `metadata/cluster-baseline.txt`
