#!/bin/bash
# Demo: Standardized topology attributes enable cross-driver NUMA alignment
# with native matchAttribute constraints — no middleware needed.
#
# Prerequisites: K8s 1.36 with GPU, CPU, and memory DRA drivers deployed,
# all publishing resource.kubernetes.io/numaNode and cpuSocketID.

set -e

BOLD="\033[1m"
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
RESET="\033[0m"

cleanup() {
    echo -e "\n${BOLD}Cleaning up...${RESET}"
    kubectl delete pod --force --grace-period=0 \
        test-numanode test-3driver test-socketid test-pcieroot 2>/dev/null || true
    kubectl delete resourceclaimtemplate \
        numanode-test three-driver-test socketid-test pcieroot-test 2>/dev/null || true
}

show_resourceslices() {
    echo -e "\n${BOLD}=== ResourceSlices with standardized attributes ===${RESET}"
    echo ""
    for slice in $(kubectl get resourceslices --no-headers -o custom-columns=NAME:.metadata.name); do
        driver=$(kubectl get resourceslice "$slice" -o jsonpath='{.spec.driverName}')
        echo -e "${BOLD}Driver: $driver${RESET}"
        kubectl get resourceslice "$slice" -o yaml | grep -A 2 "resource.kubernetes.io" | grep -v "^--$"
        echo ""
    done
}

run_test() {
    local name=$1
    local desc=$2
    local expected=$3
    local yaml=$4

    echo -e "\n${BOLD}=== $desc ===${RESET}"
    echo "$yaml" | kubectl apply -f - 2>&1

    echo -n "Waiting for scheduling... "
    for i in $(seq 1 30); do
        status=$(kubectl get resourceclaim --no-headers -o custom-columns=STATUS:.status.allocation 2>/dev/null | head -1)
        if [ -n "$status" ] && [ "$status" != "<none>" ]; then
            break
        fi
        sleep 1
    done

    claim=$(kubectl get resourceclaim --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null | head -1)
    if [ -z "$claim" ]; then
        echo -e "${RED}FAILED — no claim created${RESET}"
        return
    fi

    allocated=$(kubectl get resourceclaim "$claim" -o jsonpath='{.status.allocation.devices.results}' 2>/dev/null)
    if [ -z "$allocated" ] || [ "$allocated" = "null" ]; then
        if [ "$expected" = "fail" ]; then
            echo -e "${GREEN}EXPECTED FAILURE — claim not satisfiable${RESET}"
            reason=$(kubectl describe pod "$name" 2>/dev/null | grep "FailedScheduling" | tail -1)
            echo "  Reason: $reason"
        else
            echo -e "${RED}FAILED — claim not allocated${RESET}"
        fi
    else
        if [ "$expected" = "fail" ]; then
            echo -e "${RED}UNEXPECTED SUCCESS — expected failure${RESET}"
        else
            echo -e "${GREEN}PASSED${RESET}"
        fi
        echo ""
        echo "Allocation:"
        echo "$allocated" | python3 -m json.tool 2>/dev/null || echo "$allocated"
    fi

    # Clean up for next test
    kubectl delete pod "$name" --force --grace-period=0 2>/dev/null || true
    kubectl delete resourceclaimtemplate "${name}-claim" 2>/dev/null || true
    sleep 2
}

# --- Main ---

cleanup

echo -e "${BOLD}Standardized Topology Attributes Demo${RESET}"
echo "Proving: resource.kubernetes.io/numaNode and cpuSocketID"
echo "         enable cross-driver matchAttribute — no middleware needed"
echo ""

show_resourceslices

# Test 1: numaNode with GPU + CPU
run_test "test-numanode" \
    "Test 1: matchAttribute numaNode — GPU + CPU" \
    "pass" \
    "$(cat <<EOF
apiVersion: resource.k8s.io/v1
kind: ResourceClaimTemplate
metadata:
  name: test-numanode-claim
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
  name: test-numanode
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
    resourceClaimTemplateName: test-numanode-claim
EOF
)"

# Test 2: numaNode with GPU + CPU + Memory (3 drivers)
run_test "test-3driver" \
    "Test 2: matchAttribute numaNode — GPU + CPU + Memory (3 drivers)" \
    "pass" \
    "$(cat <<EOF
apiVersion: resource.k8s.io/v1
kind: ResourceClaimTemplate
metadata:
  name: test-3driver-claim
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
  name: test-3driver
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
    resourceClaimTemplateName: test-3driver-claim
EOF
)"

# Test 3: cpuSocketID with GPU + CPU
run_test "test-socketid" \
    "Test 3: matchAttribute cpuSocketID — GPU + CPU" \
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

# Test 4: pcieRoot for GPU+CPU FAILS (CPU has no pcieRoot)
run_test "test-pcieroot" \
    "Test 4: matchAttribute pcieRoot — GPU + CPU (expected FAIL: CPU has no pcieRoot)" \
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
      - name: cpu
        exactly:
          deviceClassName: dra.cpu
          count: 1
      constraints:
      - matchAttribute: resource.kubernetes.io/pcieRoot
        requests: [gpu, cpu]
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

echo -e "\n${BOLD}=== Summary ===${RESET}"
echo "Test 1 (numaNode GPU+CPU):        proves cross-driver NUMA alignment"
echo "Test 2 (numaNode GPU+CPU+Memory):  proves 3-driver alignment with one constraint"
echo "Test 3 (cpuSocketID GPU+CPU):      proves socket-level alignment"
echo "Test 4 (pcieRoot GPU+CPU):         proves pcieRoot alone is insufficient (CPU has no pcieRoot)"
echo ""
echo "All tests use resource.kubernetes.io/numaNode and cpuSocketID — standardized"
echo "attributes that every driver publishes. No topology coordinator, no ConfigMaps."

cleanup
