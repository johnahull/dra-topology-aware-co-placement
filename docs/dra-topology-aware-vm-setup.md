# DRA Topology-Aware VM Setup Guide

**Date:** 2026-04-28

End-to-end setup for topology-aware KubeVirt VMs using DRA for all device allocation. GPU, NIC, CPU, and memory are co-placed on the same NUMA node by the DRA scheduler, and the kubelet's topology manager pins vCPUs to match — all without device plugins.

Verified on Dell R760xa (2x A40 GPUs, CX7 NICs, 2-socket Xeon, 128 CPUs).

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│  DRA Scheduler                                                       │
│  matchAttribute: resource.kubernetes.io/numaNode                     │
│  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐               │
│  │ GPU VFIO │ │ NIC (VF) │ │ CPU dev  │ │ Memory   │               │
│  │ NUMA 0   │ │ NUMA 0   │ │ NUMA 0   │ │ NUMA 0   │               │
│  └──────────┘ └──────────┘ └──────────┘ └──────────┘               │
└────────────────────────┬────────────────────────────────────────────┘
                         │ ResourceClaim allocated
                         ▼
┌─────────────────────────────────────────────────────────────────────┐
│  Kubelet (custom build)                                              │
│  ┌──────────────────────┐  ┌──────────────────────────────────────┐ │
│  │ DRA Topology Hints   │→│ Topology Manager (restricted)         │ │
│  │ reads numaNode from  │  │ merges hints from all providers      │ │
│  │ ResourceSlice attrs  │  │ selects NUMA 0 for CPU pinning       │ │
│  └──────────────────────┘  └──────────────────────────────────────┘ │
│  ┌──────────────────────┐                                           │
│  │ CPU Manager (static) │  pins vCPUs to NUMA 0 host CPUs          │
│  └──────────────────────┘                                           │
└────────────────────────┬────────────────────────────────────────────┘
                         │ cpuset + VFIO devices
                         ▼
┌─────────────────────────────────────────────────────────────────────┐
│  KubeVirt VM (guestMappingPassthrough)                               │
│  Guest sees: 1 socket, 1 NUMA node, GPU at 0000:09:00.0             │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Prerequisites

- Kubernetes 1.36+ with DRA enabled (DynamicResourceAllocation feature gate)
- containerd 2.2.3+
- KubeVirt 1.5+ with DRA support
- IOMMU enabled in BIOS (for GPU VFIO passthrough)
- SR-IOV VFs configured on NICs (if NIC passthrough needed)

## Components

| Component | Version/Image | Purpose |
|-----------|---------------|---------|
| Kubelet | Custom build from `johnahull/kubernetes` branch `feature/enforcement-preferred` | DRA topology hints + CPU manager fixes |
| dranet | `ghcr.io/johnahull/dra-topology-drivers/dranet:latest` | NIC DRA driver with topology attrs + VFIO |
| dra-cpu | `ghcr.io/johnahull/dra-topology-drivers/dracpu:latest` | CPU DRA driver with NUMA attrs |
| dra-memory | `ghcr.io/johnahull/dra-topology-drivers/dramemory:latest` | Memory/hugepages DRA driver |
| NVIDIA DRA | GPU Operator with DRA enabled | GPU DRA driver with VFIO + topology attrs |
| KubeVirt | `johnahull/kubevirt` branch `feature/dra-vfio-numa-passthrough-v1.8.1` | Multi-request DRA claim fixes |

---

## Step 1: Custom Kubelet Build

The custom kubelet has three fixes required for DRA-aware CPU pinning:

### Fix 1: DRA Topology Hints (new file)

`pkg/kubelet/cm/dra/topology_hints.go` — Makes the DRA Manager implement `topologymanager.HintProvider`. Reads `resource.kubernetes.io/numaNode` from ResourceSlice device attributes for each allocated device in the pod's ResourceClaims. Returns NUMA topology hints so the topology manager aligns CPU pinning with DRA device placement.

The key requirement: ResourceSlice list calls must include `FieldSelector: "spec.nodeName=" + m.nodeName` — the Node Authorizer denies unscoped list requests.

### Fix 2: CPU Manager Reconciler

`pkg/kubelet/cm/cpumanager/cpu_manager.go` `AddContainer()` — The original code set `lastUpdateState` without writing the cgroup, so the reconciler never corrected cpuset mismatches. Fixed by calling `updateContainerCPUSet` immediately in `AddContainer` and only setting `lastUpdateState` after the update succeeds.

### Fix 3: Manager Registration

`pkg/kubelet/cm/container_manager_linux.go` — Registers the DRA Manager as a topology hint provider: `cm.topologyManager.AddHintProvider(logger, cm.draManager)`. Passes `string(nodeConfig.NodeName)` to `dra.NewManager`.

### Building

```bash
cd ~/devel/kubernetes/kubernetes
git checkout feature/enforcement-preferred
GOTOOLCHAIN=auto go build -mod=vendor -o _output/bin/kubelet ./cmd/kubelet/
```

### Deploying

```bash
scp _output/bin/kubelet <node>:/tmp/kubelet-custom
ssh <node> '
  sudo systemctl stop kubelet
  sudo cp /usr/bin/kubelet /usr/bin/kubelet.bak
  sudo cp /tmp/kubelet-custom /usr/bin/kubelet
  sudo rm -f /var/lib/kubelet/cpu_manager_state
  sudo systemctl start kubelet
'
```

Removing `cpu_manager_state` forces a clean state on policy change.

---

## Step 2: Kubelet Configuration

Edit `/var/lib/kubelet/config.yaml`:

```yaml
cpuManagerPolicy: static
topologyManagerPolicy: restricted
reservedSystemCPUs: "0-3"
```

- `static` — enables exclusive CPU pinning for Guaranteed QoS pods with integer CPU requests
- `restricted` — rejects pods if topology hints can't be satisfied; ensures CPUs are pinned to the same NUMA as DRA devices
- `reservedSystemCPUs` — excludes CPUs 0-3 from allocation (adjust for your system)

Restart kubelet after config changes. Remove `cpu_manager_state` when changing policies.

---

## Step 3: Hugepages

KubeVirt VMs with `guestMappingPassthrough` require hugepages.

```bash
# Set 8192 x 2Mi pages = 16Gi
sudo sysctl -w vm.nr_hugepages=8192

# Persist across reboots
echo "vm.nr_hugepages=8192" | sudo tee /etc/sysctl.d/99-hugepages.conf

# Restart kubelet to pick up new hugepage count
sudo systemctl restart kubelet

# Verify
kubectl describe node | grep hugepages
```

The node should show `hugepages-2Mi: 16Gi` in allocatable resources.

---

## Step 4: DRA Drivers

### 4a. dranet (Network)

Discovers all NICs (PFs and SR-IOV VFs) and publishes standardized topology attributes.

```yaml
# dranet-daemonset.yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: dranet
  namespace: kube-system
spec:
  selector:
    matchLabels:
      app: dranet
  template:
    metadata:
      labels:
        app: dranet
    spec:
      hostNetwork: true
      hostPID: true
      tolerations:
      - operator: Exists
      containers:
      - name: dranet
        image: ghcr.io/johnahull/dra-topology-drivers/dranet:latest
        imagePullPolicy: IfNotPresent
        args:
        - /dranet
        - --v=4
        - --hostname-override=$(NODE_NAME)
        env:
        - name: NODE_NAME
          valueFrom:
            fieldRef:
              fieldPath: spec.nodeName
        securityContext:
          privileged: true
        volumeMounts:
        - name: device-plugin
          mountPath: /var/lib/kubelet/plugins
        - name: plugin-registry
          mountPath: /var/lib/kubelet/plugins_registry
        - name: nri-plugin
          mountPath: /var/run/nri
        - name: netns
          mountPath: /var/run/netns
          mountPropagation: HostToContainer
        - name: cdi
          mountPath: /var/run/cdi
        - name: sys
          mountPath: /sys
      volumes:
      - name: device-plugin
        hostPath:
          path: /var/lib/kubelet/plugins
      - name: plugin-registry
        hostPath:
          path: /var/lib/kubelet/plugins_registry
      - name: nri-plugin
        hostPath:
          path: /var/run/nri
      - name: netns
        hostPath:
          path: /var/run/netns
      - name: cdi
        hostPath:
          path: /var/run/cdi
          type: DirectoryOrCreate
      - name: sys
        hostPath:
          path: /sys
```

### 4b. CPU Driver

```yaml
# dracpu-daemonset.yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: dracpu
  namespace: kube-system
spec:
  selector:
    matchLabels:
      app: dracpu
  template:
    metadata:
      labels:
        app: dracpu
    spec:
      tolerations:
      - operator: Exists
      containers:
      - name: dracpu
        image: ghcr.io/johnahull/dra-topology-drivers/dracpu:latest
        imagePullPolicy: IfNotPresent
        args:
        - --hostname-override=$(NODE_NAME)
        env:
        - name: NODE_NAME
          valueFrom:
            fieldRef:
              fieldPath: spec.nodeName
        securityContext:
          privileged: true
        volumeMounts:
        - name: plugins-registry
          mountPath: /var/lib/kubelet/plugins_registry
        - name: plugins
          mountPath: /var/lib/kubelet/plugins/dra.cpu
        - name: cdi
          mountPath: /var/run/cdi
      volumes:
      - name: plugins-registry
        hostPath:
          path: /var/lib/kubelet/plugins_registry
      - name: plugins
        hostPath:
          path: /var/lib/kubelet/plugins/dra.cpu
          type: DirectoryOrCreate
      - name: cdi
        hostPath:
          path: /var/run/cdi
          type: DirectoryOrCreate
```

### 4c. Memory Driver

```yaml
# dramemory-daemonset.yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: dramemory
  namespace: kube-system
spec:
  selector:
    matchLabels:
      app: dramemory
  template:
    metadata:
      labels:
        app: dramemory
    spec:
      tolerations:
      - operator: Exists
      containers:
      - name: dramemory
        image: ghcr.io/johnahull/dra-topology-drivers/dramemory:latest
        imagePullPolicy: IfNotPresent
        args:
        - --hostname-override=$(NODE_NAME)
        env:
        - name: NODE_NAME
          valueFrom:
            fieldRef:
              fieldPath: spec.nodeName
        securityContext:
          privileged: true
        volumeMounts:
        - name: plugins-registry
          mountPath: /var/lib/kubelet/plugins_registry
        - name: plugins
          mountPath: /var/lib/kubelet/plugins/dra.memory
        - name: cdi
          mountPath: /var/run/cdi
      volumes:
      - name: plugins-registry
        hostPath:
          path: /var/lib/kubelet/plugins_registry
      - name: plugins
        hostPath:
          path: /var/lib/kubelet/plugins/dra.memory
          type: DirectoryOrCreate
      - name: cdi
        hostPath:
          path: /var/run/cdi
          type: DirectoryOrCreate
```

### 4d. NVIDIA GPU DRA Driver

Install via GPU Operator with DRA enabled, or Helm:

```bash
helm install nvidia-dra nvidia/nvidia-dra-driver \
  --namespace nvidia-dra --create-namespace \
  --set nvidiaDriverRoot=/run/nvidia/driver
```

The NVIDIA DRA driver publishes `gpu-vfio-*` devices for VFIO passthrough and sets `resource.kubernetes.io/numaNode` on all devices.

---

## Step 5: DeviceClasses

```yaml
apiVersion: resource.k8s.io/v1
kind: DeviceClass
metadata:
  name: dra.net
spec:
  selectors:
  - cel:
      expression: "device.driver == 'dra.net'"
---
apiVersion: resource.k8s.io/v1
kind: DeviceClass
metadata:
  name: dra.net-sriov-vf
spec:
  selectors:
  - cel:
      expression: "device.driver == 'dra.net' && device.attributes['dra.net/isSriovVf'].BoolValue"
---
apiVersion: resource.k8s.io/v1
kind: DeviceClass
metadata:
  name: dra.cpu
spec:
  selectors:
  - cel:
      expression: "device.driver == 'dra.cpu'"
---
apiVersion: resource.k8s.io/v1
kind: DeviceClass
metadata:
  name: dra.memory
spec:
  selectors:
  - cel:
      expression: "device.driver == 'dra.memory'"
```

The `vfio.gpu.nvidia.com` DeviceClass is created automatically by the NVIDIA DRA driver.

---

## Step 6: KubeVirt Configuration

### Feature Gates

```bash
kubectl patch kubevirt kubevirt -n kubevirt --type merge -p '{
  "spec": {
    "configuration": {
      "developerConfiguration": {
        "featureGates": [
          "HostDevices",
          "DRA",
          "HostDevicesWithDRA",
          "GPUsWithDRA",
          "CPUManager",
          "ReservedOverheadMemlock"
        ]
      }
    }
  }
}'
```

All six feature gates are required:
- `DRA` — enables DRA resource claims in VMI specs
- `GPUsWithDRA` — GPU passthrough via DRA claims
- `HostDevicesWithDRA` — host device passthrough via DRA claims
- `HostDevices` — general host device support
- `CPUManager` — dedicated CPU placement
- `ReservedOverheadMemlock` — allows `reservedOverhead.addedOverhead` for VFIO memory locking

### Custom KubeVirt Build

Branch `feature/dra-vfio-numa-passthrough-v1.8.1` on `johnahull/kubevirt` contains fixes for multi-request DRA claims:

1. `copyResourceClaims` deduplicates by `{Name, Request}` not just `Name` — prevents dropping NIC when GPU is from the same claim
2. `WithExtraResourceClaims` adds all VMI claims to the compute container without a Request filter
3. `WithGPUsDRA` and `WithHostDevicesDRA` simplified to avoid duplicate claim name errors

---

## Step 7: Verification

### Check DRA Drivers

```bash
kubectl get resourceslices -o json | python3 -c "
import json, sys
data = json.load(sys.stdin)
drivers = set(s['spec']['driver'] for s in data['items'])
print('Drivers:', sorted(drivers))
"
```

Expected: `dra.cpu`, `dra.memory`, `dra.net`, `gpu.nvidia.com`

### Check Topology Attributes

```bash
kubectl get resourceslices -o json | python3 -c "
import json, sys
data = json.load(sys.stdin)
for s in data['items']:
    driver = s['spec']['driver']
    for d in s['spec'].get('devices', []):
        attrs = d.get('attributes', {})
        numa = attrs.get('resource.kubernetes.io/numaNode', {}).get('int', '?')
        print(f'{driver:40s} {d[\"name\"]:25s} NUMA={numa}')
"
```

All devices should have `resource.kubernetes.io/numaNode` set.

---

## Step 8: Create a Topology-Aware VM

### ResourceClaimTemplate

```yaml
apiVersion: resource.k8s.io/v1
kind: ResourceClaimTemplate
metadata:
  name: vm-numa0-devices
spec:
  spec:
    devices:
      requests:
      - name: gpu
        exactly:
          deviceClassName: vfio.gpu.nvidia.com
      - name: cpu
        exactly:
          deviceClassName: dra.cpu
      - name: mem
        exactly:
          deviceClassName: dra.memory
      constraints:
      - requests: ["gpu", "cpu", "mem"]
        matchAttribute: resource.kubernetes.io/numaNode
```

The `matchAttribute` constraint forces the scheduler to pick devices that share the same `numaNode` value across all three drivers.

### VirtualMachine

```yaml
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: dra-topology-vm
spec:
  running: true
  template:
    spec:
      domain:
        cpu:
          cores: 4
          sockets: 1
          threads: 1
          dedicatedCpuPlacement: true
          numa:
            guestMappingPassthrough: {}
        memory:
          guest: 4Gi
          hugepages:
            pageSize: 2Mi
          reservedOverhead:
            addedOverhead: 4Gi
        devices:
          gpus:
          - name: gpu0
            claimName: numa0
            requestName: gpu
          disks:
          - name: containerdisk
            disk:
              bus: virtio
          - name: cloudinitdisk
            disk:
              bus: virtio
        resources:
          requests:
            memory: 4Gi
      volumes:
      - name: containerdisk
        containerDisk:
          image: quay.io/containerdisks/fedora:40
      - name: cloudinitdisk
        cloudInitNoCloud:
          userData: |
            #cloud-config
            password: fedora
            chpasswd:
              expire: false
            ssh_pwauth: true
      resourceClaims:
      - name: numa0
        resourceClaimTemplateName: vm-numa0-devices
```

Key settings:
- `dedicatedCpuPlacement: true` — exclusive CPU pinning (Guaranteed QoS)
- `guestMappingPassthrough: {}` — guest NUMA topology mirrors host CPU placement
- `hugepages.pageSize: 2Mi` — required for NUMA-aware memory binding
- `reservedOverhead.addedOverhead: 4Gi` — additional locked memory for VFIO DMA

### Verify

```bash
# Check VM is running
kubectl get vmi dra-topology-vm

# Check CPU pinning
cat /var/lib/kubelet/cpu_manager_state | python3 -m json.tool

# Check DRA allocation
kubectl get resourceclaims -o json | python3 -c "
import json, sys
for c in json.load(sys.stdin)['items']:
    print(c['metadata']['name'])
    for r in c.get('status',{}).get('allocation',{}).get('devices',{}).get('results',[]):
        print(f'  {r[\"request\"]:8s} -> {r[\"driver\"]:30s} {r[\"device\"]}')
"

# Check kubelet logs for DRA topology hints
journalctl -u kubelet | grep "DRA topology"

# SSH into VM
sshpass -p fedora ssh fedora@<vm-ip>
lscpu | grep NUMA
# Should show: NUMA node(s): 1
```

---

## How It Works (Data Flow)

1. **Scheduling**: The DRA scheduler evaluates the `matchAttribute: resource.kubernetes.io/numaNode` constraint and picks GPU, CPU device, and memory device that all have the same `numaNode` value (e.g., all NUMA 0).

2. **Pod Admission**: The kubelet admits the pod. The topology manager queries all HintProviders:
   - CPU Manager generates hints based on available CPUs per NUMA
   - DRA Manager (`topology_hints.go`) reads the ResourceClaim allocations, looks up each device's `numaNode` from the ResourceSlice, and returns `{NUMANodeAffinity: 0}` (NUMA 0)

3. **Topology Decision**: The topology manager merges hints and selects NUMA 0 as the best fit.

4. **CPU Allocation**: The CPU Manager allocates 4 exclusive CPUs from NUMA 0 (e.g., CPUs 4,6,68,70).

5. **Container Creation**: `PreCreateContainer` sets `CpusetCpus: "4,6,68,70"` in the CRI config. `AddContainer` calls `UpdateContainerResources` to ensure the cgroup is correct before the container starts.

6. **VM Launch**: KubeVirt's virt-launcher reads `cpuset.cpus.effective` (4,6,68,70), maps them to host NUMA cell 0, generates libvirt XML with `<numatune><memnode cellid='0' mode='strict' nodeset='0'/></numatune>`, and starts QEMU with hugepages bound to NUMA 0 and the GPU passed through via VFIO.

---

## Troubleshooting

### DRA topology hints not generated

Check kubelet logs:
```bash
journalctl -u kubelet | grep "DRA topology"
```

If no output, verify:
- The DRA Manager is registered as a HintProvider (requires custom kubelet)
- `topologyManagerPolicy` is `restricted` or `best-effort` (not `none`)
- The pod has ResourceClaims with allocated devices

### CPUs pinned to wrong NUMA node

Check cgroup cpuset:
```bash
# Find the compute container's cgroup
find /sys/fs/cgroup -name "cri-containerd-*" -path "*<pod-uid>*" -exec sh -c 'echo "$(basename {}): $(cat {}/cpuset.cpus)"' \;

# Compare with CPU manager state
cat /var/lib/kubelet/cpu_manager_state | python3 -m json.tool
```

If cgroup doesn't match state, the kubelet needs the `AddContainer` fix (Fix 2 and 3 above).

### VM fails with `set_mempolicy: Invalid argument`

The QEMU memory binding is targeting the wrong NUMA node. Check:
1. The compute container's `cpuset.cpus` matches the CPU manager state
2. The cpuset CPUs are on the expected NUMA node: `cat /sys/devices/system/cpu/cpu<N>/topology/physical_package_id`
3. The `cpuset.mems` allows the correct NUMA node

### ResourceSlice list returns empty

The kubelet's Node Authorizer requires `spec.nodeName` field selector. Verify the custom kubelet includes this fix in `lookupDeviceNUMANode`.

### Hugepages insufficient

```bash
kubectl describe node | grep hugepages
# Must show enough hugepages-2Mi for guest memory + overhead
# Formula: (guest memory + addedOverhead) / 2Mi
```

---

## Repositories

| Repository | Branch | Changes |
|------------|--------|---------|
| `johnahull/kubernetes` | `feature/enforcement-preferred` | DRA topology hints, CPU manager fixes |
| `johnahull/kubevirt` | `feature/dra-vfio-numa-passthrough-v1.8.1` | Multi-request DRA claim fixes |
| `johnahull/dranet` | `feature/standardized-topology-attrs` | Standardized topology attributes, VFIO support |
