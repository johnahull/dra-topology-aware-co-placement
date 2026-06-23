# XE9785L MI355X DRA Topology Session — 2026-06-23

## Hardware

- **Server:** Dell PowerEdge XE9785L
- **CPU:** 2× AMD EPYC 9575F 64-Core (256 threads), NPS4 (8 NUMA nodes)
- **GPU:** 8× AMD Instinct MI355X (device ID 0x75a3)
- **NIC:** 8× AMD Pensando DSC3 Salina, 2× Mellanox ConnectX-6 Dx (SR-IOV)
- **NVMe:** 4× Micron 9550 PRO
- **Memory:** ~3 TB
- **OS:** Fedora 44, kernel 7.0.12-201.fc44.x86_64
- **Address:** 10.14.202.25

## Topology

```
Socket 0 (NUMA 0-3):
  NUMA 0: pcieRoot pci0000:d0  — GPU, Pensando NIC, 4× Mellanox CX6 VFs
  NUMA 1: pcieRoot pci0000:00  — GPU, Pensando NIC
  NUMA 2: pcieRoot pci0000:32  — GPU, Pensando NIC, NVMe
  NUMA 3: pcieRoot pci0000:a0  — GPU, Pensando NIC, NVMe

Socket 1 (NUMA 4-7):
  NUMA 4: pcieRoot pci0001:d0  — GPU, Pensando NIC
  NUMA 5: pcieRoot pci0001:00  — GPU, Pensando NIC, 4× Mellanox CX6 VFs
  NUMA 6: pcieRoot pci0001:32  — GPU, Pensando NIC, NVMe
  NUMA 7: pcieRoot pci0001:a0  — GPU, Pensando NIC, NVMe
```

## Software Stack Deployed

### Kubernetes
- **Version:** v1.37.0-alpha.1.338+d03fd8d3b15076
- **Branch:** `feature/standard-numanode-list-v3` (johnahull/kubernetes)
- **Feature gates:** `DRAListTypeAttributes=true` on apiserver, scheduler, controller-manager, kubelet
- **Key change:** Standard `resource.kubernetes.io/numaNode` attribute with both scalar (IntValue) and list (IntValues) forms via SLIT-based helpers

### DRA Drivers (all using v3 numaNode helpers)

| Driver | Branch | Helper | Devices |
|--------|--------|--------|---------|
| CPU | `feature/standardized-topology-attrs` | `GetNUMANodeAttribute` | 8 NUMA groups |
| Memory | `feature/standardized-topology-attrs` | `GetNUMANodeAttribute` | 8 memory zones |
| NVMe | `feature/local-numa-nodes-list` | `GetNUMANodeAttributeByPCIBusID` | 4 SSDs |
| SR-IOV | `feature/dra-topology-co-placement` | `GetNUMANodeAttribute` | 8 VFs (4 per socket) |
| AMD GPU | `feature/vfio-kep5304-combined` | `GetNUMANodeAttributeByPCIBusID` | 8 GIM VFs |
| dranet | `feature/standardized-topology-attrs` | `GetNUMANodeAttributeByPCIBusID` | 21 PCI NICs |

### GIM (GPU Isolation Module)
- Built from source: `/home/jhull/devel/amd/MxGPU-Virtualization/gim`
- 8 VFs created (1 per GPU PF), device ID 0x75b3
- All VFs bound to vfio-pci

### KubeVirt
- **Branch:** `feature/dra-unified` (johnahull/kubevirt)
- **Base images:** quay.io/kubevirt v1.8.0 (for libvirt 11.9.0 compatibility)
- **Feature gates:** `GPUsWithDRA`, `HostDevicesWithDRA`, `HostDevices`, `Root`
- **Build fix:** Added missing `IsVFIOVMI()` function, fixed `WithExtraResourceClaims` type mismatch

### Topology Coordinator
- **Branch:** `test/all-fixes-combined` (k8s-dra-topology-coordinator)
- Cherry-picked: `Add numaNode list-type support and includes() CEL selectors`
- 11 DeviceClasses: full, 2 half (socket), 8 quarter (NUMA)

## Tests Performed

### 1. numaNode List vs Scalar Verification (all 5 drivers)

All drivers tested with `--numa-list=true` (list) and `--numa-list=false` (scalar):

**List form:** `resource.kubernetes.io/numaNode: {"ints": [2, 0, 1, 3]}` — physical node + equidistant same-socket SLIT peers
**Scalar form:** `resource.kubernetes.io/numaNode: {"int": 2}` — physical node only

### 2. Cross-Driver matchAttribute Claims

**5-driver numaNode (CPU+memory+GPU+NVMe+NIC):**
```yaml
constraints:
- matchAttribute: resource.kubernetes.io/numaNode
  requests: [gpu, nic, nvme, cpu, mem]
```
Result: All 5 on socket 1 via list intersection `{4,5,6,7}`

**pcieRoot + numaNode combined (GPU+NVMe on same root, GPU+CPU+mem on same NUMA):**
```yaml
constraints:
- matchAttribute: resource.kubernetes.io/pcieRoot
  requests: [gpu, nvme, nic]
- matchAttribute: resource.kubernetes.io/numaNode
  requests: [gpu, cpu, mem]
```
Result: GPU+NVMe+NIC on `pci0001:32`, CPU+mem on socket 1

**Multi-GPU list intersection (4 GPUs + CPU + memory):**
```yaml
- matchAttribute: resource.kubernetes.io/numaNode
  requests: [gpu, cpu, mem]
```
With `count: 4` for GPUs — scheduler picked 4 GPUs on NUMA 4,5,6,7 (all different physical nodes), intersection `{4,5,6,7}` proves same-socket. **This is the key list-form use case** — scalar would reject since `4≠5≠6≠7`.

### 3. AMD GPU VFIO Passthrough to KubeVirt VM

**PF passthrough:** FAILED — MI355X has same firmware reset bug as MI300X (PCI config space → 0xFF after VFIO reset)

**GIM VF passthrough:** SUCCESS
- GIM built from MxGPU-Virtualization source, loaded on server
- 8 VFs (device ID 0x75b3) bound to vfio-pci
- DRA driver discovers VFs as type=`vfio` with IOMMU groups
- KEP-5304 metadata published (pciBusID + numaNode)

**Single GPU VM:** Running, QEMU with `vfio-pci host=0000:dc:02.0`

**2-GPU multi-NUMA VM (with `guestMappingPassthrough`):**
- 2 guest NUMA nodes with pxb-pcie expander buses
- SLIT distances injected from host (self=10, cross=12 or 32)
- Each GPU on its own pxb-pcie bus with correct NUMA affinity

### 4. GPU + NVMe VFIO Passthrough

NVMe driver has full VFIO support (`mode: vfio` in NvmeConfig opaque parameters).

```yaml
config:
- opaque:
    driver: dra.nvme
    parameters:
      apiVersion: nvme.dra.io/v1alpha1
      kind: NvmeConfig
      mode: vfio
```

**Result:** 2 GPUs + 2 NVMe on matching pcieRoots, all on pxb-pcie with NUMA affinity. Guest `hw-topology.sh` shows GPU and NVMe as siblings under same pcieRoot per NUMA node.

### 5. GPU + SR-IOV NIC VFIO Passthrough

SR-IOV driver has VFIO support (`driver: vfio-pci` in VfConfig).

```yaml
config:
- requests: [nic0, nic1]
  opaque:
    driver: sriovnetwork.k8snetworkplumbingwg.io
    parameters:
      apiVersion: sriovnetwork.k8snetworkplumbingwg.io/v1alpha1
      kind: VfConfig
      driver: vfio-pci
```

**Important:** Must specify `requests: [nic0, nic1]` — without explicit requests list, the config is silently dropped (bug in statehelpers.go line 73).

**Result:** 2 GPUs + 2 Mellanox CX6 VFs, all VFIO passthrough with pxb-pcie NUMA placement.

### 6. GPU + Pensando DSC3 NIC Passthrough (via dranet)

Dranet supports VFIO mode for PF passthrough:

```yaml
config:
- requests: [nic0, nic1]
  opaque:
    driver: dra.net
    parameters:
      mode: vfio
```

**Bug found and fixed:** dranet's `CreateVFIOSpec()` overwrote the CDI spec file when multiple devices shared a claim (same filename keyed by claim UID). Fixed by appending devices to existing spec.

**Result:** 2 GPUs + 2 Pensando DSC3 NICs on matching pcieRoots, pxb-pcie NUMA placement. Guest sees GPU+NIC as siblings under same root complex per NUMA node.

## Bugs Found

| Bug | Driver | Fix |
|-----|--------|-----|
| MI355X PF VFIO reset → config space 0xFF | AMD firmware | Use GIM VF passthrough |
| KubeVirt missing `IsVFIOVMI()` | kubevirt | Added function in `pkg/util/util.go` |
| KubeVirt `WithExtraResourceClaims` type mismatch | kubevirt | Changed param to `[]v1.VirtualMachineInstanceResourceClaim` |
| GPU DRA driver missing VFIO metadata in PrepareResult | k8s-gpu-dra-driver | Added `Vfio` case in `prepareResourceClaim` |
| SR-IOV config silently dropped without `requests` list | dra-driver-sriov | Must specify `requests: [nic0, nic1]` in claim config |
| SR-IOV `GetAdvertisedDevices` returns 0 without policy | dra-driver-sriov | Return all allocatable when no policies exist |
| Memory driver `os.Exit(1)` on NRI failure | dra-driver-memory | Made NRI failure non-fatal |
| SR-IOV controller manager cancels context on CRD miss | dra-driver-sriov | Made controller manager failure non-fatal |
| dranet CDI spec overwrite with multi-device claims | dranet | Append devices to existing CDI spec file |
| `hw-topology.sh` missing pcieRoot header in tree view | dra-topology-aware-co-placement | Added pcieRoot grouping header |
| `hw-topology.sh` "Socket ?" for numa=-1 devices in simple view | dra-topology-aware-co-placement | Skip in simple view, show in No NUMA section |
| `dra-verify.sh` "Socket ?" when no cpuSocketID attribute | dra-topology-aware-co-placement | Infer socket from SLIT-based numaNode list grouping |

## Key Learnings

1. **numaNode list form** enables multi-device same-socket placement under NPS4 where each device has a different physical NUMA node but all share the same socket via SLIT equidistant peers
2. **pcieRoot constraint** works for GPU+NVMe+NIC co-placement within the same PCIe root complex
3. **KubeVirt pxb-pcie placement** requires `spec.domain.cpu.numa.guestMappingPassthrough: {}` in VMI spec
4. **GIM VFs** are required for AMD GPU passthrough (PF passthrough has firmware reset bug)
5. **Opaque device config** must include explicit `requests` list for SR-IOV driver
6. **Pensando DSC3** NICs support VFIO PF passthrough via dranet (no SR-IOV needed)

## Files Modified (committed and pushed)

- `testing/scripts/dra-verify.sh` — Infer socket from SLIT numaNode lists
- `testing/scripts/hw-topology.sh` — pcieRoot header in tree view, skip numa=-1 in simple view
