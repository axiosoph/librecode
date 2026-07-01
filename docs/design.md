# librecode — Operating Model (the "how")

How the metaharness *operates*: the concrete procedures that realize the principles of
[`foundations.md`](foundations.md). This is the bridge from principle → code — the
devil-in-the-details. It elaborates foundations into procedure; it is **not** the
principle (that is foundations) and **not** the as-built reference (that is the rest of
`docs/`). Where a mechanism is derived but not yet built, it is marked **[design-pending
→ roadmap X]**.

---

## 1 · The campaign lifecycle (the state machine)

A campaign carries a goal through a controlled trajectory. Two context regimes: the
**architecture** phase retains full context; **composition** dispatches into fresh
contexts.

**Architecture (context-retaining):**
1. **Prepare** — arbitrarily complex; research where needed.
2. **Orient + align docs** — apply what prep revealed; reconcile the anchor (AGENTS.md).
3. **Formalize the IBC** — requirements, invariants, constraints, all unknowns
   (known + filed), goal & scope, definition of done. (The IBC is the *transducer*, §5.)
4. **Council architecture + sign-off** *(fresh context)* — decorrelated seats review the
   plan; sign off or remediate (§2). Then hand to the composer.

**Composition (dispatch ⇄ reconcile):** until DAG completion —
1. Execute a DAG layer (conflict-free set in parallel; serialized where surfaces overlap).
2. Monitor / nudge; convene decorrelated assistance on trigger (§2).
3. Maintainer sign-off on the layer's collected work; if not, loop.
4. Merge into the campaign branch; advance the tip.

**Convention (per campaign):** decorrelated seat review (incl. invoked guests) →
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

**Convening trigger (the dual-trigger, §3 of foundations' recurring pattern):** a
**deterministic signal** (a delegation-table decision-type · gate-non-convergence after
N attempts · divergence-from-plan) **+ a model-articulated reason** (why *this* council,
*what* question) — never haphazard (seats are expensive), never missed.

**Decorrelation caveat:** the *ideal* seat set is **cross-model** (disparate θ). Today's
available fallback is **lens-decorrelated personas** (same-model, different lens) — the
degraded form; cross-model seats are **[design-pending → roadmap E]**. Every council
record states which it used.

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

## 7 · Design-pending (the open mechanics)

- **Memory ↔ context** — the LTM (git-backed) / context-map consolidation, accuracy
  verification, retrieval structure. **[→ roadmap C; needs its own dialectic.]**
- **The living loop** — sensor (§6) + actuator (§4) implementation. **[→ roadmap B/D.]**
- **The §8 invariants as a machine-checked spec.** **[→ roadmap A; `/spec` or `/form`.]**
- **Cross-model seats.** **[→ roadmap E.]**
