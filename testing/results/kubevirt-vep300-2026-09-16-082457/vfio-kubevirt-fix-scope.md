# VFIO/KubeVirt fix scope

This document records generic VFIO/KubeVirt and DRA-driver integration work
encountered while running the VEP-300 tests. These items are not part of the
VEP-300 managed-claim implementation or its acceptance criteria.

## KubeVirt PCI-aperture branch

Branch: `fix/vfio-vm-pci-aperture`  
Base: current KubeVirt `main`

Commits:

- `98b76608ea` — add locked guest memory and expand the PCI aperture for
  VFIO VMs.
- `1c7f4057ce` — configure the PCI aperture through libvirt and preserve
  `directsync` compatibility.

The changes add libvirt `<memoryBacking><locked/></memoryBacking>` for VMIs
with GPUs or host devices and configure a 256 GiB 64-bit PCI hole on the PCIe
root controller. They address QEMU/KVM startup failures caused by VFIO device
BAR mapping and memory registration. The branch's focused converter and
libvirt XML tests passed.

These changes require separate review for scope, locked-memory resource and
security implications, existing PCI-root-controller handling, and whether a
fixed 256 GiB aperture is appropriate as a general KubeVirt default.

## DRA-driver VFIO preparation

The SR-IOV driver work was tested separately on
`fix/vfio-standalone-no-nad`:

- driver-only VFIO configuration without a NetworkAttachmentDefinition;
- NRI identity from the environment;
- skipping RDMA/CNI setup for VFIO devices;
- exposing the VFIO device node to the launcher.

This is DRA-driver behavior, not VEP-300 behavior. The VEP-300 test only
asserts that the managed claim carries the expected request/configuration and
that the allocated claim reaches the VM launcher.

## Out of scope for VEP-300 results

- `vfio-pci` binding and unbinding;
- CDI generation and permissions;
- NRI plugin registration;
- NAD lookup and RDMA setup;
- IOMMUFD versus legacy VFIO backend selection;
- QEMU PCI-hole sizing;
- locked-memory limits;
- guest PCI-root topology.
