SCHEDULER-CUBE.md

Version: 1.0.0
Status: DRAFT — candidate for freeze after implementation
Depends on:
- SNAPSHOT-FORMAT v1
- UNIVERSE-ISA v1
- UNIVERSE-ARCHITECTURE v1

---

1. Purpose

This document defines the deterministic scheduler/cube engine.

It is a pure function that selects an ordered instruction stream from a
workset under explicit policy parameters.

Scheduler output is consensus-critical.

---

2. Deterministic Scheduling Law

Given identical inputs:

canonical snapshot bytes
canonical workset bytes
canonical policy parameters bytes
canonical scheduler-state bytes

all compliant implementations MUST output:

identical chosen instruction batch bytes
identical next scheduler-state bytes

No host time, randomness, container iteration order, or hash-map iteration
may influence results.

---

3. Cube / Cell Model

3.1 Cell Definition

Cell = (shard, t0, t1, e0, e1, tier)

shard : u32
t0    : u64 (inclusive)
t1    : u64 (exclusive)
e0    : i64 (inclusive)
e1    : i64 (inclusive)
tier  : u8

Cells are ordered canonically by:
(shard asc, tier asc, t0 asc, t1 asc, e0 asc, e1 asc)

Tier direction (v1): lower tier runs first.

3.2 Touch-Set Rule

Each WorkItem has a TouchSet of entity IDs (and optionally component keys).
A WorkItem is valid for a Cell iff:

TouchSet entities ⊆ [e0..e1]

If not, scheduling MUST fail with SCH_ERR_OUT_OF_RANGE.

---

4. WorkItem Definition

4.1 Canonical Fields (v1)

work_id      : 32 bytes (opaque canonical id)
cell         : Cell
deadline_tick: u64 (use maxBound if unused)
priority     : u32 (higher wins)
cost         : u32 (deterministic cost units)
instrstream  : bytes (canonical instrstream bytes)

WorkItem is atomic in v1: either all instructions run or none.

4.2 Work Ordering Key

Comparator key tuple:

1. tier (ascending)
2. priority (descending)
3. deadline_tick (ascending)
4. cost (ascending)
5. work_id (lexicographic ascending)

---

5. Scheduler State

5.1 Cursor

SchedulerState contains a cursor over cells:

cursor_cell_key : bytes (canonical encoding of last chosen cell)

The next scheduling round starts scanning from the next cell after cursor in
canonical cell order.

---

6. Batch Formation

6.1 Slice Budget

SchedulerParams include:

slice_budget : u32 (total cost units)
max_skip     : u32 (max conflicts skipped per batch)
max_work     : u32 (max work items inspected per batch)

6.2 Algorithm (v1)

1. Validate all WorkItems (structure + TouchSet rule).
2. Group WorkItems by Cell; order each cell queue by the comparator key.
3. Enumerate cells in canonical order starting from cursor.
4. Perform a deterministic k-way merge of the top WorkItem from each eligible cell.
5. Append WorkItems until adding the next would exceed slice_budget.
6. Enforce conflict rule (6.3). If a candidate conflicts, skip deterministically.
7. Emit batch instrstream as concatenation of WorkItem instrstreams in chosen order.
8. Update cursor to the last chosen cell (or unchanged if no work chosen).

6.3 Conflict Rule (v1)

Within a batch, two WorkItems MAY NOT overlap in TouchSet entities.

If a candidate conflicts with already chosen WorkItems:
- it may be skipped
- total skips MUST NOT exceed max_skip
- if max_skip is exceeded, scheduling halts with SCH_ERR_LIMIT_EXCEEDED

6.4 Deterministic Skip Rule

Skips are counted in canonical order of candidates.
No backtracking is permitted.

---

7. Canonical WorkSet Law (v1)

WorkSet input order is non-semantic.
Scheduler MUST behave as if the WorkSet were sorted by the Work ordering key,
with work_id as the final tie-breaker.

Permutation invariance is consensus-critical:

schedule(workset) == schedule(shuffle(workset))

---

8. Cell Overlap Rule (v1)

Two cells are invalid if they overlap in shard, tier, time, and entity ranges:

shard equal
t0 < other.t1 and other.t0 < t1
e0 <= other.e1 and other.e0 <= e1
tier equal

Overlapping cells MUST be rejected with SCH_ERR_INVALID_CELL.

---

9. Budget Monotonicity Law (v1)

Budget exhaustion is not an error. It produces a prefix batch.

If budget1 < budget2, then:

batch(budget1) is a prefix of batch(budget2)

---

10. Skip Semantics Law (v1)

Conflict skipping is non-destructive.

If a work item is skipped due to a touch conflict:
- it MUST remain eligible for future scheduling
- it MUST NOT be dropped
- it MUST NOT be mutated

Skipping only affects the current batch.

---

11. Scheduler Error Wire Format (v1)

Scheduler errors have a canonical 16-bit little-endian wire encoding.
Only the numeric code is consensus-critical.

0x0001 SCH_ERR_LIMIT_EXCEEDED
0x0002 SCH_ERR_INVALID_CELL
0x0003 SCH_ERR_OUT_OF_RANGE
0x0004 SCH_ERR_DUPLICATE_WORKID
0x0005 SCH_ERR_MALFORMED_WORK
0x0006 SCH_ERR_INTERNAL

Any diagnostic payload is non-consensus.

---

12. Scheduler Error Priority (v1)

If multiple errors apply, the returned error MUST be the highest priority:

1. SCH_ERR_INVALID_CELL
2. SCH_ERR_OUT_OF_RANGE
3. SCH_ERR_DUPLICATE_WORKID
4. SCH_ERR_MALFORMED_WORK
5. SCH_ERR_LIMIT_EXCEEDED
6. SCH_ERR_INTERNAL

Error choice is deterministic.

---

13. Touch Projection Binding (v1)

Touch-set extraction is bound to ISA opcode semantics.
If a new opcode touches entities, the scheduler MUST be updated in lockstep.
Unknown opcodes MUST be treated as touching nothing.

---

14. Fairness Scope Disclaimer (v1)

Scheduler fairness is guaranteed only within a single batch.
Long-term fairness across batches is NOT consensus-critical.

Implementations MAY differ in:

queue persistence
retry timing
starvation mitigation

As long as batch determinism is preserved.

---

15. Scheduler Identity Law (v1)

Scheduler output is uniquely determined by:

(snapshot, canonicalWorkSet, params, state)

No external entropy is permitted.

---

16. Scheduler Errors (v1)

SCH_ERR_LIMIT_EXCEEDED   = 0x0001
SCH_ERR_INVALID_CELL     = 0x0002
SCH_ERR_OUT_OF_RANGE     = 0x0003
SCH_ERR_DUPLICATE_WORKID = 0x0004
SCH_ERR_MALFORMED_WORK   = 0x0005
SCH_ERR_INTERNAL         = 0x0006

Error priority order:

1. SCH_ERR_INVALID_CELL
2. SCH_ERR_OUT_OF_RANGE
3. SCH_ERR_DUPLICATE_WORKID
4. SCH_ERR_MALFORMED_WORK
5. SCH_ERR_LIMIT_EXCEEDED
6. SCH_ERR_INTERNAL

Errors MUST be deterministic and consistent across implementations.

---

17. Canonical Encoding (v1)

All scheduler inputs/outputs are canonical bytes.
If a scheduler input is non-canonical, scheduling MUST fail with SCH_ERR_MALFORMED_WORK.

---

18. Compliance Checklist (v1)

- Deterministic Scheduling Law enforced
- Work ordering key comparator enforced
- Conflict rule enforced
- Atomic WorkItem semantics enforced
- Error priority order enforced
- Canonical encoding enforced
- Canonical workset ordering enforced
- Cell overlap rule enforced
- Budget monotonicity enforced
- Skip semantics enforced
- Error wire format enforced
- Touch projection binding enforced
- Scheduler identity law enforced

---

END OF DRAFT
