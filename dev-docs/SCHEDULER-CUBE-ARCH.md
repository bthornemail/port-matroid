SCHEDULER-CUBE-ARCH.md

Version: 1.0
Status: Non-normative commentary for SCHEDULER-CUBE v1

---

1. Purpose

This document explains the scheduler/cube engine at a systems level.
It complements SCHEDULER-CUBE.md but does not define consensus law.

---

2. Where the Scheduler Fits

Snapshot layer defines state.
ISA defines legal transitions.
Scheduler defines which transitions execute, in what order.

The scheduler is a deterministic policy machine.
It does not mutate snapshots. It outputs a canonical instruction batch.

---

3. Cube Intuition

Cells are regions in (shard, time, entity-range, tier).

Work items are attached to exactly one cell in v1.
Scheduling is a merge of ordered queues across cells.

This mirrors CSPT regions and reconciliation logic.

---

4. Determinism Notes

All selection is based on canonical bytes and explicit comparator keys.
Tie-breaking uses work_id and cell ordering, not insertion order.

---

5. Atomic Work Items

WorkItem atomicity keeps replay simple:
either the whole stream runs, or none of it runs.

Partial rescheduling is deferred to v2.

---

6. Conflict Avoidance

v1 forbids overlapping TouchSets in a batch.
This avoids nondeterministic interleavings and simplifies replay law.

---

7. Future Extensions (Non-normative)

Possible v2 directions:
- partial work item consumption
- multi-cell work items
- aging/priority decay
- Merkleized workset exchange

These are intentionally out of scope for v1.
