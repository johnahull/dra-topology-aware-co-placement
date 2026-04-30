# Use Case Hardware Diagrams

Visual illustrations of topology use cases on real test hardware. Each diagram shows which devices are selected, the DMA paths used, and the NVLink/xGMI interconnects between GPUs.

Blue = selected/co-located devices. Grey = not selected. Green = NVLink/xGMI path. Red = cross-NUMA path (avoided).

---

## 1. pcieRoot — NCCL Proxy (XE8640, 4x H100 SXM5)

GPU `5f` and E810 NIC share PEX890xx switch SW1 on `pci0000:59`. NCCL selects GPU `5f` as the inter-node RDMA proxy. The other 3 GPUs relay data to the proxy over NVLink (900 GB/s bidirectional), and the proxy sends it out the NIC via GPUDirect RDMA with no root complex hop.

```mermaid
graph TD
    subgraph "Socket 0 — NUMA 0"
        subgraph "Switch SW1 (pci0000:59) — NCCL proxy pair"
            GPU1["GPU 5f (H100) — RDMA PROXY"]
            E810["E810 NIC 5e — inter-node RDMA"]
            GPU1 ---|"GPUDirect RDMA<br/>(no root complex hop)"| E810
        end
        subgraph "Switch SW0 (pci0000:48)"
            GPU0["GPU 4e (H100)"]
        end
    end

    subgraph "Socket 1 — NUMA 1"
        subgraph "Switch SW2 (pci0000:c7)"
            GPU2["GPU cb (H100)"]
        end
        subgraph "Switch SW3 (pci0000:d7)"
            GPU3["GPU db (H100)"]
        end
    end

    GPU0 ---|"NVLink"| GPU1
    GPU2 ---|"NVLink"| GPU1
    GPU3 ---|"NVLink"| GPU1
    GPU0 ---|"NVLink"| GPU2
    GPU0 ---|"NVLink"| GPU3
    GPU2 ---|"NVLink"| GPU3

    style GPU1 fill:#2a6,color:#fff
    style E810 fill:#2a6,color:#fff
    style GPU0 fill:#49a,color:#fff
    style GPU2 fill:#49a,color:#fff
    style GPU3 fill:#49a,color:#fff
```

**Key:** GPU `5f` is the only GPU that qualifies for `pcieRoot` matching with the NIC. The other GPUs don't need direct NIC access — NVLink to the proxy is faster than each GPU going to the NIC independently over PCIe.

---

## 2. pcieRoot Unsatisfiable (R760xa, 2x A40)

Every PCIe slot has its own root port — no two devices share a root. `matchAttribute: pcieRoot` fails for any GPU+NIC pair. `enforcement: preferred` relaxes pcieRoot and falls through to `numaNode`, which correctly pairs both GPUs with the ConnectX-7 on NUMA 0.

```mermaid
graph TD
    subgraph "Socket 0 — NUMA 0"
        subgraph "Root pci0000:49 (own root)"
            GPU0["A40 GPU 4a"]
        end
        subgraph "Root pci0000:60 (own root)"
            GPU1["A40 GPU 61"]
        end
        subgraph "Root pci0000:36 (own root)"
            CX7["ConnectX-7 37"]
        end
        subgraph "Root pci0000:21 (own root)"
            E810R["E810-XXV 22"]
        end
        RC0["Root Complex 0"]
        GPU0 ---|"PCIe"| RC0
        GPU1 ---|"PCIe"| RC0
        CX7 ---|"PCIe"| RC0
        E810R ---|"PCIe"| RC0
    end

    subgraph "Socket 1 — NUMA 1 (no GPUs)"
        subgraph "Root pci0000:9f (own root)"
            BF3["BlueField-3 a0"]
        end
        subgraph "Root pci0000:b4 (own root)"
            CX6["ConnectX-6 Dx b5"]
        end
    end

    style GPU0 fill:#49a,color:#fff
    style GPU1 fill:#49a,color:#fff
    style CX7 fill:#49a,color:#fff
    style E810R fill:#49a,color:#fff
    style BF3 fill:#888,color:#fff
    style CX6 fill:#888,color:#fff
```

**Key:** No shared switches. `pcieRoot` → unsatisfiable. `numaNode` → all Socket 0 devices co-located (blue). Socket 1 NICs (grey) excluded — wrong NUMA.

---

## 3. numaNode — Training Pod (XE9680, 8x MI300X)

4 GPUs + NIC + CPU + memory co-located on NUMA 0. GPUs communicate over xGMI (Infinity Fabric). GPU `1b` shares a switch with the NIC and acts as the NCCL proxy for inter-node RDMA. NUMA 1 is an independent second training group.

```mermaid
graph TD
    subgraph "Training Pod — NUMA 0"
        subgraph "Switch (pci0000:15)"
            GPU0["GPU 1b — RDMA PROXY"]
            NIC0["NIC 1d (CX-6 Dx)"]
            GPU0 ---|"GPUDirect RDMA"| NIC0
        end
        subgraph "Switch (pci0000:37)"
            GPU1["GPU 3d"]
        end
        subgraph "Switch (pci0000:48)"
            GPU2["GPU 4e"]
        end
        subgraph "Switch (pci0000:59)"
            GPU3["GPU 5f"]
        end
        CPU0["64 CPUs (even)"]
        MEM0["~1 TB memory"]
    end

    GPU0 ---|"xGMI"| GPU1
    GPU0 ---|"xGMI"| GPU2
    GPU0 ---|"xGMI"| GPU3
    GPU1 ---|"xGMI"| GPU2
    GPU1 ---|"xGMI"| GPU3
    GPU2 ---|"xGMI"| GPU3

    subgraph "Training Pod — NUMA 1"
        subgraph "Switch (pci0000:97)"
            GPU4["GPU 9d — RDMA PROXY"]
            NIC1["NIC 9f (CX-6 Dx)"]
            GPU4 ---|"GPUDirect RDMA"| NIC1
        end
        GPU5["GPU bd"]
        GPU6["GPU cd"]
        GPU7["GPU dd"]
    end

    GPU4 ---|"xGMI"| GPU5
    GPU4 ---|"xGMI"| GPU6
    GPU4 ---|"xGMI"| GPU7
    GPU5 ---|"xGMI"| GPU6
    GPU5 ---|"xGMI"| GPU7
    GPU6 ---|"xGMI"| GPU7

    style GPU0 fill:#2a6,color:#fff
    style NIC0 fill:#2a6,color:#fff
    style GPU1 fill:#49a,color:#fff
    style GPU2 fill:#49a,color:#fff
    style GPU3 fill:#49a,color:#fff
    style CPU0 fill:#49a,color:#fff
    style MEM0 fill:#49a,color:#fff
    style GPU4 fill:#2a6,color:#fff
    style NIC1 fill:#2a6,color:#fff
    style GPU5 fill:#49a,color:#fff
    style GPU6 fill:#49a,color:#fff
    style GPU7 fill:#49a,color:#fff
```

**Key:** All 8 GPUs usable (100% yield). Each NUMA group has its own proxy GPU + NIC pair. xGMI links handle GPU-to-GPU communication. The one root complex hop for non-proxy GPUs to reach the NIC is negligible.

---

## 4. numaNode — Multi-Tenant Inference (XE9680)

4 independent inference pods on NUMA 0, each with its own GPU and NIC VF. No NVLink between pods — each GPU is isolated. Each pod gets its own SR-IOV VF from the physical NIC for network isolation.

```mermaid
graph TD
    subgraph "NUMA 0"
        subgraph "Pod 1"
            P1_GPU["GPU 1b"]
            P1_NIC["NIC VF 1d:00.2"]
        end
        subgraph "Pod 2"
            P2_GPU["GPU 3d"]
            P2_NIC["NIC VF 1d:00.3"]
        end
        subgraph "Pod 3"
            P3_GPU["GPU 4e"]
            P3_NIC["NIC VF 1d:00.4"]
        end
        subgraph "Pod 4"
            P4_GPU["GPU 5f"]
            P4_NIC["NIC VF 1d:00.5"]
        end
        NIC_PF["NIC PF 1d:00.0 (CX-6 Dx)<br/>SR-IOV: 4 VFs active"]
        P1_NIC -.-> NIC_PF
        P2_NIC -.-> NIC_PF
        P3_NIC -.-> NIC_PF
        P4_NIC -.-> NIC_PF
    end

    style P1_GPU fill:#49a,color:#fff
    style P1_NIC fill:#49a,color:#fff
    style P2_GPU fill:#2a6,color:#fff
    style P2_NIC fill:#2a6,color:#fff
    style P3_GPU fill:#fa4,color:#000
    style P3_NIC fill:#fa4,color:#000
    style P4_GPU fill:#a4f,color:#fff
    style P4_NIC fill:#a4f,color:#fff
    style NIC_PF fill:#888,color:#fff
```

**Key:** Each pod has its own color — isolated GPU + VF pairs. All on NUMA 0 via `matchAttribute: numaNode`. VFs share physical NIC bandwidth but have independent IPs for routing/monitoring. No NVLink used — pods don't cooperate.

---

## 5. KubeVirt Single-NUMA VM (R760xa)

1 A40 GPU + 1 ConnectX-7 VF on NUMA 0 passed through via VFIO. KEP-5304 metadata carries PCI addresses and NUMA nodes to virt-launcher. VEP 115 builds a single pxb-pcie bus on guest NUMA 0.

```mermaid
graph TD
    subgraph "Host — NUMA 0"
        GPU_H["A40 GPU 4a<br/>(vfio-pci)"]
        NIC_H["CX-7 VF 37:00.1<br/>(vfio-pci)"]
        CPU_H["CPUs 4,6,68,70<br/>(dedicated)"]
        MEM_H["hugepages<br/>(NUMA 0)"]
    end

    subgraph "KEP-5304 Metadata"
        META["pciBusID: 0000:4a:00.0, numaNode: 0<br/>pciBusID: 0000:37:00.1, numaNode: 0"]
    end

    subgraph "Guest VM"
        subgraph "Guest NUMA 0"
            subgraph "pxb-pcie bus 0"
                GPU_G["GPU (numa_node=0)"]
                NIC_G["NIC VF (numa_node=0)"]
            end
            CPU_G["4 vCPUs"]
            MEM_G["4 GiB hugepages"]
        end
    end

    GPU_H --> META
    NIC_H --> META
    META --> GPU_G
    META --> NIC_G

    style GPU_H fill:#49a,color:#fff
    style NIC_H fill:#49a,color:#fff
    style CPU_H fill:#49a,color:#fff
    style MEM_H fill:#49a,color:#fff
    style GPU_G fill:#2a6,color:#fff
    style NIC_G fill:#2a6,color:#fff
    style CPU_G fill:#2a6,color:#fff
    style MEM_G fill:#2a6,color:#fff
    style META fill:#fa4,color:#000
```

**Key:** Host devices (blue) → KEP-5304 metadata (orange) → guest devices (green). Guest sees `numa_node=0` on both devices. vLLM inside the VM correctly pins to NUMA 0.

---

## 6. KubeVirt Multi-NUMA VM (XE9680, 8x MI300X)

Full-node training VM with all 8 GPUs spanning both sockets. Guest sees 2 NUMA nodes with 4 GPUs + 1 NIC each. NCCL inside the VM reads guest `numa_node` and selects a proxy GPU per NUMA (GPU `1b` on guest NUMA 0, GPU `9d` on guest NUMA 1) for inter-node RDMA. xGMI handles GPU-to-GPU communication within and across guest NUMA nodes.

```mermaid
graph TD
    subgraph "Host"
        subgraph "NUMA 0"
            H_GPU0["GPU 1b"]
            H_GPU1["GPU 3d"]
            H_GPU2["GPU 4e"]
            H_GPU3["GPU 5f"]
            H_NIC0["NIC 1d (CX-6 Dx)"]
        end
        subgraph "NUMA 1"
            H_GPU4["GPU 9d"]
            H_GPU5["GPU bd"]
            H_GPU6["GPU cd"]
            H_GPU7["GPU dd"]
            H_NIC1["NIC 9f (CX-6 Dx)"]
        end
    end

    subgraph "Guest VM (2 NUMA nodes)"
        subgraph "Guest NUMA 0 (pxb-pcie bus 0)"
            G_GPU0["GPU 1b (numa_node=0) — PROXY"]
            G_GPU1["GPU 3d (numa_node=0)"]
            G_GPU2["GPU 4e (numa_node=0)"]
            G_GPU3["GPU 5f (numa_node=0)"]
            G_NIC0["NIC 1d (numa_node=0)"]
            G_CPU0["vCPUs 0-31"]
            G_GPU0 ---|"GPUDirect RDMA"| G_NIC0
        end
        subgraph "Guest NUMA 1 (pxb-pcie bus 1)"
            G_GPU4["GPU 9d (numa_node=1) — PROXY"]
            G_GPU5["GPU bd (numa_node=1)"]
            G_GPU6["GPU cd (numa_node=1)"]
            G_GPU7["GPU dd (numa_node=1)"]
            G_NIC1["NIC 9f (numa_node=1)"]
            G_CPU1["vCPUs 32-63"]
            G_GPU4 ---|"GPUDirect RDMA"| G_NIC1
        end
    end

    G_GPU0 ---|"xGMI"| G_GPU1
    G_GPU0 ---|"xGMI"| G_GPU4
    G_GPU2 ---|"xGMI"| G_GPU3
    G_GPU4 ---|"xGMI"| G_GPU5
    G_GPU6 ---|"xGMI"| G_GPU7

    style H_GPU0 fill:#2a6,color:#fff
    style H_GPU1 fill:#49a,color:#fff
    style H_GPU2 fill:#49a,color:#fff
    style H_GPU3 fill:#49a,color:#fff
    style H_NIC0 fill:#2a6,color:#fff
    style H_GPU4 fill:#2a6,color:#fff
    style H_GPU5 fill:#49a,color:#fff
    style H_GPU6 fill:#49a,color:#fff
    style H_GPU7 fill:#49a,color:#fff
    style H_NIC1 fill:#2a6,color:#fff
    style G_GPU0 fill:#2a6,color:#fff
    style G_GPU1 fill:#49a,color:#fff
    style G_GPU2 fill:#49a,color:#fff
    style G_GPU3 fill:#49a,color:#fff
    style G_NIC0 fill:#2a6,color:#fff
    style G_CPU0 fill:#49a,color:#fff
    style G_GPU4 fill:#2a6,color:#fff
    style G_GPU5 fill:#49a,color:#fff
    style G_GPU6 fill:#49a,color:#fff
    style G_GPU7 fill:#49a,color:#fff
    style G_NIC1 fill:#2a6,color:#fff
    style G_CPU1 fill:#49a,color:#fff
```

**Key:** Guest sees 2 NUMA nodes matching host placement. Each guest NUMA has 4 GPUs + 1 NIC — NCCL selects a proxy per NUMA for inter-node RDMA. xGMI connects GPUs within and across guest NUMA nodes. Without guest topology, NCCL sees all 8 GPUs as flat and can't optimize per-NUMA proxy selection.
