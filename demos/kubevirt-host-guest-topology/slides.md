# Slides: Host and Guest Topology Match

10-minute presentation.
Live deck: https://docs.google.com/presentation/d/1aGQzYyEnA9x0MAjxAloL4RM6BtEwLO8L3Ig3k7Hp3f8/edit
Earlier HTML version: https://claude.ai/artifact/5rcNeAH7E42PsepyhErtZg

## 1. Cover

**Host and guest topology match** — a KubeVirt VM carries its host's NUMA and
PCIe-root placement for two GPU/NIC pairs straight into the guest.

AMD MI300X • ConnectX-6 • Kubernetes DRA • KubeVirt. 10-minute
proof-of-concept demonstration.

## 2. Use cases for topology-aware VMs

DRA picks co-located devices on the host; KubeVirt makes the guest see that
same layout. Get either half wrong and NCCL, vLLM, and numactl inside the
guest pin to the wrong node and silently lose bandwidth.

Three VM use cases:

- **Single-NUMA inference** — a NUMA node can host several GPUs and NICs;
  DRA pairs the ones sharing a PCIe root. vLLM pins threads and memory to
  the local node.
- **Multi-NUMA training** — GPUs span sockets; NCCL/RCCL sees the two-NUMA
  layout and selects the right RDMA path.
- **Full-node VM** — a VM spanning every GPU on the server; guest topology
  mirrors the host socket-for-socket.

Why a VM: hardware isolation, per-tenant driver versions, compliance
boundaries, and lift-and-shift from VMware/KVM.

## 3. This is a POC — upstream building blocks

Proven end-to-end on real hardware with local patches; not yet fully
upstream.

- **Kubernetes KEPs:** KEP-4381 (DRA structured parameters), KEP-5304
  (native device metadata), KEP-5491 (list-typed attributes)
- **KubeVirt VEPs:** VEP-10 (GPUsWithDRA), VEP-183 (NetworkDevicesWithDRA),
  VEP-115 (PCI NUMA-aware topology + enhancements for DRA, beta), VEP-152
  (CPU DRA support, alpha), KubeVirt memory DRA support (POC)
- **Drivers:** AMD GPU DRA w/VFIO (alpha), dra-driver-sriov (alpha/beta),
  dra-driver-cpu (beta), dra-driver-memory (alpha)
- **Hardware:** Dell XE9680 — 2× Xeon 6448Y, 8× AMD MI300X, 2× ConnectX-6 Dx

## 4. Demo overview

**The claim:** 8 CPUs, 4 GiB of 1-GiB hugepage memory, 2× AMD GPU VFs, 2×
ConnectX6 NIC VFs, two independent GPU/NIC pairs.

**Placement constraints:**

- Each GPU + NIC shares a PCIe root.
- Each pair's CPU and memory share its NUMA node.

CPUs and hugepages are DRA requests too, so the scheduler lands them on the
pair's NUMA node; `guestMappingPassthrough` needs both to build the guest
NUMA cells.

**Five checks:** physical host topology → device attributes each driver
publishes → ResourceSlices from all four drivers → claim allocation →
topology inside the guest.

(`hw-topology.sh` and `dra-verify.sh topology / slices / claims / guest`)

## 5. The claim — one ResourceClaim, four drivers

`ResourceClaimTemplate amd-host-guest-topology-dual-pair`: eight requests
across four drivers (`demo-vm.yaml`).

- requests: `cpu0`, `cpu1` (dra.cpu, 4 each) | `mem0`, `mem1`
  (dra.hugepages-1g, 2Gi each) | `gpu0`, `gpu1` (gpu.amd.com) | `nic0`,
  `nic1` (sriovnetwork.k8snetworkplumbingwg.io)

```yaml
constraints:
  - matchAttribute: resource.kubernetes.io/pcieRoot
    requests: [gpu0, nic0]
  - matchAttribute: resource.kubernetes.io/pcieRoot
    requests: [gpu1, nic1]
  - matchAttribute: resource.kubernetes.io/numaNode
    requests: [cpu0, mem0, gpu0, nic0]
  - matchAttribute: resource.kubernetes.io/numaNode
    requests: [cpu1, mem1, gpu1, nic1]
```

The scheduler enforces the pairing from standard attributes the drivers
publish in their ResourceSlices: no node labels, no driver-specific placement
logic. The VM references the claim by request name (`gpu0` → `amd-gpu-0`,
`nic0` → `connectx-vf-0`).

## 6. Server diagram — the selected pair

Dell XE9680 — 2 sockets, 8 GPUs total; 2 GPUs are used by this claim. Real
PCI addresses from the recording:

| NUMA | pcieRoot | GPU (used) | NIC (used) | Idle GPUs on this node |
|------|----------|------------|------------|-------------------------|
| 0 | `pci0000:15` | `0000:1b:02.0` | `0000:1d:00.2` (ConnectX-6) | `0000:3d:02.0`, `0000:4e:02.0`, `0000:5f:02.0` |
| 1 | `pci0000:97` | `0000:9d:02.0` | `0000:9f:00.2` (ConnectX-6) | `0000:bd:02.0`, `0000:cd:02.0`, `0000:dd:02.0` |

A GPU pairs with a NIC only when they share a PCIe root; the claim selects
those pairs.

## 7. How topology is constructed inside the VM

Three hops from ResourceSlice to guest NUMA:

1. **Drivers publish** — DRA drivers attach KEP-5304 metadata to each
   device (`pciBusID` + `pcieRoot` + `numaNode` → files under
   `/var/run/kubernetes.io/dra-device-attributes/`).
2. **virt-launcher reads** — the kubelet mounts the metadata into the pod;
   virt-launcher maps `pciBusID` to `<hostdev>` entries in the domain XML.
3. **Guest boots aligned** — KubeVirt creates one `pxb-pcie` expander bus
   per guest NUMA cell and maps host NUMA IDs to guest cell IDs.

Enabled by `kubevirt.io/pci-topology-version: v3` and
`guestMappingPassthrough`.

## Demo screenshots (shown live, not a slide)

Two real frames from `demo.mp4`:

- `dra-verify.sh claims` — the scheduler's own claim output, with
  `pcieRoot aligned` and `numaNode aligned` checkmarks for both pairs.
- `dra-verify.sh guest $VM` — the same check from inside the running
  guest: NUMA 0 with CPUs 0–3, NUMA 1 with CPUs 4–7, each still carrying
  its own GPU and NIC behind one pcieRoot.
