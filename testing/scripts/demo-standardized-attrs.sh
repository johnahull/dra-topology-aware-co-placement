#!/bin/bash
# Demo: Standardized topology attributes enable cross-driver NUMA alignment
# with native matchAttribute constraints — no middleware needed.
#
# Tests 1-5: matchAttribute with required constraints (K8s 1.36+)
# Tests 6-8: enforcement:preferred for distance hierarchy (custom scheduler)
#
# Prerequisites: K8s 1.36+ with GPU, NIC, CPU, and memory DRA drivers deployed,
# all publishing resource.kubernetes.io/numaNode and cpuSocketID.
# DeviceClasses must have driver selectors (device.driver == 'driverName').
# Tests 6-8 require custom kube-apiserver/kube-scheduler/kubectl with
# enforcement:preferred support (johnahull/kubernetes feature/enforcement-preferred).
#
# Usage:
#   ./demo-standardized-attrs.sh              # run all tests
#   ./demo-standardized-attrs.sh --test 3     # run test 3 only
#   ./demo-standardized-attrs.sh --list       # list available tests
#   ./demo-standardized-attrs.sh --show-slices # show ResourceSlices only
#   ./demo-standardized-attrs.sh --no-cleanup  # keep pods after tests

set -e

BOLD="\033[1m"
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
RESET="\033[0m"

# Defaults
RUN_TEST=""
DO_CLEANUP=true
SHOW_SLICES_ONLY=false

# Use kubectl-custom if available (has enforcement:preferred support)
if command -v kubectl-custom &>/dev/null; then
    KUBECTL="kubectl-custom"
else
    KUBECTL="kubectl"
fi

# Parse flags
while [[ $# -gt 0 ]]; do
    case "$1" in
        --test)
            RUN_TEST="$2"
            shift 2
            ;;
        --all)
            RUN_TEST=""
            shift
            ;;
        --list)
            echo "Available tests:"
            echo "  1  numaNode — GPU + CPU (2 drivers)"
            echo "  2  numaNode — GPU + CPU + Memory (3 drivers)"
            echo "  3  numaNode — GPU + NIC + CPU + Memory (4 drivers)"
            echo "  4  cpuSocketID — GPU + CPU"
            echo "  5  pcieRoot — GPU + NIC (expected FAIL, different PCIe roots)"
            echo "  6  enforcement:preferred — pcieRoot preferred + numaNode required (GPU+NIC)"
            echo "  7  enforcement:preferred — pcieRoot preferred + cpuSocketID required (4 drivers)"
            echo "  8  enforcement:preferred — full distance hierarchy"
            echo "  9  pcieRoot — GPU + NVMe (same PCIe switch, requires NVMe driver)"
            echo "  10 numaNode — GPU + NVMe + CPU + Memory (4 drivers)"
            echo "  11 numaNode — GPU + NIC + NVMe + CPU + Memory (5 drivers, full stack)"
            exit 0
            ;;
        --show-slices)
            SHOW_SLICES_ONLY=true
            shift
            ;;
        --no-cleanup)
            DO_CLEANUP=false
            shift
            ;;
        --help|-h)
            echo "Usage: $0 [--test N] [--all] [--list] [--show-slices] [--no-cleanup]"
            exit 0
            ;;
        *)
            echo "Unknown flag: $1"
            exit 1
            ;;
    esac
done

# Track results for summary table
declare -a TEST_NAMES
declare -a TEST_RESULTS
declare -a TEST_DETAILS

should_run() {
    local test_num=$1
    [[ -z "$RUN_TEST" ]] || [[ "$RUN_TEST" == "$test_num" ]]
}

cleanup() {
    echo -e "\n${BOLD}Cleaning up...${RESET}"
    $KUBECTL delete pod --all --force --grace-period=0 2>/dev/null || true
    $KUBECTL delete resourceclaimtemplate --all 2>/dev/null || true
    $KUBECTL delete resourceclaim --all 2>/dev/null || true
}

show_resourceslices() {
    echo -e "\n${BOLD}=== ResourceSlices with standardized attributes ===${RESET}"
    echo ""
    $KUBECTL get resourceslices -o json | python3 -c "
import json,sys
d=json.load(sys.stdin)
for item in d['items']:
    name = item['metadata']['name']
    devs = item.get('spec',{}).get('devices',[])
    # Find driver name from first device
    driver = 'unknown'
    for dev in devs:
        for k in dev.get('attributes',{}):
            if 'resource.kubernetes.io' not in k and '/' in k:
                driver = k.split('/')[0]
                break
        break
    # Also check name for driver hint
    for hint in ['gpu.nvidia','dra.cpu','dra.memory','sriovnetwork']:
        if hint in name:
            driver = hint
            break
    print(f'  {driver}: {len(devs)} devices')
    for dev in devs[:2]:
        attrs = dev.get('attributes',{})
        numa = attrs.get('resource.kubernetes.io/numaNode',{}).get('int','?')
        socket = attrs.get('resource.kubernetes.io/cpuSocketID',{}).get('int','?')
        pcieroot = attrs.get('resource.kubernetes.io/pcieRoot',{}).get('string','')
        extra = f' pcieRoot={pcieroot}' if pcieroot else ''
        print(f'    {dev[\"name\"]}: numaNode={numa} cpuSocketID={socket}{extra}')
    if len(devs) > 2:
        print(f'    ... and {len(devs)-2} more')
    print()
"
}

run_test() {
    local pod_name=$1
    local claim_name="${pod_name}-claim"
    local desc=$2
    local expected=$3
    local yaml=$4

    echo -e "\n${BOLD}=== $desc ===${RESET}"
    echo "$yaml" | $KUBECTL apply -f - 2>&1 | grep -v "^$"

    echo -n "Waiting for scheduling... "
    local allocated=""
    for i in $(seq 1 30); do
        local claim=$($KUBECTL get resourceclaim --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null | grep "$pod_name" | head -1)
        if [ -n "$claim" ]; then
            allocated=$($KUBECTL get resourceclaim "$claim" -o jsonpath='{.status.allocation.devices.results}' 2>/dev/null)
            if [ -n "$allocated" ] && [ "$allocated" != "null" ]; then
                break
            fi
        fi
        sleep 1
    done

    local result_detail=""
    if [ -z "$allocated" ] || [ "$allocated" = "null" ]; then
        if [ "$expected" = "fail" ]; then
            echo -e "${GREEN}EXPECTED FAILURE${RESET}"
            local reason=$($KUBECTL describe pod "$pod_name" 2>/dev/null | grep -o "cannot allocate all claims\|FailedScheduling.*" | tail -1)
            result_detail="Expected: unsatisfiable"
            echo "  $reason"
            TEST_RESULTS+=("EXPECTED FAIL")
        else
            echo -e "${RED}FAILED${RESET}"
            result_detail="Claim not allocated"
            TEST_RESULTS+=("FAILED")
        fi
    else
        if [ "$expected" = "fail" ]; then
            echo -e "${RED}UNEXPECTED SUCCESS${RESET}"
            result_detail="Expected failure but succeeded"
            TEST_RESULTS+=("UNEXPECTED")
        else
            echo -e "${GREEN}PASSED${RESET}"
            # Extract device summary
            result_detail=$(echo "$allocated" | python3 -c "
import json,sys
results = json.load(sys.stdin)
parts = []
for r in results:
    parts.append(f\"{r['device']} ({r['driver'].split('.')[0]})\")
print(', '.join(parts))
" 2>/dev/null || echo "allocated")
            TEST_RESULTS+=("PASSED")
        fi
        echo ""
        echo "Allocation:"
        echo "$allocated" | python3 -m json.tool 2>/dev/null || echo "$allocated"
    fi

    TEST_NAMES+=("$desc")
    TEST_DETAILS+=("$result_detail")

    # Clean up for next test
    $KUBECTL delete pod "$pod_name" --force --grace-period=0 2>/dev/null || true
    $KUBECTL delete resourceclaimtemplate "$claim_name" 2>/dev/null || true
    sleep 2
}

# --- Main ---

cleanup 2>/dev/null

echo -e "${BOLD}Standardized Topology Attributes Demo${RESET}"
echo "Proving: resource.kubernetes.io/numaNode and cpuSocketID"
echo "         enable cross-driver matchAttribute — no middleware needed"
echo ""

show_resourceslices

if $SHOW_SLICES_ONLY; then
    exit 0
fi

# Test 1: numaNode with GPU + CPU (2 drivers)
if should_run 1; then
run_test "test-numanode-2d" \
    "Test 1: numaNode — GPU + CPU (2 drivers)" \
    "pass" \
    "$(cat <<EOF
apiVersion: resource.k8s.io/v1
kind: ResourceClaimTemplate
metadata:
  name: test-numanode-2d-claim
spec:
  spec:
    devices:
      requests:
      - name: gpu
        exactly:
          deviceClassName: gpu.nvidia.com
          count: 1
      - name: cpu
        exactly:
          deviceClassName: dra.cpu
          count: 1
      constraints:
      - matchAttribute: resource.kubernetes.io/numaNode
        requests: [gpu, cpu]
---
apiVersion: v1
kind: Pod
metadata:
  name: test-numanode-2d
spec:
  containers:
  - name: test
    image: registry.access.redhat.com/ubi9/ubi-minimal:latest
    command: ["sleep", "60"]
    resources:
      claims:
      - name: devices
  resourceClaims:
  - name: devices
    resourceClaimTemplateName: test-numanode-2d-claim
EOF
)"
fi

# Test 2: numaNode with GPU + CPU + Memory (3 drivers)
if should_run 2; then
run_test "test-numanode-3d" \
    "Test 2: numaNode — GPU + CPU + Memory (3 drivers)" \
    "pass" \
    "$(cat <<EOF
apiVersion: resource.k8s.io/v1
kind: ResourceClaimTemplate
metadata:
  name: test-numanode-3d-claim
spec:
  spec:
    devices:
      requests:
      - name: gpu
        exactly:
          deviceClassName: gpu.nvidia.com
          count: 1
      - name: cpu
        exactly:
          deviceClassName: dra.cpu
          count: 1
      - name: mem
        exactly:
          deviceClassName: dra.memory
          count: 1
      constraints:
      - matchAttribute: resource.kubernetes.io/numaNode
        requests: [gpu, cpu, mem]
---
apiVersion: v1
kind: Pod
metadata:
  name: test-numanode-3d
spec:
  containers:
  - name: test
    image: registry.access.redhat.com/ubi9/ubi-minimal:latest
    command: ["sleep", "60"]
    resources:
      claims:
      - name: devices
  resourceClaims:
  - name: devices
    resourceClaimTemplateName: test-numanode-3d-claim
EOF
)"
fi

# Test 3: numaNode with GPU + NIC + CPU + Memory (4 drivers)
if should_run 3; then
run_test "test-numanode-4d" \
    "Test 3: numaNode — GPU + NIC + CPU + Memory (4 drivers)" \
    "pass" \
    "$(cat <<EOF
apiVersion: resource.k8s.io/v1
kind: ResourceClaimTemplate
metadata:
  name: test-numanode-4d-claim
spec:
  spec:
    devices:
      requests:
      - name: gpu
        exactly:
          deviceClassName: gpu.nvidia.com
          count: 1
      - name: nic
        exactly:
          deviceClassName: dra.net-sriov-vf
          count: 1
      - name: cpu
        exactly:
          deviceClassName: dra.cpu
          count: 1
      - name: mem
        exactly:
          deviceClassName: dra.memory
          count: 1
      constraints:
      - matchAttribute: resource.kubernetes.io/numaNode
        requests: [gpu, nic, cpu, mem]
---
apiVersion: v1
kind: Pod
metadata:
  name: test-numanode-4d
spec:
  containers:
  - name: test
    image: registry.access.redhat.com/ubi9/ubi-minimal:latest
    command: ["sleep", "60"]
    resources:
      claims:
      - name: devices
  resourceClaims:
  - name: devices
    resourceClaimTemplateName: test-numanode-4d-claim
EOF
)"
fi

# Test 4: cpuSocketID with GPU + CPU
if should_run 4; then
run_test "test-socketid" \
    "Test 4: cpuSocketID — GPU + CPU" \
    "pass" \
    "$(cat <<EOF
apiVersion: resource.k8s.io/v1
kind: ResourceClaimTemplate
metadata:
  name: test-socketid-claim
spec:
  spec:
    devices:
      requests:
      - name: gpu
        exactly:
          deviceClassName: gpu.nvidia.com
          count: 1
      - name: cpu
        exactly:
          deviceClassName: dra.cpu
          count: 1
      constraints:
      - matchAttribute: resource.kubernetes.io/cpuSocketID
        requests: [gpu, cpu]
---
apiVersion: v1
kind: Pod
metadata:
  name: test-socketid
spec:
  containers:
  - name: test
    image: registry.access.redhat.com/ubi9/ubi-minimal:latest
    command: ["sleep", "60"]
    resources:
      claims:
      - name: devices
  resourceClaims:
  - name: devices
    resourceClaimTemplateName: test-socketid-claim
EOF
)"
fi

# Test 5: pcieRoot for GPU+NIC FAILS (both publish pcieRoot but on different roots)
# GPU-0 is on pci0000:49, CX7 NIC VFs are on pci0000:36 — same NUMA node but different PCIe roots.
if should_run 5; then
run_test "test-pcieroot" \
    "Test 5: pcieRoot — GPU + NIC (expected FAIL)" \
    "fail" \
    "$(cat <<EOF
apiVersion: resource.k8s.io/v1
kind: ResourceClaimTemplate
metadata:
  name: test-pcieroot-claim
spec:
  spec:
    devices:
      requests:
      - name: gpu
        exactly:
          deviceClassName: gpu.nvidia.com
          count: 1
      - name: nic
        exactly:
          deviceClassName: dra.net-sriov-vf
          count: 1
      constraints:
      - matchAttribute: resource.kubernetes.io/pcieRoot
        requests: [gpu, nic]
---
apiVersion: v1
kind: Pod
metadata:
  name: test-pcieroot
spec:
  containers:
  - name: test
    image: registry.access.redhat.com/ubi9/ubi-minimal:latest
    command: ["sleep", "60"]
    resources:
      claims:
      - name: devices
  resourceClaims:
  - name: devices
    resourceClaimTemplateName: test-pcieroot-claim
EOF
)"
fi

# Test 6: enforcement:preferred — pcieRoot preferred, numaNode required (GPU + NIC)
# Compare with Test 5: same GPU+NIC pcieRoot constraint but Required fails, Preferred succeeds.
# Proves the scheduler relaxed pcieRoot (different roots) while enforcing numaNode (same NUMA).
if should_run 6; then
run_test "test-preferred-pcie" \
    "Test 6: pcieRoot preferred + numaNode (GPU+NIC)" \
    "pass" \
    "$(cat <<EOF
apiVersion: resource.k8s.io/v1
kind: ResourceClaimTemplate
metadata:
  name: test-preferred-pcie-claim
spec:
  spec:
    devices:
      requests:
      - name: gpu
        exactly:
          deviceClassName: gpu.nvidia.com
          count: 1
      - name: nic
        exactly:
          deviceClassName: dra.net-sriov-vf
          count: 1
      constraints:
      - matchAttribute: resource.kubernetes.io/pcieRoot
        requests: [gpu, nic]
        enforcement: Preferred
      - matchAttribute: resource.kubernetes.io/numaNode
        requests: [gpu, nic]
---
apiVersion: v1
kind: Pod
metadata:
  name: test-preferred-pcie
spec:
  containers:
  - name: test
    image: registry.access.redhat.com/ubi9/ubi-minimal:latest
    command: ["sleep", "60"]
    resources:
      claims:
      - name: devices
  resourceClaims:
  - name: devices
    resourceClaimTemplateName: test-preferred-pcie-claim
EOF
)"
fi

# Test 7: enforcement:preferred — pcieRoot preferred, cpuSocketID required (4 drivers)
if should_run 7; then
run_test "test-preferred-4d" \
    "Test 7: pcieRoot preferred + socketID (4 drivers)" \
    "pass" \
    "$(cat <<EOF
apiVersion: resource.k8s.io/v1
kind: ResourceClaimTemplate
metadata:
  name: test-preferred-4d-claim
spec:
  spec:
    devices:
      requests:
      - name: gpu
        exactly:
          deviceClassName: gpu.nvidia.com
          count: 1
      - name: nic
        exactly:
          deviceClassName: dra.net-sriov-vf
          count: 1
      - name: cpu
        exactly:
          deviceClassName: dra.cpu
          count: 1
      - name: mem
        exactly:
          deviceClassName: dra.memory
          count: 1
      constraints:
      - matchAttribute: resource.kubernetes.io/pcieRoot
        requests: [gpu, nic, cpu, mem]
        enforcement: Preferred
      - matchAttribute: resource.kubernetes.io/cpuSocketID
        requests: [gpu, nic, cpu, mem]
---
apiVersion: v1
kind: Pod
metadata:
  name: test-preferred-4d
spec:
  containers:
  - name: test
    image: registry.access.redhat.com/ubi9/ubi-minimal:latest
    command: ["sleep", "60"]
    resources:
      claims:
      - name: devices
  resourceClaims:
  - name: devices
    resourceClaimTemplateName: test-preferred-4d-claim
EOF
)"
fi

# Test 8: full distance hierarchy — pcieRoot preferred → numaNode preferred → cpuSocketID required
if should_run 8; then
run_test "test-hierarchy" \
    "Test 8: full hierarchy pcieRoot→numa→socket" \
    "pass" \
    "$(cat <<EOF
apiVersion: resource.k8s.io/v1
kind: ResourceClaimTemplate
metadata:
  name: test-hierarchy-claim
spec:
  spec:
    devices:
      requests:
      - name: gpu
        exactly:
          deviceClassName: gpu.nvidia.com
          count: 1
      - name: cpu
        exactly:
          deviceClassName: dra.cpu
          count: 1
      - name: mem
        exactly:
          deviceClassName: dra.memory
          count: 1
      constraints:
      - matchAttribute: resource.kubernetes.io/pcieRoot
        requests: [gpu, cpu, mem]
        enforcement: Preferred
      - matchAttribute: resource.kubernetes.io/numaNode
        requests: [gpu, cpu, mem]
        enforcement: Preferred
      - matchAttribute: resource.kubernetes.io/cpuSocketID
        requests: [gpu, cpu, mem]
---
apiVersion: v1
kind: Pod
metadata:
  name: test-hierarchy
spec:
  containers:
  - name: test
    image: registry.access.redhat.com/ubi9/ubi-minimal:latest
    command: ["sleep", "60"]
    resources:
      claims:
      - name: devices
  resourceClaims:
  - name: devices
    resourceClaimTemplateName: test-hierarchy-claim
EOF
)"
fi

# Test 9: pcieRoot with GPU + NVMe (same PCIe switch — should PASS if NVMe driver is deployed)
if should_run 9; then
run_test "test-pcie-gpu-nvme" \
    "Test 9: pcieRoot — GPU + NVMe (same switch)" \
    "pass" \
    "$(cat <<EOF
apiVersion: resource.k8s.io/v1
kind: ResourceClaimTemplate
metadata:
  name: test-pcie-gpu-nvme-claim
spec:
  spec:
    devices:
      requests:
      - name: gpu
        exactly:
          deviceClassName: gpu.nvidia.com
      - name: nvme
        exactly:
          deviceClassName: dra.nvme
          selectors:
          - cel:
              expression: "device.attributes[\"dra.nvme\"].model != \"Dell_BOSS-N1\""
      constraints:
      - matchAttribute: resource.kubernetes.io/pcieRoot
        requests: [gpu, nvme]
---
apiVersion: v1
kind: Pod
metadata:
  name: test-pcie-gpu-nvme
spec:
  containers:
  - name: test
    image: registry.access.redhat.com/ubi9/ubi-minimal:latest
    command: ["sleep", "60"]
    resources:
      claims:
      - name: devices
  resourceClaims:
  - name: devices
    resourceClaimTemplateName: test-pcie-gpu-nvme-claim
EOF
)"
fi

# Test 10: numaNode with GPU + NVMe + CPU + Memory (5 drivers if NVMe deployed, else 4)
if should_run 10; then
run_test "test-5driver-numa" \
    "Test 10: numaNode — GPU+NVMe+CPU+Mem (multi)" \
    "pass" \
    "$(cat <<EOF
apiVersion: resource.k8s.io/v1
kind: ResourceClaimTemplate
metadata:
  name: test-5driver-numa-claim
spec:
  spec:
    devices:
      requests:
      - name: gpu
        exactly:
          deviceClassName: gpu.nvidia.com
      - name: nvme
        exactly:
          deviceClassName: dra.nvme
          selectors:
          - cel:
              expression: "device.attributes[\"dra.nvme\"].model != \"Dell_BOSS-N1\""
      - name: cpu
        exactly:
          deviceClassName: dra.cpu
      - name: mem
        exactly:
          deviceClassName: dra.memory
      constraints:
      - matchAttribute: resource.kubernetes.io/numaNode
        requests: [gpu, nvme, cpu, mem]
---
apiVersion: v1
kind: Pod
metadata:
  name: test-5driver-numa
spec:
  containers:
  - name: test
    image: registry.access.redhat.com/ubi9/ubi-minimal:latest
    command: ["sleep", "60"]
    resources:
      claims:
      - name: devices
  resourceClaims:
  - name: devices
    resourceClaimTemplateName: test-5driver-numa-claim
EOF
)"
fi

# Test 11: numaNode with GPU + NIC + NVMe + CPU + Memory (5 drivers, full stack)
if should_run 11; then
run_test "test-fullstack" \
    "Test 11: numaNode — 5 drivers full stack" \
    "pass" \
    "$(cat <<EOF
apiVersion: resource.k8s.io/v1
kind: ResourceClaimTemplate
metadata:
  name: test-fullstack-claim
spec:
  spec:
    devices:
      requests:
      - name: gpu
        exactly:
          deviceClassName: gpu.nvidia.com
      - name: nic
        exactly:
          deviceClassName: dra.net-sriov-vf
      - name: nvme
        exactly:
          deviceClassName: dra.nvme
          selectors:
          - cel:
              expression: "device.attributes[\"dra.nvme\"].model != \"Dell_BOSS-N1\""
      - name: cpu
        exactly:
          deviceClassName: dra.cpu
      - name: mem
        exactly:
          deviceClassName: dra.memory
      constraints:
      - matchAttribute: resource.kubernetes.io/numaNode
        requests: [gpu, nic, nvme, cpu, mem]
---
apiVersion: v1
kind: Pod
metadata:
  name: test-fullstack
spec:
  containers:
  - name: test
    image: registry.access.redhat.com/ubi9/ubi-minimal:latest
    command: ["sleep", "60"]
    resources:
      claims:
      - name: devices
  resourceClaims:
  - name: devices
    resourceClaimTemplateName: test-fullstack-claim
EOF
)"
fi

# --- Summary Table ---

echo -e "\n${BOLD}╔══════════════════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║                        TEST RESULTS                             ║${RESET}"
echo -e "${BOLD}╠══════════════════════════════════════════════════════════════════╣${RESET}"
printf "${BOLD}║ %-4s %-40s %-15s ║${RESET}\n" "#" "Test" "Result"
echo -e "${BOLD}╠══════════════════════════════════════════════════════════════════╣${RESET}"

for i in "${!TEST_NAMES[@]}"; do
    result="${TEST_RESULTS[$i]}"
    case "$result" in
        PASSED)        color="$GREEN" ;;
        "EXPECTED FAIL") color="$GREEN" ;;
        *)             color="$RED" ;;
    esac
    printf "║ %-4s %-40s ${color}%-15s${RESET} ║\n" "$((i+1))" "${TEST_NAMES[$i]:0:40}" "$result"
done

echo -e "${BOLD}╠══════════════════════════════════════════════════════════════════╣${RESET}"

# Count results
passed=0
expected_fail=0
failed=0
for r in "${TEST_RESULTS[@]}"; do
    case "$r" in
        PASSED) ((passed++)) ;;
        "EXPECTED FAIL") ((expected_fail++)) ;;
        *) ((failed++)) ;;
    esac
done

echo -e "║ ${GREEN}Passed: $passed${RESET}   ${GREEN}Expected fail: $expected_fail${RESET}   ${RED}Failed: $failed${RESET}              ║"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════════╝${RESET}"

echo -e "\n${BOLD}Conclusion:${RESET}"
echo "Standardized resource.kubernetes.io/numaNode and cpuSocketID enable"
echo "cross-driver NUMA alignment with a single matchAttribute constraint."
echo "enforcement:preferred enables the distance hierarchy:"
echo "  pcieRoot (preferred) → numaNode (preferred) → cpuSocketID (required)"
echo "No topology coordinator. No ConfigMaps. No middleware."

if $DO_CLEANUP; then
    cleanup
fi
