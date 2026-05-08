# Upstream Proposal: `enforcement: preferred` on `matchAttribute`

> **TL;DR:** Add an `enforcement` field to `DeviceConstraint` with two values: `Required` (default, current behavior) and `Preferred` (scheduler tries constraint, relaxes if unsatisfiable). This makes topology constraints composable — a user can express "I'd like bus proximity if available, but I require memory proximity regardless" without the claim failing on hardware that lacks shared PCIe roots. Separable from the numaNode standardization proposal; independently useful for pcieRoot on direct-attached hardware.

---

## Why This Is Needed

### pcieRoot is unsatisfiable on common hardware

On the Dell R760xa, every PCIe slot has its own root port — no two devices share a root. `matchAttribute: pcieRoot` as a required constraint fails for any GPU+NIC pair, even though all devices are on the same NUMA node and would perform well together.

This is common on standard rack servers. Only high-density GPU systems (XE8640, XE9680) use PCIe switches that create shared roots. A required constraint that fails on standard server hardware isn't portable.

### Users shouldn't need to know their hardware topology

Today, a workload author must know whether their target server has PCIe switches or direct-attached slots to decide whether to include a pcieRoot constraint. With `enforcement: preferred`, one claim works on any hardware:

```yaml
constraints:
- matchAttribute: resource.kubernetes.io/pcieRoot
  requests: [gpu, nic]
  enforcement: preferred        # bus proximity: try same PCIe switch
- matchAttribute: resource.kubernetes.io/numaNode
  requests: [gpu, nic, cpu, mem]
  enforcement: required         # memory proximity: must share memory controller
```

On switched hardware (XE8640), the scheduler finds a GPU+NIC pair sharing a switch. On direct-attached hardware (R760xa), the pcieRoot constraint has no effect — the numaNode constraint provides the co-placement guarantee independently. The workload author doesn't need to know the server model.

### pcieRoot and numaNode are orthogonal signals

`pcieRoot` measures bus topology (which PCIe switch tree). `numaNode` measures memory topology (which memory controller). They are independent physical properties — a GPU and NIC can be connected to different PCIe switches but the same memory controller. `enforcement: preferred` lets users compose independent constraints from both signals without one blocking the other.

---

## Proposed API Change

Add an `enforcement` field to `DeviceConstraint`:

```go
type DeviceConstraint struct {
    // ... existing fields ...

    // Enforcement specifies whether this constraint is required or preferred.
    // Required (default): the constraint must be satisfied or allocation fails.
    // Preferred: the scheduler tries to satisfy the constraint but does not
    // fail if no satisfying allocation exists.
    //
    // +optional
    // +default="Required"
    Enforcement *ConstraintEnforcement `json:"enforcement,omitempty"`
}

type ConstraintEnforcement string

const (
    ConstraintEnforcementRequired  ConstraintEnforcement = "Required"
    ConstraintEnforcementPreferred ConstraintEnforcement = "Preferred"
)
```

### Scheduler behavior: two-pass allocation

The implementation (in our fork, branch `feature/enforcement-preferred` on `johnahull/kubernetes`) uses a two-pass allocation strategy:

**Pass 1 (strict):** All constraints — including preferred — are treated as required. The allocator searches for a solution that satisfies everything. If found, optimal placement is guaranteed.

**Pass 2 (relaxed):** If pass 1 finds no solution and preferred constraints exist, the allocator resets all constraint state and re-runs with preferred constraints relaxed. In this pass, devices that fail a preferred constraint are skipped rather than rejected — the allocator proceeds with remaining required constraints.

This two-pass approach ensures the scheduler prefers the tightest placement when possible, and only relaxes when necessary. The `constraint` interface gains a `reset()` method to clear tracked state between passes.

**Default value:** `nil` pointer (interpreted as Required). Existing claims are unaffected.

**Scope:** Only `matchAttribute` constraints support `enforcement: preferred`. `distinctAttribute` is always required.

**Feature gate:** The fork implementation piggybacks on `DRAListTypeAttributes` because the code lives in the experimental allocator. An upstream implementation should have its own feature gate (e.g., `DRAPreferredConstraints`) — enforcement:preferred is unrelated to list-typed attributes.

---

## Use Cases

### Portable GPU+NIC co-placement

```yaml
constraints:
- matchAttribute: resource.kubernetes.io/pcieRoot
  requests: [gpu, nic]
  enforcement: preferred
- matchAttribute: resource.kubernetes.io/numaNode
  requests: [gpu, nic, cpu]
```

Works on switched hardware (pcieRoot satisfied), direct-attached hardware (pcieRoot relaxed, numaNode satisfied), and single-socket servers (both trivially satisfied).

### Non-NCCL workloads

Custom RDMA applications, DPDK networking, or GPU-Direct Storage that don't auto-detect PCIe topology. The scheduler is their only chance at optimal bus-level placement. `enforcement: preferred` gives them the best available placement without risking unsatisfiable claims.

### Topology coordinator replacement

The topology coordinator's `fallbackAttribute` mechanism already implements this pattern — try pcieRoot, fall back to numaNode. `enforcement: preferred` makes this scheduler-native, eliminating the need for middleware to implement constraint fallback.

---

## Arguments For

- **Portability** — one claim works on any hardware topology without the author knowing the server model
- **Composability** — orthogonal topology signals (bus, memory) can be combined without one blocking the other
- **Simplifies middleware** — the topology coordinator's fallback logic becomes unnecessary for basic cases
- **Non-breaking** — default is `Required`, preserving existing behavior. No changes needed for existing claims.

## Arguments Against

- **API complexity** — adding a field to `DeviceConstraint` requires changes to apiserver, scheduler, controller-manager, kubelet, and kubectl
- **Ambiguous semantics for multiple preferred constraints** — which preferred constraints take priority? The scheduler must define a selection strategy
- **NCCL/RCCL already handle proxy selection** — for AI workloads, the frameworks auto-detect PCIe topology and pick the best proxy GPU regardless of scheduler placement. The scheduler doing it too is redundant for this use case
- **Minimal real-world benefit for the pcieRoot case** — the performance gain between same-switch and same-NUMA is one root complex hop, negligible for most workloads. The 58% throughput cliff is at the NUMA boundary, not the PCIe switch boundary

---

## Relationship to Other Proposals

**Separable from numaNode standardization.** `enforcement: preferred` is independently useful — it makes pcieRoot portable on direct-attached hardware even without numaNode. `numaNode` is valuable as a required constraint on SNC-off hardware even without `enforcement: preferred`. They complement each other but neither depends on the other.

**Replaces topology coordinator fallback logic.** The coordinator's `fallbackAttribute` field and distance-based constraint generation implement the same pattern at the controller level. With `enforcement: preferred` in the scheduler, this logic becomes unnecessary for basic NUMA alignment — the coordinator retains value for partition abstraction and cross-driver bundling.

---

## Evidence

Tested on three server platforms:

| System | pcieRoot satisfiable? | Needs enforcement:preferred? |
|--------|----------------------|------------------------------|
| Dell XE8640 (4x H100 SXM5) | Yes (1 of 4 GPUs share switch with NIC) | Yes — without preferred, 3 of 4 GPUs excluded |
| Dell R760xa (2x A40) | No (every slot has own root port) | Yes — pcieRoot constraint is unsatisfiable |
| Dell XE9680 (8x MI300X) | Yes (2 of 8 GPUs share switch with NIC) | Yes — without preferred, 6 of 8 GPUs excluded |

The topology coordinator's `fix/distance-based-fallback` branch implements this pattern at the controller level, proving the concept works on real hardware.

---

## Implementation Status

A working implementation exists in the fork `johnahull/kubernetes`, branch `feature/enforcement-preferred` (based on v1.37-alpha):

| Commit | Change |
|--------|--------|
| `de14cbe` | Add `Enforcement` field to `DeviceConstraint`, single-pass allocator support |
| `5f6efee` | Protobuf serialization, OpenAPI schema, enable `DRAListTypeAttributes` by default |
| `8708a85` | Pass `ListTypeAttributes` flag to `AllocatorFeatures` |
| `fde1979` | Two-pass allocation: strict search first, then preferred relaxation with `reset()` |

**Files modified:**
- `pkg/apis/resource/types.go` — internal API type
- `staging/src/k8s.io/api/resource/v1/types.go` — external API type
- `staging/src/k8s.io/dynamic-resource-allocation/structured/internal/experimental/allocator_experimental.go` — two-pass allocation logic
- `staging/src/k8s.io/dynamic-resource-allocation/structured/internal/experimental/constraint.go` — `reset()` interface method
- Generated deepcopy, conversion, protobuf, and OpenAPI files

**Deployed on:** Dell R760xa (K8s 1.37-alpha custom build) and Dell XE8640 (K8s 1.36.0 custom build).

---

## References

- [Upstream Proposal: Standardize numaNode](upstream-proposal-standardize-numanode.md) — the complementary attribute standardization proposal
- [Topology Coordinator Design](../topology-coordinator.md) — implements fallback pattern via `fallbackAttribute`
- [Topology Use Cases](../topology-use-cases.md) — AI workloads mapped to topology levels
- [Use Case Diagrams](../diagrams/use-case-diagrams-v2.md) — hardware topology diagrams showing where pcieRoot is satisfiable vs not
- [DRA KEP Ecosystem Overview](kep-ecosystem-overview.md) — how this fits into the broader DRA roadmap
