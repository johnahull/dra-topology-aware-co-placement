# numa-topology-live.ks — Fedora 44 Live ISO kickstart
# Built by build-live-iso.sh using livecd-creator
#
# The numa-topology.sh script is injected by the build script into the
# INJECT_NUMA_TOPOLOGY_SCRIPT marker below.

lang en_US.UTF-8
keyboard us
timezone UTC
selinux --permissive
firewall --disabled
rootpw --plaintext topology

# Live image filesystem
part / --size 4096 --fstype ext4

# Repositories — use Fedora 42 (current stable) since 44 may not exist yet
repo --name=fedora --mirrorlist=https://mirrors.fedoraproject.org/mirrorlist?repo=fedora-42&arch=$basearch
repo --name=updates --mirrorlist=https://mirrors.fedoraproject.org/mirrorlist?repo=updates-released-f42&arch=$basearch

%packages
@core
bash
pciutils
dmidecode
coreutils
util-linux
gawk
sed
grep
less
vim-minimal
numactl
NetworkManager
openssh-clients
dracut-live
-@fonts
-@multimedia
-@printing
%end

%post
#!/bin/bash

# ── Embed numa-topology.sh ──────────────────────────────────────────────────
cat > /usr/local/bin/numa-topology.sh << 'NUMA_SCRIPT_EOF'
##INJECT_NUMA_TOPOLOGY_SCRIPT##
NUMA_SCRIPT_EOF
chmod +x /usr/local/bin/numa-topology.sh

# ── Systemd service for auto-capture on boot ────────────────────────────────
cat > /etc/systemd/system/numa-topology-capture.service << 'UNIT'
[Unit]
Description=Capture NUMA topology on boot
After=multi-user.target
Wants=multi-user.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/numa-topology-capture.sh
StandardOutput=journal+console

[Install]
WantedBy=multi-user.target
UNIT

# ── Capture wrapper ─────────────────────────────────────────────────────────
cat > /usr/local/bin/numa-topology-capture.sh << 'WRAPPER'
#!/bin/bash
OUTDIR="/root"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
SYS_MODEL=$(dmidecode -s system-product-name 2>/dev/null | tr ' /' '-_' | tr -cd '[:alnum:]_-' || echo "unknown")
[ -z "$SYS_MODEL" ] && SYS_MODEL="unknown"
OUTFILE="${OUTDIR}/numa-topology-${SYS_MODEL}-${TIMESTAMP}.txt"

echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║  NUMA Topology Capture — Live ISO                            ║"
echo "║  Output: ${OUTFILE}                                          ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""

/usr/local/bin/numa-topology.sh 2>&1 | tee "${OUTFILE}"

/usr/local/bin/numa-topology.sh --accelerators --flat 2>&1 \
    > "${OUTDIR}/numa-topology-accelerators-${SYS_MODEL}-${TIMESTAMP}.txt"

# Strip ANSI color codes from saved files
for f in "${OUTDIR}"/numa-topology-*.txt; do
    sed -i 's/\x1b\[[0-9;]*m//g' "$f"
done

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "  Output saved to: ${OUTFILE}"
echo "  Accelerator view: ${OUTDIR}/numa-topology-accelerators-${SYS_MODEL}-${TIMESTAMP}.txt"
echo ""
echo "  To re-run:  numa-topology.sh [--help]"
echo "  To copy out: mount a USB and cp /root/numa-topology-*.txt /mnt/"
echo "════════════════════════════════════════════════════════════════"
WRAPPER
chmod +x /usr/local/bin/numa-topology-capture.sh

systemctl enable numa-topology-capture.service

# ── Auto-login root on tty1 ────────────────────────────────────────────────
mkdir -p /etc/systemd/system/getty@tty1.service.d
cat > /etc/systemd/system/getty@tty1.service.d/autologin.conf << 'AUTOLOGIN'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear %I $TERM
AUTOLOGIN

# ── MOTD ────────────────────────────────────────────────────────────────────
cat > /etc/motd << 'MOTD'

  ╔════════════════════════════════════════════════╗
  ║  NUMA Topology Capture — Fedora Live          ║
  ╚════════════════════════════════════════════════╝

  Topology output is in /root/numa-topology-*.txt

  Useful commands:
    numa-topology.sh              Full topology tree
    numa-topology.sh -a           Accelerators only
    numa-topology.sh -a -f        Accelerators flat list
    numa-topology.sh -n           Network devices only
    lspci -tv                     PCI tree
    dmidecode -t memory           DIMM info
    lscpu                         CPU topology

MOTD

%end
