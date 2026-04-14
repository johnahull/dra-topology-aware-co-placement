# DRA Topology-Aware Co-Placement Architecture — Fedora 43 + K8s 1.36

## Full Stack Overview

```mermaid
graph TB
    subgraph "K8s 1.36 Control Plane"
        API["kube-apiserver<br/>DRA resource.k8s.io/v1<br/>DRAConsumableCapacity β"]
        SCHED["kube-scheduler<br/>CEL selectors<br/>capacity accounting"]
    end

    subgraph "DRA Drivers (4 DaemonSets)"
        CPU_DRV["DRA CPU Driver<br/>dra.cpu<br/>2 devices × 64 CPUs<br/>consumable: dra.cpu/cpu"]
        GPU_DRV["AMD GPU DRA Driver<br/>gpu.amd.com<br/>8 MI300X GPUs<br/>KEP-5304 metadata"]
        NIC_DRV["DRA SR-IOV Driver<br/>sriovnetwork<br/>8 ConnectX-6 VFs<br/>KEP-5304 metadata"]
        MEM_DRV["DRA Memory Driver<br/>dra.memory<br/>2 regular + 2 hugepages<br/>consumable: size"]
    end

    subgraph "containerd 2.3-dev"
        CTR["containerd<br/>NRI v0.11.0"]
        CDI["CDI specs<br/>/var/run/cdi"]
        NRI["NRI socket<br/>/var/run/nri"]
    end

    subgraph "kubelet"
        KUB["kubelet v1.36.0-rc.0"]
        META["KEP-5304<br/>Metadata Writer"]
    end

    CPU_DRV -->|ResourceSlice| API
    GPU_DRV -->|ResourceSlice| API
    NIC_DRV -->|ResourceSlice| API
    MEM_DRV -->|ResourceSlice| API

    SCHED -->|allocate + consume capacity| API
    KUB -->|PrepareResources| CPU_DRV
    KUB -->|PrepareResources| GPU_DRV
    KUB -->|PrepareResources| NIC_DRV
    KUB -->|PrepareResources| MEM_DRV

    CPU_DRV -->|NRI cpuset| NRI
    MEM_DRV -->|NRI cgroup limits| NRI
    GPU_DRV -->|CDI /dev/dri /dev/kfd| CDI
    NIC_DRV -->|CDI /dev/vfio| CDI

    GPU_DRV -->|Metadata| META
    NIC_DRV -->|Metadata| META
    META -->|CDI bind mount| CDI
    NRI --> CTR
    CDI --> CTR
```

## Dell XE9680 Hardware Layout

```mermaid
graph TB
    subgraph "Socket 0 — NUMA Node 0"
        CPU0["64 CPUs<br/>even: 0,2,4,...,126"]
        subgraph "PCIe — NUMA 0"
            GPU0A["MI300X<br/>1b:00.0<br/>pci0000:15"]
            GPU0B["MI300X<br/>3d:00.0<br/>pci0000:37"]
            GPU0C["MI300X<br/>4e:00.0<br/>pci0000:48"]
            GPU0D["MI300X<br/>5f:00.0<br/>pci0000:59"]
            NIC0["ConnectX-6 VFs<br/>1d:00.2-5<br/>4 VFs"]
        end
        MEM0["~1 TiB DDR5<br/>32 GiB Hugepages (2Mi)"]
    end

    subgraph "Socket 1 — NUMA Node 1"
        CPU1["64 CPUs<br/>odd: 1,3,5,...,127"]
        subgraph "PCIe — NUMA 1"
            GPU1A["MI300X<br/>9d:00.0<br/>pci0000:97"]
            GPU1B["MI300X<br/>bd:00.0<br/>pci0000:b7"]
            GPU1C["MI300X<br/>cd:00.0<br/>pci0000:c7"]
            GPU1D["MI300X<br/>dd:00.0<br/>pci0000:d7"]
            NIC1["ConnectX-6 VFs<br/>9f:00.2-5<br/>4 VFs"]
        end
        MEM1["~1 TiB DDR5<br/>32 GiB Hugepages (2Mi)"]
    end
```

## Quarter-Machine Allocation (4 Pods)

```mermaid
graph LR
    subgraph "NUMA 0"
        subgraph "Pod q0"
            Q0["32 CPUs<br/>gpu-9, gpu-17<br/>NIC 1d:00.2-3<br/>128 GiB mem<br/>8 GiB hugepages"]
        end
        subgraph "Pod q1"
            Q1["32 CPUs<br/>gpu-1, gpu-25<br/>NIC 1d:00.4-5<br/>128 GiB mem<br/>8 GiB hugepages"]
        end
    end

    subgraph "NUMA 1"
        subgraph "Pod q2"
            Q2["32 CPUs<br/>gpu-33, gpu-41<br/>NIC 9f:00.4-5<br/>128 GiB mem<br/>8 GiB hugepages"]
        end
        subgraph "Pod q3"
            Q3["32 CPUs<br/>gpu-49, gpu-57<br/>NIC 9f:00.2-3<br/>128 GiB mem<br/>8 GiB hugepages"]
        end
    end
```

## DRAConsumableCapacity Flow

```mermaid
sequenceDiagram
    participant User
    participant API as kube-apiserver
    participant Sched as kube-scheduler
    participant Kubelet
    participant CPU as DRA CPU Driver
    participant GPU as AMD GPU Driver
    participant NIC as SR-IOV Driver
    participant MEM as Memory Driver

    User->>API: Create ResourceClaim<br/>(cpu: 32 cores, gpu: 2,<br/>nic: 2, mem: 128Gi,<br/>hugepages: 8Gi,<br/>all NUMA 0)

    User->>API: Create Pod

    API->>Sched: Schedule pod
    Sched->>Sched: CEL: filter by numaNode==0
    Sched->>Sched: Capacity: 32 of 64 CPUs available?
    Sched->>Sched: Capacity: 128Gi of 1Ti memory available?
    Sched->>Sched: Capacity: 8Gi of 32Gi hugepages available?
    Sched->>API: Allocate with consumedCapacity:<br/>cpu=32, mem=128Gi, hp=8Gi

    Note over Sched: Second pod requests same NUMA 0<br/>→ 32 CPUs remaining, 128Gi remaining<br/>→ still satisfiable ✓

    Kubelet->>CPU: PrepareResources(32 CPUs from NUMA 0)
    CPU->>CPU: Assign exclusive cpuset<br/>(e.g., 0,2,4,...,62)
    CPU-->>Kubelet: CDI + NRI cpuset

    Kubelet->>GPU: PrepareResources(gpu-9, gpu-17)
    GPU->>GPU: CDI spec for /dev/dri/card*, /dev/kfd
    GPU->>GPU: KEP-5304 metadata: pciBusID
    GPU-->>Kubelet: CDI devices + Metadata

    Kubelet->>NIC: PrepareResources(1d:00.2, 1d:00.3)
    NIC->>NIC: Bind VFs to vfio-pci
    NIC->>NIC: CDI spec for /dev/vfio/*
    NIC->>NIC: KEP-5304 metadata: pciBusID
    NIC-->>Kubelet: CDI devices + Metadata

    Kubelet->>MEM: PrepareResources(memory-gt5gdg, 128Gi)
    MEM->>MEM: NRI cgroup memory limits
    MEM-->>Kubelet: NRI adjustments

    Kubelet->>Kubelet: Write KEP-5304 metadata files
    Kubelet->>Kubelet: Generate CDI mounts for metadata
    Kubelet->>API: Container starts with:<br/>• 32 exclusive CPUs (cpuset)<br/>• 2 GPUs (/dev/dri, /dev/kfd)<br/>• 2 VFIO NICs (/dev/vfio)<br/>• 128 GiB NUMA-local memory<br/>• 8 GiB hugepages<br/>• KEP-5304 metadata
```

## KEP-5304 Native Metadata Flow (K8s 1.36)

```mermaid
sequenceDiagram
    participant Driver as DRA Driver
    participant Helper as kubeletplugin.Helper
    participant MetaWriter as Metadata Writer
    participant CDI as CDI Spec
    participant Pod

    Driver->>Helper: kubeletplugin.Start(<br/>EnableDeviceMetadata(true),<br/>MetadataVersions(v1alpha1))

    Note over Driver: During PrepareResourceClaims

    Driver->>Helper: PrepareResult{<br/>Devices: [{<br/>  DeviceName: "gpu-9",<br/>  Metadata: {<br/>    Attributes: {<br/>      "pciBusID": "0000:3d:00.0",<br/>      "productName": "MI300X"<br/>    }<br/>  }<br/>}]}

    Helper->>MetaWriter: processPreparedClaim()
    MetaWriter->>MetaWriter: Write JSON to<br/>{pluginDataDir}/metadata/

    MetaWriter->>CDI: Generate CDI spec<br/>with bind mount

    CDI->>Pod: Mount metadata at<br/>/var/run/kubernetes.io/<br/>dra-device-attributes/<br/>resourceclaims/{claim}/{request}/

    Note over Pod: Pod reads JSON:<br/>pciBusID, productName, etc.

    Note over Helper: On UnprepareResourceClaims
    Helper->>MetaWriter: cleanupClaim()
    MetaWriter->>MetaWriter: Remove metadata files + CDI specs
```

## Patch Summary

```mermaid
graph LR
    subgraph "SR-IOV DRA Driver (5 patches)"
        S1["KEP-5304 native metadata"]
        S2["Populate Metadata field"]
        S3["NAD optional (VFIO)"]
        S4["Skip RDMA (vfio-pci)"]
        S5["Skip CNI (VFIO)"]
    end

    subgraph "AMD GPU DRA Driver (5 patches)"
        G1["driverVersion fallback 0.0.0"]
        G2["Multi-driver claim filter"]
        G3["KEP-5304 native metadata"]
        G4["Standard pciBusID attribute"]
        G5["K8s 1.36 API rename"]
    end

    subgraph "Memory Driver (2 patches)"
        M1["cgroup2 mount filter<br/>(Calico workaround)"]
        M2["Go 1.26 Dockerfile"]
    end

    subgraph "containerd"
        C1["Built from main<br/>NRI v0.8.0 → v0.11.0"]
    end
```

## Device Attribute Namespaces

```mermaid
graph TB
    subgraph "Each Driver's NUMA Attribute"
        A1["dra.cpu/numaNodeID"]
        A2["gpu.amd.com/numaNode"]
        A3["dra.net/numaNode"]
        A4["dra.memory/numaNode"]
    end

    subgraph "CEL Selectors (per claim)"
        C1["device.attributes<br/>[dra.cpu].numaNodeID == 0"]
        C2["device.attributes<br/>[gpu.amd.com].numaNode == 0"]
        C3["device.attributes<br/>[dra.net].numaNode == 0"]
        C4["device.attributes<br/>[dra.memory].numaNode == 0"]
    end

    subgraph "Result"
        R["All devices from<br/>same NUMA node"]
    end

    A1 --> C1
    A2 --> C2
    A3 --> C3
    A4 --> C4
    C1 & C2 & C3 & C4 --> R

    subgraph "Capacity Keys"
        CAP1["dra.cpu/cpu: 32"]
        CAP2["size: 128Gi"]
        CAP3["size: 8Gi"]
    end

    CAP1 -.->|"consumedCapacity"| R
    CAP2 -.->|"consumedCapacity"| R
    CAP3 -.->|"consumedCapacity"| R
```
