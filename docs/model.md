# librecode-model — the reference state machine

The pure applicative reference model of the metaharness's core state machine
(roadmap workstream A's first piece; the spine workstream J sits on). It is
**not** the runtime — `src/runner/` and `src/meta/` are the threaded CLOS
harness — it is the precise, checkable definition of *what correct means*
that the runtime will later be conformance-tested against (see "The
conformance seam" below). Lives in `src/model/` (`librecode-model` system,
dependency-free, no CLOS, no threads); tests in `t/model-tests.lisp`.

## The state-machine picture

**Work DAG** (`dag.lisp`) — a list of `dag-node` (id, dependency ids).
`make-dag` is the *only* constructor and validates id-uniqueness, referential
integrity, and acyclicity before ever returning a `dag`; every other function
that receives one may assume it is valid without re-checking. `dag-layers`
derives the Kahn schedule (a list of alphabetically-sorted parallel layers).

**Node status** (`state-machine.lisp`) — the regressable plan-level
lifecycle:

```
:queued --dispatch--> :dispatched --land--> :landed
                                                |
                          +---------------------+----------------------+
                          |                                            |
                  (gated: checker present)                 (degraded: checker absent)
                          |                                            |
                 gate-check :pass  ---------> :proven          quarantine ---> :quarantined
                 gate-check :fail/:timeout -> :rework                          |
                                                 |                    +--------+--------+
                                                 |                    |                 |
                                          re-dispatch          discharge :pass   discharge :fail
                                                                       |                 |
                                                                    :proven         :rework

  (from any non-terminal status: skip -> :skipped, escalate -> :escalated — both terminal)
```

`:proven`, `:skipped`, and `:escalated` are **absorbing** — every transition's
precondition excludes them as a starting status, so once reached, no further
event ever touches that node. This one structural fact is what makes several
of the invariants below hold *by construction* rather than by separately
proving them.

**Phase** — a per-node non-negative integer that only `gate-check` and
`discharge` ever touch, and only ever by `(1+ current-phase)`. The
agent-driven events (`dispatch`, `land`, `skip`, `escalate`) never read or
write it, and the API gives no way for a caller to supply a phase value at
all — it is always derived internally. This reconciles "monotonic proof,
regressable plan" (`docs/design.md` §3: `status` regresses via `rework`) with
"the DAG phase only advances" (`docs/design.md` §7): they are different
fields, and only one of them is a plan-level status that can move backward.

**Deposit** — a node's landed work as gated: `validation-state` (`:pending`
`:proven` `:failed`) and `gate-mode` (`:gated` `:degraded`), stamped with the
phase at creation or last resolution. **Naming debt:** the gate-harness-protocol
design (`.scratch/campaign-6-one-calculus/gate-harness-protocol-proposal-2026-07-05.md`
§1) corrects the vocabulary this document predates — deposit (a static data
artifact) ≠ contract (the Nickel checker) ≠ verdict (a checker's output). This
struct is a *verdict*, not a deposit; `deposit → verdict` is a mechanical
rename deferred to workstream J (see `docs/roadmap.md` §J), bundled with
introducing the real deposit-data artifact. Kept as `deposit` here until then.

**Event log** — append-only, oldest-first: `(:dispatched id)`
`(:landed id)` `(:gate-checked id result)` `(:quarantined id)`
`(:discharged id result)` `(:skipped id)` `(:escalated id)`
`(:surface-widened id new-surface)`. `transition-event`
is the single fold primitive every transition and `replay` route through —
state is a fold over the log, never a store consulted independently of it.

**Transitions** — `dispatch`, `land`, `gate-check`, `quarantine`,
`discharge`, `skip`, `escalate`, `widen-surface`. Every one is total: `(values new-state
outcome)`, where `outcome` is `:ok` or `(:rejected reason)`. An illegal call
(wrong status, an unmet dependency, an unknown node) never signals — it
leaves state untouched. The only place this model signals a Lisp `error` is
`transition-event` given a malformed event referencing a node absent from the
DAG: that is a log-integrity violation, not a legal-domain rejection. The
runtime's journal reconciliation (`apply-journal-entry`,
`src/meta/journal.lisp`) shares this signal literally, not merely by analogy:
four of its six event kinds (`:node-dispatched`/`:node-landed`/`:node-skipped`/
`:surface-widened`) route directly through `transition-event`, so the same
condition fires there — one code path, not two implementations kept in sync
by hand. The remaining two kinds (`:node-accepted`/`:node-rework`) stay
journal-only bookkeeping, not yet calculus-conformant (workstream J).

## The three decided edge cases

These were settled in `.scratch/decorrelated-review-2026-07-01.md` (F1/F2)
before this model was built, and are exercised as example tests in
`t/model-tests.lisp`, not merely asserted:

1. **Degraded-mode discharge failure.** `quarantine` lands a deposit durably
   but `:pending`; the phase does not advance past that gate while pending.
   A failed `discharge` reverts the node to `:rework`, **losing nothing
   proven** — trivially true here, since it was never `:proven` to begin
   with.
2. **Non-terminating contract = fail.** `gate-check` accepts `:timeout` as a
   third result value but folds it into exactly the same branch as `:fail`
   (`:rework`, deposit `:failed`) — never a pass, never a third state.
3. **Degraded quarantine blocks a dependent.** A `:quarantined` node is
   durably recorded but not `:proven`, so a dependent's `dispatch` is
   rejected `:dependencies-not-proven` — the DAG phase genuinely does not
   advance past a pending gate.

## The five crown-jewel invariants

Defined in `invariants.lisp`, each a pure function of `(dag events)` — a
trajectory, not a single snapshot, because monotonicity and tamper-evidence
are properties of a *history*, not a state in isolation. Each reconstructs
via `transition-event`/`replay` alone, which is what lets any of them run
unchanged against a recorded runtime trace (see the conformance seam below).

1. **Phase monotonicity** (`phase-monotonic-p`) — no reachable event
   sequence lowers a node's phase. Checked directly: across the trajectory,
   every node's phase is non-decreasing. Holds by construction (phase is
   only ever `(1+ previous)`, never agent-suppliable), and this predicate
   verifies the implementation actually honors that.
2. **No pending marked proven** (`no-pending-proven-p`) — no reachable state
   has a `:validation-pending` deposit on a `:proven` node. Checked at every
   point of the trajectory, not just the end, so a transient violation
   mid-run cannot hide behind a clean final state.
3. **Tamper-evidence** (`tamper-evident-p`) — every `:proven` mark is
   justified by a gate/discharge event whose parameters were machine-derived.
   Half of this is true by construction: `gate-check`/`discharge` take only a
   node id and a pass/fail/timeout result — there is no phase parameter for
   a caller to forge. What the predicate checks is the other half,
   reconstructibility: a `:proven` node must trace to a logged `:pass` event
   for it. Because `:proven` is absorbing, any such logged event is
   necessarily the one that produced the final mark — no phase bookkeeping
   is needed to disambiguate "which" pass event.
4. **DAG soundness** (`dag-preserved-p` + `schedule-correct-p`) — DAG
   structure (node set, dependency edges) is preserved by every transition
   (no transition ever rewrites it), and the schedule is correct: a node's
   `dispatch` is legal only once every dependency was already `:proven` in
   the immediately-preceding state.
5. **Plan-surface monotonicity** (`surface-monotonic-p`) — closes a blind
   spot `dag-preserved-p` leaves open: that predicate compares only the
   DAG's node-id set, not any other `node-state` field, so it would not
   catch a `file-surface` that shrinks or becomes malformed. `widen-surface`
   unions a node's surface before emitting its event, so this holds by
   construction on the safe API path; this predicate checks it against the
   log directly, the same `(dag events) -> boolean` shape as the other four,
   so a raw/malformed event (as a real runtime's logged journal might
   contain) is still caught rather than assumed away.

All five are shipped as `check-it` property tests over randomly generated
(including illegal) operation sequences, not merely asserted against
hand-picked examples. One adversarial finding surfaced while building that
suite is worth recording: a generator that includes `skip`/`escalate` (both
legal from *any* non-terminal status) drives nearly every node to a
terminal, non-`:proven` end within its first several steps, which would make
invariants 2 and 3 pass *vacuously* — green because `:proven` states were
essentially never reached, not because they were checked and held. The test
suite therefore also runs invariants 2 and 3 against a second generator that
excludes `skip`/`escalate` and runs much longer, plus a direct sanity check
(`test-property-proven-nodes-actually-occur`) asserting the reach-`:proven`
rate is actually high under that generator — so a future edit that
accidentally starved this coverage again would be caught rather than
silently passing.

## The conformance seam

The model consumes exactly the event vocabulary above — the same shape the
runtime's own event log (`src/runner/event-store.lisp`,
`src/meta/journal.lisp`) already journals its transitions in. `replay` folds
`transition-event` over a `dag` and an event list to reconstruct a
`model-state` from the log alone, with no other input — "state is a fold
over the log," never a store consulted independently of it. This seam is
wired, not hypothetical: `apply-journal-entry` routes the calculus-conformant
event kinds through `transition-event` directly as it replays a campaign's
journal (no separate translation step to build), and `run-campaign` runs the
crown-jewel invariants against the replayed `(dag, events)` trajectory as a
**resume boot-gate**, before any node dispatch — a trajectory that violates
one refuses to resume rather than continuing past a corrupted or tampered
log (`librecode-runner.conditions:journal-invariant-violation`; see
`t/journal-tests.lisp`'s `test-journal-boot-gate-invariant-violation`).
Divergence between what the runtime actually did and what this model says is
legal is exactly what this boot-gate catches.

This is also why every transition routes through the single
`transition-event` primitive rather than each maintaining its own
state-update logic: a live call (`dispatch`, `gate-check`, ...) and a
replayed event produce the identical resulting state by construction, not by
coincidence kept in sync by hand. `t/model-tests.lisp`'s
`test-replay-reconstructs-live-state` checks this directly — replaying a
live run's own recorded event log reproduces that run's exact final state.

## Deliberately deferred

Per this workstream's own scope: a typed embedding (Coalton) and a separate
machine-checked proof layer (ACL2). The invariants are tractable to
discipline (totality, exhaustive case analysis) plus property tests, and a
proof over a separate model would not reach the running code. Keeping every
invariant a first-order predicate over plain data leaves both doors open at
zero cost, should one ever prove worth opening.
