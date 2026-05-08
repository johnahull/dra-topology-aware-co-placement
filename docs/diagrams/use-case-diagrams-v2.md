# Use Case Hardware Diagrams (v2)

Visual illustrations of topology use cases on real test hardware. Each diagram shows which devices are selected and how they relate to PCIe topology (bus) and NUMA topology (memory controller). These are orthogonal physical properties — `pcieRoot` identifies which devices share a PCIe switch, `numaNode` identifies which devices share a memory controller. Some use cases need bus proximity (UC1), others need memory proximity (UC2-UC4), and KubeVirt VMs need numaNode to reconstruct guest NUMA boundaries (UC5-UC6).

---

## 1. pcieRoot — NCCL Proxy (XE8640, 4x H100 SXM5)

**Bus topology signal in action.** GPU `5f` and E810 NIC share PCIe switch SW1 on `pci0000:59` — `pcieRoot` correctly identifies this bus-level proximity. NCCL selects GPU `5f` as the inter-node RDMA proxy. The other 3 GPUs relay data to the proxy over NVLink. This is the use case pcieRoot was designed for.

![pcieRoot NCCL Proxy](uc1-pcieroot-nccl-proxy.svg)

---

## 2. pcieRoot Unsatisfiable (R760xa, 2x A40)

**Bus topology has no shared roots, but memory topology groups everything.** Every PCIe slot has its own root port — no two devices share a root. `matchAttribute: pcieRoot` fails for any GPU+NIC pair. But all Socket 0 devices share a memory controller — `matchAttribute: numaNode` co-locates them. Demonstrates that bus and memory topology are orthogonal: devices can be on separate PCIe trees while sharing a memory controller.

![pcieRoot Unsatisfiable](uc2-pcieroot-unsatisfiable.svg)

---

## 3. numaNode — Training Pod (XE9680, 8x MI300X)

**Memory topology signal for cross-driver co-placement.** 4 GPUs + NIC + CPU + memory co-located on each NUMA node — all share the same memory controller. GPU `1b` also shares a PCIe switch with the NIC (bus proximity), so RCCL selects it as the inter-node RDMA proxy. The other 3 GPUs are on different PCIe roots but the same NUMA — pcieRoot can't group them with the NIC, numaNode can.

![numaNode Training Pod](uc3-numanode-training.svg)

---

## 4. numaNode — Multi-Tenant Inference (XE9680)

**Different PCIe roots, same memory controller.** 4 independent inference pods on one NUMA node, each with its own GPU and NIC VF for multi-tenancy. The NIC PF sits behind a shared PCIe switch with GPU 1b (`pci0000:15`), while GPUs 3d, 4e, 5f are on their own root ports — different bus topology, same memory topology. SR-IOV splits the NIC into 4 VFs — one per pod. `matchAttribute: numaNode` pairs all 4 GPUs with VFs because they share a memory controller. `matchAttribute: pcieRoot` would only pair GPU 1b because it's the only one sharing a PCIe switch with the NIC.

![numaNode Multi-Tenant Inference](uc4-numanode-multitenant.svg)

---

## 5. KubeVirt Single-NUMA VM (R760xa)

**numaNode required for guest topology.** 1 A40 GPU + 1 ConnectX-7 VF on NUMA 0 passed through via VFIO. KEP-5304 metadata carries PCI addresses and NUMA nodes to virt-launcher. VEP 115 builds a single pxb-pcie bus on guest NUMA 0. pcieRoot can't be used here — the GPU and NIC are on different root ports. numaNode is the only signal that groups them into the same guest NUMA cell.

![KubeVirt Single-NUMA VM](uc5-kubevirt-single-numa.svg)

---

## 6. KubeVirt Multi-NUMA VM (XE9680, 8x MI300X)

**numaNode reconstructs NUMA boundaries that pcieRoot cannot.** Full-node training VM with all 8 GPUs spanning both sockets. Host devices are bound to `vfio-pci` and passed through to the guest. KEP-5304 metadata carries each device's PCI address and NUMA node to virt-launcher, which builds the guest topology using VEP 115 `pxb-pcie` expander buses. The 8 GPUs are on 8 different pcieRoot values — pcieRoot cannot reconstruct which 4 belong to NUMA 0 vs NUMA 1. numaNode directly encodes this grouping. The guest sees 2 NUMA nodes matching the host layout — 4 GPUs + 1 NIC per guest NUMA. NCCL inside the VM reads guest `numa_node` and selects a proxy GPU per NUMA for inter-node RDMA.

![KubeVirt Multi-NUMA VM](uc6-kubevirt-multi-numa.svg)

---

## 7. GPU VF Multi-Tenant — Developer Partitioning (XE9680)

**Memory topology groups VFs across PCIe boundaries.** GPU SR-IOV slicing for developer multi-tenancy. Each MI300X is split into 4 VFs via SR-IOV, giving 16 GPU slices per NUMA node (32 per node). Each developer pod gets 1 GPU VF + 1 NIC VF + CPUs, all on the same NUMA. Shows 2 of 4 physical GPUs — GPU 1b (shares a PCIe switch with the NIC) and GPU 3d (own root port). `matchAttribute: numaNode` groups all GPU VFs and NIC VFs that share a memory controller, regardless of which PCIe root they're behind. `matchAttribute: pcieRoot` would only group GPU 1b's VFs with the NIC VFs — the others are on different PCIe trees.

![GPU VF Multi-Tenant](uc7-gpu-vf-multitenant.svg)

---

## Orthogonality: pcieRoot vs numaNode

The following diagrams demonstrate that `pcieRoot` (bus topology) and `numaNode` (memory topology) are orthogonal signals — they partition the same device set along different physical axes.

---

### A. Two-Axis Matrix — XE8640 (4x H100 SXM5)

Devices placed on a grid with pcieRoot as rows and numaNode as columns. Multiple pcieRoot values map to one numaNode. CPU and memory have no pcieRoot — they only exist in the numaNode dimension.

```
                        │  numaNode = 0              │  numaNode = 1
────────────────────────┼────────────────────────────┼──────────────────────
pcieRoot = pci0000:48   │  H100 gpu-4e               │
                        │  NVMe (×2)                 │
────────────────────────┼────────────────────────────┼──────────────────────
pcieRoot = pci0000:59   │  H100 gpu-5f               │
                        │  E810 nic (×2)             │
                        │  NVMe (×2)                 │
────────────────────────┼────────────────────────────┼──────────────────────
pcieRoot = pci0000:26   │  CX6 Dx nic (×2)           │
────────────────────────┼────────────────────────────┼──────────────────────
pcieRoot = pci0000:00   │  BCM5720 mgmt nic (×2)     │
────────────────────────┼────────────────────────────┼──────────────────────
pcieRoot = pci0000:c7   │                            │  H100 gpu-cb
────────────────────────┼────────────────────────────┼──────────────────────
pcieRoot = pci0000:d7   │                            │  H100 gpu-db
────────────────────────┼────────────────────────────┼──────────────────────
(no pcieRoot)           │  CPU cores (×64)           │  CPU cores (×64)
                        │  Memory (~512 GiB)         │  Memory (~512 GiB)
────────────────────────┴────────────────────────────┴──────────────────────

matchAttribute: pcieRoot  →  selects one ROW  (one PCIe switch)
matchAttribute: numaNode  →  selects one COLUMN (one memory controller)
Independent axes. Neither is a finer version of the other.
```

### A. Two-Axis Matrix — XE9680 (8x MI300X, SNC off)

Same concept on a larger system. 8 PCIe roots across 2 NUMA nodes. Only 2 of 8 GPUs share a root with a NIC.

```
                        │  numaNode = 0              │  numaNode = 1
────────────────────────┼────────────────────────────┼──────────────────────
pcieRoot = pci0000:15   │  MI300X gpu-1b             │
                        │  CX6 nic (×2)  ← shared   │
────────────────────────┼────────────────────────────┼──────────────────────
pcieRoot = pci0000:37   │  MI300X gpu-3d             │
────────────────────────┼────────────────────────────┼──────────────────────
pcieRoot = pci0000:48   │  MI300X gpu-4e             │
────────────────────────┼────────────────────────────┼──────────────────────
pcieRoot = pci0000:59   │  MI300X gpu-5f             │
────────────────────────┼────────────────────────────┼──────────────────────
pcieRoot = pci0000:97   │                            │  MI300X gpu-9d
                        │                            │  CX6 nic (×2) ← shared
────────────────────────┼────────────────────────────┼──────────────────────
pcieRoot = pci0000:b7   │                            │  MI300X gpu-bd
────────────────────────┼────────────────────────────┼──────────────────────
pcieRoot = pci0000:c7   │                            │  MI300X gpu-cd
────────────────────────┼────────────────────────────┼──────────────────────
pcieRoot = pci0000:d7   │                            │  MI300X gpu-dd
────────────────────────┼────────────────────────────┼──────────────────────
(no pcieRoot)           │  CPU cores (×64)           │  CPU cores (×64)
                        │  Memory (~1 TiB)           │  Memory (~1 TiB)
────────────────────────┴────────────────────────────┴──────────────────────

pcieRoot GPU+NIC match: 2 of 8 (25%) — only gpu-1b and gpu-9d
numaNode GPU+NIC match: 8 of 8 (100%) — all GPUs share a column with NICs
```

---

### B. Same Hardware, Two Colorings — XE8640

Two views of the same NUMA 0 devices. Left: grouped by pcieRoot (4 groups, CPU/memory ungroupable). Right: grouped by numaNode (1 group, everything included).

```
    Grouped by pcieRoot (bus topology)         Grouped by numaNode (memory topology)
  ┌──────────────────────────────────┐       ┌──────────────────────────────────┐
  │                                  │       │                                  │
  │  ┌─ pci0000:48 ──────────────┐   │       │  ┌─ numaNode = 0 ─────────────┐  │
  │  │  H100 gpu-4e              │   │       │  │  H100 gpu-4e               │  │
  │  └───────────────────────────┘   │       │  │  H100 gpu-5f               │  │
  │  ┌─ pci0000:59 ──────────────┐   │       │  │  E810 nic                  │  │
  │  │  H100 gpu-5f              │   │       │  │  CX6 nic                   │  │
  │  │  E810 nic                 │   │       │  │  CPU cores (×64)           │  │
  │  └───────────────────────────┘   │       │  │  Memory (~512 GiB)         │  │
  │  ┌─ pci0000:26 ──────────────┐   │       │  └────────────────────────────┘  │
  │  │  CX6 nic                  │   │       │                                  │
  │  └───────────────────────────┘   │       │  4 pcieRoot groups → 1 numaNode  │
  │  ┌─ (no pcieRoot) ──────────┐   │       │  group. Different physical       │
  │  │  CPU cores (×64)    ⚠     │   │       │  properties, different           │
  │  │  Memory (~512 GiB)  ⚠     │   │       │  groupings of the same devices.  │
  │  └───────────────────────────┘   │       │                                  │
  │  ⚠ = cannot participate in       │       │                                  │
  │    matchAttribute: pcieRoot      │       │                                  │
  └──────────────────────────────────┘       └──────────────────────────────────┘
```

### B. Same Hardware, Two Colorings — XE9680

```
    Grouped by pcieRoot (bus topology)         Grouped by numaNode (memory topology)
  ┌──────────────────────────────────┐       ┌──────────────────────────────────┐
  │ NUMA 0:                          │       │ NUMA 0:                          │
  │  ┌─ pci0000:15 ──────────────┐   │       │  ┌─ numaNode = 0 ─────────────┐  │
  │  │  MI300X gpu-1b            │   │       │  │  MI300X gpu-1b             │  │
  │  │  CX6 nic (×2)            │   │       │  │  MI300X gpu-3d             │  │
  │  └───────────────────────────┘   │       │  │  MI300X gpu-4e             │  │
  │  ┌─ pci0000:37 ──────────────┐   │       │  │  MI300X gpu-5f             │  │
  │  │  MI300X gpu-3d            │   │       │  │  CX6 nic (×2)             │  │
  │  └───────────────────────────┘   │       │  │  CPU cores (×64)           │  │
  │  ┌─ pci0000:48 ──────────────┐   │       │  │  Memory (~1 TiB)           │  │
  │  │  MI300X gpu-4e            │   │       │  └────────────────────────────┘  │
  │  └───────────────────────────┘   │       │                                  │
  │  ┌─ pci0000:59 ──────────────┐   │       │ NUMA 1:                          │
  │  │  MI300X gpu-5f            │   │       │  ┌─ numaNode = 1 ─────────────┐  │
  │  └───────────────────────────┘   │       │  │  MI300X gpu-9d             │  │
  │  ┌─ (no pcieRoot) ──────────┐   │       │  │  MI300X gpu-bd             │  │
  │  │  CPU cores (×64)    ⚠     │   │       │  │  MI300X gpu-cd             │  │
  │  │  Memory (~1 TiB)   ⚠     │   │       │  │  MI300X gpu-dd             │  │
  │  └───────────────────────────┘   │       │  │  CX6 nic (×2)             │  │
  │                                  │       │  │  CPU cores (×64)           │  │
  │ NUMA 1:                          │       │  │  Memory (~1 TiB)           │  │
  │  ┌─ pci0000:97 ──────────────┐   │       │  └────────────────────────────┘  │
  │  │  MI300X gpu-9d            │   │       │                                  │
  │  │  CX6 nic (×2)            │   │       │  8 pcieRoot groups → 2 numaNode  │
  │  └───────────────────────────┘   │       │  groups. pcieRoot fragments what  │
  │  ┌─ pci0000:b7 ──────────────┐   │       │  numaNode unifies.              │
  │  │  MI300X gpu-bd            │   │       │                                  │
  │  └───────────────────────────┘   │       │                                  │
  │  ┌─ pci0000:c7 ──────────────┐   │       │                                  │
  │  │  MI300X gpu-cd            │   │       │                                  │
  │  └───────────────────────────┘   │       │                                  │
  │  ┌─ pci0000:d7 ──────────────┐   │       │                                  │
  │  │  MI300X gpu-dd            │   │       │                                  │
  │  └───────────────────────────┘   │       │                                  │
  │  ┌─ (no pcieRoot) ──────────┐   │       │                                  │
  │  │  CPU cores (×64)    ⚠     │   │       │                                  │
  │  │  Memory (~1 TiB)   ⚠     │   │       │                                  │
  │  └───────────────────────────┘   │       │                                  │
  └──────────────────────────────────┘       └──────────────────────────────────┘
```

---

### C. Boundary Overlay — XE8640 NUMA 0

One view with two sets of boundaries. Dashed borders show pcieRoot groups (many small groups). Solid border shows numaNode group (one large group). pcieRoot boundaries are nested within the numaNode boundary — they partition the same space differently.

```
  ┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓
  ┃  numaNode = 0  (solid border = memory controller boundary)      ┃
  ┃                                                                 ┃
  ┃   ┌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌┐  ┌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌┐   ┃
  ┃   ╎ pcieRoot:pci0000:48 ╎  ╎ pcieRoot:pci0000:59             ╎   ┃
  ┃   ╎                     ╎  ╎                                  ╎   ┃
  ┃   ╎   H100 gpu-4e      ╎  ╎   H100 gpu-5f                   ╎   ┃
  ┃   ╎   NVMe (×2)        ╎  ╎   E810 nic (×2)                 ╎   ┃
  ┃   ╎                     ╎  ╎   NVMe (×2)                     ╎   ┃
  ┃   └╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌┘  └╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌┘   ┃
  ┃                                                                 ┃
  ┃   ┌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌┐  ┌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌┐   ┃
  ┃   ╎ pcieRoot:pci0000:26 ╎  ╎ pcieRoot:pci0000:00             ╎   ┃
  ┃   ╎                     ╎  ╎                                  ╎   ┃
  ┃   ╎   CX6 Dx nic (×2)  ╎  ╎   BCM5720 mgmt (×2)            ╎   ┃
  ┃   └╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌┘  └╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌┘   ┃
  ┃                                                                 ┃
  ┃   CPU cores (×64)    ← no pcieRoot, inside numaNode boundary   ┃
  ┃   Memory (~512 GiB)  ← no pcieRoot, inside numaNode boundary   ┃
  ┃                                                                 ┃
  ┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛

  ━━━ = numaNode boundary (memory controller)
  ╌╌╌ = pcieRoot boundary (PCIe switch)

  4 pcieRoot groups nested inside 1 numaNode group.
  CPU and memory exist inside the numaNode boundary but outside all pcieRoot boundaries.
```

### C. Boundary Overlay — XE9680 NUMA 0

```
  ┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓
  ┃  numaNode = 0  (solid border = memory controller boundary)      ┃
  ┃                                                                 ┃
  ┃   ┌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌┐  ┌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌┐   ┃
  ┃   ╎ pcieRoot:pci0000:15       ╎  ╎ pcieRoot:pci0000:37      ╎   ┃
  ┃   ╎                           ╎  ╎                          ╎   ┃
  ┃   ╎   MI300X gpu-1b           ╎  ╎   MI300X gpu-3d          ╎   ┃
  ┃   ╎   CX6 nic (×2) ← shared  ╎  ╎                          ╎   ┃
  ┃   └╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌┘  └╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌┘   ┃
  ┃                                                                 ┃
  ┃   ┌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌┐  ┌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌┐   ┃
  ┃   ╎ pcieRoot:pci0000:48       ╎  ╎ pcieRoot:pci0000:59      ╎   ┃
  ┃   ╎                           ╎  ╎                          ╎   ┃
  ┃   ╎   MI300X gpu-4e           ╎  ╎   MI300X gpu-5f          ╎   ┃
  ┃   └╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌┘  └╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌┘   ┃
  ┃                                                                 ┃
  ┃   CPU cores (×64)    ← no pcieRoot                             ┃
  ┃   Memory (~1 TiB)    ← no pcieRoot                             ┃
  ┃                                                                 ┃
  ┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛

  Only gpu-1b's pcieRoot group contains a NIC.
  The other 3 GPUs are in their own pcieRoot groups with no NIC.
  All 4 GPUs + NIC + CPU + memory are inside the numaNode boundary.
```

---

### D. Constraint Result — XE8640

What the scheduler sees for a 4-device claim: 1 GPU + 1 NIC + CPU + memory, all from NUMA 0.

```
  Claim: requests: [gpu, nic, cpu, mem]

  ┌─────────────────────────────────────┬─────────────────────────────────────┐
  │ matchAttribute: pcieRoot            │ matchAttribute: numaNode            │
  │                                     │                                     │
  │ gpu-4e  pcieRoot: pci0000:48        │ gpu-4e  numaNode: 0                 │
  │ nic-cx6 pcieRoot: pci0000:26        │ nic-cx6 numaNode: 0                 │
  │                                     │                                     │
  │ pci0000:48 ≠ pci0000:26  → ✗ FAIL  │ 0 == 0                   → ✓ MATCH  │
  │                                     │                                     │
  │ gpu-5f  pcieRoot: pci0000:59        │ gpu-5f  numaNode: 0                 │
  │ nic-e810 pcieRoot: pci0000:59       │ nic-e810 numaNode: 0                │
  │                                     │                                     │
  │ pci0000:59 == pci0000:59 → ✓ MATCH  │ 0 == 0                   → ✓ MATCH  │
  │ but: cpu has no pcieRoot  → ✗ FAIL  │ cpu numaNode: 0           → ✓       │
  │       mem has no pcieRoot → ✗ FAIL  │ mem numaNode: 0           → ✓       │
  │                                     │                                     │
  │ Result: 1 of 4 devices matchable    │ Result: 4 of 4 devices match        │
  │ Constraint UNSATISFIABLE for        │ Constraint SATISFIED                │
  │ [gpu, nic, cpu, mem]                │ for [gpu, nic, cpu, mem]            │
  └─────────────────────────────────────┴─────────────────────────────────────┘

  pcieRoot answers: "same PCIe switch?" — only 1 GPU+NIC pair qualifies,
    and CPU/memory can't participate at all.
  numaNode answers: "same memory controller?" — all 4 device types qualify.
```

### D. Constraint Result — XE9680

```
  Claim: requests: [gpu, nic, cpu, mem] — allocate from NUMA 0

  ┌─────────────────────────────────────┬─────────────────────────────────────┐
  │ matchAttribute: pcieRoot            │ matchAttribute: numaNode            │
  │                                     │                                     │
  │ Candidate GPUs on NUMA 0:           │ Candidate GPUs on NUMA 0:           │
  │  gpu-1b pcieRoot: pci0000:15        │  gpu-1b numaNode: 0                 │
  │  gpu-3d pcieRoot: pci0000:37        │  gpu-3d numaNode: 0                 │
  │  gpu-4e pcieRoot: pci0000:48        │  gpu-4e numaNode: 0                 │
  │  gpu-5f pcieRoot: pci0000:59        │  gpu-5f numaNode: 0                 │
  │                                     │                                     │
  │ NIC:    pcieRoot: pci0000:15        │ NIC:    numaNode: 0                 │
  │                                     │                                     │
  │ gpu-1b matches NIC  → ✓             │ gpu-1b matches NIC  → ✓             │
  │ gpu-3d ≠ NIC root   → ✗             │ gpu-3d matches NIC  → ✓             │
  │ gpu-4e ≠ NIC root   → ✗             │ gpu-4e matches NIC  → ✓             │
  │ gpu-5f ≠ NIC root   → ✗             │ gpu-5f matches NIC  → ✓             │
  │ cpu: no pcieRoot    → ✗             │ cpu:    numaNode: 0 → ✓             │
  │ mem: no pcieRoot    → ✗             │ mem:    numaNode: 0 → ✓             │
  │                                     │                                     │
  │ Result: 1 of 4 GPUs usable         │ Result: 4 of 4 GPUs usable          │
  │ CPU/mem excluded entirely           │ CPU/mem included                     │
  │ 25% GPU yield                       │ 100% GPU yield                      │
  └─────────────────────────────────────┴─────────────────────────────────────┘

  Same hardware. Different question. Different answer.
  pcieRoot: "which GPU shares a PCIe switch with the NIC?" → 1 of 4
  numaNode: "which GPU shares a memory controller with the NIC?" → 4 of 4
```
