#!/bin/bash
# R760xa (nvd-srv-31) node setup after boot
# Run on the node as root.
set -e

echo "=== SR-IOV VFs ==="
echo 2 | tee /sys/class/net/enp55s0np0/device/sriov_numvfs  # CX7, NUMA 0
echo 2 | tee /sys/class/net/ens7f0np0/device/sriov_numvfs   # CX6Dx, NUMA 1

echo "=== Hugepages (64 x 2MB per NUMA node) ==="
echo 64 | tee /sys/devices/system/node/node0/hugepages/hugepages-2048kB/nr_hugepages
echo 64 | tee /sys/devices/system/node/node1/hugepages/hugepages-2048kB/nr_hugepages

echo "=== Node labels ==="
kubectl --kubeconfig=/etc/kubernetes/admin.conf label node $(hostname) cpumanager=true kubevirt.io/cpumanager=true --overwrite

echo "=== Verify ==="
echo "VFs:"
ls /sys/class/net/ | grep -E "v[0-9]$"
echo "Hugepages:"
cat /proc/meminfo | grep HugePages_Total
echo "vfio_pci:"
lsmod | grep vfio_pci || echo "not loaded (should auto-load via /etc/modules-load.d/vfio-pci.conf)"
