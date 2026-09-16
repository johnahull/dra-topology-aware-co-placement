# VEP-300 live test results

Date: 2026-09-16
Server: `jhull@10.6.62.52`
KubeVirt branch: `feature/vep-300-managed-dra-claims`
KubeVirt image: `localhost:5000/kubevirt/*:vep300`; patched launcher image used for the final test: `virt-launcher:vep300-pci-hole3`

## Results

| Test | Result | Evidence |
|---|---|---|
| KubeVirt VEP-300 deployment | PASS | KubeVirt reports `Available=True`; image tag is `vep300`. |
| Managed DRA feature gates/controller | PASS | `ManagedDRAClaims`, `GPUsWithDRA`, `NetworkDevicesWithDRA`, `HostDevicesWithDRA`, and `HostDevices` are enabled; managed-claim controller is Ready. |
| GPU + NIC managed claim creation | PASS | The controller created and the scheduler allocated `gpu-vfio-4` and `0000-1d-00-4`. |
| PCI-root co-placement | PASS | Both allocation results map to `resource.kubernetes.io/pcieRoot=pci0000:15`. |
| GPU VFIO configuration | PASS at allocation | The GPU config requests AMD `VfioDeviceConfig` with `backendPolicy: LegacyOnly`. |
| NIC VFIO configuration | PASS at allocation | The NIC config requests SR-IOV `VfConfig` with `driver: vfio-pci`. |
| VMI launch with both devices | PASS | The patched launcher started a 4 GiB VMI with both VFIO devices; QEMU used `mem-lock=on` and `q35-pcihost.pci-hole64-size=268435456K`. |
| NRI registration and VFIO passthrough | PASS | The plugin registered as `42-dra-driver-sriov`; it skipped CNI attachment for the VFIO NIC with no NAD and returned `/dev/vfio/373`. |
| Cleanup/release | PASS | After deleting the failed VMI, the claim and provisioner were removed, the NIC returned to `mlx5_core`, and the existing GPU VMs remained Running. |

## Important finding

The managed-claim controller and Kubernetes scheduler correctly perform cross-driver PCI-root alignment. After rebuilding the SR-IOV driver, kubelet DRA `NodePrepareResources` succeeded: the NIC VF was bound to `vfio-pci`, `/dev/vfio/373` was exposed, and no NAD lookup or RDMA setup was attempted. NRI also registered normally in `STANDALONE` mode. KubeVirt generated QEMU host devices for both the GPU VF (`0000:1b:02.0`) and NIC VF (`0000:1d:01.2`). The KubeVirt converter fix then enabled locked memory and emitted libvirt's `<pcihole64 unit='KiB'>268435456</pcihole64>` on the PCI root controller, allowing QEMU/KVM startup.

## Root cause investigation

The corrective SR-IOV work is on branch `fix/vfio-standalone-no-nad` and was pushed to the fork. Commits: `a6612d3` (allow driver-only VFIO config), `7aadca7` (use NRI identity from environment), and `924b454` (skip RDMA setup for VFIO devices). The deployed image was `localhost:5000/dra-driver-sriov:fix-vfio-standalone`.

The NRI fix is important because NRI is the standard integration path: the Helm environment already supplies `NRI_PLUGIN_NAME` and `NRI_PLUGIN_IDX`, while the old code redundantly set them through stub options and failed with `plugin name already set`. The rebuilt driver now uses the environment-provided identity.

The existing source test run reached 93/94 passing; its one failure is an outdated expectation for empty `Requests` and is separate from this live VFIO path. Before the converter fix, the live blocker was:

```text
qemu-kvm: kvm_set_user_memory_region: KVM_SET_USER_MEMORY_REGION failed,
slot=4, start=0x400000400000, size=0x2000: Invalid argument
```

The AMD GPU DRA driver was not the failing component. Existing AMD operator `ContainerStatusUnknown`/`ImagePullBackOff` pods were pre-existing environment noise and are captured in the baseline metadata.

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

## Follow-up tests after the PCI-hole fix

| Test | Result | Evidence |
|---|---|---|
| Delete and recreate GPU+NIC VMI | PASS | The claim released and the recreated VMI reached `Running`/`Ready=True` with a new pod IP. |
| Two-GPU `matchAttribute: numaNode` claim | PASS | Existing `vm-amd-vfio-2gpu-numa` claim allocated `gpu-vfio-3` and `gpu-vfio-6`; both expose scalar NUMA `3` and list NUMA `[3,2]`. |
| Two-GPU VFIO VM launch | PASS | `amd-vfio-vm-2gpu-numa` remained `Running` and virt-launcher injected both GPU host devices. |
| Unsatisfiable GPU claim | PARTIAL | A claim selecting nonexistent PCI address `0000:00:00.0` remained unallocated, but this cluster emitted no claim event or human-readable allocation reason. |
| Two fresh GPU+NIC VMs | PASS | `amd-managed-gpu-nic-a` and `amd-managed-gpu-nic-b` are `Running`/`Ready=True`; their VMIs allocated GPU/NIC pairs on `pci0000:97` and `pci0000:15`, respectively. |
| Guest PCI visibility | PASS | QEMU guest-agent inspection found AMD `0x1002:0x74b5` and Mellanox `0x15b3:0x101e` devices in both guests. |
| VM restart and claim reacquisition | PASS | VM `amd-managed-gpu-nic-a` was halted and restarted; it returned `Running`/`Ready=True` with a new allocation timestamp, while VM `amd-managed-gpu-nic-b` stayed Running. |
| AMD GPU DRA driver restart | PASS | `default-dra-driver` DaemonSet rolled out successfully; both VMs remained Ready. |
| SR-IOV DRA driver restart | PASS | `dra-driver-sriov` DaemonSet rolled out successfully; both GPU/NIC claims remained allocated and both VMs remained Ready. |
