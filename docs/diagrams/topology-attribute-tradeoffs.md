# Topology Attribute Tradeoffs: numaNode vs. pcieRoot — 2026-04-15

## The Problem: NUMA Doesn't Always Mean What You Think

On most AI/HPC servers, NUMA node = socket. One NUMA node, one set of PCIe devices, one pool of memory. `numaNode` alignment works perfectly.

But modern CPUs support **sub-NUMA partitioning** — AMD NPS (Nodes Per Socket) and Intel SNC (Sub-NUMA Clustering) — which splits a single socket into multiple NUMA domains. This breaks the assumption that `numaNode` represents the physical topology boundary.

---

## Case 1: Standard Configuration (NPS1 / No SNC)

This is the simple case. One socket = one NUMA node. All PCIe devices local to a socket share the same NUMA node ID. `matchAttribute: dra.net/numaNode` correctly aligns everything.

```mermaid
graph TB
    subgraph "Socket 0 — NUMA Node 0"
        CPU0["64 CPU Cores"]
        MEM0["512 GiB Memory"]
        subgraph "PCIe Devices"
            GPU0A["GPU 0<br/>pci0000:15"]
            GPU0B["GPU 1<br/>pci0000:37"]
            NIC0["NIC VFs<br/>pci0000:XX"]
        end
    end

    subgraph "Socket 1 — NUMA Node 1"
        CPU1["64 CPU Cores"]
        MEM1["512 GiB Memory"]
        subgraph "PCIe Devices "
            GPU1A["GPU 2<br/>pci0000:97"]
            GPU1B["GPU 3<br/>pci0000:b7"]
            NIC1["NIC VFs<br/>pci0000:YY"]
        end
    end

    style CPU0 fill:#4a9,color:#fff
    style MEM0 fill:#4a9,color:#fff
    style GPU0A fill:#4a9,color:#fff
    style GPU0B fill:#4a9,color:#fff
    style NIC0 fill:#4a9,color:#fff

    style CPU1 fill:#49a,color:#fff
    style MEM1 fill:#49a,color:#fff
    style GPU1A fill:#49a,color:#fff
    style GPU1B fill:#49a,color:#fff
    style NIC1 fill:#49a,color:#fff
```

```yaml
# Works: one constraint aligns all devices on a NUMA node
constraints:
- matchAttribute: dra.net/numaNode
  requests: [gpu, nic, cpu, mem]
```

**Result:** All devices with `numaNode == 0` land together. Simple, correct, covers all resource types including memory.

---

## Case 2: AMD NPS4 — One Socket, Four NUMA Nodes

With NPS4 enabled, AMD splits each socket's memory controllers into 4 independent NUMA domains. The CPU cores and memory are partitioned across 4 NUMA nodes, but all PCIe devices on the socket are reported as local to **one** of the NUMA nodes (typically NUMA 0 on socket 0).

```mermaid
graph TB
    subgraph S0["Socket 0 (NPS4)"]
        subgraph N0["NUMA 0 — has PCIe devices"]
            CPU0["16 Cores"]
            MEM0["128 GiB"]
            GPU0A["GPU 0"]
            GPU0B["GPU 1"]
            NIC0["NIC VFs"]
        end
        subgraph N1["NUMA 1 — no PCIe"]
            CPU1["16 Cores"]
            MEM1["128 GiB"]
        end
        subgraph N2["NUMA 2 — no PCIe"]
            CPU2["16 Cores"]
            MEM2["128 GiB"]
        end
        subgraph N3["NUMA 3 — no PCIe"]
            CPU3["16 Cores"]
            MEM3["128 GiB"]
        end
    end

    subgraph S1["Socket 1 (NPS4)"]
        subgraph N4["NUMA 4 — has PCIe devices"]
            CPU4["16 Cores"]
            MEM4["128 GiB"]
            GPU1A["GPU 2"]
            GPU1B["GPU 3"]
            NIC1["NIC VFs"]
        end
        subgraph N5["NUMA 5 — no PCIe"]
            CPU5["16 Cores"]
            MEM5["128 GiB"]
        end
        subgraph N6["NUMA 6 — no PCIe"]
            CPU6["16 Cores"]
            MEM6["128 GiB"]
        end
        subgraph N7["NUMA 7 — no PCIe"]
            CPU7["16 Cores"]
            MEM7["128 GiB"]
        end
    end

    style CPU0 fill:#4a9,color:#fff
    style MEM0 fill:#4a9,color:#fff
    style GPU0A fill:#4a9,color:#fff
    style GPU0B fill:#4a9,color:#fff
    style NIC0 fill:#4a9,color:#fff
    style CPU1 fill:#7c7,color:#000
    style MEM1 fill:#7c7,color:#000
    style CPU2 fill:#ad5,color:#000
    style MEM2 fill:#ad5,color:#000
    style CPU3 fill:#cc6,color:#000
    style MEM3 fill:#cc6,color:#000
```

### The Problem

```yaml
# Fails: GPU/NIC report numaNode=0, but only 16 of 64 cores are on NUMA 0
# The other 48 cores on the same socket (NUMA 1,2,3) are excluded
constraints:
- matchAttribute: dra.net/numaNode
  requests: [gpu, nic, cpu, mem]
```

The constraint says "all devices must be on the same NUMA node." But under NPS4:
- GPUs and NICs report `numaNode: 0` (the NUMA node their PCIe root is on)
- Only 16 of 64 cores on socket 0 are on NUMA 0
- 48 cores on NUMA 1, 2, 3 are on the **same socket** with the same PCIe bandwidth to the GPUs — but `numaNode` matching excludes them

This artificially limits the available CPUs to 16 instead of 64, even though all 64 cores on the socket have equivalent access to the GPUs.

```mermaid
graph LR
    subgraph "What numaNode matching sees"
        MATCH["NUMA 0 only<br/>16 CPUs + 128 GiB<br/>+ GPUs + NICs"]
        EXCLUDED["NUMA 1,2,3<br/>48 CPUs + 384 GiB<br/>EXCLUDED ✗"]
    end

    subgraph "What the hardware actually provides"
        REAL["All 64 CPUs on Socket 0<br/>have equal PCIe bandwidth<br/>to all GPUs and NICs<br/>on Socket 0"]
    end

    MATCH -.->|"numaNode over-constrains"| REAL
    EXCLUDED -.->|"wasted capacity"| REAL

    style MATCH fill:#4a9,color:#fff
    style EXCLUDED fill:#f44,color:#fff
    style REAL fill:#4af,color:#fff
```

---

## Case 3: Intel Sub-NUMA Clustering (SNC)

Intel SNC splits each socket into 2 (SNC2) or 4 (SNC4) NUMA domains. Similar to NPS4, but with Intel CPUs.

```mermaid
graph TB
    subgraph IS0["Socket 0 with SNC2"]
        subgraph IN0["NUMA 0 — GPUs here"]
            ICPU0["32 Cores"]
            IMEM0["256 GiB"]
            IGPU0["GPU 0, GPU 1"]
        end
        subgraph IN1["NUMA 1 — NICs here"]
            ICPU1["32 Cores"]
            IMEM1["256 GiB"]
            INIC0["NIC VFs"]
        end
    end

    style ICPU0 fill:#4a9,color:#fff
    style IMEM0 fill:#4a9,color:#fff
    style IGPU0 fill:#4a9,color:#fff
    style ICPU1 fill:#49a,color:#fff
    style IMEM1 fill:#49a,color:#fff
    style INIC0 fill:#49a,color:#fff
```

### The Problem

Under SNC2, GPUs and NICs on the **same socket** may report **different NUMA nodes** because each is connected to a different half of the socket's memory controller:

```yaml
# Fails: GPU reports numaNode=0, NIC reports numaNode=1
# They are on the SAME socket with fast interconnect
# but numaNode matching says they don't belong together
constraints:
- matchAttribute: dra.net/numaNode
  requests: [gpu, nic]    # ✗ unsatisfiable if GPU on NUMA 0, NIC on NUMA 1
```

This is worse than the NPS4 case — `numaNode` matching not only wastes CPU capacity but can make valid GPU+NIC alignments **unsatisfiable**, even though the devices are on the same socket with sub-millisecond interconnect latency.

---

## Solution A: pcieRoot as List (CPU as Pivot)

The CPU driver publishes all PCIe root complexes local to each CPU group as a list attribute. This uses the existing standard attribute — no new attribute needed.

```mermaid
graph TB
    subgraph "ResourceSlice Attributes"
        CPU_ATTR["CPU (NUMA 0 group)<br/>pcieRoot: [pci0000:15, pci0000:37,<br/>pci0000:48, pci0000:59, pci0000:XX]<br/><i>list type — KEP-5491</i>"]
        GPU_ATTR["GPU 0<br/>pcieRoot: pci0000:15<br/><i>scalar</i>"]
        NIC_ATTR["NIC VF<br/>pcieRoot: pci0000:XX<br/><i>scalar</i>"]
    end

    subgraph "Constraint Evaluation (set intersection)"
        C1["Constraint 1: matchAttribute pcieRoot<br/>requests: [gpu, cpu]<br/>{pci0000:15} ∩ {pci0000:15,...,pci0000:XX}<br/>= {pci0000:15} ✓"]
        C2["Constraint 2: matchAttribute pcieRoot<br/>requests: [nic, cpu]<br/>{pci0000:XX} ∩ {pci0000:15,...,pci0000:XX}<br/>= {pci0000:XX} ✓"]
    end

    GPU_ATTR --> C1
    CPU_ATTR --> C1
    NIC_ATTR --> C2
    CPU_ATTR --> C2

    C1 --> RESULT["All devices on NUMA 0 ✓<br/>CPU is the pivot device"]
    C2 --> RESULT

    style CPU_ATTR fill:#4af,color:#fff
    style GPU_ATTR fill:#fa4,color:#000
    style NIC_ATTR fill:#a4f,color:#fff
    style C1 fill:#4a9,color:#fff
    style C2 fill:#4a9,color:#fff
    style RESULT fill:#4a4,color:#fff
```

### What each driver publishes (ResourceSlices)

With `DRAListTypeAttributes` enabled (alpha in v1.36), the CPU driver publishes `pcieRoot` as a list. All other drivers publish it as a scalar (unchanged). The memory driver has no pcieRoot at all.

```yaml
# CPU driver ResourceSlice — publishes pcieRoot as a LIST of local roots
# Requires: DRAListTypeAttributes feature gate + dra-driver-cpu with pcieRoot scanning
apiVersion: resource.k8s.io/v1
kind: ResourceSlice
metadata:
  name: dra-cpu-node1
spec:
  driver: dra.cpu
  nodeName: node1
  devices:
  - name: numa-0
    attributes:
      dra.cpu/numaNodeID:
        int: 0
      dra.cpu/socketID:
        int: 0
      dra.net/numaNode:                          # compatibility attribute
        int: 0
      resource.kubernetes.io/pcieRoot:            # LIST type (KEP-5491)
        strings:                                  # all PCIe roots local to this CPU group
        - "pci0000:15"
        - "pci0000:37"
        - "pci0000:48"
        - "pci0000:59"
        - "pci0000:6a"
    capacity:
      dra.cpu/cpu:
        quantity: "64"
  - name: numa-1
    attributes:
      dra.cpu/numaNodeID:
        int: 1
      dra.cpu/socketID:
        int: 1
      dra.net/numaNode:
        int: 1
      resource.kubernetes.io/pcieRoot:
        strings:
        - "pci0000:97"
        - "pci0000:b7"
        - "pci0000:c7"
        - "pci0000:d7"
        - "pci0000:e8"
    capacity:
      dra.cpu/cpu:
        quantity: "64"
---
# GPU driver ResourceSlice — publishes pcieRoot as a SCALAR (unchanged)
apiVersion: resource.k8s.io/v1
kind: ResourceSlice
metadata:
  name: gpu-amd-node1
spec:
  driver: gpu.amd.com
  nodeName: node1
  devices:
  - name: gpu-0
    attributes:
      gpu.amd.com/numaNode:
        int: 0
      resource.kubernetes.io/pcieRoot:            # scalar — one root per GPU
        string: "pci0000:15"
      resource.kubernetes.io/pciBusID:
        string: "0000:1b:00.0"
  - name: gpu-1
    attributes:
      gpu.amd.com/numaNode:
        int: 0
      resource.kubernetes.io/pcieRoot:
        string: "pci0000:37"
      resource.kubernetes.io/pciBusID:
        string: "0000:3d:00.0"
  # ... gpu-2 through gpu-7 on their own roots
---
# NIC driver ResourceSlice — publishes pcieRoot as a SCALAR (unchanged)
apiVersion: resource.k8s.io/v1
kind: ResourceSlice
metadata:
  name: sriov-nic-node1
spec:
  driver: sriovnetwork.k8snetworkplumbingwg.io
  nodeName: node1
  devices:
  - name: vf-0
    attributes:
      dra.net/numaNode:
        int: 0
      resource.kubernetes.io/pcieRoot:            # scalar — one root per NIC VF
        string: "pci0000:6a"
      resource.kubernetes.io/pciBusID:
        string: "0000:6b:00.2"
  # ... more VFs
---
# Memory driver ResourceSlice — NO pcieRoot (memory is not a PCI device)
apiVersion: resource.k8s.io/v1
kind: ResourceSlice
metadata:
  name: dra-memory-node1
spec:
  driver: dra.memory
  nodeName: node1
  devices:
  - name: mem-numa0-regular
    attributes:
      dra.memory/numaNode:
        int: 0
      dra.memory/hugeTLB:
        bool: false
      dra.cpu/numaNodeID:                         # compatibility attribute
        int: 0
      dra.net/numaNode:                           # compatibility attribute
        int: 0
      # NOTE: no resource.kubernetes.io/pcieRoot — memory is not a PCI device
    capacity:
      size:
        quantity: "1Ti"
```

### ResourceClaim: aligning all four resource types

Since memory has no pcieRoot, Solution A requires **mixed constraints** — pcieRoot for PCI devices (GPU, NIC, CPU) and a separate numaNode constraint for memory:

```yaml
# Solution A: pcieRoot-as-list with CPU pivot + numaNode for memory
# Requires: DRAListTypeAttributes feature gate
# Requires: CPU driver publishing pcieRoot as list
# Requires: GPU driver publishing dra.net/numaNode (patch #9)
apiVersion: resource.k8s.io/v1
kind: ResourceClaim
metadata:
  name: solution-a-full
  namespace: test
spec:
  devices:
    requests:
    - name: gpu
      exactly:
        deviceClassName: gpu.amd.com
        count: 2
    - name: nic
      exactly:
        deviceClassName: sriovnetwork.k8snetworkplumbingwg.io
        count: 2
    - name: cpu
      exactly:
        deviceClassName: dra.cpu
        count: 1
        capacity:
          requests:
            dra.cpu/cpu: "32"
    - name: mem
      exactly:
        deviceClassName: dra.memory
        count: 1
        selectors:
        - cel:
            expression: 'device.attributes["dra.memory"].hugeTLB == false'
        capacity:
          requests:
            size: "128Gi"
    constraints:
    #
    # Constraint 1: GPU and CPU share a pcieRoot
    # GPU scalar {pci0000:15} ∩ CPU list {pci0000:15,...} = {pci0000:15} ✓
    #
    - matchAttribute: resource.kubernetes.io/pcieRoot
      requests: [gpu, cpu]

    #
    # Constraint 2: NIC and CPU share a pcieRoot
    # NIC scalar {pci0000:6a} ∩ CPU list {pci0000:15,...,pci0000:6a} = {pci0000:6a} ✓
    #
    - matchAttribute: resource.kubernetes.io/pcieRoot
      requests: [nic, cpu]

    #
    # Constraint 3: Memory on same NUMA node as CPU
    # Memory has no pcieRoot — must use numaNode for this leg
    # Both CPU and memory drivers publish dra.net/numaNode
    #
    - matchAttribute: dra.net/numaNode
      requests: [mem, cpu]
---
apiVersion: v1
kind: Pod
metadata:
  name: solution-a-test
  namespace: test
spec:
  containers:
  - name: worker
    image: registry.access.redhat.com/ubi9/ubi-minimal:latest
    command: ["/bin/sleep", "infinity"]
  resourceClaims:
  - name: devices
    resourceClaimName: solution-a-full
```

**How the allocator evaluates this:**

1. Constraint 1 picks a CPU device and GPU devices that share a pcieRoot (set intersection)
2. Constraint 2 picks NIC devices that also share a pcieRoot with the **same** CPU device
3. Constraint 3 picks memory on the same NUMA node as the **same** CPU device
4. All four resource types are co-located because they all match through the CPU pivot

The CPU device is the pivot in all three constraints. Since the CPU device in grouped mode represents one NUMA node's worth of cores, all matched devices are on the same NUMA boundary.

### For comparison: Solution B with same resources (simpler)

```yaml
# Solution B: dra.net/numaNode — one constraint, all drivers
# Requires: GPU driver publishing dra.net/numaNode (patch #9)
# Does NOT require: DRAListTypeAttributes feature gate or CPU pcieRoot scanning
apiVersion: resource.k8s.io/v1
kind: ResourceClaim
metadata:
  name: solution-b-full
  namespace: test
spec:
  devices:
    requests:
    - name: gpu
      exactly:
        deviceClassName: gpu.amd.com
        count: 2
    - name: nic
      exactly:
        deviceClassName: sriovnetwork.k8snetworkplumbingwg.io
        count: 2
    - name: cpu
      exactly:
        deviceClassName: dra.cpu
        count: 1
        capacity:
          requests:
            dra.cpu/cpu: "32"
    - name: mem
      exactly:
        deviceClassName: dra.memory
        count: 1
        selectors:
        - cel:
            expression: 'device.attributes["dra.memory"].hugeTLB == false'
        capacity:
          requests:
            size: "128Gi"
    constraints:
    #
    # One constraint — all four resource types
    # All drivers publish dra.net/numaNode with the same value
    #
    - matchAttribute: dra.net/numaNode
      requests: [gpu, nic, cpu, mem]
```

**Key differences:**

| | Solution A (pcieRoot-as-list) | Solution B (numaNode) |
|---|---|---|
| Constraints needed | 3 (gpu↔cpu, nic↔cpu, mem↔cpu) | 1 |
| Feature gates | `DRAListTypeAttributes` | None beyond base DRA |
| CPU driver changes | Must publish pcieRoot list (WIP) | None (already publishes `dra.net/numaNode`) |
| GPU driver changes | None (already publishes pcieRoot) | Must publish `dra.net/numaNode` (patch #9) |
| Memory alignment | Requires separate numaNode constraint | Included in the single constraint |
| NPS4/SNC correctness | Correct (PCIe topology is physical) | May over-constrain or break |
| Uses standard attribute | Yes (`resource.kubernetes.io/pcieRoot`) | No (informal `dra.net/numaNode`) |

### Why a single constraint across all three fails

```mermaid
graph LR
    subgraph "Single constraint: matchAttribute pcieRoot [gpu, nic, cpu]"
        FAIL_GPU["GPU: {pci0000:15}"]
        FAIL_NIC["NIC: {pci0000:XX}"]
        FAIL_CPU["CPU: {pci0000:15,...,pci0000:XX}"]
        INTERSECT["Global intersection:<br/>{pci0000:15} ∩ {pci0000:XX} ∩ {list}<br/>= {} EMPTY"]
    end

    FAIL_GPU --> INTERSECT
    FAIL_NIC --> INTERSECT
    FAIL_CPU --> INTERSECT
    INTERSECT --> FAIL_RESULT["✗ Unsatisfiable<br/>GPU and NIC on different roots"]

    style INTERSECT fill:#f44,color:#fff
    style FAIL_RESULT fill:#f44,color:#fff
```

The `matchAttribute` non-empty intersection is computed across ALL devices simultaneously. Since GPU and NIC never share a root on multi-root hardware, the global intersection is always empty. Two separate constraints with the CPU as pivot are required.

### How pcieRoot-as-list handles NPS4/SNC

Under NPS4, the CPU driver groups by NUMA node (16 cores per group). Each NUMA group publishes the PCIe roots that are local to the entire socket — because `local_cpulist` on each PCI bridge includes all cores on the socket. The pcieRoot list is identical for all 4 NUMA groups on the same socket, so matching works correctly regardless of which NUMA group is selected:

```mermaid
graph TB
    subgraph "NPS4 — Socket 0"
        NUMA0["NUMA 0: 16 CPUs<br/>pcieRoot: [root-A, root-B, root-C]"]
        NUMA1["NUMA 1: 16 CPUs<br/>pcieRoot: [root-A, root-B, root-C]"]
        NUMA2["NUMA 2: 16 CPUs<br/>pcieRoot: [root-A, root-B, root-C]"]
        NUMA3["NUMA 3: 16 CPUs<br/>pcieRoot: [root-A, root-B, root-C]"]
    end

    GPU["GPU: pcieRoot: root-A"]
    NIC["NIC: pcieRoot: root-C"]

    GPU -->|"constraint 1"| NUMA0
    GPU -->|"constraint 1"| NUMA1
    GPU -->|"constraint 1"| NUMA2
    GPU -->|"constraint 1"| NUMA3
    NIC -->|"constraint 2"| NUMA0
    NIC -->|"constraint 2"| NUMA1
    NIC -->|"constraint 2"| NUMA2
    NIC -->|"constraint 2"| NUMA3

    NUMA0 --> OK["Any NUMA group on Socket 0<br/>satisfies both constraints ✓"]
    NUMA1 --> OK
    NUMA2 --> OK
    NUMA3 --> OK

    style OK fill:#4a4,color:#fff
    style NUMA0 fill:#4a9,color:#fff
    style NUMA1 fill:#7c7,color:#000
    style NUMA2 fill:#ad5,color:#000
    style NUMA3 fill:#cc6,color:#000
```

**Limitation:** Memory has no pcieRoot — it can't participate in pcieRoot constraints. A separate mechanism (numaNode or CEL selector) is needed for memory alignment.

---

## Solution B: numaNode (One Constraint, All Drivers)

All drivers publish a common `dra.net/numaNode` attribute. One constraint aligns everything.

```mermaid
graph TB
    subgraph "ResourceSlice Attributes"
        B_CPU["CPU<br/>dra.net/numaNode: 0"]
        B_GPU["GPU<br/>dra.net/numaNode: 0"]
        B_NIC["NIC<br/>dra.net/numaNode: 0"]
        B_MEM["Memory<br/>dra.net/numaNode: 0"]
    end

    subgraph "Constraint Evaluation"
        B_C1["matchAttribute: dra.net/numaNode<br/>requests: [gpu, nic, cpu, mem]<br/>0 == 0 == 0 == 0 ✓"]
    end

    B_CPU --> B_C1
    B_GPU --> B_C1
    B_NIC --> B_C1
    B_MEM --> B_C1

    B_C1 --> B_RESULT["All devices on NUMA 0 ✓<br/>Including memory"]

    style B_CPU fill:#4af,color:#fff
    style B_GPU fill:#fa4,color:#000
    style B_NIC fill:#a4f,color:#fff
    style B_MEM fill:#9d5,color:#000
    style B_C1 fill:#4a9,color:#fff
    style B_RESULT fill:#4a4,color:#fff
```

**Simple, covers all resource types.** But breaks on NPS4/SNC hardware as shown above.

---

## Solution C: Topology Coordinator (Abstracts Over Both)

The coordinator uses ConfigMap rules to map whatever attributes each driver publishes into a common topology concept. It handles the attribute fragmentation and generates the correct constraints for the deployed hardware.

```mermaid
graph TB
    subgraph DRIVERS["DRA Drivers"]
        D_CPU["CPU Driver<br/>dra.cpu/numaNodeID"]
        D_GPU["GPU Driver<br/>gpu.amd.com/numaNode"]
        D_NIC["NIC Driver<br/>dra.net/numaNode"]
        D_MEM["Memory Driver<br/>dra.memory/numaNode"]
    end

    subgraph TC["Topology Coordinator"]
        RULES["ConfigMap Rules<br/>Map vendor attrs to numaNode"]
        MODEL["Topology Model<br/>Cross-driver grouping"]
        PARTS["Partition Builder<br/>eighth / quarter / half / full"]
        WH["Mutating Webhook"]
    end

    D_CPU --> RULES
    D_GPU --> RULES
    D_NIC --> RULES
    D_MEM --> RULES
    RULES --> MODEL
    MODEL --> PARTS

    USER["User request:<br/>deviceClassName: quarter-machine"] --> WH

    WH --> EXPANDED["Expanded claim:<br/>4 requests + matchAttribute<br/>+ capacity requests"]

    PARTS -.->|"publishes DeviceClasses"| USER

    style RULES fill:#4af,color:#fff
    style MODEL fill:#4af,color:#fff
    style PARTS fill:#4af,color:#fff
    style WH fill:#4af,color:#fff
    style EXPANDED fill:#4a4,color:#fff
```

### How the coordinator handles NPS4/SNC

The ConfigMap rules can be configured per-hardware:

```mermaid
graph LR
    subgraph CFG1["NPS1 / No SNC"]
        R1["Map numaNodeID to numaNode"]
    end

    subgraph CFG2["NPS4 / SNC"]
        R2["Map socketID to socket"]
    end

    subgraph CFG3["Mixed hardware"]
        R3["pcieRoot for PCI devices<br/>numaNode for memory"]
    end

    R1 --> V1["One numaNode constraint"]
    R2 --> V2["Socket-level alignment"]
    R3 --> V3["Per-driver constraints"]

    style V1 fill:#4a9,color:#fff
    style V2 fill:#4a9,color:#fff
    style V3 fill:#4a9,color:#fff
```

The coordinator insulates users from the ongoing upstream debate about which attribute to standardize. If the community standardizes `numaNode`, the rules simplify. If they go with pcieRoot-as-list, the rules adapt. The user's claim doesn't change.

---

## Decision Matrix

```mermaid
graph TD
    START["What hardware?"] --> Q1{"NPS1 / No SNC?<br/>(most AI/HPC)"}
    Q1 -->|"Yes"| NUMA["Use dra.net/numaNode<br/>One constraint, all drivers<br/>Including memory"]
    Q1 -->|"No"| Q2{"Need memory alignment?"}
    Q2 -->|"Yes"| COORD["Use Topology Coordinator<br/>Handles mixed constraints<br/>per hardware config"]
    Q2 -->|"No"| PCIE["Use pcieRoot-as-list<br/>Two constraints, CPU as pivot<br/>Standard attribute"]

    Q1 -->|"Unknown / mixed fleet"| COORD

    style NUMA fill:#4a9,color:#fff
    style PCIE fill:#fa4,color:#000
    style COORD fill:#4af,color:#fff
    style START fill:#ddd,color:#000
```

| Approach | Standard Attr | Memory | NPS4/SNC | Complexity | Status |
|---|---|---|---|---|---|
| `dra.net/numaNode` | No (informal) | Yes | Breaks | 1 constraint | Works today (with GPU driver patch) |
| `pcieRoot` as list | Yes | No | Correct | 2+ constraints | WIP ([k/k#138297](https://github.com/kubernetes/kubernetes/pull/138297), [dra-driver-cpu#68](https://github.com/kubernetes-sigs/dra-driver-cpu/pull/68)) |
| Topology Coordinator | N/A (abstracts) | Yes | Configurable | User writes 1 request | POC ([k8s-dra-topology-coordinator](https://github.com/fabiendupont/k8s-dra-topology-coordinator)) |

---

## Summary

There is no single topology attribute that works perfectly across all hardware configurations:

- **`numaNode`** is simple and covers all resource types, but sysfs NUMA indices don't reflect real hardware topology under SNC/NPS sub-NUMA partitioning
- **`pcieRoot`** is physically accurate and uses a standard attribute, but can't cover non-PCI resources (memory, hugepages) and requires the CPU driver to publish lists
- **`cpuSocketNumber`** is under discussion upstream but faces similar objections — too coarse for intra-socket topology, doesn't reflect real bandwidth distances

The topology coordinator resolves this by abstracting over attribute differences via ConfigMap rules, generating hardware-appropriate constraints regardless of which upstream standard eventually emerges.

---

## References

### Upstream KEPs and Standards

- [KEP-4381: DRA Structured Parameters](https://github.com/kubernetes/enhancements/blob/master/keps/sig-node/4381-dra-structured-parameters/README.md) — defines `resource.kubernetes.io/pcieRoot` and `resource.kubernetes.io/pciBusID` as the only two standard device attributes
- [KEP-4381 PR #5316: Define standard device attributes](https://github.com/kubernetes/enhancements/pull/5316) — the PR that standardized `pcieRoot`. Originally proposed `numaNode` too, but it was removed after objections about SNC/NPS accuracy. Key discussion threads:
  - [kad's objection to numaNode](https://github.com/kubernetes/enhancements/pull/5316#discussion_r2095270564) — "NUMA in sysfs does not represent real hardware topology in case of SNC or NPS active"
  - [fromani on numaNode vs cpuSocketNumber tradeoff](https://github.com/kubernetes/enhancements/pull/5316#discussion_r2095270564) — "swapping a problem set with another problem set"
  - [gauravkghildiyal's cpuSocketNumber proposal](https://github.com/kubernetes/enhancements/pull/5316#discussion_r2095270564) — multi-socket CPU+NIC alignment use case
- [KEP-5491: DRA List Types for Attributes](https://github.com/kubernetes/enhancements/issues/5491) — alpha in v1.36, enables list-typed attributes and set-based `matchAttribute` semantics
- [KEP-5491 implementation PR](https://github.com/kubernetes/kubernetes/pull/137190) — merged 2026-03-21, feature gate `DRAListTypeAttributes`
- [KEP-5942: Shared Consumable Capacity](https://github.com/kubernetes/enhancements/pull/5942) — proposed enhancement that may be needed for correct capacity representation when grouping CPUs by PCIe root

### pcieRoot-as-list Implementation

- [WIP: `GetPCIeRootAttributeMapFromCPUId` helper (kubernetes/kubernetes#138297)](https://github.com/kubernetes/kubernetes/pull/138297) — everpeace's upstream helper that scans sysfs to build CPU-to-PCIe-root mapping
- [WIP: Group CPUs by PCIe root (dra-driver-cpu#68)](https://github.com/kubernetes-sigs/dra-driver-cpu/pull/68) — fromani's CPU driver implementation with sysfs scanning, on hold pending k8s 1.36 rebase
- [NIC/CPU alignment by pcieRoot list (dra-driver-cpu#114)](https://github.com/kubernetes-sigs/dra-driver-cpu/issues/114) — everpeace's issue with example ResourceClaim YAML showing the approach
- [Original pcieRoot helper discussion (kubernetes/kubernetes#132296)](https://github.com/kubernetes/kubernetes/pull/132296#discussion_r2154600716) — where johnbelamaric proposed changing matchAttribute semantics to non-empty intersection of lists

### Cross-Driver Interoperability

- [DRA driver interoperability tracking (dra-driver-cpu#56)](https://github.com/kubernetes-sigs/dra-driver-cpu/issues/56) — fromani's issue tracking cross-driver attribute coordination
- [CPU driver compatibility with dra-driver-sriov (dra-driver-cpu#65)](https://github.com/kubernetes-sigs/dra-driver-cpu/pull/65) — adds `dra.net/numaNode` to CPU driver for NIC alignment
- [DraNet GPU/NIC alignment (google/dranet#92)](https://github.com/google/dranet/issues/92) — discussion of CPU/NIC alignment via DraNet
- [DraNet pcieRoot standard attribute (google/dranet#114)](https://github.com/google/dranet/pull/114) — DraNet adopting `resource.kubernetes.io/pcieRoot`

### Performance Validation

- [The Kubernetes Network Driver Model (arXiv:2506.23628)](https://arxiv.org/abs/2506.23628) — Ojea 2025, benchmarks showing 58% throughput improvement with topological GPU+NIC alignment on NVIDIA B200 GPUs
- [kad's KubeCon presentation on PCIe topology](https://sched.co/1i7ke) — explains why PCIe roots have different distances to particular cores depending on vendor and generation

### Topology Coordinator and Drivers

- [Node Partition Topology Coordinator](https://github.com/fabiendupont/k8s-dra-topology-coordinator) — POC by Fabien Dupont
- [CPU DRA Driver](https://github.com/kubernetes-sigs/dra-driver-cpu) — kubernetes-sigs
- [Memory DRA Driver](https://github.com/kad/dra-driver-memory) — early development
- [AMD GPU DRA Driver](https://github.com/ROCm/k8s-gpu-dra-driver)
- [NVIDIA GPU DRA Driver](https://github.com/NVIDIA/k8s-dra-driver-gpu)
- [SR-IOV NIC DRA Driver](https://github.com/k8snetworkplumbingwg/dra-driver-sriov)
- [DraNet](https://github.com/google/dranet)
