# Slides: Host and Guest Topology Match

10-minute presentation. Live deck: https://claude.ai/artifact/5rcNeAH7E42PsepyhErtZg

## 1. Cover

**Host and guest topology match** — a KubeVirt VM carries its host's NUMA and
PCIe-root placement for two GPU/NIC pairs straight into the guest.

## 2. Use cases for topology-aware VMs

Three VM use cases:

- **Single-NUMA inference** — 1-2 GPUs + a NIC on one NUMA node; vLLM pins
  threads and memory to the node that's actually local.
- **Multi-NUMA training** — GPUs span sockets; NCCL/RCCL sees the real
  2-NUMA layout and picks the right RDMA proxy GPU.
- **Full-node VM** — a VM spanning every GPU on the box; guest topology
  mirrors the host socket-for-socket.

Why a VM, not a pod: multi-tenancy with hardware isolation, per-tenant
driver versions, compliance boundaries, and lift-and-shift off VMware/KVM
without repackaging as containers.

## 3. This is a POC — KEPs, VEPs, and DRA drivers used

Proven end-to-end on real hardware with local patches; not yet fully
upstream.

- **Kubernetes KEPs:** KEP-4381 (DRA structured parameters), KEP-5304
  (native device metadata), KEP-5491 (list-typed attributes)
- **KubeVirt VEPs:** VEP 10 (GPUsWithDRA), VEP 183 (NetworkDevicesWithDRA),
  VEP 115 (PCI NUMA-aware topology)
- **DRA drivers in this demo:** AMD GPU DRA driver, SR-IOV network DRA
  driver, CPU DRA driver (kubernetes-sigs), memory DRA driver
  (hugepages-1Gi)
- **Hardware:** Dell XE9680 — 2× Xeon 6448Y, 8× AMD MI300X, 2× ConnectX-6 Dx

## 4. Demo overview

**The claim:** 8 CPUs, 4 GiB of 1-GiB hugepage memory, 2× AMD GPU VFs, 2×
ConnectX NIC VFs, split into two independent pairs. Each GPU+NIC shares a
PCIe root; each pair's CPU and memory share that pair's NUMA node.

**How we verify it** — five checks, host to guest:

1. Physical host topology
2. What the DRA drivers publish
3. ResourceSlices, all four drivers
4. Claim allocation, pairs aligned
5. Topology from inside the guest

(`hw-topology.sh` and `dra-verify.sh topology / slices / claims / guest`)

## 5. How the topology is constructed inside the VM

Three hops from ResourceSlice to guest NUMA:

1. **Drivers publish** — DRA drivers attach KEP-5304 metadata to each
   allocated device (`pciBusID` + `numaNode` → JSON files under
   `/var/run/kubernetes.io/dra-device-attributes/`).
2. **virt-launcher reads** — the kubelet mounts the metadata into the pod;
   virt-launcher reads it (`pciBusID` → `<hostdev>` in the domain XML).
3. **Guest boots aligned** — one `pxb-pcie` expander bus per guest NUMA
   cell; host NUMA IDs are mapped to guest cell IDs
   (`numaNode` → pxb-pcie → guest cell).

Enabled by two VM annotations: `kubevirt.io/pci-topology-version: v3` and
`guestMappingPassthrough` on the domain's CPU/NUMA spec.

## 6. Server diagram

Dell XE9680 — 2 sockets, 8 GPUs total, 2 used by this claim. Real PCI
addresses from the recording:

| NUMA | pcieRoot | GPU (used) | Idle GPUs on this node | NIC (used) |
|------|----------|------------|-------------------------|------------|
| 0 | `pci0000:15` | `1b:02.0` | `3d:02.0`, `4e:02.0`, `5f:02.0` | `1d:00.2` (ConnectX-6) |
| 1 | `pci0000:97` | `9d:02.0` | `bd:02.0`, `cd:02.0`, `dd:02.0` | `9f:00.2` (ConnectX-6) |

Only one GPU per socket shares a PCIe root with a NIC — that's the pair
this claim asks for. The other six GPUs sit on other roots and go unused
by this particular VM.

## 7. Demo screenshots

Two real frames from `demo.mp4`:

- `dra-verify.sh claims` — the scheduler's own claim output, with
  `pcieRoot aligned` and `numaNode aligned` checkmarks for both pairs.
- `dra-verify.sh guest $VM` — the same check from inside the running
  guest: NUMA 0 with CPUs 0–3, NUMA 1 with CPUs 4–7, each still carrying
  its own GPU and NIC behind one pcieRoot.
