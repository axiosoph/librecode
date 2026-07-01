# librecode — Roadmap

Derived from [`foundations.md`](foundations.md); grounded in where we actually stand.
Not a rigid sequence — a dependency-aware set of workstreams with one ordering
principle: **stabilize the core before adding compatibility surface — but do it fast**,
so we can fill in the missing implementation and reach a fully working stack.

---

## Where we are (2026-07-01)

- **Runner:** resilience thesis proven (condition/restart tiers, the worker
  freeze/handshake, the reusable failure-relay); concurrency hardened; event-sourced
  SQLite; compaction + context epochs.
- **Metaharness:** supervision thesis proven — harness protocol + in-process and
  real cross-process (subprocess) backends; campaign DAG + Kahn + crash-safe journal;
  native `nickel` gate; supervision loop (multi-child, failure→condition→restart via the
  relay, journal resume); autonomous recovery ladder.
- **PoC — reached:** metaharness → **real subprocess child** → real builtin tools
  (read/write/bash, CWD-safe) → native gate, producing a gated artifact, with
  mid-run kill/resume; an endpoint-generic OpenAI-compatible provider; and a runnable
  demo against a small local model (Ollama, `qwen2.5-coder:3b`).
- **Foundations + manifesto:** drafted and reviewed (`foundations.md`, `../MANIFESTO.md`).
- **Known regression (must-fix):** a recent change reintroduced a raw thread-kill in
  tool-timeout cleanup and removed its tests — violating the cooperative-shutdown invariant.

## Destination

`foundations.md §"what derives"`: **PoC → stable metaharness (§8 invariants enforced) →
opencode-compatible runner** — a libre, heterogeneous, decorrelated commons with a
message-first human-seam API.

---

## Workstreams

### A · Formalize "stable" *(highest leverage; unblocks the rest)*
Turn `foundations.md §8` into a **machine-checked spec** of the static invariants
(monotonic unforgeable progress; bounded+recoverable divergence; seams surfaced never
crossed; decorrelated composition) — grounded against the *now-running* metaharness. This
converts "stable metaharness" from prose into a gate.
Its own determinization ratchet: every invariant we can make deterministic, we must.

### B · Harden the runner/metaharness core
- **Fix the shutdown regression** — restore cooperative shutdown and the deleted tests.
  *Do this first; it is a proven invariant that slipped.*
- Provider auth + non-OpenAI dialects (beyond the endpoint-generic base).
- The accepted-vs-skipped ladder semantics (recently implemented; needs verification).
- Stand up the **coherence telemetry substrate** (the living loop's *sensor*):
  iterations-to-gate, rework/escalation/gate-fail rates, per basin/content-type/time.

### C · Memory & Context *(built on J; early — highest blast radius, do not glaze)*
Long-term memory (durable) and the context map (ephemeral). **Memory is built *on* the contract
substrate (J), not as a separate prose-summarization system** — "a local model compacts the
conversation into the ledger" is the *dangerous* framing, reintroducing the lossy, unverifiable
summarization contracts exist to prevent. Memory *writes are deposits*: structured,
evidence-bearing, and **verified** (cheap contract check + decorrelated accuracy review), never
trusted self-summary. That de-fangs most of the open unknowns below — consolidation becomes
structured deposits; accuracy-verification becomes contract-verification + the glaze-check;
retrieval is the ledger structure; the LTM↔context boundary is reconstruct-from-contract; dedup is
event-sourcing + basin promotion.

**Why this cannot be glazed:** memory *is* agent-scaffolding — the extreme end of the drift-risk
gradient (§6) — and its blast radius is the whole system. A flaw in one work-product is bounded and
reviewable; a flaw in memory silently corrupts the foundation of *every future session* and
compounds. So this design work happens **early**, depending on J, before cross-session state accumulates.

**The two residual dragons** (what memory-on-contracts does *not* solve, and must not skip):
1. **Self-consolidation shares the consolidator's blind spots** (§1/§3 at the memory layer) — a
   model summarizing its own context cannot verify it kept what matters; consolidation must be
   decorrelated (a different model, a deterministic contract, or the human), never unchecked
   self-summary.
2. **Exploratory / rationale context beyond the structured deposit** — the reasoning, dead-ends,
   and roads-not-taken a work-contract does not capture, where the *why-we-didn't* (often what a
   later session most needs) lives. Preserving *and verifying* it is the residual hard-accuracy
   problem.

**Pieces we already have** (map to `foundations.md §4`, reconstruct-not-recall):
- the append-only, replayable **event log + s-expr journal** — the immutable statespace
  (source of truth);
- the runner's **compaction engine + context epochs** — consolidation + reconstruction;
- a git-repo-backed **ledger** — a de-facto long-term memory: cheap, trivially redundant,
  **no lock-in** (git is the right medium, per the freedom stance);
- an existing git-backed **memory pattern** (one-fact-per-file + a searchable index +
  `[[links]]` + dedup/update discipline) — a concrete LTM pattern to learn from.

**Open unknowns** (still to be worked out):
1. **Consolidation mechanics** — a *local model* (freedom/privacy: keep it libre and
   off-vendor) opportunistically compacts fresh conversation → writes the ledger.
   Trigger, granularity, format? Enforce local-only, or advise as good style?
2. **Accuracy verification** — during compaction, compare the compacted understanding
   *against the written ledger*: were important details missed? What is the check — a
   decorrelated re-read, a diff, a coherence score? (This is the hard part.)
3. **Retrieval API & structure** — a *meaningful git log* is the high-level index (read
   commit messages to know where to dive), with arbitrarily deep detail from there. What
   *minimal coherent structure* keeps it effective/searchable without imposing bounds?
4. **LTM ↔ context-map boundary** — what is promoted to durable memory vs. held in the
   working context; when and how (cf. the scratch→durable-store promotion pattern).
5. **Dedup / update** — avoid duplicate/stale memory; update-in-place vs. append; delete
   what proved wrong.

### D · The living coherence loop *(the dynamic stability face)*
Implement the *actuator* over B's sensor: re-derive attention from telemetry each run
(auto), propose rule-promotions for gating (human/collective), with transparency + the
**dual promotion trigger** (deterministic flag + non-deterministic judgment + human
ratification). The human quality scalar at campaign close is the ground-truth anchor.
- **The self-governing instruction layer** (`foundations.md`; `design.md §4`): the actuator's
  persistent output is edits to the harness's own **prose procedures** and **contracts**, in
  versioned scoped basins (default ⊕ commons ⊕ project ⊕ operator) with an immutable core and
  human-ratified promotion. Two cross-session signals drive it: contract-fill failure ⇒ finer
  prose; recurring un-contracted pattern ⇒ new contract. Overlaps **C** (the basins are the
  procedural half of git-backed memory).
- **Contract language — decided: Nickel** (`design.md §4`). Type-level composable contracts with
  arbitrary Turing-complete predicates, multi-format, pure; the external binary is *load-bearing*
  (one gate at harness ⊕ CI ⊕ commit). A CL DSL is the wrong direction, not just a high bar. Cost:
  Nickel present + version-pinned wherever gates run; absent ⇒ degrade, don't fail.
- **Contract *shaping* — approach found** (`design.md §7`). Partial validation via a
  **self-declared phase enum** + a recursive phase-aware contract (typestate in Nickel), with
  deferred/degraded validation as the in-time complement — both a *monotonic frontier*. Remaining
  is per-contract (phase design + the monotonic-phase invariant), not systemic.

### E · Heterogeneity / decorrelation-first *(the manifesto's core value)*
- Cross-model **verification seats** (different models, not lenses on one).
- A real cross-process **opencode backend** — the heterogeneity play.
- **Arms-length proprietary** via terminal-pane reading driven by a cheap local model —
  disparate models for decorrelation without deep coupling (the freedom-preserving path).

### F · The human-seam API + TUI
The daemon↔UI **message-first protocol** = the human-seam API (`foundations.md §7`);
a **Rust/ratatui** client (clean boundary, best-in-class UX), doubling as an alternate
frontend to opencode proper.

### G · opencode-compatible runner
opencode is the open-source agent harness librecode's runner targets for compatibility.
Full opencode-spec compliance — the runner's stability measured against that external
standard; the compatibility surface, added *after* the core is stable.
- **The augmentation seam:** the runner exposes hooks so the metaharness can enforce its
  invariants on it, while the runner runs standalone as pure-opencode (metaharness an
  *optional* consumer). **Open prior-art unknown:** how extensible opencode already is
  (plugins / hooks / events / MCP) — investigate first, and reuse opencode's own extension
  mechanism if one exists (compat for free) before adding our own.

### H · Runner capability floor *(prerequisite for meaningfully testing the metaharness)*
A bounded set of the critical features *any* LLM agent harness needs — robust multi-turn
tool use, real file/code editing, dependable error handling — stabilized to a **testable
standard**, so realistic scenarios exist to stress the metaharness. NOT full opencode
parity: enough to exercise supervision and coherence, no more. Keeps us bounded —
stabilize an elegant, minimal-but-capable runner API before broadening the code surface.

### I · The multi-stakeholder commons *(the concrete coordination mechanism — prioritized)*
Make the commons literal — many humans + many sessions under one governance layer — because the
commons is only compelling once concrete (`foundations.md` Positioning, §5; `design.md §2`).
- **Build the assent engine.** Delegation and sign-off are currently stubs (no-ops);
  implement them machine-enforced, then generalize the table so arbitrary humans are
  first-class seats and a node can carry a hard sign-off gate ("X waits on Alice AND Bob")
  enforced like any deterministic gate.
- **The regression transitions.** Implement `reset-to-checkpoint` and
  `cut-clean-and-decorrelate` (`design.md §3`), currently design-only.
- **Cross-instance coherent view.** Disparate isolated sessions (each stakeholder on their own
  harness) share the append-only statespace as a single global view into ongoing work — the
  substrate that makes long-horizon multi-stakeholder alignment enforceable, not aspirational.
- **Above any single harness.** Coordinate heterogeneous human+tool operators without requiring
  them to standardize on one harness (the metaharness-not-harness argument).

### J · The contract substrate *(the spine — foundational, early)*
The deposit / prose-procedure / contract / gate machinery the rest of the governance layer builds
on (`foundations.md` self-governing instruction layer; `design.md §4/§7`). Named explicitly
because **A, D, and I all sit on it** and it is currently implicit.
- **Artifacts + scoped basins** — prose procedures and contracts as versioned, committable
  artifacts, layered default ⊕ commons ⊕ project ⊕ operator, with an immutable core and
  human-ratified promotion.
- **Phase-aware contracts (typestate) + deterministic gate-parameterization** — the phase is set
  by the gate/DAG and overrides any agent-declared value; agents never set the terms of their own
  checking (generalizes to all contract parameters).
- **The cost-ordered pipeline** — a cheap contract cull (auto-reprompt on fail) gating expensive
  decorrelated review; the deposit as the co-located claim+evidence review substrate.
- **Nickel as the checker** (decided), run at harness ⊕ CI ⊕ commit gate; **graceful degradation**
  (recorded, never silent) + **deferred validation** when it is absent.
- Relationships: **A** authors the immutable-core contracts on this; **D**'s actuator commits
  refinements to the basins; **I**'s assent engine is contracts over it.

---

## Sequencing

**Stabilize, then broaden.** **B (harden, incl. the shutdown fix) + the sensor** comes first.
The **contract substrate (J)** is foundational and lands early — A, D, and I all sit on it, so
it precedes them. **H (runner capability floor)** lands early — the metaharness cannot be
meaningfully tested against a toy runner, so a bounded-but-capable runner is
a prerequisite for **A (formalize stable)**, which authors the immutable-core contracts on J and
grounds the §8 invariants against a *realistically exercised* running metaharness. **C (memory)**
is **not** a lazy parallel track: it depends on J (memory-writes are verified deposits) and, given
its whole-system blast radius, its design work happens **early**, before cross-session state
accumulates. **D** (the self-governing loop) follows the sensor and builds on J. **I** is
**prioritized** — its assent engine is contracts on J; the shutdown fix still comes first (a
regressed proven invariant is always first), and the exact interleave of I with H/A is a later
maintainer decision.
**E / F / G** (heterogeneity, TUI, full opencode-compat) are the broadening surface, deliberately
after the core is stable per §8 — and G's full compatibility comes only after H's bounded floor.

## Immediate next
1. **Landed** (on master): the foundation set, its review and remediation, and the
   self-governing instruction layer. A fix for the shutdown regression is in review.
2. **Next:** the **contract substrate (J)** and H (**runner capability floor**) toward
   A (**formalize stable**); C (memory) sequenced early on J.
