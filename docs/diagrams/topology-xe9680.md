# Topology Distance Hierarchy — Diagrams

## 1. PCIe Tree with DMA Paths

Shows the physical hardware topology and DMA path for each coupling level.
Diagrams in sections 1 and 2 are based on a **Dell PowerEdge XE9860** (2-socket, 8× GPU, 2× NIC).

### SNC off (2 NUMA nodes)

```mermaid
graph TD
    subgraph "Socket 0 — NUMA 0"
        subgraph "PCIe Root pci0000:15"
            SW0["PEX890xx Switch"]
            GPU0["GPU 1b"]
            NIC0["NIC 1d (CX-6 Dx)"]
            NVMe0["NVMe 18"]
            E0_0["1 empty slot"]
            GPU0 --- SW0
            NIC0 --- SW0
            NVMe0 --- SW0
            SW0 -.- E0_0
        end
        subgraph "PCIe Root pci0000:37"
            SW1["PEX890xx Switch"]
            GPU1["GPU 3d"]
            NVMe1["NVMe 3a"]
            E1_0["1 empty slot"]
            GPU1 --- SW1
            NVMe1 --- SW1
            SW1 -.- E1_0
        end
        subgraph "PCIe Root pci0000:48"
            SW2["PEX890xx Switch"]
            GPU2["GPU 4e"]
            NVMe2["NVMe 4b"]
            E2_0["1 empty slot"]
            GPU2 --- SW2
            NVMe2 --- SW2
            SW2 -.- E2_0
        end
        subgraph "PCIe Root pci0000:59"
            SW3["PEX890xx Switch"]
            GPU3["GPU 5f"]
            NVMe3["NVMe 5c"]
            E3_0["1 empty slot"]
            GPU3 --- SW3
            NVMe3 --- SW3
            SW3 -.- E3_0
        end
        RC0["Root Complex 0"]
        SW0 --- RC0
        SW1 --- RC0
        SW2 --- RC0
        SW3 --- RC0
    end

    subgraph "Socket 1 — NUMA 1"
        subgraph "PCIe Root pci0000:97"
            SW4["PEX890xx Switch (4 slots)"]
            GPU4["GPU 9d"]
            NIC1["NIC 9f (CX-6 Dx)"]
            E4_0["1 empty"]
            E4_1["1 empty (no NVMe)"]
            GPU4 --- SW4
            NIC1 --- SW4
            SW4 -.- E4_0
            SW4 -.- E4_1
        end
        subgraph "PCIe Root pci0000:b7"
            SW5["PEX890xx Switch (3 slots)"]
            GPU5["GPU bd"]
            E5_0["1 empty"]
            E5_1["1 empty (no NVMe)"]
            GPU5 --- SW5
            SW5 -.- E5_0
            SW5 -.- E5_1
        end
        subgraph "PCIe Root pci0000:c7"
            SW6["PEX890xx Switch (3 slots)"]
            GPU6["GPU cd"]
            E6_0["1 empty"]
            E6_1["1 empty (no NVMe)"]
            GPU6 --- SW6
            SW6 -.- E6_0
            SW6 -.- E6_1
        end
        subgraph "PCIe Root pci0000:d7"
            SW7["PEX890xx Switch (3 slots)"]
            GPU7["GPU dd"]
            E7_0["1 empty"]
            E7_1["1 empty (no NVMe)"]
            GPU7 --- SW7
            SW7 -.- E7_0
            SW7 -.- E7_1
        end
        RC1["Root Complex 1"]
        SW4 --- RC1
        SW5 --- RC1
        SW6 --- RC1
        SW7 --- RC1
    end

    UPI["UPI / Inter-socket Link"]
    RC0 --- UPI
    RC1 --- UPI

    style GPU0 fill:#2a6,color:#fff
    style NIC0 fill:#2a6,color:#fff
    style NVMe0 fill:#49a,color:#fff
    style GPU1 fill:#49a,color:#fff
    style NVMe1 fill:#49a,color:#fff
    style GPU2 fill:#49a,color:#fff
    style NVMe2 fill:#49a,color:#fff
    style GPU3 fill:#49a,color:#fff
    style NVMe3 fill:#49a,color:#fff
    style GPU4 fill:#2a6,color:#fff
    style NIC1 fill:#2a6,color:#fff
    style GPU5 fill:#49a,color:#fff
    style GPU6 fill:#49a,color:#fff
    style GPU7 fill:#49a,color:#fff
    style E0_0 fill:#333,color:#999,stroke-dasharray: 5
    style E1_0 fill:#333,color:#999,stroke-dasharray: 5
    style E2_0 fill:#333,color:#999,stroke-dasharray: 5
    style E3_0 fill:#333,color:#999,stroke-dasharray: 5
    style E4_0 fill:#333,color:#999,stroke-dasharray: 5
    style E4_1 fill:#333,color:#999,stroke-dasharray: 5
    style E5_0 fill:#333,color:#999,stroke-dasharray: 5
    style E5_1 fill:#333,color:#999,stroke-dasharray: 5
    style E6_0 fill:#333,color:#999,stroke-dasharray: 5
    style E6_1 fill:#333,color:#999,stroke-dasharray: 5
    style E7_0 fill:#333,color:#999,stroke-dasharray: 5
    style E7_1 fill:#333,color:#999,stroke-dasharray: 5
    style UPI fill:#f44,color:#fff
```

**Physical slots per switch:**
- 2 switches with NIC (roots `15`, `97`): 4 slots — NVMe/empty + GPU + empty + NIC
- 6 switches without NIC: 3 slots — NVMe/empty + GPU + empty
- NUMA 0: each switch has GPU + NVMe + 1 empty
- NUMA 1: each switch has GPU + 1 empty (no NVMe), plus NIC on root `97`

### SNC on (4 NUMA nodes)

Same physical PCIe tree (same NVMe and empty slots) — SNC only changes which memory controller services each root complex.

```mermaid
graph TD
    subgraph "Socket 0"
        subgraph "NUMA 0"
            subgraph "PCIe Root pci0000:15"
                S_GPU0["GPU 1b"]
                S_NIC0["NIC 1d"]
                S_SW0["PCIe Switch"]
                S_GPU0 --- S_SW0
                S_NIC0 --- S_SW0
            end
            subgraph "PCIe Root pci0000:59"
                S_GPU3["GPU 5f"]
                S_SW3["PCIe Switch"]
                S_GPU3 --- S_SW3
            end
        end
        subgraph "NUMA 1 (no NIC)"
            subgraph "PCIe Root pci0000:37"
                S_GPU1["GPU 3d"]
                S_SW1["PCIe Switch"]
                S_GPU1 --- S_SW1
            end
            subgraph "PCIe Root pci0000:48"
                S_GPU2["GPU 4e"]
                S_SW2["PCIe Switch"]
                S_GPU2 --- S_SW2
            end
        end
        S_RC0["Root Complex 0"]
        S_SW0 --- S_RC0
        S_SW3 --- S_RC0
        S_SW1 --- S_RC0
        S_SW2 --- S_RC0
    end

    subgraph "Socket 1"
        subgraph "NUMA 2"
            subgraph "PCIe Root pci0000:97"
                S_GPU4["GPU 9d"]
                S_NIC1["NIC 9f"]
                S_SW4["PCIe Switch"]
                S_GPU4 --- S_SW4
                S_NIC1 --- S_SW4
            end
            subgraph "PCIe Root pci0000:d7"
                S_GPU7["GPU dd"]
                S_SW7["PCIe Switch"]
                S_GPU7 --- S_SW7
            end
        end
        subgraph "NUMA 3 (no NIC)"
            subgraph "PCIe Root pci0000:b7"
                S_GPU5["GPU bd"]
                S_SW5["PCIe Switch"]
                S_GPU5 --- S_SW5
            end
            subgraph "PCIe Root pci0000:c7"
                S_GPU6["GPU cd"]
                S_SW6["PCIe Switch"]
                S_GPU6 --- S_SW6
            end
        end
        S_RC1["Root Complex 1"]
        S_SW4 --- S_RC1
        S_SW7 --- S_RC1
        S_SW5 --- S_RC1
        S_SW6 --- S_RC1
    end

    S_UPI["UPI / Inter-socket Link"]
    S_RC0 --- S_UPI
    S_RC1 --- S_UPI

    style S_GPU0 fill:#2a6,color:#fff
    style S_NIC0 fill:#2a6,color:#fff
    style S_GPU3 fill:#49a,color:#fff
    style S_GPU1 fill:#f44,color:#fff
    style S_GPU2 fill:#f44,color:#fff
    style S_GPU4 fill:#2a6,color:#fff
    style S_NIC1 fill:#2a6,color:#fff
    style S_GPU7 fill:#49a,color:#fff
    style S_GPU5 fill:#f44,color:#fff
    style S_GPU6 fill:#f44,color:#fff
    style S_UPI fill:#f44,color:#fff
```

**DMA paths:**
- **Tight (pcieRoot):** GPU 1b ↔ Switch ↔ NIC 1d — no root complex hop
- **Local (numaNode):** GPU 5f ↔ Switch ↔ Root Complex ↔ Switch ↔ NIC 1d — one hop, local memory
- **Near (socket):** GPU 3d ↔ Switch ↔ Root Complex ↔ Switch ↔ NIC 1d — same socket, crosses sub-NUMA boundary
- **Cross-socket:** GPU 3d ↔ Root Complex 0 ↔ UPI ↔ Root Complex 1 ↔ Switch ↔ NIC 9f — inter-socket penalty

**SNC impact on match coverage:**

| Attribute | SNC off | SNC on |
|-----------|---------|--------|
| pcieRoot | 2 of 8 (25%) | 2 of 8 (25%) |
| numaNode | 8 of 8 (100%) | 4 of 8 (50%) — NUMA 1,3 have no NIC |
| cpuSocketID | 8 of 8 (100%) | 8 of 8 (100%) |

Green = tight (same switch as NIC). Blue = local (same NUMA, different switch). Red = no NIC on this NUMA — needs near (same socket) fallback.

---

## 2. Distance Rings

### SNC off (2 NUMA nodes)

```mermaid
graph TD
    subgraph "Node"
        subgraph "Socket 0"
            subgraph "NUMA 0"
                subgraph "pcieRoot 0000:15"
                    G0["GPU"]
                    N0["NIC"]
                end
                G1["GPU"]
                G2["GPU"]
                G3["GPU"]
            end
        end
        subgraph "Socket 1"
            subgraph "NUMA 1"
                subgraph "pcieRoot 0000:97"
                    G4["GPU"]
                    N1["NIC"]
                end
                G5["GPU"]
                G6["GPU"]
                G7["GPU"]
            end
        end
    end

    style G0 fill:#2a6,color:#fff
    style N0 fill:#2a6,color:#fff
    style G1 fill:#49a,color:#fff
    style G2 fill:#49a,color:#fff
    style G3 fill:#49a,color:#fff
    style G4 fill:#2a6,color:#fff
    style N1 fill:#2a6,color:#fff
    style G5 fill:#49a,color:#fff
    style G6 fill:#49a,color:#fff
    style G7 fill:#49a,color:#fff
```

### SNC on (4 NUMA nodes)

```mermaid
graph TD
    subgraph "Node"
        subgraph "Socket 0"
            subgraph "NUMA 0"
                subgraph "pcieRoot 0000:15"
                    SG0["GPU"]
                    SN0["NIC"]
                end
                SG3["GPU"]
            end
            subgraph "NUMA 1 (no NIC)"
                SG1["GPU"]
                SG2["GPU"]
            end
        end
        subgraph "Socket 1"
            subgraph "NUMA 2"
                subgraph "pcieRoot 0000:97"
                    SG4["GPU"]
                    SN1["NIC"]
                end
                SG7["GPU"]
            end
            subgraph "NUMA 3 (no NIC)"
                SG5["GPU"]
                SG6["GPU"]
            end
        end
    end

    style SG0 fill:#2a6,color:#fff
    style SN0 fill:#2a6,color:#fff
    style SG3 fill:#49a,color:#fff
    style SG1 fill:#f44,color:#fff
    style SG2 fill:#f44,color:#fff
    style SG4 fill:#2a6,color:#fff
    style SN1 fill:#2a6,color:#fff
    style SG7 fill:#49a,color:#fff
    style SG5 fill:#f44,color:#fff
    style SG6 fill:#f44,color:#fff
```

| Ring | Attribute | SNC off | SNC on |
|------|-----------|---------|--------|
| Innermost | `pcieRoot` | 2 of 8 | 2 of 8 |
| Middle | `numaNode` | 8 of 8 | 4 of 8 |
| Outer | `socket` | 8 of 8 | 8 of 8 |

Green = tight. Blue = local. Red = no NIC on this NUMA (needs near/socket fallback).

---

## 3. Scheduler Decision Flowchart

```mermaid
flowchart TD
    START["Evaluate constraints"] --> PC{pcieRoot match?}
    PC -->|satisfiable| TIGHT["Use pcieRoot ✓\n(tightest coupling)"]
    PC -->|preferred, not satisfiable| NUMA{numaNode match?}
    NUMA -->|satisfiable| LOOSE["Use numaNode ✓\n(good coupling)"]
    NUMA -->|preferred, not satisfiable| SOCK{socket match?}
    SOCK -->|satisfiable| SOCKET["Use socket ✓\n(acceptable coupling)"]
    SOCK -->|required, not satisfiable| FAIL["Claim fails ✗"]

    style TIGHT fill:#2a6,color:#fff
    style LOOSE fill:#49a,color:#fff
    style SOCKET fill:#fa4,color:#000
    style FAIL fill:#f44,color:#fff
    style START fill:#666,color:#fff
```

