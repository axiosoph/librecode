# librecode — Foundations

The first-principles derivation of what librecode's metaharness *is* and what "stable"
*means* for it. This is the design bedrock the code must map onto (see **Completeness
discipline**); it specifies, it does not persuade (that is `MANIFESTO.md`) and it does
not describe the as-built system (that is the rest of `docs/`).

---

## Positioning

Agent harnesses (opencode and kin) have an informal, nearly-formalized grasp of
progress in **focused microcosms of concern** — one session, short horizon, a bounded
task. That problem is essentially understood; librecode's **runner** reimplements it.

What is missing — in the field at large — is a formalization of **coherent progress on
long-horizon work and large, long-timespan goals.** Companies, movements, and commons
all do this procedurally. We take the **commons** as the purest distillation of those
principles (superior goods, least *a priori* structural bias) and use it to bound the
system. librecode's **metaharness** is the first attempt to formalize this layer —
which is why, unlike the runner, its stability has no external spec and must be derived
here.

---

## The derivation

Everything follows from one axiom; each link is an *entailment*.

### Axiom — two stochastic walkers
The **machine** (LLM) is a stochastic walker **bounded** to `support(P(·|θ))` — it
samples only within its model `θ` (training + fine-tuning + safeguards). The **human**
is a stochastic walker **unbounded** by any known `θ`.

### 1 · Decorrelation Theorem — why disparate models
Error splits into a **variance** term (sensitivity to prompt/lens, cancellable) and a
**θ-bias** term (systematic, invariant across conditioning). Same-model "decorrelation"
has a **hard floor**: it cancels variance but leaves θ-bias, so errors stay correlated
*through* `θ`. Only **disparate models** break the floor; the total reachable space is
`⋃_θ support(P(·|·,θ))`, strictly larger than any single model. (Ensembles need diverse
base learners, not one learner with varied inputs.)

### 2 · Freedom is the enabling condition of the math
`⋃_θ` is reachable only by composing *competing* vendors — which no incumbent is
incentivized to build (lock-in is anti-decorrelation by construction). So the
superior architecture is structurally unbuildable by any incumbent; it requires a
**vendor-neutral, libre** layer. Freedom is what *lets the math be reached*, not an
ideological addendum.

### 3 · The human/machine division — and its transducer
Being *unbounded*, the human alone reaches **outside `⋃_θ`** (genuine novelty), is the
**different-substrate final check** against *correlated* ensemble failure, and is the
best judge of **coherence/meaning**. So the **human operates ON the basin** (sets,
moves, overrides, judges); the **machine walks WITHIN it.** Made precise:
- **No perfect judge.** The human is fallible too. There is no infallible oracle —
  which is the entire justification for measurement (§6).
- **Judgment is split:** deterministic gates judge the *mechanical*, the human judges
  the *meaningful* — together, the **Verification Dual**.
- **The IBC is the transducer.** Human intent is often *underspecified*, and the
  machine's failure mode is *acting on insufficient information* → drift. The IBC
  converts unbounded-but-underspecified intent into a *sufficient boundary* a raw agent
  executes without context drift. It is the concrete human→machine handoff.

### 4 · Tragedy of the commons — why a deterministic bounding layer
Uncoordinated stochastic walkers **deplete a shared resource**. The resource is
**dual**: (a) the **coherence/integrity of the artifact** (protected classically by the
four freedoms), and (b) the **robustness of the commons and its people** (the Ostrom
half the freedoms omit — protected by *measurable substance*, §6, not weaponizable
rhetoric). Drift and hallucination deplete both. The response is a **deterministic
bounding layer** whose state is an **append-only, immutable, replayable statespace** —
which is also the **context substrate** (context is *reconstructed, not recalled*).
Proof is **monotonic** (a passed gate never silently un-passes; a proven deposit is
never lost); the **plan is regressable** (reset-to-checkpoint, or cut-clean-and-
decorrelate — making decorrelation an *error-recovery* mechanism, not only detection).

### 5 · The layer = Ostrom governance ⊕ decorrelated production
Elinor Ostrom empirically identified the principles of long-enduring self-governed
commons. **The bounding layer is Ostrom's eight principles reified as machine-enforced
state** — the *governing* half — composed with the disparate-`θ` decorrelation of §1–3
— the *productive* half. Neither alone is the layer.

| Ostrom principle | Reified as | Status |
|---|---|---|
| Clear boundaries | IBC + `file_surface`; authority gate | built |
| Graduated sanctions | recovery ladder (retry→rework→skip→escalate) | built |
| Monitoring by accountable monitors | gates + process-auditor + maintainer + hooks | built/partial |
| Nested / polycentric | goal-nesting; alignment-to-parent | built |
| Collective-choice | DAG amendment; architect revising the IBC | partial |
| Conflict-resolution | council delegation table; decorrelated review | partial |
| Congruence (cost ∝ benefit) | ceremony ∝ task; gate strength ∝ drift-risk | partial |
| Right to organize (no external authority undermines) | freedom; runner stands alone; no lock-in | stance |

Ostrom *described*; we make it *prescriptive and enforced*. (Predicate wanted this but
could not enforce it in prose — its unenforceable ambitions are the requirement set.)

### 6 · The living coherence loop — measurement without an oracle
Because there is no perfect judge (§3), a static layer is insufficient: the CPR's health
must be **measured** and attention **adapted** where it degrades. A **dense
deterministic telemetry bed** (iterations-to-gate, rework counts, escalation frequency,
gate-fail rates, decorrelation rounds — sliced by basin/content-type/node/project/time)
is anchored by the sparse but **authoritative human quality scalar** (the human
overrides agent self-metrics).

- **Iterations-to-convergence is one signal, three uses:** longitudinal coherence
  health · the **novelty/uncertainty trigger** for the council (non-convergence ⇒ near
  the `⋃_θ` boundary) · adaptive attention allocation.
- **Divergence-from-plan alerts the human in real time** — a second seam beyond novelty:
  intervene fast, do not wait for close.

**The actuator boundary (auto vs. gated).** The line is §3's *WITHIN-basin vs. ON-basin*,
operationalized by two derivable criteria — **reversibility** (recoverable from the
append-only log with no loss of proven state) and **persistence** (a standing rule vs.
re-derived per run). The clean form: **the actuator never *mutates* rules — it
*re-derives* allocation from the immutable telemetry each run (auto), and *proposes*
rule-promotions for gating.** Reconstruct-not-recall applied to governance.
- **Auto (reversible-local):** reversible AND non-persistent — this-walk allocation that
  leaves rules and proof intact.
- **Gated (rule-change):** persistent OR redefines a gate — routed through collective-
  choice (Ostrom).
- **Emergent-regularity safeguard = transparency + a dual promotion trigger.** A
  consistently re-derived heuristic can become a *de-facto ungoverned rule*
  (path-dependence — the mechanized form of the §4b exclusion hazard). Guard it with
  **transparency** (derived priorities always visible and contestable) **and** a
  **promotion trigger that is itself deterministic + non-deterministic**: a deterministic
  recurrence threshold *flags* the candidate; a non-deterministic judgment *assesses*
  whether it is a real rule; the human *ratifies*. We cannot weigh this boundary
  deterministically, so we combine both to best-estimate **before it compounds**.

### 7 · The composition medium — the human-seam message API
Human and machine compose only through a **message-first API that surfaces exactly the
genuine seams and nothing else** (time is the scarcest resource): the seams are
**novelty-bounding, divergence-alert, coherence-judgment**. The agent is **primed to
know its own arsenal** (ARM applied to self-awareness) and owes **generative** reports
(trade-offs, decisions-and-why, goal-fit, and suggestions that *spark* the human).
This API *is* the **daemon↔UI protocol**: a lightweight CL daemon, a heavyweight
opinionated client (Rust/ratatui) so the boundary cannot be cheated — doubling as an
alternate frontend to opencode proper.

### 8 · "Stable" — the checkable metric
The metaharness is **stable** when, for *any* agent composition:
- **(static)** the bounding-layer invariants hold — monotonic unforgeable progress,
  bounded+recoverable divergence, seams surfaced never crossed silently, decorrelated
  composition; **and**
- **(dynamic)** the measured coherence hit-rate is healthy and **self-correcting** — a
  *living* commons that detects and repairs its own degradation, not a merely correct
  machine.

---

## Congruence inverted on certainty — the determinization ratchet
Scaffolding is deployed **inversely to certainty** (Ostrom congruence, §5, made
dynamic). Where certainty is *lowest* — novel/greenfield, near the `⋃_θ` boundary, high
divergence — deploy the *maximum*: a full council, every applicable gate and check,
**and a meta-review that actively seeks a NEW deterministic gate** (an overlooked test
case, an extractable invariant) to convert the uncertainty into a *permanent* check —
the Verification Dual's "if a deterministic evaluator *can be built*, it must be," made
a standing discipline. This **compounds**: each pass under uncertainty ratchets some of
it into determinism, so the **deterministic surface grows and the uncertain frontier
recedes** — the commons *progressively determinizes*, needing less expensive scaffolding
as it matures and freeing attention for the next frontier. (Symmetrically, where
certainty is high, ceremony collapses — focus before ceremony.)

## The recurring pattern (self-similarity)
Wherever a boundary is **inherently undecidable deterministically**, the system uses the
same shape — a **deterministic flag + a non-deterministic judgment + human
ratification** (an instance of the Verification Dual) — never pure-determinism (brittle)
nor pure-judgment (ungovernable). It appears at least at: the council-convening trigger
(§6, Q5), the rule-promotion trigger (§6), and the accept/rework/escalate ladder. That
the actuator governs *itself* with the same dual the whole system uses is a completeness
signal: self-similarity means fewer special cases and cleaner code.

## Scope rule (freedom)
- **Out:** *deep* integration with / dependence on proprietary systems (unverifiable
  black boxes; coupling is lock-in).
- **In, deliberately elegant:** proprietary models as **arms-length ensemble members**
  (a cheap local libre model driving a proprietary text-only harness via tmux panes) —
  their disparate `θ` without deep coupling. The freedom line is **dependence +
  transparency**, not refusing proprietary outputs.
- **The runner stands alone; the metaharness augments — never assumed, never coupled.**

## Completeness discipline
The foundation is complete-and-connected when the **concept↔procedure mapping is
orphan-free**: no concept here without a procedure that implements it, no procedure in
the code without a concept here it serves — the same referential integrity the system
enforces on itself. Verified by continued *decorrelated* agreement (human drafting in
one basin, machine synthesizing in another, converging). Loss of that mapping is the
early signal the code will suffer.

## What derives from here (not before)
1. Formalize the §8 invariants into a machine-checked spec (`/form` or `/spec`),
   grounded against the *running* metaharness once the PoC (campaign-5) lands.
2. Scrutinize the primitives (GROUND / ARM / COMPOSE / INTENT / TRACK) against §1–§8;
   settle context-management as a facet of the append-only statespace (§4).
3. Derive the roadmap: PoC → stable metaharness (§8 enforced) → opencode-compatible runner.
