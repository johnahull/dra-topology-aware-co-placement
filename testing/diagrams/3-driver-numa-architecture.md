# DRA 3-Driver NUMA-Isolated Architecture — 2026-04-14

## Full Stack: GPU + CPU + NIC via DRA

```mermaid
graph TB
    subgraph "Control Plane"
        API[kube-apiserver]
        SCHED[kube-scheduler<br/>DRA allocation engine]
        COORD[Topology Coordinator]
    end

    subgraph "DRA Drivers (Node DaemonSets)"
        GPU_DRV["AMD GPU DRA Driver<br/>gpu.amd.com<br/>8 MI300X GPUs"]
        CPU_DRV["DRA CPU Driver<br/>dra.cpu<br/>2 devices (64 CPUs each)"]
        NIC_DRV["DRA SR-IOV Driver<br/>sriovnetwork<br/>8 NIC VFs (ConnectX-6)"]
    end

    subgraph "Node Hardware — NUMA 0 (Socket 0)"
        direction LR
        CPU0["64 CPUs<br/>(even: 0,2,4,...,126)"]
        GPU0["4x MI300X<br/>gpu-1, gpu-9<br/>gpu-17, gpu-25"]
        NIC0["4x CX-6 VFs<br/>1d:00.2-5"]
    end

    subgraph "Node Hardware — NUMA 1 (Socket 1)"
        direction LR
        CPU1["64 CPUs<br/>(odd: 1,3,5,...,127)"]
        GPU1["4x MI300X<br/>gpu-33, gpu-41<br/>gpu-49, gpu-57"]
        NIC1["4x CX-6 VFs<br/>9f:00.2-5"]
    end

    GPU_DRV -->|ResourceSlice| API
    CPU_DRV -->|ResourceSlice| API
    NIC_DRV -->|ResourceSlice| API

    GPU_DRV -.->|discovers| GPU0
    GPU_DRV -.->|discovers| GPU1
    CPU_DRV -.->|discovers| CPU0
    CPU_DRV -.->|discovers| CPU1
    NIC_DRV -.->|discovers| NIC0
    NIC_DRV -.->|discovers| NIC1

    COORD -->|reads slices| API
    COORD -->|creates partition<br/>DeviceClasses| API
    SCHED -->|allocates from<br/>same NUMA node| API
```

## Four-Pod Quarter-Machine Allocation

```mermaid
graph LR
    subgraph "NUMA 0"
        subgraph "Pod q0"
            Q0G["gpu-1<br/>gpu-25"]
            Q0N["1d:00.2<br/>1d:00.3"]
        end
        subgraph "Pod q1"
            Q1G["gpu-9<br/>gpu-17"]
            Q1N["1d:00.4<br/>1d:00.5"]
        end
    end

    subgraph "NUMA 1"
        subgraph "Pod q2"
            Q2G["gpu-33<br/>gpu-41"]
            Q2N["9f:00.2<br/>9f:00.5"]
        end
        subgraph "Pod q3"
            Q3G["gpu-49<br/>gpu-57"]
            Q3N["9f:00.3<br/>9f:00.4"]
        end
    end
```

## DRA Allocation Flow

```mermaid
sequenceDiagram
    participant User
    participant API as kube-apiserver
    participant Sched as kube-scheduler
    participant Kubelet
    participant GPU as AMD GPU DRA Driver
    participant CPU as DRA CPU Driver
    participant NIC as DRA SR-IOV Driver

    User->>API: Create ResourceClaim<br/>(gpu: count=2, numaNode==0<br/> nic: count=2, numaNode==0)
    User->>API: Create Pod (references claim)

    API->>Sched: Schedule pod
    Sched->>Sched: CEL selectors filter devices<br/>by NUMA node
    Sched->>API: Allocate:<br/>2 GPUs + 2 NICs from NUMA 0

    Kubelet->>GPU: PrepareResources<br/>(2 GPUs)
    GPU->>GPU: Filter by result.Driver<br/>Generate CDI specs<br/>(/dev/dri/card*, /dev/kfd)

    Kubelet->>NIC: PrepareResources<br/>(2 NIC VFs)
    NIC->>NIC: Filter by result.Driver<br/>Bind VFs to vfio-pci<br/>Write KEP-5304 metadata<br/>Generate CDI specs

    Kubelet->>Kubelet: Create container<br/>with CDI devices

    Note over User: Pod runs with:<br/>2 GPUs (/dev/dri/*, /dev/kfd)<br/>2 VFIO NICs (/dev/vfio/*)<br/>All from NUMA 0
```

## Topology Coordinator Rules

```mermaid
graph TB
    subgraph "Topology Rules (ConfigMaps)"
        R1["cpu-numa-rule<br/>dra.cpu/numaNodeID → numaNode"]
        R2["sriov-numa-rule<br/>dra.net/numaNode → numaNode"]
        R3["gpu-numa-rule<br/>gpu.amd.com/numaNode → numaNode"]
        R4["memory-numa-rule<br/>dra.memory/numaNode → numaNode"]
    end

    subgraph "ResourceSlices (per driver)"
        S1["dra.cpu<br/>numaNodeID: 0, 1"]
        S2["sriovnetwork<br/>numaNode: 0, 1"]
        S3["gpu.amd.com<br/>numaNode: 0, 1"]
        S4["dra.memory<br/>numaNode: 0, 1"]
    end

    subgraph "Coordinator"
        DISC[Device Discovery]
        MAP["Attribute Mapping<br/>All → common 'numaNode'"]
        PART[Partition Builder]
    end

    subgraph "Partition DeviceClasses"
        DC_E["eighth<br/>(1 GPU)"]
        DC_Q["quarter<br/>(2 GPUs + NIC + CPU + mem)"]
        DC_H["half<br/>(4 GPUs + NICs + CPU + mem)"]
        DC_F["full<br/>(all devices)"]
    end

    R1 & R2 & R3 & R4 --> MAP
    S1 & S2 & S3 & S4 --> DISC
    DISC --> MAP --> PART --> DC_E & DC_Q & DC_H & DC_F
```

## Device-to-NUMA Mapping (Dell XE9680)

```mermaid
graph TB
    subgraph "NUMA 0 — Socket 0"
        CPU0_D["CPUs 0,2,4,...,126<br/>(64 cores)"]
        GPU0_D["MI300X GPUs<br/>1b:00.0, 3d:00.0<br/>4e:00.0, 5f:00.0"]
        NIC0_D["ConnectX-6 VFs<br/>1d:00.2, 1d:00.3<br/>1d:00.4, 1d:00.5"]
        MEM0_D["Memory + Hugepages"]
    end

    subgraph "NUMA 1 — Socket 1"
        CPU1_D["CPUs 1,3,5,...,127<br/>(64 cores)"]
        GPU1_D["MI300X GPUs<br/>9d:00.0, bd:00.0<br/>cd:00.0, dd:00.0"]
        NIC1_D["ConnectX-6 VFs<br/>9f:00.2, 9f:00.3<br/>9f:00.4, 9f:00.5"]
        MEM1_D["Memory + Hugepages"]
    end

    subgraph "DRA Drivers"
        D_CPU["dra.cpu<br/>cpudevnuma000 (NUMA 0)<br/>cpudevnuma001 (NUMA 1)"]
        D_GPU["gpu.amd.com<br/>8 devices, 4 per NUMA"]
        D_NIC["sriovnetwork<br/>8 VFs, 4 per NUMA"]
        D_MEM["dra.memory<br/>4 zones, 2 per NUMA"]
    end

    CPU0_D -.-> D_CPU
    CPU1_D -.-> D_CPU
    GPU0_D -.-> D_GPU
    GPU1_D -.-> D_GPU
    NIC0_D -.-> D_NIC
    NIC1_D -.-> D_NIC
    MEM0_D -.-> D_MEM
    MEM1_D -.-> D_MEM
```

## Bugs Found

```mermaid
graph LR
    subgraph "AMD GPU DRA Driver"
        B1["Bug 1: Empty driverVersion<br/>fails semver validation<br/>Fix: fallback '0.0.0'"]
        B2["Bug 2: No driver filter<br/>in prepareDevices()<br/>Fix: skip other drivers"]
    end

    subgraph "Topology Coordinator"
        B3["Bug 2: matchAttribute<br/>namespace mismatch<br/>(nodepartition.dra.k8s.io)"]
        B4["Bug 3: Profile label<br/>exceeds 63 chars<br/>with 4+ drivers"]
    end

    subgraph "SR-IOV DRA Driver"
        B5["Patch 7: KEP-5304<br/>NRI mount collision<br/>with multi-device requests"]
    end
```
