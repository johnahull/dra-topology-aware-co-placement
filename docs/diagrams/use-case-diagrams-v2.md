# Use Case Hardware Diagrams (v2)

Visual illustrations of topology use cases on real test hardware. Each diagram shows which devices are selected and how they relate to the PCIe and NUMA topology.

---

## 1. pcieRoot — NCCL Proxy (XE8640, 4x H100 SXM5)

GPU `5f` and E810 NIC share PCIe switch SW1 on `pci0000:59`. NCCL selects GPU `5f` as the inter-node RDMA proxy. The other 3 GPUs relay data to the proxy over NVLink.

![pcieRoot NCCL Proxy](uc1-pcieroot-nccl-proxy.svg)

---

## 2. pcieRoot Unsatisfiable (R760xa, 2x A40)

Every PCIe slot has its own root port — no two devices share a root. `matchAttribute: pcieRoot` fails for any GPU+NIC pair. All Socket 0 devices are co-located by `numaNode`.

![pcieRoot Unsatisfiable](uc2-pcieroot-unsatisfiable.svg)

---

## 3. numaNode — Training Pod (XE9680, 8x MI300X)

4 GPUs + NIC + CPU + memory co-located on each NUMA node. GPU sharing a switch with the NIC acts as the RCCL proxy for inter-node RDMA. Other GPUs communicate via xGMI.

![numaNode Training Pod](uc3-numanode-training.svg)

---

## 4. numaNode — Multi-Tenant Inference (XE9680)

4 independent inference pods on one NUMA node, each with its own GPU and NIC VF for multi-tenancy. The NIC PF sits behind a shared PCIe switch with GPU 1b (pci0000:15), while GPUs 3d, 4e, 5f are on their own root ports. SR-IOV splits the NIC into 4 VFs — one per pod. `matchAttribute: numaNode` pairs all 4 GPUs with VFs (100% yield). `matchAttribute: pcieRoot` would only pair GPU 1b (25% yield).

![numaNode Multi-Tenant Inference](uc4-numanode-multitenant.svg)

---

## 5. KubeVirt Single-NUMA VM (R760xa)

1 A40 GPU + 1 ConnectX-7 VF on NUMA 0 passed through via VFIO. KEP-5304 metadata carries PCI addresses and NUMA nodes to virt-launcher. VEP 115 builds a single pxb-pcie bus on guest NUMA 0.

![KubeVirt Single-NUMA VM](uc5-kubevirt-single-numa.svg)

---

## 6. KubeVirt Multi-NUMA VM (XE9680, 8x MI300X)

Full-node training VM with all 8 GPUs spanning both sockets. Host devices are bound to `vfio-pci` and passed through to the guest. KEP-5304 metadata carries each device's PCI address and NUMA node to virt-launcher, which builds the guest topology using VEP 115 `pxb-pcie` expander buses. The guest sees 2 NUMA nodes matching the host layout — 4 GPUs + 1 NIC per guest NUMA. NCCL inside the VM reads guest `numa_node` and selects a proxy GPU per NUMA (GPU `1b` on guest NUMA 0, GPU `9d` on guest NUMA 1) for inter-node RDMA. Without correct guest topology, NCCL sees all 8 GPUs as flat and can't optimize per-NUMA proxy selection.

![KubeVirt Multi-NUMA VM](uc6-kubevirt-multi-numa.svg)

---

## 7. GPU VF Multi-Tenant — Developer Partitioning (XE9680)

GPU SR-IOV slicing for developer multi-tenancy. Each MI300X is split into 4 VFs via SR-IOV, giving 16 GPU slices per NUMA node (32 per node). Each developer pod gets 1 GPU VF + 1 NIC VF + CPUs, all on the same NUMA. Shows 2 of 4 physical GPUs — GPU 1b (shares a PCIe switch with the NIC) and GPU 3d (own root port). `matchAttribute: numaNode` groups all GPU VFs and NIC VFs on the same NUMA regardless of which PCIe root they're behind. `pcieRoot` would only group GPU 1b's VFs with the NIC VFs.

![GPU VF Multi-Tenant](uc7-gpu-vf-multitenant.svg)
