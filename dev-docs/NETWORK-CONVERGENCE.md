NETWORK-CONVERGENCE.md

Distributed Convergence Laws (v1 Frozen Draft)

Status
Consensus-critical (v1). Any divergence is a protocol fork.

This document defines deterministic convergence of distributed scheduler state.

It specifies:

epoch adoption semantics
digest authority
anti-entropy workset exchange
conflict merge rules
convergence guarantees
fail-closed behavior

Transport, encryption, peer discovery, and liveness are out of scope.

1. Purpose

The goal of convergence is:

All correct peers eventually derive identical canonical worksets given the same routing context and reachable replica set.

Convergence must be:

deterministic
order-independent
timing-independent
transport-independent

Network timing MUST NOT affect final scheduler state.

2. Epoch Adoption Law (v1)

A node may adopt a higher routing epoch only if it possesses a complete routing context:

(epoch, params, full PeerSet)

2.1 Atomic context rule

Routing context is atomic.

Partial contexts MUST be rejected.

A node MUST NOT:

adopt epoch with missing peers
guess missing peers
merge partial contexts

2.2 Adoption rule

If a node receives a context with:

epoch_new > epoch_current

then it may adopt iff:

version valid
params valid
PeerSet canonical
PeerSet complete
validation succeeds per CUBE-ROUTING.md

Otherwise:

reject
remain on current epoch

2.3 Fail-closed

If routing context cannot be validated:

routing is unavailable
scheduler network MUST halt convergence

No best-effort fallback is allowed.

3. Replica Digest Authority Law (v1)

For shard S:

replicas = routeShard(ctx, S)

Any peer P may advertise work digests for S iff:

P in replicas

3.1 Authority rule

Digest acceptance depends only on replica membership.

Replica rank (primary/secondary) is non-semantic.

3.2 Rejection rule

If sender is not in replicas:

digest MUST be rejected

No warning mode exists.

4. Canonical Workset Union Law (v1)

When two admissible replicas disagree:

W_local != W_remote

the receiver MUST compute:

W_union = canonicalUnion(W_local, W_remote)

Union is defined as:

set union by work_id
duplicate work_ids forbidden
identical work_id with different bytes -> reject (malformed)

4.1 Union determinism

canonicalUnion is:

sorted by canonical WorkItem ordering
duplicate-free
byte-stable

Union order is non-semantic.

5. Deterministic Resolution Law (v1)

After union:

batch = schedule(W_union)

Resolution is performed exclusively by scheduler rules.

Routing layer MUST NOT:

prioritize peers
prefer primaries
apply timestamps
apply arrival order

Only scheduler semantics resolve conflicts.

6. Anti-Entropy Exchange Loop (v1)

For each shard:

peers send MSG_WORK_DIGEST
recipients compute missing IDs
recipients send MSG_WORK_REQUEST
sender replies MSG_WORK_BUNDLE
receiver unions work
scheduler produces batch

Repeat until digests converge.

6.1 Convergence property

If no new work is introduced:

anti-entropy MUST converge to identical canonical worksets.

This is a safety guarantee, not a liveness guarantee.

7. Divergence Handling Law (v1)

If two replicas produce incompatible work items:

same work_id
different bytes

the receiver MUST reject both and mark shard inconsistent.

This is a consensus violation.

Recovery is out of scope.

8. Failure Semantics (v1)

Malformed or non-canonical inputs MUST:

be rejected
produce no partial state
not affect scheduler

Unknown message types MUST be rejected.

Routing failure MUST halt convergence, not degrade.

9. Convergence Identity Law (v1)

Given:

routing context
initial workset
anti-entropy exchange
scheduler rules

All correct peers MUST derive identical canonical batches.

External entropy is forbidden.

10. Compatibility Law (v1)

Unknown convergence versions MUST be rejected.

No downgrade.
No partial compatibility.
No best-effort interpretation.

11. Compliance Checklist (v1)

An implementation is compliant iff:

epoch adoption is atomic
replica authority enforced
union is canonical and deterministic
scheduler is sole conflict resolver
malformed work rejected
non-replica digests rejected
canonical ordering enforced
routing context validated strictly
convergence produces identical batches

12. Notes (Non-normative)

Union + deterministic scheduling ensures:

no leader dependency
no timing dependence
no trust hierarchy
eventual convergence

The network is a transport layer.
The scheduler is the truth layer.

END OF DRAFT
