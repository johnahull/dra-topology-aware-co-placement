# KubeVirt VEP-300 AMD GPU/NIC DRA validation

This run validates managed DRA claims through AMD GPU VF allocation, SR-IOV VF allocation, VFIO preparation, CDI/launcher injection, and PCI-root co-placement. NUMA attributes are recorded but are not treated as managed-claim alignment because the aligner currently emits only the PCI-root constraint.

## Acceptance criteria

- A managed claim containing one AMD GPU VF and one ConnectX VF allocates both devices from the same `resource.kubernetes.io/pcieRoot`.
- The GPU and NIC allocation results, opaque configurations, CDI metadata, virt-launcher pod, and guest devices agree.
- A one-GPU managed claim reaches `Ready`.
- Unsatisfiable topology requests remain pending and report a clear allocation reason.
- Delete/recreate and restart operations release and reacquire claims without leaks.

## Execution status

The GPU+NIC managed claim and PCI-root co-placement criteria passed. VM launch was blocked during SR-IOV DRA preparation because the deployed standalone SR-IOV driver attempted to read `default/` as a NetworkAttachmentDefinition; this cluster has no NetworkAttachmentDefinition CRD. See `results-summary.md` for the complete result matrix and cleanup verification.

## Limitations

- The cluster is single-node; migration is not tested.
- NUMA scalar/list values are evidence only, not an alignment assertion.
- Pre-existing failed AMD operator pods are recorded as environmental noise.
