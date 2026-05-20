#!/bin/bash
# intel-topology-capture.sh — Capture Intel-specific topology data for IIO stack mapping
# Run alongside hw-topology.sh on Granite Rapids or other Intel Xeon systems.
# Output goes to stdout; redirect to a file for later analysis.

set -uo pipefail

HOSTNAME=$(hostname 2>/dev/null || echo "unknown")
DATE=$(date +%Y%m%d-%H%M%S)

echo "=== Intel Topology Capture — ${HOSTNAME} — ${DATE} ==="
echo ""

# ── Platform ─────────────────────────────────────────────────────────────────

echo "── Platform ──────────────────────────────────────────────────────────"
echo "Product: $(dmidecode -s system-product-name 2>/dev/null || echo 'unknown')"
echo "Board:   $(dmidecode -s baseboard-product-name 2>/dev/null || echo 'unknown')"
echo ""

# ── CPU / NUMA / SNC ─────────────────────────────────────────────────────────

echo "── CPU / NUMA / SNC ────────────────────────────────────────────────"
lscpu 2>/dev/null
echo ""

echo "── NUMA node CPU lists ─────────────────────────────────────────────"
for node in /sys/devices/system/node/node*/; do
    nid=$(basename "$node")
    cpus=$(cat "${node}cpulist" 2>/dev/null || echo "?")
    mem=$(awk '/MemTotal/ {printf "%.1f GB", $4/1024/1024}' "${node}meminfo" 2>/dev/null || echo "?")
    echo "  ${nid}: CPUs ${cpus}  Memory ${mem}"
done
echo ""

# ── DMAR / IIO stack mapping ─────────────────────────────────────────────────

echo "── DMAR IOMMU instances ────────────────────────────────────────────"
if ls /sys/class/iommu/dmar* &>/dev/null 2>&1; then
    for dmar in /sys/class/iommu/dmar*/; do
        name=$(basename "$dmar")
        dev_count=$(ls "${dmar}devices/" 2>/dev/null | wc -l)
        devs=$(ls "${dmar}devices/" 2>/dev/null | head -10 | tr '\n' ' ')
        echo "  ${name} (${dev_count} devices): ${devs}"
    done
else
    echo "  (no DMAR instances found — is VT-d enabled?)"
fi
echo ""

# ── GPU to DMAR mapping ──────────────────────────────────────────────────────

echo "── GPU / Accelerator → DMAR mapping ────────────────────────────────"
_found=0
for grp_dir in /sys/kernel/iommu_groups/*/; do
    grp=$(basename "$grp_dir")
    for dev in "${grp_dir}devices/"*/; do
        bdf=$(basename "$dev")
        [ "$bdf" = "*" ] && continue
        class=$(cat "${dev}class" 2>/dev/null || echo "0")
        class_int=$(printf '%d' "$class" 2>/dev/null) || continue
        top=$(( class_int >> 16 ))
        # 3 = Display/VGA, 18 = Processing accelerator
        [ "$top" -eq 3 ] || [ "$top" -eq 18 ] || continue

        iommu_link=$(readlink -f "${dev}iommu" 2>/dev/null || true)
        iommu_name=$(basename "$iommu_link" 2>/dev/null || echo "?")
        numa=$(cat "${dev}numa_node" 2>/dev/null || echo "-1")
        drv_link=$(readlink "${dev}driver" 2>/dev/null || true)
        drv=$(basename "$drv_link" 2>/dev/null || echo "none")
        name=""
        command -v lspci &>/dev/null && name=$(lspci -s "$bdf" 2>/dev/null | sed 's/^[^ ]* //' | cut -c1-70)

        echo "  ${bdf}  IOMMU grp ${grp} → ${iommu_name}  NUMA ${numa}  driver: ${drv}"
        [ -n "$name" ] && echo "    ${name}"
        _found=1
    done
done
[ "$_found" -eq 0 ] && echo "  (no GPUs or accelerators found)"
echo ""

# ── NIC to DMAR mapping ─────────────────────────────────────────────────────

echo "── NIC → DMAR mapping ──────────────────────────────────────────────"
_found=0
for grp_dir in /sys/kernel/iommu_groups/*/; do
    grp=$(basename "$grp_dir")
    for dev in "${grp_dir}devices/"*/; do
        bdf=$(basename "$dev")
        [ "$bdf" = "*" ] && continue
        class=$(cat "${dev}class" 2>/dev/null || echo "0")
        class_int=$(printf '%d' "$class" 2>/dev/null) || continue
        top=$(( class_int >> 16 ))
        [ "$top" -eq 2 ] || continue

        iommu_link=$(readlink -f "${dev}iommu" 2>/dev/null || true)
        iommu_name=$(basename "$iommu_link" 2>/dev/null || echo "?")
        numa=$(cat "${dev}numa_node" 2>/dev/null || echo "-1")
        sriov=""
        [ -f "${dev}sriov_totalvfs" ] && sriov="  SR-IOV: $(cat ${dev}sriov_numvfs 2>/dev/null)/$(cat ${dev}sriov_totalvfs 2>/dev/null) VFs"
        name=""
        command -v lspci &>/dev/null && name=$(lspci -s "$bdf" 2>/dev/null | sed 's/^[^ ]* //' | cut -c1-70)

        echo "  ${bdf}  IOMMU grp ${grp} → ${iommu_name}  NUMA ${numa}${sriov}"
        [ -n "$name" ] && echo "    ${name}"
        _found=1
    done
done
[ "$_found" -eq 0 ] && echo "  (no NICs found)"
echo ""

# ── NVMe to DMAR mapping ────────────────────────────────────────────────────

echo "── NVMe → DMAR mapping ─────────────────────────────────────────────"
_found=0
for grp_dir in /sys/kernel/iommu_groups/*/; do
    grp=$(basename "$grp_dir")
    for dev in "${grp_dir}devices/"*/; do
        bdf=$(basename "$dev")
        [ "$bdf" = "*" ] && continue
        class=$(cat "${dev}class" 2>/dev/null || echo "0")
        class_int=$(printf '%d' "$class" 2>/dev/null) || continue
        top=$(( class_int >> 16 ))
        sub=$(( (class_int >> 8) & 0xFF ))
        [ "$top" -eq 1 ] && [ "$sub" -eq 8 ] || continue

        iommu_link=$(readlink -f "${dev}iommu" 2>/dev/null || true)
        iommu_name=$(basename "$iommu_link" 2>/dev/null || echo "?")
        numa=$(cat "${dev}numa_node" 2>/dev/null || echo "-1")
        sriov=""
        [ -f "${dev}sriov_totalvfs" ] && sriov="  SR-IOV: $(cat ${dev}sriov_numvfs 2>/dev/null)/$(cat ${dev}sriov_totalvfs 2>/dev/null) VFs"
        name=""
        command -v lspci &>/dev/null && name=$(lspci -s "$bdf" 2>/dev/null | sed 's/^[^ ]* //' | cut -c1-70)

        echo "  ${bdf}  IOMMU grp ${grp} → ${iommu_name}  NUMA ${numa}${sriov}"
        [ -n "$name" ] && echo "    ${name}"
        _found=1
    done
done
[ "$_found" -eq 0 ] && echo "  (no NVMe controllers found)"
echo ""

# ── Uncore / mesh topology devices ───────────────────────────────────────────

echo "── Uncore / mesh topology devices ──────────────────────────────────"
if command -v lspci &>/dev/null; then
    lspci -d 8086: 2>/dev/null | grep -iE "system|uncore|mesh|IIO" || echo "  (none found)"
else
    echo "  (lspci not available)"
fi
echo ""

# ── DMAR full device ownership ───────────────────────────────────────────────

echo "── DMAR full device ownership (all devices per instance) ───────────"
if ls /sys/class/iommu/dmar* &>/dev/null 2>&1; then
    for dmar in /sys/class/iommu/dmar*/; do
        name=$(basename "$dmar")
        echo "  ${name}:"
        for dev in "${dmar}devices/"*/; do
            bdf=$(basename "$dev")
            [ "$bdf" = "*" ] && continue
            class=$(cat "${dev}class" 2>/dev/null || echo "?")
            numa=$(cat "${dev}numa_node" 2>/dev/null || echo "-1")
            echo "    ${bdf}  class=${class}  numa=${numa}"
        done
    done
else
    echo "  (no DMAR instances)"
fi
echo ""

echo "=== Capture complete ==="
