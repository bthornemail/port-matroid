SCHEDULER-NETWORK.md

Scheduler Workset Exchange Protocol (v1 Frozen Draft)

Status

Consensus-adjacent. This protocol defines deterministic workset exchange semantics.
Routing and authority are defined in CUBE-ROUTING.md.
Scheduler semantics are defined in SCHEDULER-CUBE.md.

Networking transport, encryption, peer discovery, and liveness are out of scope.

---

1. Purpose

This document defines how peers exchange scheduler WorkItems deterministically.

It specifies:

message types and canonical payload encodings
anti-entropy exchange for worksets
authority checks based on routing
failure semantics

It does NOT define network transport or security.

---

2. Dependencies

This protocol depends on:

- CUBE-ROUTING.md (routing context, replica sets)
- SCHEDULER-CUBE.md (WorkItem encoding, scheduling rules)

All workset messages MUST carry canonical WorkItem bytes as defined by the scheduler.

---

3. Routing Context

Peers MUST operate under a shared RoutingContext:

routing_version
epoch
replication_factor
routing_salt
peer set

RoutingContext is encoded per CUBE-ROUTING.md.

Peers MUST fail closed if RoutingContext is invalid or unknown.

---

4. Work Authority

A peer MAY originate a WorkItem w only if its peer_id is in:

routeCell(ctx, w.cell)

Recipients MUST reject WorkItems whose origin is outside the replica set.

This is a consensus boundary. There is no best-effort acceptance.

---

5. Message Types (v1)

All messages are canonical byte payloads with a type tag.

5.1 Type Tags

u16le message_type:

0x0001 MSG_ROUTING_CONTEXT
0x0002 MSG_WORK_DIGEST
0x0003 MSG_WORK_REQUEST
0x0004 MSG_WORK_BUNDLE

Unknown message types MUST be rejected.

5.2 MSG_ROUTING_CONTEXT

payload:

routing_context : bytes (canonical encoding per CUBE-ROUTING.md)

5.3 MSG_WORK_DIGEST

payload:

shard : u32le
count : u32le
items : count * (work_id[32] || cell)

cell encoding:
  shard : u32le
  t0    : u64le
  t1    : u64le
  e0    : i64le
  e1    : i64le
  tier  : u8

WorkItem IDs MUST be sorted lexicographically by (cell, work_id).

5.4 MSG_WORK_REQUEST

payload:

shard : u32le
count : u32le
work_ids : count * work_id[32]

work_ids MUST be sorted lexicographically.

5.5 MSG_WORK_BUNDLE

payload:

count : u32le
work_items : count * WorkItem

WorkItem is encoded per SCHEDULER-CUBE.md (WorkSet encoding).
WorkItems MUST be sorted by canonical work ordering key.

---

6. Anti-Entropy Protocol (v1)

Given a RoutingContext and peer set:

1. For each shard, a peer periodically sends MSG_WORK_DIGEST to peers in the shard's replica set.
2. The recipient compares the digest against its local workset.
3. Missing work IDs are requested via MSG_WORK_REQUEST.
4. The sender replies with MSG_WORK_BUNDLE containing the requested WorkItems.

This exchange is deterministic given identical local worksets.

---

7. Canonical Ordering

All lists in the protocol are canonical:

MSG_WORK_DIGEST: sorted by (cell, work_id)
MSG_WORK_REQUEST: sorted by work_id
MSG_WORK_BUNDLE: sorted by WorkItem ordering key

Any non-canonical list MUST be rejected.

---

8. Failure Semantics

If a message is malformed or non-canonical:

the recipient MUST reject it
the recipient MUST NOT apply partial results

Unknown message types MUST be rejected.

Fail-closed behavior is required for consensus safety.

---

9. Compatibility

Message type tags are fixed for v1.

Unknown types MUST be rejected.
No downgrade or partial decode is permitted.

---

10. Compliance Checklist (v1)

An implementation is compliant iff:

- RoutingContext decoding matches CUBE-ROUTING.md
- Authority rule enforced (origin in replica set)
- Canonical ordering enforced for all lists
- Message type tags enforced
- Malformed or non-canonical messages rejected
- WorkItem encoding matches SCHEDULER-CUBE.md

---

END OF DRAFT
