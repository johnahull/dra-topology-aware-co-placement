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

Each VM uses the manually authored `devices` claim, which contains all four
requests:

| Request | Driver | Device | Allocation |
|---|---|---|---|
| `cpu` | `dra.cpu` | `cpudevnuma000` | 4 CPUs |
| `mem` | `dra.memory` | `hugepages-1gi-pjj9lv` | 4Gi |

The claim includes a `matchAttribute` constraint on
`resource.kubernetes.io/numaNode` covering all four requests. GPU NUMA
attributes are published as lists; the scheduler matched the common NUMA
value across CPU, memory, GPU, and NIC.

The same claim also includes `gpu0` and `nic0`, constrained by
`resource.kubernetes.io/pcieRoot`.

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

For `amd-cpu-gpu-nic-hugepages`, the common NUMA value is 0 and the GPU/NIC
both resolve to `pci0000:15`.

The second VM, `amd-cpu-gpu-nic-explicit`, was recreated with the same manual
claim and is also Running and Ready.

Observed claim results:

| VM | CPU | Memory | GPU | NIC |
|---|---|---|---|---|
| `amd-cpu-gpu-nic-hugepages` | `cpudevnuma000` (NUMA 0) | `hugepages-1gi-pjj9lv` (0/1) | `gpu-vfio-4` (0/1) | `0000-1d-00-2` (NUMA 0) |
| `amd-cpu-gpu-nic-explicit` | `cpudevnuma002` (NUMA 2) | `hugepages-1gi-dgnnzj` (2/3) | `gpu-vfio-2` (2/3) | `0000-9f-01-2` (NUMA 2) |

For `amd-cpu-gpu-nic-explicit`, the common NUMA value is 2 and the GPU/NIC
both resolve to `pci0000:97`.

Both launcher pods reference `cpu`, `mem`, `gpu0`, and `nic0` under the single
local claim name `devices`; neither has a KubeVirt-generated `*-dra` claim.

## Driver recovery observation

Restarting kubelet caused the SR-IOV ResourceSlice to disappear temporarily.
The SR-IOV driver continued to discover all 16 VFs, and restarting its
DaemonSet restored the ResourceSlice and all PCIe-root attributes. The current
SR-IOV driver pod is Running.
