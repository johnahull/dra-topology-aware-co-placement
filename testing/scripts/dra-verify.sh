#!/bin/bash
# dra-verify.sh — Verify DRA topology-aware co-placement stack
#
# Usage:
#   dra-verify.sh drivers                    Show DRA driver status
#   dra-verify.sh attributes                 Show ResourceSlice topology attributes
#   dra-verify.sh claims [-n ns]             Show allocated claims with pods/VMs and devices
#   dra-verify.sh alignment [pod] [-n ns]    Show device NUMA/pcieRoot/socket alignment
#   dra-verify.sh cpupinning [pod] [-n ns]   Show cpuset vs device NUMA
#   dra-verify.sh vfio                       Show VFIO-bound devices and CDI specs
#   dra-verify.sh metadata [pod] [-n ns]     Show KEP-5304 metadata in pod
#   dra-verify.sh guest [vm] [-n ns]         Show guest NUMA topology in VM
#   dra-verify.sh all [-n ns]                Run all checks

set -uo pipefail

# ── Colors ────────────────────────────────────────────────────────────────────
BOLD='\033[1m'
DIM='\033[2m'
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

OK="${GREEN}✓${NC}"
WARN="${YELLOW}!${NC}"
FAIL="${RED}✗${NC}"

# ── Argument parsing ──────────────────────────────────────────────────────────
CMD="${1:-help}"
shift || true

NAMESPACE=""
TARGET=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -n|--namespace) NAMESPACE="$2"; shift 2 ;;
        -h|--help) CMD="help"; shift ;;
        *) TARGET="$1"; shift ;;
    esac
done

ns_flag() {
    if [[ -n "$NAMESPACE" ]]; then
        echo "-n $NAMESPACE"
    else
        echo "-A"
    fi
}

section() {
    echo ""
    echo -e "${BOLD}${CYAN}═══ $1 ═══${NC}"
    echo ""
}

# ── drivers ───────────────────────────────────────────────────────────────────

cmd_drivers() {
    section "DRA Driver Status"

    echo -e "${BOLD}DaemonSets:${NC}"
    kubectl get ds -A -o wide 2>/dev/null | grep -i "dra\|gpu\|sriov\|dranet\|nvme\|cpu.*driver\|memory.*driver" || echo -e "  ${DIM}(no DRA daemonsets found)${NC}"
    echo ""

    echo -e "${BOLD}Driver Pods:${NC}"
    kubectl get pods -A -o wide 2>/dev/null | grep -i "dra\|gpu.*dra\|gpu.*kubelet\|sriov\|dranet\|nvme\|cpu.*driver\|memory.*driver" || echo -e "  ${DIM}(no DRA driver pods found)${NC}"
    echo ""

    echo -e "${BOLD}ResourceSlices (per driver):${NC}"
    kubectl get resourceslices -o json 2>/dev/null | python3 -c "
import json, sys
data = json.load(sys.stdin)
drivers = {}
for rs in data.get('items', []):
    driver = rs['spec']['driver']
    node = rs['spec'].get('nodeName', rs['spec'].get('pool', {}).get('name', '?'))
    devices = rs['spec'].get('devices', []) or []
    if driver not in drivers:
        drivers[driver] = {'nodes': set(), 'devices': 0}
    drivers[driver]['nodes'].add(node)
    drivers[driver]['devices'] += len(devices)

if not drivers:
    print('  (no ResourceSlices found)')
else:
    for d in sorted(drivers):
        info = drivers[d]
        nodes = ', '.join(sorted(info['nodes']))
        print(f'  \033[1m{d}\033[0m: {info[\"devices\"]} devices on {nodes}')
" 2>/dev/null
    echo ""

    echo -e "${BOLD}Kubelet Plugin Registration:${NC}"
    local reg_dir="/var/lib/kubelet/plugins_registry"
    if [[ -d "$reg_dir" ]]; then
        ls -la "$reg_dir"/*dra* "$reg_dir"/*gpu* "$reg_dir"/*sriov* "$reg_dir"/*dranet* "$reg_dir"/*nvme* "$reg_dir"/*cpu* "$reg_dir"/*memory* 2>/dev/null | while read -r line; do
            echo "  $line"
        done
        if [[ -z "$(ls "$reg_dir"/*dra* "$reg_dir"/*gpu* "$reg_dir"/*sriov* "$reg_dir"/*dranet* 2>/dev/null)" ]]; then
            echo -e "  ${DIM}(no DRA plugins registered — run on the node, not remotely)${NC}"
        fi
    else
        echo -e "  ${DIM}(not running on a node — kubelet plugin dir not found)${NC}"
    fi
}

# ── attributes ────────────────────────────────────────────────────────────────

cmd_attributes() {
    section "ResourceSlice Topology Attributes"

    kubectl get resourceslices -o json 2>/dev/null | python3 -c "
import json, sys

data = json.load(sys.stdin)
TOPO_ATTRS = [
    'resource.kubernetes.io/numaNode',
    'resource.kubernetes.io/cpuSocketID',
    'resource.kubernetes.io/pcieRoot',
    'resource.kubernetes.io/pciBusID',
]
# Also check vendor-specific NUMA attrs
NUMA_VENDOR = ['numaNode', 'numa', 'numaNodeID']

drivers = {}
for rs in data.get('items', []):
    driver = rs['spec']['driver']
    for dev in rs['spec'].get('devices', []) or []:
        name = dev['name']
        attrs = dev.get('attributes', {})

        # Extract topology values
        topo = {}
        for key in TOPO_ATTRS:
            if key in attrs:
                val = attrs[key]
                topo[key.split('/')[-1]] = list(val.values())[0]

        # Check vendor NUMA
        for vk in NUMA_VENDOR:
            for ak, av in attrs.items():
                aname = ak.split('/')[-1] if '/' in ak else ak
                if aname == vk and vk not in [k.split('/')[-1] for k in TOPO_ATTRS]:
                    domain = ak.split('/')[0] if '/' in ak else ''
                    topo[f'{domain}/{vk}' if domain else vk] = list(av.values())[0]

        if driver not in drivers:
            drivers[driver] = []
        drivers[driver].append({'name': name, 'topo': topo})

for driver in sorted(drivers):
    devs = drivers[driver]
    print(f'\033[1m{driver}\033[0m ({len(devs)} devices):')

    # Header
    all_keys = set()
    for d in devs:
        all_keys.update(d['topo'].keys())
    keys = sorted(all_keys)

    hdr = f'  {\"Device\":<20}'
    for k in keys:
        hdr += f'{k:<16}'
    print(f'\033[2m{hdr}\033[0m')

    for d in sorted(devs, key=lambda x: x['name']):
        line = f'  {d[\"name\"]:<20}'
        for k in keys:
            v = d['topo'].get(k, '-')
            line += f'{str(v):<16}'

        # Check for missing standard attrs
        missing = []
        if 'numaNode' not in d['topo']:
            missing.append('numaNode')
        if 'pciBusID' not in d['topo'] and 'cpuSocketID' not in d['topo']:
            # PCI devices need pciBusID, non-PCI need cpuSocketID
            pass

        if missing:
            line += f'  \033[33m(missing: {\", \".join(missing)})\033[0m'
        print(line)
    print()
" 2>/dev/null
}

# ── claims ───────────────────────────────────────────────────────────────────

cmd_claims() {
    section "Allocated Resource Claims"

    local nf
    nf=$(ns_flag)

    { kubectl get resourceclaims $nf -o json 2>/dev/null; echo "---SEP---"; kubectl get resourceslices -o json 2>/dev/null; echo "---SEP---"; kubectl get vmi $nf -o json 2>/dev/null; } | python3 -c "
import json, sys

raw = sys.stdin.read()
parts = raw.split('---SEP---')
claims_data = json.loads(parts[0])
slices_data = json.loads(parts[1])
try:
    vmi_data = json.loads(parts[2])
except:
    vmi_data = {'items': []}

# Build device attr lookup
device_attrs = {}
for rs in slices_data.get('items', []):
    driver = rs['spec']['driver']
    for dev in rs['spec'].get('devices', []) or []:
        attrs = dev.get('attributes', {})
        topo = {}
        for key, val in attrs.items():
            short = key.split('/')[-1] if '/' in key else key
            if short in ('numaNode', 'numa', 'numaNodeID', 'pciBusID', 'pcieRoot', 'cpuSocketID', 'productName'):
                topo[short] = list(val.values())[0]
        device_attrs[f'{driver}/{dev[\"name\"]}'] = topo

# Build VMI name lookup from pod names
vmi_by_pod_prefix = {}
for vmi in vmi_data.get('items', []):
    name = vmi['metadata']['name']
    ns = vmi['metadata']['namespace']
    vmi_by_pod_prefix[f'virt-launcher-{name}-'] = f'{ns}/{name}'

claims = claims_data.get('items', [])
if not claims:
    print('No resource claims found')
    sys.exit(0)

for c in sorted(claims, key=lambda x: x['metadata']['name']):
    cname = c['metadata']['name']
    ns = c['metadata']['namespace']
    state = c.get('status', {}).get('allocation', {})
    reserved = c.get('status', {}).get('reservedFor', [])

    if not state:
        print(f'\033[2m{ns}/{cname}: pending\033[0m')
        continue

    # Find pod/VM
    pod_name = reserved[0]['name'] if reserved else '(unreserved)'
    vm_name = ''
    for prefix, vmi_ref in vmi_by_pod_prefix.items():
        if pod_name.startswith(prefix):
            vm_name = vmi_ref
            break

    header = f'\033[1m{ns}/{cname}\033[0m'
    if vm_name:
        header += f'  →  VM \033[1;35m{vm_name}\033[0m'
    else:
        header += f'  →  pod \033[1;36m{pod_name}\033[0m'
    print(header)

    results = state.get('devices', {}).get('results', [])
    if not results:
        print('  (no devices)')
        print()
        continue

    print(f'  {\"Request\":<12}{\"Driver\":<25}{\"Device\":<20}{\"NUMA\":<6}{\"pcieRoot\":<16}{\"PCI Bus ID\":<18}{\"Product\":<30}')
    print(f'  {\"─\"*12}{\"─\"*25}{\"─\"*20}{\"─\"*6}{\"─\"*16}{\"─\"*18}{\"─\"*30}')

    numas = set()
    roots = set()
    for r in results:
        driver = r['driver']
        device = r['device']
        request = r['request']
        dev_key = f'{driver}/{device}'
        topo = device_attrs.get(dev_key, {})

        numa = topo.get('numaNode', topo.get('numa', topo.get('numaNodeID', '-')))
        root = topo.get('pcieRoot', '-')
        pci = topo.get('pciBusID', '-')
        product = str(topo.get('productName', '-'))[:28]

        driver_short = driver if len(driver) <= 23 else driver[:21] + '..'
        print(f'  {request:<12}{driver_short:<25}{device:<20}{str(numa):<6}{str(root):<16}{str(pci):<18}{product:<30}')

        if root != '-':
            roots.add(str(root))

        if numa != '-':
            numas.add(str(numa))

    print()
    if len(numas) == 1:
        print(f'  \033[32m✓ All devices on NUMA {numas.pop()}\033[0m')
    elif len(numas) > 1:
        numa_list = ', '.join(sorted(numas))
        print(f'  \033[33m! Multi-NUMA: devices on NUMA {numa_list}\033[0m')

    if len(roots) == 1:
        print(f'  \033[32m✓ All PCI devices on pcieRoot {roots.pop()}\033[0m')
    elif len(roots) > 1:
        root_list = ', '.join(sorted(roots))
        print(f'  \033[33m! Multiple pcieRoots: {root_list}\033[0m')
    print()
" 2>/dev/null
}

# ── alignment ─────────────────────────────────────────────────────────────────

cmd_alignment() {
    section "Device NUMA Alignment"

    local target_pod="$TARGET"
    local nf
    nf=$(ns_flag)

    # Get claims and slices together
    { kubectl get resourceclaims $nf -o json 2>/dev/null; echo "---SEP---"; kubectl get resourceslices -o json 2>/dev/null; } | python3 -c "
import json, sys

raw = sys.stdin.read()
parts = raw.split('---SEP---')
claims_data = json.loads(parts[0])
slices_data = json.loads(parts[1])

target_pod = '$target_pod'

# Build device attr lookup from ResourceSlices
device_attrs = {}  # 'driver/device' -> {numaNode, pcieRoot, cpuSocketID}
for rs in slices_data.get('items', []):
    driver = rs['spec']['driver']
    for dev in rs['spec'].get('devices', []) or []:
        name = dev['name']
        attrs = dev.get('attributes', {})
        topo = {}
        for key, val in attrs.items():
            short = key.split('/')[-1] if '/' in key else key
            domain = key.split('/')[0] if '/' in key else ''
            if short in ('numaNode', 'numa', 'numaNodeID', 'pcieRoot', 'pciBusID', 'cpuSocketID'):
                topo[short] = list(val.values())[0]
        device_attrs[f'{driver}/{name}'] = topo

# Process claims
pods = {}
for c in claims_data.get('items', []):
    reserved = c.get('status', {}).get('reservedFor', [])
    if not reserved:
        continue
    pod = reserved[0]['name']
    ns = c['metadata']['namespace']
    if target_pod and target_pod != pod:
        continue

    key = f'{ns}/{pod}'
    if key not in pods:
        pods[key] = []

    for r in c.get('status', {}).get('allocation', {}).get('devices', {}).get('results', []):
        driver = r['driver']
        device = r['device']
        request = r['request']
        dev_key = f'{driver}/{device}'
        topo = device_attrs.get(dev_key, {})
        pods[key].append({
            'driver': driver,
            'device': device,
            'request': request,
            'numa': topo.get('numaNode', topo.get('numa', topo.get('numaNodeID', '?'))),
            'pcieRoot': topo.get('pcieRoot', '-'),
            'socketID': topo.get('cpuSocketID', '-'),
            'pciBusID': topo.get('pciBusID', '-'),
        })

if not pods:
    if target_pod:
        print(f'No claims found for pod {target_pod}')
    else:
        print('No allocated claims found')
    sys.exit(0)

for pod_key in sorted(pods):
    devices = pods[pod_key]
    print(f'\033[1m{pod_key}\033[0m')
    print(f'  {\"Request\":<25}{\"Driver\":<30}{\"Device\":<20}{\"NUMA\":<8}{\"Socket\":<10}{\"pcieRoot\":<18}{\"pciBusID\":<16}')
    print(f'  {\"─\"*25}{\"─\"*30}{\"─\"*20}{\"─\"*8}{\"─\"*10}{\"─\"*18}{\"─\"*16}')

    for d in devices:
        driver_short = d['driver']
        if len(driver_short) > 28:
            driver_short = driver_short[:28] + '..'
        print(f'  {d[\"request\"]:<25}{driver_short:<30}{d[\"device\"]:<20}{str(d[\"numa\"]):<8}{str(d[\"socketID\"]):<10}{str(d[\"pcieRoot\"]):<18}{str(d[\"pciBusID\"]):<16}')

    # Alignment summary
    numas = set(str(d['numa']) for d in devices if d['numa'] != '?')
    sockets = set(str(d['socketID']) for d in devices if d['socketID'] != '-')
    roots = set(str(d['pcieRoot']) for d in devices if d['pcieRoot'] != '-')

    print()
    if len(numas) == 1:
        print(f'  \033[32m✓ numaNode aligned: all on NUMA {numas.pop()}\033[0m')
    elif len(numas) > 1:
        numa_list = ', '.join(sorted(numas))
        print(f'  \033[33m! numaNode SPLIT: devices on NUMA {numa_list}\033[0m')
    else:
        print(f'  \033[2m? numaNode unknown\033[0m')

    if len(sockets) == 1:
        print(f'  \033[32m✓ cpuSocketID aligned: all on socket {sockets.pop()}\033[0m')
    elif len(sockets) > 1:
        socket_list = ', '.join(sorted(sockets))
        print(f'  \033[31m✗ cpuSocketID SPLIT: devices on sockets {socket_list}\033[0m')

    if len(roots) == 1:
        print(f'  \033[32m✓ pcieRoot aligned: all on {roots.pop()}\033[0m')
    elif len(roots) > 1:
        root_list = ', '.join(sorted(roots))
        print(f'  \033[33m! pcieRoot differs: {root_list} (expected on most hardware)\033[0m')

    print()
" 2>/dev/null
}

# ── cpupinning ────────────────────────────────────────────────────────────────

cmd_cpupinning() {
    section "CPU Pinning vs Device NUMA"

    local target_pod="$TARGET"
    local nf
    nf=$(ns_flag)

    if [[ -z "$target_pod" ]]; then
        echo -e "${DIM}Usage: dra-verify.sh cpupinning <pod-name> [-n namespace]${NC}"
        echo -e "${DIM}Checking all pods with DRA claims...${NC}"
        echo ""
    fi

    # Get pod cpusets and claim allocations
    kubectl get pods $nf -o json 2>/dev/null | python3 -c "
import json, sys, os, subprocess

data = json.load(sys.stdin)
target = '$target_pod'

for pod in data.get('items', []):
    name = pod['metadata']['name']
    ns = pod['metadata']['namespace']
    if target and name != target:
        continue

    # Check if pod has resource claims
    claims = pod['spec'].get('resourceClaims', [])
    if not claims:
        continue

    node = pod['spec'].get('nodeName', '?')
    uid = pod['metadata']['uid']

    print(f'\033[1m{ns}/{name}\033[0m (node: {node})')

    # Get container cpusets
    for cs in pod.get('status', {}).get('containerStatuses', []):
        cid = cs.get('containerID', '')
        cname = cs['name']

        # Try to read cpuset from cgroup (only works on the node)
        cpuset_paths = [
            f'/sys/fs/cgroup/kubepods.slice/kubepods-pod{uid.replace(\"-\", \"_\")}.slice/*/cpuset.cpus.effective',
            f'/sys/fs/cgroup/kubepods.slice/kubepods-burstable.slice/kubepods-burstable-pod{uid.replace(\"-\", \"_\")}.slice/*/cpuset.cpus.effective',
            f'/sys/fs/cgroup/kubepods.slice/kubepods-guaranteed.slice/kubepods-guaranteed-pod{uid.replace(\"-\", \"_\")}.slice/*/cpuset.cpus.effective',
        ]

        cpuset = None
        import glob
        for pattern in cpuset_paths:
            matches = glob.glob(pattern)
            for m in matches:
                if cname in m or 'compute' in m:
                    try:
                        cpuset = open(m).read().strip()
                    except:
                        pass

        if cpuset:
            print(f'  container {cname}: cpuset = {cpuset}')

            # Map CPUs to NUMA nodes
            cpu_numas = set()
            for part in cpuset.split(','):
                if '-' in part:
                    lo, hi = part.split('-')
                    cpus = range(int(lo), int(hi) + 1)
                else:
                    cpus = [int(part)]
                for cpu in cpus:
                    numa_path = f'/sys/devices/system/cpu/cpu{cpu}/topology/physical_package_id'
                    try:
                        # Check which NUMA node this CPU belongs to
                        for node_dir in glob.glob('/sys/devices/system/node/node*/cpulist'):
                            node_id = node_dir.split('node')[-1].split('/')[0]
                            cpulist = open(node_dir).read().strip()
                            for p in cpulist.split(','):
                                if '-' in p:
                                    l, h = p.split('-')
                                    if int(l) <= cpu <= int(h):
                                        cpu_numas.add(int(node_id))
                                elif int(p) == cpu:
                                    cpu_numas.add(int(node_id))
                    except:
                        pass

            if cpu_numas:
                numa_str = ', '.join(str(n) for n in sorted(cpu_numas))
                if len(cpu_numas) == 1:
                    print(f'  \033[32m✓ CPUs pinned to NUMA {numa_str}\033[0m')
                else:
                    print(f'  \033[33m! CPUs span NUMA nodes: {numa_str}\033[0m')
        else:
            print(f'  container {cname}: cpuset = \033[2m(run on node to read cgroup)\033[0m')
    print()
" 2>/dev/null
}

# ── vfio ──────────────────────────────────────────────────────────────────────

cmd_vfio() {
    section "VFIO Devices"

    echo -e "${BOLD}Devices bound to vfio-pci:${NC}"
    local found=0
    for dev in /sys/bus/pci/devices/*/driver; do
        local driver_name
        driver_name=$(basename "$(readlink "$dev" 2>/dev/null)")
        if [[ "$driver_name" == "vfio-pci" ]]; then
            local bdf
            bdf=$(basename "$(dirname "$dev")")
            local iommu_grp
            iommu_grp=$(basename "$(readlink "/sys/bus/pci/devices/$bdf/iommu_group" 2>/dev/null)" 2>/dev/null)
            local numa
            numa=$(cat "/sys/bus/pci/devices/$bdf/numa_node" 2>/dev/null)
            local class
            class=$(cat "/sys/bus/pci/devices/$bdf/class" 2>/dev/null)
            local desc=""
            if command -v lspci &>/dev/null; then
                desc=$(lspci -s "$bdf" 2>/dev/null | sed 's/^[^ ]* //')
            fi
            echo -e "  ${BOLD}$bdf${NC}  NUMA=$numa  IOMMU=$iommu_grp  ${DIM}$desc${NC}"
            found=1
        fi
    done
    if [[ "$found" == "0" ]]; then
        echo -e "  ${DIM}(no devices bound to vfio-pci — run on the node)${NC}"
    fi
    echo ""

    echo -e "${BOLD}CDI Specs (/var/run/cdi):${NC}"
    if [[ -d /var/run/cdi ]]; then
        local cdi_files
        cdi_files=$(ls /var/run/cdi/*.json 2>/dev/null)
        if [[ -n "$cdi_files" ]]; then
            for f in $cdi_files; do
                local fname
                fname=$(basename "$f")
                local devices
                devices=$(python3 -c "
import json
d = json.load(open('$f'))
devs = d.get('devices', [])
for dev in devs:
    nodes = dev.get('containerEdits', {}).get('deviceNodes', [])
    paths = [n['path'] for n in nodes if 'vfio' in n.get('path', '')]
    if paths:
        print(f'  {dev[\"name\"]}: {\", \".join(paths)}')
" 2>/dev/null)
                if [[ -n "$devices" ]]; then
                    echo -e "  ${DIM}$fname:${NC}"
                    echo "$devices"
                fi
            done
        else
            echo -e "  ${DIM}(no CDI spec files)${NC}"
        fi
    else
        echo -e "  ${DIM}(/var/run/cdi not found — run on the node)${NC}"
    fi
}

# ── metadata ──────────────────────────────────────────────────────────────────

cmd_metadata() {
    section "KEP-5304 Device Metadata"

    local target_pod="$TARGET"
    local nf
    nf=$(ns_flag)

    if [[ -z "$target_pod" ]]; then
        echo -e "${DIM}Usage: dra-verify.sh metadata <pod-name> [-n namespace]${NC}"
        echo ""
        echo -e "${DIM}Looking for pods with DRA claims...${NC}"
        kubectl get pods $nf -o json 2>/dev/null | python3 -c "
import json, sys
data = json.load(sys.stdin)
for pod in data.get('items', []):
    claims = pod['spec'].get('resourceClaims', [])
    if claims:
        ns = pod['metadata']['namespace']
        name = pod['metadata']['name']
        print(f'  {ns}/{name} ({len(claims)} claims)')
" 2>/dev/null
        return
    fi

    local ns_arg=""
    [[ -n "$NAMESPACE" ]] && ns_arg="-n $NAMESPACE"

    echo -e "${BOLD}Checking metadata in pod $target_pod:${NC}"
    echo ""

    # Try to list metadata files inside the pod
    kubectl exec $ns_arg "$target_pod" -- find /var/run/kubernetes.io/dra-device-attributes/ -name "*.json" 2>/dev/null | while read -r f; do
        echo -e "  ${BOLD}$f${NC}"
        kubectl exec $ns_arg "$target_pod" -- cat "$f" 2>/dev/null | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    for req in data.get('requests', []):
        rname = req.get('name', '?')
        for dev in req.get('devices', []):
            driver = dev.get('driver', '?')
            attrs = dev.get('attributes', {})
            pci = attrs.get('resource.kubernetes.io/pciBusID', {}).get('string', '-')
            numa = attrs.get('numaNode', {}).get('int', '-')
            model = attrs.get('productName', attrs.get('model', {})).get('string', '-')
            print(f'    request={rname} driver={driver} pciBusID={pci} numaNode={numa} model={model}')
except:
    print('    (failed to parse)')
" 2>/dev/null
        echo ""
    done

    # Also check the older path
    kubectl exec $ns_arg "$target_pod" -- find /var/run/dra-device-attributes/ -name "*.json" 2>/dev/null | while read -r f; do
        echo -e "  ${DIM}(legacy path) $f${NC}"
    done
}

# ── guest ─────────────────────────────────────────────────────────────────────

cmd_guest() {
    section "Guest NUMA Topology"

    local target_vm="$TARGET"

    if [[ -z "$target_vm" ]]; then
        echo -e "${DIM}Usage: dra-verify.sh guest <vm-name> [-n namespace]${NC}"
        echo ""
        echo -e "${DIM}Running VMs:${NC}"
        kubectl get vmi $(ns_flag) 2>/dev/null | grep -v "^NAME" || echo -e "  ${DIM}(no VMs found)${NC}"
        return
    fi

    local ns_arg=""
    [[ -n "$NAMESPACE" ]] && ns_arg="-n $NAMESPACE"

    echo -e "${BOLD}Checking guest topology for VM $target_vm:${NC}"
    echo ""

    echo -e "${BOLD}NUMA nodes:${NC}"
    virtctl ssh $ns_arg "$target_vm" -- "ls -d /sys/devices/system/node/node* 2>/dev/null | while read n; do echo \"  \$(basename \$n): \$(cat \$n/cpulist 2>/dev/null) CPUs, \$(awk '/MemTotal/{printf \"%.0f MB\", \$4/1024}' \$n/meminfo 2>/dev/null)\"; done" 2>/dev/null || echo -e "  ${DIM}(SSH failed — is virtctl available?)${NC}"
    echo ""

    echo -e "${BOLD}PCI devices with NUMA affinity:${NC}"
    virtctl ssh $ns_arg "$target_vm" -- "for d in /sys/bus/pci/devices/*/numa_node; do dev=\$(basename \$(dirname \$d)); node=\$(cat \$d); class=\$(cat /sys/bus/pci/devices/\$dev/class 2>/dev/null); [ \"\$node\" != \"-1\" ] && echo \"  \$dev: numa=\$node class=\$class\"; done" 2>/dev/null || echo -e "  ${DIM}(SSH failed)${NC}"
}

# ── all ───────────────────────────────────────────────────────────────────────

cmd_all() {
    cmd_drivers
    cmd_attributes
    cmd_claims
    cmd_alignment
    cmd_vfio

    if [[ -n "$TARGET" ]]; then
        cmd_cpupinning
        cmd_metadata
    fi
}

# ── help ──────────────────────────────────────────────────────────────────────

cmd_help() {
    echo "Usage: $(basename "$0") <command> [options]"
    echo ""
    echo "Commands:"
    echo "  drivers                    Show DRA driver DaemonSets, pods, registration"
    echo "  attributes                 Show ResourceSlice topology attributes per driver"
    echo "  claims [-n ns]             Show allocated claims with pods/VMs and devices"
    echo "  alignment [pod] [-n ns]    Show device NUMA/pcieRoot/socket alignment"
    echo "  cpupinning [pod] [-n ns]   Show container cpuset vs device NUMA nodes"
    echo "  vfio                       Show VFIO-bound devices, IOMMU groups, CDI specs"
    echo "  metadata [pod] [-n ns]     Show KEP-5304 metadata files in pod"
    echo "  guest [vm] [-n ns]         Show guest NUMA topology in KubeVirt VM"
    echo "  all [-n ns]                Run all checks"
    echo ""
    echo "Options:"
    echo "  -n, --namespace NS         Kubernetes namespace"
    echo ""
    echo "Examples:"
    echo "  $(basename "$0") drivers"
    echo "  $(basename "$0") alignment my-gpu-pod -n test"
    echo "  $(basename "$0") cpupinning virt-launcher-vm0-xxxxx -n default"
    echo "  $(basename "$0") metadata my-gpu-pod -n test"
    echo "  $(basename "$0") guest vm0 -n default"
    echo "  $(basename "$0") all -n test"
}

# ── Dispatch ──────────────────────────────────────────────────────────────────

case "$CMD" in
    drivers)    cmd_drivers ;;
    attributes) cmd_attributes ;;
    claims)     cmd_claims ;;
    alignment)  cmd_alignment ;;
    cpupinning) cmd_cpupinning ;;
    vfio)       cmd_vfio ;;
    metadata)   cmd_metadata ;;
    guest)      cmd_guest ;;
    all)        cmd_all ;;
    help|-h|--help) cmd_help ;;
    *) echo "Unknown command: $CMD"; cmd_help; exit 1 ;;
esac
