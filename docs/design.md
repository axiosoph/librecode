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

**A forge is not the assent engine.** A git forge's review/approval UI may *evidence* a
human sign-off — worth mirroring outbound (roadmap I) — but forge state is mutable
(reviews get dismissed, comments edited), so it cannot be the record of assent; the
journal is. Where a forge integration exists, an approval event is translated into a
journal entry, never trusted as the entry itself. (Full argument: `foundations.md`, "The
null hypothesis.")

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

**Determinization ratchet — the self-governing loop (`foundations.md`):** the actuator's
persistent output is edits to the harness's own **prose procedures** and **contracts**,
committed to versioned, scoped basins (default ⊕ commons ⊕ project ⊕ operator). Vocabulary:
- **Prose procedure** — the actionable means (*do X, then Y*); freely refinable guidance.
- **Contract** — the declarative target: a typed record with a slot per step, whose filled
  instance must type-check and meet its invariants or fail unambiguously.
- **Deposit** — the machine-written *filled* contract (the agent's record of its work); the
  audit trail and the checked object are one.
- **Gate** — the act that enforces a contract against a deposit.

Two cross-session signals (§6) drive it: *repeated failure to fill a contract* ⇒ the prose is
too coarse, refine it; *a recurring un-contracted area* ⇒ reify a new contract. An **immutable
core of contracts** (the §8 static invariants) cannot be modified at any scope; scoped
contracts add within it, never relax it. Promoting a refinement into the shipped default — or
editing the core — is the **dual promotion trigger** above: privileged, human-ratified.

**Verification is a cost-ordered pipeline.** The gate is the cheap first line: the harness runs
the contract (and re-runs any evaluator a deposit names) in milliseconds to decide whether the
worker did what it said, *before* spending a decorrelated council seat or a human minute. The
asymmetry is what makes it safe to automate — a contract *failure* is unambiguous, so it
**auto-reprompts**, targeted by exactly which slot failed; a contract *pass* is
necessary-not-sufficient, so it **earns** review of the subtleties a contract cannot see, not
acceptance. The cheap tier culls; the expensive tier judges. The reprompt loop is bounded (the
recovery ladder); *persistent* fill-failure is itself the ratchet signal — finer prose, or
escalate.

**Contracts as review substrate.** For that soft path, the reviewer reads the deposit's prose
reasoning against the *co-located* evidence the same contract carries — catching a glaze that
contradicts its own evidence, which is harder to fake than either half alone. Fill-*thinness*
relative to a step's demand is a heat map for review attention: a mechanical flag that points a
**decorrelated** reviewer (a same-`θ` reviewer is fooled by fluent glaze), never an auto-verdict.

**Contract language — decided: Nickel.** The choice is settled, not open. Its decisive property
is contract-abstraction *at the type level* with arbitrary, Turing-complete runtime predicates,
**composable like types** (`all_of [Dag, DagNoConflict]` — two graph algorithms composed into one
contract-type): "a valid DAG" becomes a *type*, enforced at the boundary, for a domain whose
invariants *are* arbitrary computations over machine-written data. It also ingests multiple
formats (YAML/JSON/TOML) and evaluates purely. The external-binary property is **load-bearing,
not a wrinkle**: one `nickel export` is the identical gate in the harness, in CI, and at the
commit hook — single-source-of-truth *enforcement* (no drift between what each layer checks) and
the ledger's integrity validated at write time (a violating deposit cannot enter **proven**
history — in degraded mode deposits land quarantined and unproven, never proven-then-retracted;
see §7). A
native Common Lisp DSL is **the wrong direction**, not merely a high bar: in-process, its one
advantage (no external dependency) is the liability — it binds contracts to the harness runtime,
loses the CI/commit gates, and its in-language convenience invites verifying *imperatively in the
harness*, collapsing the trusted-checker/untrusted-data separation that Nickel's foreignness
enforces for free. The honest cost is real but cheap: Nickel must be present and version-pinned
wherever gates run — and where it is **absent the system degrades (validation deferred), never
fails** (§7).

## 5 · The human seam

The API surfaces exactly the human-owned decisions and nothing else (time is the scarcest
resource). The authoritative enumeration is the **delegation table** (§2) — which includes
ratifying contract/core promotions (§4) and selecting regression transitions at stakes (§3) —
and three seam classes dominate its traffic:
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

Two further signals feed the self-governing loop (§4), and both need the metaharness's
**cross-session vantage**: *repeated contract-fill failures* on a procedure (⇒ its prose is
too coarse) and *recurring un-contracted patterns* (⇒ a candidate for a new contract). No
single session can see either; only the harness watching many walks can.

**The sensor must be two-sided.** Every signal above measures *friction* — and a
**false-accepting** gate (a wrongly-specified contract passing what it should fail) produces
*less* friction, reading as improved health while it silently mis-verifies every deposit on a
surface the ratchet's economy has removed human review from (`foundations.md`, the ratchet).
Two counter-instruments are part of the schema from the start, not retrofits: **periodic
decorrelated audit-sampling of gate-*passed* deposits** (a small random fraction re-reviewed
by a decorrelated reviewer), and **close-time attribution** — when the human quality scalar
judges a campaign poorly, trace which contracts passed the offending work and flag them for
re-scrutiny.

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
- **Contract *shaping* — a clean approach found; remaining work is per-contract.** A full
  contract is not satisfiable on the first or second commit, yet the gate should still run and
  pass on *what is done so far*. Two parts.
  - **Representation:** a typed **phase enum** + a single *static* contract that reads the phase
    and recursively requires only the slots due *up to it*, later slots optional (**typestate** —
    Strom & Yemini 1986; cf. typed holes / Hazel, gradual typing, ratchet-CI — in the exact idiom
    `findings.ncl` already uses: inspect the value, conditionally require). The phase enum is the
    coarse skeleton of the prose procedure, so defining it falls out of writing the procedure.
  - **Integrity:** at authoritative gates the phase is **not the agent's to set** — the commit
    gate/hook derives it *deterministically from execution state* ("layer 3, commit 3", read off
    the DAG) and overrides any value the deposit declared; an agent-declared phase is **advisory**
    only (self-description, or a manual "check myself" when stuck). This makes monotonicity **free**
    (the DAG position only advances) and closes the fudge-the-inputs hole — the agent supplies
    work, never the terms of its own checking (generalizes to *all* contract parameters at gates).
  - Completion separates cleanly: the contract certifies "valid up to phase K," the plan holds the
    target phase, done = *reaches target ∧ passes*. **Remaining (per-contract, not systemic):**
    each contract's phase enum and the map from DAG position to it; plus *deferred* validation
    (below), the in-time complement of the same frontier. **[largely resolved.]**
- **Graceful degradation of the checker — semantics decided.** Nickel composes *loosely*:
  where it is absent the system continues **degraded** rather than hard-failing, with exact
  precedence: deposits land durably but **quarantined `validation-pending`**, and the DAG phase
  **does not advance past a gate on a pending deposit** — degradation defers *proof
  advancement*, never proof-then-retract. Discharge (when the checker returns) either advances
  the phase or reverts the pending node to rework; a failed discharge loses nothing proven, so
  §3's monotonic-proof invariant is unconditional in both modes. The degradation is **recorded,
  never silent** (pending marks in the ledger; the operator surfaced). What degraded mode costs
  is ratchet advancement, not work capture. **Contract non-termination is a fail:** a contract
  predicate that diverges or exhausts its resource budget on a deposit is treated as a **gate
  failure** (bounded timeout → fail → the normal reprompt/escalate path), never as a pass and
  never as a third state — conservative, and it preserves §4's unambiguous-failure asymmetry.
  **[remaining: implementation in J.]**
- **The §8 invariants as a machine-checked spec.** **[→ roadmap A; `/spec` or `/form`.]**
- **Cross-model seats.** **[→ roadmap E.]**
- **The augmentation seam** — how metaharness governance reaches an opencode-compatible
  runner via **hooks the runner exposes** (the runner runs standalone as pure-opencode;
  the metaharness is an *optional* consumer, and the runner depends on nothing), and how
  extensible opencode already is. **[→ roadmap G; prior-art unknown resolved 2026-07-05 —
  MCP-first ruling, survey record in `.scratch/opencode-seam-survey-2026-07-05.md`.]**
- **The harness supervision contract + one-event calculus** — reifying supervision as
  conditions/restarts advertised over the wire, and unifying the two event spines at the
  governance level. Ratified 2026-07-05: one governance *calculus* (the model's
  vocabulary), not one *log* — the runner's session event log stays walk-interior;
  scope, contingencies, and the named open design items live in roadmap K. **[→ roadmap K.]**
- **The gate-harness contract protocol** — boundary design ratified 2026-07-05 (full
  record: `.scratch/campaign-6-one-calculus/gate-harness-protocol-proposal-2026-07-05.md`).
  The DAG gets the same two-tier treatment as the deposit-gate degradation above: a
  Lisp-native, always-available structural floor (`src/model/dag.lisp`) becomes the
  load-bearing runtime scheduler; Nickel's `Dag`/`DagNoConflict` become optional Tier-2
  enrichment (conflict-freedom, discipline validation), never a hard dependency for DAG
  correctness at charter or mid-campaign amendment. Vocabulary corrected: deposit (data)
  ≠ contract (the Nickel checker) ≠ verdict (a checker's output) — `src/model`'s `deposit`
  struct is a mis-named verdict, renamed when J lands. Implementation and the concrete
  file-level deltas are workstream J's own scope; the full ruling lives in
  `docs/roadmap.md` §J. **[→ roadmap J.]**

---

## Doc conventions (single source of truth)
A fact lives in one place: invariant *status* is owned by `AGENTS.md`; the transition
ladder by §3 here; principles by `foundations.md`; the plan by `docs/roadmap.md`.
Everything else references it. Roadmap cross-references use each workstream's stable
letter-ID; those IDs are never renumbered.
