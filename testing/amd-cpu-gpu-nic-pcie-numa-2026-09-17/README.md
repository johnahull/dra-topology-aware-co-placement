# AMD GPU/NIC PCIe-root and CPU/memory DRA test

Date: 2026-09-17

Server: `jhull@10.6.62.52`

Goal: allocate an AMD GPU VF and ConnectX VF with the same
`resource.kubernetes.io/pcieRoot`, while allocating dedicated CPUs and 1Gi
hugepage-backed memory through DRA on the same NUMA node.

## Deployment

- KubeVirt branch: `feat/vep152-cpu-dra`, commit `3ef1a339`
- CPU DRA driver: upstream `main`, commit `009e907a`
- CPU driver option: `--expose-pcie-roots=true`
- KubeVirt feature gates: `CPUsWithDRA`, `MemoryWithDRA`, `GPUsWithDRA`,
  `HostDevicesWithDRA`, and `NetworkDevicesWithDRA`
- Kubernetes scheduler feature gate: `DRAListTypeAttributes=true`
- Hugepages: 16 x 1Gi per NUMA node, 64Gi total

## Artifacts

- [VM and ResourceClaimTemplate](./manifests/amd-cpu-gpu-nic-hugepages.yaml)
- [Test results](./results.md)
- [Observed server state](./server-state.txt)

The hugepage pool was created at runtime through sysfs and is not persistent
across a host reboot.
