# KubeVirt VEP-300 AMD GPU/NIC DRA validation

This run validates managed DRA claims through AMD GPU VF allocation, SR-IOV VF allocation, VFIO preparation, CDI/launcher injection, and PCI-root co-placement. NUMA attributes are recorded but are not treated as managed-claim alignment because the aligner currently emits only the PCI-root constraint.

## Acceptance criteria

- A managed claim containing one AMD GPU VF and one ConnectX VF allocates both devices from the same `resource.kubernetes.io/pcieRoot`.
- The GPU and NIC allocation results, opaque configurations, CDI metadata, virt-launcher pod, and guest devices agree.
- A one-GPU managed claim reaches `Ready`.
- Unsatisfiable topology requests remain pending and report a clear allocation reason.
- Delete/recreate and restart operations release and reacquire claims without leaks.

## Execution status

The GPU+NIC managed claim and PCI-root co-placement criteria passed. Two persistent `VirtualMachine` objects were created; both reached `Running`/`Ready=True`, and each guest exposed one AMD GPU VF and one ConnectX VF through the QEMU guest agent. Restarting one VM released and reacquired its claim while the other VM remained Running. Restarting the AMD GPU and SR-IOV DRA driver DaemonSets also left both VMs Running and their claims allocated. See `results-summary.md` for the complete result matrix and evidence.

## Follow-up execution

- Guest PCI validation: PASS. Both guests exposed AMD `0x1002:0x74b5` and Mellanox `0x15b3:0x101e` devices under `/sys/bus/pci/devices`.
- Guest PCI topology validation: PASS. In both guests, the NIC appeared at `0000:08:00.0` below guest root port `00:02.7`, and the GPU appeared at `0000:09:00.0` below guest root port `00:03.0`.
- VM restart and claim reacquisition: PASS. VM `amd-managed-gpu-nic-a` was halted and restarted; its claim allocation timestamp changed, while VM `amd-managed-gpu-nic-b` remained Running.
- AMD GPU DRA driver restart: PASS. The driver DaemonSet rolled out successfully and both VMs remained Ready.
- SR-IOV DRA driver restart: PASS. The driver DaemonSet rolled out successfully and both VMs remained Ready with their GPU/NIC claims allocated.
- VM cleanup and reacquisition: PASS. Halting VM `amd-managed-gpu-nic-a` removed its VMI and managed claim while VM `amd-managed-gpu-nic-b` remained Running; setting `runStrategy: Always` recreated the claim and VMI successfully.
- KubeVirt converter regression tests: PASS. The focused `api`, `converter`, and `libvirtxml` Go packages passed.

## Limitations

- The cluster is single-node; migration is not tested.
- NUMA scalar/list values are evidence only, not an alignment assertion for this GPU+NIC test.
- Pre-existing failed AMD operator pods are recorded as environmental noise.
