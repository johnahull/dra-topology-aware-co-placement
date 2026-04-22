# Topology Distance Hierarchy — Diagrams

## 1. PCIe Tree with DMA Paths (XE9680, SNC off)

Shows the physical hardware topology and DMA path for each coupling level.

```mermaid
graph TD
    subgraph "Socket 0 — NUMA 0"
        subgraph "PCIe Root pci0000:15"
            GPU0["GPU 1b:00.0"]
            NIC0["NIC 1d:00.0"]
            SW0["PCIe Switch"]
            GPU0 --- SW0
            NIC0 --- SW0
        end
        subgraph "PCIe Root pci0000:37"
            GPU1["GPU 3d:00.0"]
            SW1["PCIe Switch"]
            GPU1 --- SW1
        end
        subgraph "PCIe Root pci0000:48"
            GPU2["GPU 4e:00.0"]
            SW2["PCIe Switch"]
            GPU2 --- SW2
        end
        subgraph "PCIe Root pci0000:59"
            GPU3["GPU 5f:00.0"]
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
            GPU4["GPU 9d:00.0"]
            NIC1["NIC 9f:00.0"]
            SW4["PCIe Switch"]
            GPU4 --- SW4
            NIC1 --- SW4
        end
        subgraph "PCIe Root pci0000:b7"
            GPU5["GPU bd:00.0"]
            SW5["PCIe Switch"]
            GPU5 --- SW5
        end
        RC1["Root Complex 1"]
        SW4 --- RC1
        SW5 --- RC1
    end

    UPI["UPI / Inter-socket Link"]
    RC0 --- UPI
    RC1 --- UPI

    style GPU0 fill:#4a9,color:#fff
    style NIC0 fill:#4a9,color:#fff
    style GPU1 fill:#49a,color:#fff
    style GPU2 fill:#49a,color:#fff
    style GPU3 fill:#49a,color:#fff
    style GPU4 fill:#4a9,color:#fff
    style NIC1 fill:#4a9,color:#fff
    style GPU5 fill:#49a,color:#fff
    style UPI fill:#f44,color:#fff
```

**DMA paths:**
- **Tight (pcieRoot):** GPU 1b ↔ Switch ↔ NIC 1d — no root complex hop
- **Loose (numaNode):** GPU 3d ↔ Switch ↔ Root Complex 0 ↔ Switch ↔ NIC 1d — one hop, local memory
- **Cross-socket:** GPU 3d ↔ Root Complex 0 ↔ UPI ↔ Root Complex 1 ↔ Switch ↔ NIC 9f — inter-socket penalty

---

## 2. Distance Rings

```mermaid
graph TD
    subgraph "Node"
        subgraph "Socket 0"
            subgraph "NUMA 0"
                subgraph "pcieRoot pci0000:15"
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
                subgraph "pcieRoot pci0000:97"
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

| Ring | Attribute | GPU+NIC pairs matched | Performance |
|------|-----------|----------------------|-------------|
| Innermost | `pcieRoot` | 2 of 8 | Best — within switch |
| Middle | `numaNode` | 8 of 8 | Good — local memory |
| Outer | `socket` | 8 of 8 | Acceptable — within socket |
| Outside | none | 8 of 8 | Bad — may cross socket |

---

## 3. SNC On vs Off Comparison

```mermaid
graph LR
    subgraph "SNC OFF — 2 NUMA nodes"
        subgraph "NUMA 0 (Socket 0)"
            A0["GPU 1b + NIC 1d ✓"]
            A1["GPU 3d ✓"]
            A2["GPU 4e ✓"]
            A3["GPU 5f ✓"]
        end
        subgraph "NUMA 1 (Socket 1)"
            A4["GPU 9d + NIC 9f ✓"]
            A5["GPU bd ✓"]
            A6["GPU cd ✓"]
            A7["GPU dd ✓"]
        end
    end

    style A0 fill:#2a6,color:#fff
    style A1 fill:#49a,color:#fff
    style A2 fill:#49a,color:#fff
    style A3 fill:#49a,color:#fff
    style A4 fill:#2a6,color:#fff
    style A5 fill:#49a,color:#fff
    style A6 fill:#49a,color:#fff
    style A7 fill:#49a,color:#fff
```

```mermaid
graph LR
    subgraph "SNC ON — 4 NUMA nodes"
        subgraph "NUMA 0"
            B0["GPU 1b + NIC 1d ✓"]
            B1["GPU 5f ✓"]
        end
        subgraph "NUMA 1"
            B2["GPU 3d ✗"]
            B3["GPU 4e ✗"]
        end
        subgraph "NUMA 2"
            B4["GPU 9d + NIC 9f ✓"]
            B5["GPU dd ✓"]
        end
        subgraph "NUMA 3"
            B6["GPU bd ✗"]
            B7["GPU cd ✗"]
        end
    end

    style B0 fill:#2a6,color:#fff
    style B1 fill:#49a,color:#fff
    style B2 fill:#f44,color:#fff
    style B3 fill:#f44,color:#fff
    style B4 fill:#2a6,color:#fff
    style B5 fill:#49a,color:#fff
    style B6 fill:#f44,color:#fff
    style B7 fill:#f44,color:#fff
```

| | SNC OFF (numaNode) | SNC ON (numaNode) | SNC ON (socket) |
|--|-------------------|-------------------|-----------------|
| GPU+NIC matched | 8 of 8 (100%) | 4 of 8 (50%) | 8 of 8 (100%) |

`socket` recovers the GPUs that `numaNode` loses under SNC.

---

## 4. Scheduler Decision Flowchart

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

---

## 5. Device Placement Grid

```mermaid
graph TD
    subgraph "Socket 0"
        subgraph "NUMA 0 — pcieRoot 0000:15"
            D00["🟢 GPU 1b\n🟢 NIC 1d\nTIGHT"]
        end
        subgraph "NUMA 0 — pcieRoot 0000:37"
            D01["🔵 GPU 3d\nLOOSE"]
        end
        subgraph "NUMA 0 — pcieRoot 0000:48"
            D02["🔵 GPU 4e\nLOOSE"]
        end
        subgraph "NUMA 0 — pcieRoot 0000:59"
            D03["🔵 GPU 5f\nLOOSE"]
        end
    end

    subgraph "Socket 1"
        subgraph "NUMA 1 — pcieRoot 0000:97"
            D10["🟢 GPU 9d\n🟢 NIC 9f\nTIGHT"]
        end
        subgraph "NUMA 1 — pcieRoot 0000:b7"
            D11["🔵 GPU bd\nLOOSE"]
        end
        subgraph "NUMA 1 — pcieRoot 0000:c7"
            D12["🔵 GPU cd\nLOOSE"]
        end
        subgraph "NUMA 1 — pcieRoot 0000:d7"
            D13["🔵 GPU dd\nLOOSE"]
        end
    end

    style D00 fill:#2a6,color:#fff
    style D01 fill:#49a,color:#fff
    style D02 fill:#49a,color:#fff
    style D03 fill:#49a,color:#fff
    style D10 fill:#2a6,color:#fff
    style D11 fill:#49a,color:#fff
    style D12 fill:#49a,color:#fff
    style D13 fill:#49a,color:#fff
```

**Legend:**
- 🟢 TIGHT — GPU and NIC share pcieRoot (same PCIe switch)
- 🔵 LOOSE — GPU on same NUMA as NIC but different switch
- 🔴 NO NIC — GPU on a NUMA node without any NIC (SNC on only)
