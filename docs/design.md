# librecode — Operating Model (the "how")

How the metaharness *operates*: the concrete procedures that realize the principles of
[`foundations.md`](foundations.md). This is the bridge from principle → code — the
devil-in-the-details. It elaborates foundations into procedure; it is **not** the
principle (that is foundations) and **not** the as-built reference (that is the rest of
`docs/`). Where a mechanism is derived but not yet built, it is marked **[design-pending
→ roadmap X]**.

---

## 1 · The campaign lifecycle (the state machine)

**Scope is plural by design.** The metaharness governs one or more **commons** — each a
body of stewards plus its many **projects** (repositories); one steward or team may run
several commons at once. Work is organized as focused efforts (campaigns) that may span
one or more projects within a commons. Single-project or single-human operation is a
special case, never an assumption; governance is **plural-human** (multiple stewards are
the human-side decorrelation of `foundations.md §3`).

A campaign carries a goal through a controlled trajectory. Two context regimes: the
**architecture** phase retains full context; **composition** dispatches into fresh
contexts.

**Architecture (context-retaining):**
1. **Prepare** — arbitrarily complex; research where needed.
2. **Orient + align docs** — apply what prep revealed; reconcile the anchor (AGENTS.md).
3. **Formalize the IBC** (Initial Boundary Condition — the sufficient boundary a raw agent
   executes from without drift) — requirements, invariants, constraints, all unknowns
   (known + filed), goal & scope, definition of done. (The IBC is the *transducer*, §5.)
4. **Council architecture + sign-off** *(fresh context)* — decorrelated seats review the
   plan; sign off or remediate (§2). Then hand to the composer.

**Composition (dispatch ⇄ reconcile):** until DAG (directed-acyclic work graph) completion —
1. Execute a DAG layer (conflict-free set in parallel; serialized where surfaces overlap).
2. Monitor / nudge; convene decorrelated assistance on trigger (§2).
3. Maintainer sign-off on the layer's collected work; if not, loop.
4. Merge into the campaign branch; advance the tip.

**Convening (per campaign):** decorrelated seat review (incl. invoked guests) →
remediation / reconciliation / extension. If extended, re-run the DAG loop and
reconvene; else final sign-off, merge, close + cleanup.

Every state transition is journaled (append-only, `force-output`) so the trajectory
reconstructs from the flight recorder alone.

## 2 · The decorrelated roster + council protocol

**Seats:** architect (boundary/goal/strategy), composer (execution/scheduling — the
conductor), lead-maintainer (the merge gate), auditor (process + residue), worker
variants (feature / docs / refine), council-guests (domain experts). The human is the
head / final arbiter.

**Delegation:** each decision-type routes to its owning seat and its required assent
(single / subset / full / human) — the delegation table. Independent-first: each seat
deposits *before* reading a sibling's; correction is relayed through the composer.

**The council scales to arbitrary human stakeholders — it is the concrete commons**
(`foundations.md §5`). Seats are not a fixed panel: the delegation table admits any number of
humans as first-class seats, so a large group project runs as one commons. Each stakeholder
works in their own isolated session (their own harness); the shared append-only statespace gives
every session a **global coherent view** into the others' ongoing work. A **hard human-gated
blocker** — "node X cannot proceed until Alice and Bob both sign off" — is a delegation edge with
required-assent `{alice, bob}`, enforced like any deterministic gate rather than tracked
out-of-band. The metaharness sits *above* any single harness precisely so these stakeholders need
not standardize on one tool. **[Status: the machine-enforced assent/delegation engine —
`convene-council`, `validate-assent`, the human-gated sign-off blockers — is design-pending →
roadmap I; `src/meta/council.lisp` is currently a stub.]**

**Convening trigger (the dual-trigger, §3 of foundations' recurring pattern):** a
**deterministic signal** (a delegation-table decision-type · gate-non-convergence after
N attempts · divergence-from-plan) **+ a model-articulated reason** (why *this* council,
*what* question) — never haphazard (seats are expensive), never missed.

**Decorrelation caveat:** real decorrelation is **cross-model** (disparate θ). Today's
available fallback is **lens-decorrelated personas** (same-model, different lens) — which
provide diverse *surfacing* but **not** error-decorrelation: they share the model's `θ`-floor
(foundations §1), a difference of kind, not degree. Cross-model seats are **[design-pending →
roadmap E]**. Every council record states which it used.

## 3 · Progress, regression, and transitions

**Monotonic proof, regressable plan** (foundations §4). The immutable proof layer only
grows; the working plan can move backward without that being failure.

| Transition | When | Effect |
|---|---|---|
| `accept` | evaluators re-run clean + coherence review passes | ratchet: merge, mark proven |
| `rework` | an evaluator / surface / coherence check fails | delta IBC (error feedback), re-dispatch |
| `skip` (`:skipped`) | node abandoned but siblings independent | terminal-non-blocking, **distinct from accepted** |
| `escalate` | reserved predicate / bounded rework exhausted | surface to human |
| `reset-to-checkpoint` | divergence point demarcated | rewind to a pre-divergence state |
| `cut-clean-and-decorrelate` | basin gone rogue | abandon, re-approach with a **different θ** (decorrelation as *recovery*) |

Selecting a regression transition is **not fully deterministic** — a deterministic
signal detects it; a model (and, at stakes, the human) judges *where* the walk left the
rails and *which* transition applies.

`accept` / `rework` / `skip` / `escalate` are built; **`reset-to-checkpoint` and
`cut-clean-and-decorrelate` are design-pending [→ roadmap I].**

## 4 · The actuator (adaptive attention)  [impl: design-pending → roadmap D]

The loop **never mutates rules** — it **re-derives** attention allocation from the
immutable telemetry each run. The boundary:
- **Auto (reversible-local):** reversible AND non-persistent — this-walk allocation
  (budget more iterations here, deprioritize a thrashing basin for this node) that leaves
  rules and proof intact.
- **Gated (rule-change):** persistent OR redefines a gate — routed through collective-
  choice (the council / human).

**Emergent-regularity safeguard:** **transparency** (derived priorities always visible /
contestable) **+ a dual promotion trigger** — a deterministic recurrence threshold
*flags* a would-be de-facto rule; a non-deterministic judgment *assesses* it; the human
*ratifies*. Combine both because the boundary can't be weighed deterministically — catch
it before it compounds.

**Determinization ratchet (foundations):** scaffolding ∝ *un*certainty. Where certainty
is lowest, deploy the maximum — full council, every check — **and hunt for a *new*
deterministic gate** (an overlooked test, an extractable invariant) that converts the
uncertainty into a permanent check. The deterministic surface grows; the uncertain
frontier recedes. Where certainty is high, ceremony collapses.

## 5 · The human seam

Only three classes of decision are genuinely the human's; the API surfaces exactly these
and nothing else (time is the scarcest resource):
1. **Novelty-bounding** — greenfield outside `⋃_θ`. The human supplies requirements /
   invariants / constraints; the **IBC transducer** converts that (often underspecified)
   intent into a *sufficient boundary* a raw agent executes without drift. The machine's
   failure mode — *acting on insufficient information* — is the thing the IBC prevents.
2. **Divergence-alert** — deviation from a severely-mapped plan alerts the human in
   **real time**; intervene fast, don't wait for close.
3. **Coherence-judgment** — the human quality scalar at close is the ground truth and
   **overrides** agent self-metrics (the human is fallible too — hence measurement, §6 —
   but is the final decorrelation basin against correlated model failure).

**The API is message-first** (all features triggerable by human prose) and *is* the
daemon↔UI protocol **[design-pending → roadmap F: Rust/ratatui client]**.

**Reporting discipline:** agents are primed to know their own arsenal and owe
**generative** reports — not only *what was done*, but the trade-offs, decisions-and-why,
goal-fit, **and suggestions that spark** the human. This is what makes the human's catch
of a *correlated* hallucination cheap.

## 6 · Coherence measurement (the sensor)  [impl: design-pending → roadmap B]

A **dense deterministic telemetry bed** — iterations-to-gate, rework / escalation /
gate-fail rates, decorrelation rounds — sliced by basin / **content-type** / node /
project / time, **anchored** by the sparse authoritative **human quality scalar**.
Content-type carries a drift-risk gradient — **agent-scaffolding (extreme) > code (very
high) > docs** — which maps to gate strength (congruence). One signal
(iterations-to-convergence) serves three uses: coherence health · the §2 convening
trigger · adaptive attention (§4).

**Caveat (`foundations.md §3`):** convergence is *not* health on novel work — correlated
hallucination presents as fast, confident agreement. The novelty trigger therefore also
uses a signal **independent of convergence** (cross-*substrate* disagreement, or a human
spot-check), and confident-fast-agreement on novel work routes **to the human**.

## 7 · Design-pending (the open mechanics)

- **The council assent engine** — machine-enforced delegation/sign-off (`convene-council`,
  `validate-assent`, human-gated blockers); `src/meta/council.lisp` is a stub. **[→ roadmap I.]**
- **The regression transitions** `reset-to-checkpoint` and `cut-clean-and-decorrelate` (§3).
  **[→ roadmap I.]**
- **Memory ↔ context** — the LTM (git-backed) / context-map consolidation, accuracy
  verification, retrieval structure. **[→ roadmap C; needs its own dialectic.]**
- **The living loop** — sensor (§6) + actuator (§4) implementation. **[→ roadmap B/D.]**
- **The §8 invariants as a machine-checked spec.** **[→ roadmap A; `/spec` or `/form`.]**
- **Cross-model seats.** **[→ roadmap E.]**
- **The augmentation seam** — how metaharness governance reaches an opencode-compatible
  runner via **hooks the runner exposes** (the runner runs standalone as pure-opencode;
  the metaharness is an *optional* consumer, and the runner depends on nothing), and how
  extensible opencode already is. **[→ roadmap G; open prior-art unknown.]**

---

## Doc conventions (single source of truth)
A fact lives in one place: invariant *status* is owned by `AGENTS.md`; the transition
ladder by §3 here; principles by `foundations.md`; the plan by `docs/roadmap.md`.
Everything else references it. Roadmap cross-references use each workstream's stable
letter-ID; those IDs are never renumbered.
