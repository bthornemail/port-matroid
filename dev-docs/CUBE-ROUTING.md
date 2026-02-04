CUBE-ROUTING.md

Cube Routing + Shard Assignment Laws (v1 Frozen Draft)

Status

Consensus-critical (v1). Any divergence is a protocol fork.

This document defines the minimal topology assumptions required for distributed scheduling and workset exchange:

canonical shard ownership
deterministic routing from shard -> responsible peers
replica selection
deterministic tie-breakers
failure semantics (fail-closed)

Networking transport, discovery, encryption, and liveness are explicitly out of scope.

1. Terms

1.1 Cell

A cell is the scheduler partition key:

shard : uint32
tier : uint8
t0,t1 : uint64 (half-open interval [t0, t1))
e0,e1 : int64 (closed interval [e0, e1])

A cell is valid iff:

t0 < t1
e0 <= e1

(Validity is enforced at the scheduler layer; routing assumes canonical cells.)

1.2 Shard

A shard is a uint32 index naming a responsibility domain for cells.

Important: In v1, routing is defined only in terms of cell.shard.
Routing does not interpret tier/ticks/entities. Those remain scheduler semantics.

1.3 PeerId

A peer is identified by a 32-byte immutable identifier:

peer_id : bytes[32]

Peer IDs are compared by lexicographic raw byte order.

1.4 PeerSet

A PeerSet is a finite set of peers that can participate in routing.

Canonical PeerSet representation is:

sorted ascending by peer_id raw bytes
duplicate peer IDs forbidden

2. Routing Inputs (v1)

Routing is defined as a pure function of:

RoutingParams
PeerSet
shard

2.1 RoutingParams (v1)

Consensus parameters:

routing_version : uint16 MUST be 0x0001
replication_factor : uint8 (R)
routing_salt : bytes[32] (domain separator; fixed for the network)

Constraints:

1 <= R <= |PeerSet|

If the constraint fails, routing MUST fail closed (see Section 7).

3. Canonical Score Function (v1)

Routing uses Rendezvous Hashing (a.k.a. Highest Random Weight), chosen for:

deterministic peer selection
graceful membership changes
no rings / no rebalancing state required

3.1 Score(peer_id, shard)

Define:

score = SHA256( routing_salt || peer_id || le32(shard) )

Interpret score as an unsigned 256-bit integer in big-endian order.

3.2 Tie-breaking

If two peers have equal score (possible only by collision), break ties by:

smaller peer_id (lexicographic) wins

This removes any ambiguity.

4. Route Function (v1)

4.1 routeShard

routeShard(params, peers, shard) -> [peer_id]

Algorithm:

For each peer in PeerSet, compute score(peer, shard)

Sort peers by:

descending score
then ascending peer_id

Return the first R = replication_factor peers

The returned list is the ReplicaSet for that shard, ordered:

index 0 = Primary
indices 1..R-1 = Secondaries

4.2 routeCell

routeCell(params, peers, cell) = routeShard(params, peers, cell.shard)

In v1, cell routing is shard-only.

5. Authority Law (v1)

This law defines which peers may originate authoritative work for a shard.

5.1 Origination

A work item w is authoritative for a cell c iff:

w.workCell == c
the originating peer is in routeCell(..., c).

5.2 Primary vs Secondary

In v1:

Primary is the preferred origin for new work items.

Secondaries MAY originate work if:

they can prove primary unavailability (non-consensus), or
the protocol layer allows secondary origination explicitly

Consensus rule: regardless of who sends it, a work item is only acceptable if its origin is within the ReplicaSet.

(How accepted work is propagated is protocol-layer, not routing-layer.)

5.3 Fail-closed for unknown peers

If a peer not in ReplicaSet attempts authoritative origination for a shard, recipients MUST reject it.

6. Shard Assignment Epoch (v1)

Routing must be bound to a declared peer membership snapshot.

Define:

epoch : uint64
peers : PeerSet
params : RoutingParams

A node MUST treat (epoch, peers, params) as a single immutable routing context.

6.1 Epoch monotonicity

If a node learns of a higher epoch, it MAY adopt it only if:

it has the full PeerSet + params for that epoch, and
the adoption policy is deterministic at the protocol layer

Routing itself is pure: it does not negotiate epochs; it only consumes them.

7. Failure Semantics (v1)

Routing MUST fail closed under any of these conditions:

routing_version != 0x0001
PeerSet is not canonical (unsorted or duplicates)
replication_factor invalid
|PeerSet| == 0
any required bytes are malformed

Fail closed means:

the higher layer MUST treat routing as unavailable and MUST NOT best effort guess routes.

8. Compatibility Law (v1)

Unknown routing versions MUST be rejected.

No downgrade. No partial routing. No closest match.

9. Canonical Encoding (v1)

This section defines the byte-defined canonical form for routing context exchange.

9.1 Routing Context Wire Format

RoutingContext canonical encoding:

routing_version : u16le (must be 1)
epoch : u64le
replication_factor : u8
routing_salt : bytes[32]
peer_count : u32le
peers : peer_count * bytes[32] (in canonical sorted order)

Any violation MUST reject the context.

(Transport framing is out-of-scope; this is payload format.)

10. Compliance Checklist (v1)

An implementation is compliant iff:

- score() matches Section 3 exactly (byte concatenation + SHA256 + interpretation)
- tie-breaking matches Section 3.2
- routeShard selects top-R by score, ordered as specified
- primary is index 0
- PeerSet canonicalization rules enforced
- invalid params fail closed
- routing_version mismatch fails closed
- canonical wire encoding/decoding implemented exactly (Section 9)

11. Notes (Non-normative)

Rendezvous hashing makes shard ownership stable under membership changes, minimizing reassignment churn.

This routing layer intentionally does not constrain scheduler fairness, batch construction, or workset structure.

Routing context distribution is a protocol concern; this doc only defines what the context means.
