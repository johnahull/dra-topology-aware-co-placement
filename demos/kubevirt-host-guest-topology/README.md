# Demo: Host and Guest Topology Match

This demo shows a multi-device DRA allocation carried from the host into a
KubeVirt guest. The claim contains 8 dedicated CPUs, 4 GiB of 1-GiB
hugepage-backed memory, two AMD GPU VFs, and two ConnectX VFs.

Each GPU/NIC pair is constrained to the same `resource.kubernetes.io/pcieRoot`.
Each pair's CPU and memory are constrained to the same
`resource.kubernetes.io/numaNode` as that GPU/NIC pair.
The verification requires both pairs to be present.

The host views are compared before the VM is started:

```bash
testing/scripts/hw-topology.sh --simple
testing/scripts/dra-verify.sh topology --simple
```

Host and guest BDFs are expected to differ; the comparison is based on NUMA
placement, PCIe-root grouping, and resource identity.

## Prerequisites

- Kubernetes 1.37+ with DRA enabled
- KubeVirt with `CPUsWithDRA`, `MemoryWithDRA`, `GPUsWithDRA`,
  `HostDevicesWithDRA`, `NUMA`, and `PCINUMAAwareTopology`
- AMD GPU DRA and SR-IOV DRA drivers publishing standard topology attributes
- 1-GiB hugepages available on the host
- VFIO-capable AMD and ConnectX VFs
- `virtctl` or direct SSH access to the guest

## Run

```bash
kubectl apply -f demos/kubevirt-host-guest-topology/demo-vm.yaml
kubectl wait --for=condition=Ready vmi/amd-host-guest-topology-dual-pair --timeout=180s
vhs demos/kubevirt-host-guest-topology/demo.tape
```

The tape assumes the VM is already running and uses the existing
`hw-topology.sh` and `dra-verify.sh` scripts directly.

Results are written to `/tmp/kubevirt-host-guest-topology/` unless
`RESULTS_DIR` is set.

Host-backed hugepages are verified through the host pool, launcher request, and
QEMU memory backend. Guest `HugePages_Total` is informational because host
backing does not necessarily create guest-managed HugeTLB pages.

## Cleanup

```bash
kubectl delete -f demos/kubevirt-host-guest-topology/demo-vm.yaml
```
