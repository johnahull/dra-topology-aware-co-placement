# Topology Distance Hierarchy — Diagrams

## 1. PCIe Tree with DMA Paths

Shows the physical hardware topology and DMA path for each coupling level.

### SNC off (2 NUMA nodes)

```mermaid
graph TD
    subgraph "Socket 0 — NUMA 0"
        subgraph "PCIe Root pci0000:15"
            GPU0["GPU 1b"]
            NIC0["NIC 1d"]
            SW0["PCIe Switch"]
            GPU0 --- SW0
            NIC0 --- SW0
        end
        subgraph "PCIe Root pci0000:37"
            GPU1["GPU 3d"]
            SW1["PCIe Switch"]
            GPU1 --- SW1
        end
        subgraph "PCIe Root pci0000:48"
            GPU2["GPU 4e"]
            SW2["PCIe Switch"]
            GPU2 --- SW2
        end
        subgraph "PCIe Root pci0000:59"
            GPU3["GPU 5f"]
            SW3["PCIe Switch"]
            GPU3 --- SW3
        end
        RC0["Root Complex 0"]
        SW0 --- RC0
        SW1 --- RC0
        SW2 --- RC0
        SW3 --- RC0
    end

    subgraph "Socket 1 — NUMA 1"
        subgraph "PCIe Root pci0000:97"
            GPU4["GPU 9d"]
            NIC1["NIC 9f"]
            SW4["PCIe Switch"]
            GPU4 --- SW4
            NIC1 --- SW4
        end
        subgraph "PCIe Root pci0000:b7"
            GPU5["GPU bd"]
            SW5["PCIe Switch"]
            GPU5 --- SW5
        end
        subgraph "PCIe Root pci0000:c7"
            GPU6["GPU cd"]
            SW6["PCIe Switch"]
            GPU6 --- SW6
        end
        subgraph "PCIe Root pci0000:d7"
            GPU7["GPU dd"]
            SW7["PCIe Switch"]
            GPU7 --- SW7
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
    style GPU1 fill:#49a,color:#fff
    style GPU2 fill:#49a,color:#fff
    style GPU3 fill:#49a,color:#fff
    style GPU4 fill:#2a6,color:#fff
    style NIC1 fill:#2a6,color:#fff
    style GPU5 fill:#49a,color:#fff
    style GPU6 fill:#49a,color:#fff
    style GPU7 fill:#49a,color:#fff
    style UPI fill:#f44,color:#fff
```

### SNC on (4 NUMA nodes)

Same physical PCIe tree — SNC only changes which memory controller services each root complex.

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
| socket | 8 of 8 (100%) | 8 of 8 (100%) |

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

