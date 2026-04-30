#!/bin/bash
# build-live-iso.sh — Build a Fedora live ISO and USB image with numa-topology.sh
#
# Prerequisites:
#   sudo dnf install livecd-tools pykickstart
#
# Usage:
#   sudo ./build-live-iso.sh
#
# Output:
#   ./output/numa-topology-live.iso  — bootable ISO (iDRAC virtual media, burn to DVD)
#   ./output/numa-topology-live.img  — bootable USB image with writable overlay
#
# The .img file can be:
#   - Mounted via iDRAC virtual media as a USB device
#   - Written to a physical USB: dd if=output/numa-topology-live.img of=/dev/sdX bs=4M

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
KICKSTART="${SCRIPT_DIR}/numa-topology-live.ks"
NUMA_SCRIPT="${SCRIPT_DIR}/../scripts/numa-topology.sh"
OUTPUT_DIR="${SCRIPT_DIR}/output"
WORK_DIR="${SCRIPT_DIR}/work"
ISO_LABEL="NUMA-TOPO"
IMG_SIZE_MB=4096
OVERLAY_MB=512

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: Must run as root (livecd-creator needs root)"
    echo "Usage: sudo $0"
    exit 1
fi

for cmd in livecd-creator ksvalidator; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "ERROR: $cmd not found. Install prerequisites:"
        echo "  sudo dnf install livecd-tools pykickstart"
        exit 1
    fi
done

if [ ! -f "$NUMA_SCRIPT" ]; then
    echo "ERROR: numa-topology.sh not found at: $NUMA_SCRIPT"
    exit 1
fi

echo "Validating kickstart..."
ksvalidator "$KICKSTART" || {
    echo "WARNING: Kickstart validation failed (may still work)"
}

# Inject numa-topology.sh content into kickstart
echo "Injecting numa-topology.sh into kickstart..."
GENERATED_KS="${WORK_DIR}/numa-topology-live-generated.ks"
mkdir -p "$WORK_DIR" "$OUTPUT_DIR"
sed -e "/##INJECT_NUMA_TOPOLOGY_SCRIPT##/{
    r $NUMA_SCRIPT
    d
}" "$KICKSTART" > "$GENERATED_KS"

echo ""
echo "Step 1: Building live ISO..."
echo "  Kickstart: $KICKSTART"
echo "  Script:    $NUMA_SCRIPT"
echo ""

livecd-creator \
    --config "$GENERATED_KS" \
    --fslabel "$ISO_LABEL" \
    --cache "${WORK_DIR}/cache" \
    --tmpdir "$WORK_DIR"

# livecd-creator outputs to cwd
mv "${ISO_LABEL}.iso" "$OUTPUT_DIR/numa-topology-live.iso"

echo ""
echo "Step 2: Creating USB image with writable overlay..."
echo ""

IMG_FILE="$OUTPUT_DIR/numa-topology-live.img"

# Create a sparse disk image file
truncate -s ${IMG_SIZE_MB}M "$IMG_FILE"

# Set up a loop device
LOOP=$(losetup --find --show "$IMG_FILE")
trap "losetup -d $LOOP 2>/dev/null || true" EXIT

# Convert ISO to bootable USB image on the loop device
livecd-iso-to-disk \
    --overlay-size-mb "$OVERLAY_MB" \
    "$OUTPUT_DIR/numa-topology-live.iso" \
    "$LOOP"

losetup -d "$LOOP"
trap - EXIT

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "  Built successfully:"
echo ""
echo "  ISO: $OUTPUT_DIR/numa-topology-live.iso"
echo "       Mount via iDRAC virtual media (read-only, console output only)"
echo ""
echo "  IMG: $OUTPUT_DIR/numa-topology-live.img"
echo "       Mount via iDRAC as virtual USB (writable — output persists)"
echo "       Or write to physical USB:"
echo "         dd if=$OUTPUT_DIR/numa-topology-live.img of=/dev/sdX bs=4M"
echo ""
echo "  Boot the server — topology is auto-captured to:"
echo "    /root/numa-topology-*.txt"
echo "════════════════════════════════════════════════════════════════"
