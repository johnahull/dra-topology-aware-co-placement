# Results

## GPU/NIC PCIe-root allocation

The generated device claim allocated:

| Request | Driver | Device | PCIe root |
|---|---|---|---|
| `gpu0` | `gpu.amd.com` | `gpu-vfio-4` | `pci0000:15` |
| `nic0` | `sriovnetwork.k8snetworkplumbingwg.io` | `0000-1d-00-2` | `pci0000:15` |

The claim used `matchAttribute: resource.kubernetes.io/pcieRoot`, so the
matching was performed by the Kubernetes DRA scheduler.

## CPU and memory allocation

The KubeVirt-generated claim allocated:

| Request | Driver | Device | Allocation |
|---|---|---|---|
| `cpu` | `dra.cpu` | `cpudevnuma000` | 4 CPUs |
| `mem` | `dra.memory` | `hugepages-1gi-pjj9lv` | 4Gi |

The CPU/memory claim includes a `matchAttribute` constraint on
`resource.kubernetes.io/numaNode`. The selected CPU device is NUMA node 0;
the selected 1Gi hugepage device is also NUMA node 0.

## VM status

The first run reached `Starting` but did not become Ready. Its pod was
scheduled and all four DRA allocations were successful, but kubelet rejected
the HugePages volume mount:

```text
hugePages storage requested, but there is no resource request for huge pages
```

The VEP-152 branch removed the classic `hugepages-1Gi` pod resource request
when `MemoryWithDRA` was enabled. That is incompatible with KubeVirt's
HugePages `emptyDir` volume, which kubelet still requires to have a matching
pod resource request.

The branch was fixed to retain the matching hugepage request and the
controller/launcher images were rebuilt and deployed. The rerun created a
launcher pod with `hugepages-1Gi: 4Gi` in both requests and limits, and the VM
reached `Running`/`Ready`.

Final allocation after the fix:

| Request | Driver | Device |
|---|---|---|
| `cpu` | `dra.cpu` | `cpudevnuma000` |
| `mem` | `dra.memory` | `hugepages-1gi-pjj9lv` |
| `gpu0` | `gpu.amd.com` | `gpu-vfio-4` |
| `nic0` | `sriovnetwork.k8snetworkplumbingwg.io` | `0000-1d-00-2` |

The GPU and NIC both resolve to `pci0000:15`. CPU and memory are selected on
NUMA node 0 by the generated claim's `resource.kubernetes.io/numaNode`
constraint.

The non-hugepage counterpart, `amd-cpu-gpu-nic-explicit`, remains Running and
Ready with the same GPU/NIC PCIe-root constraint and DRA CPU allocation.

## Driver recovery observation

Restarting kubelet caused the SR-IOV ResourceSlice to disappear temporarily.
The SR-IOV driver continued to discover all 16 VFs, and restarting its
DaemonSet restored the ResourceSlice and all PCIe-root attributes. The current
SR-IOV driver pod is Running.
