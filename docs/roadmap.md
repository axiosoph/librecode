# librecode — Roadmap

Derived from [`foundations.md`](foundations.md); grounded in where we actually stand.
Not a rigid sequence — a dependency-aware set of workstreams with one ordering
principle: **stabilize the core before adding compatibility surface — but do it fast**,
so we can fill in the missing implementation and reach a fully working stack.

---

## Where we are (2026-07-05)

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
- **The shutdown regression is fixed** (cooperative shutdown restored and gated against
  raw kills, `93c61ad`); workstream K is ratified; G's seam question is answered
  (MCP-first); the project README exists.

## Destination

`foundations.md §"what derives"`: **PoC → stable metaharness (§8 invariants enforced) →
opencode-compatible runner** — a libre, heterogeneous, decorrelated commons with a
message-first human-seam API.

---

## Workstreams

### A · Formalize "stable" *(highest leverage; unblocks the rest)*
Turn `foundations.md §8` into a **machine-checked spec** of the static invariants
(tamper-evident monotonic progress; bounded+recoverable divergence; seams surfaced never
crossed; decorrelated composition) — grounded against the *now-running* metaharness. This
converts "stable metaharness" from prose into a gate. **Pin the threat model first** (§8's
"tamper-evident, precisely"): formalize ledger integrity — checkable — and never let the spec
claim work-validity under the same name; include the evaluator-surface countermeasure (a test
deleted or weakened without a linked decision fails the gate).
Its own determinization ratchet: every invariant we can make deterministic, we must.

### B · Harden the runner/metaharness core
- **Fix the shutdown regression** — restore cooperative shutdown and the deleted tests.
  *Do this first; it is a proven invariant that slipped.*
- Provider auth + non-OpenAI dialects (beyond the endpoint-generic base).
- The accepted-vs-skipped ladder semantics (recently implemented; needs verification).
- Stand up the **coherence telemetry substrate** (the living loop's *sensor*):
  iterations-to-gate, rework/escalation/gate-fail rates, per basin/content-type/time —
  **two-sided from the start** (`design.md §6`): friction metrics PLUS the false-accept
  instruments (decorrelated audit-sampling of gate-passed deposits; close-time attribution
  from the human quality scalar back to contracts). The human anchor enters the schema as a
  *partially correlated* signal, not unqualified ground truth (`foundations.md §3`).
- **Cross-model probe** — a measurement of whether a disparate-model reviewer catches
  defects a same-model reviewer misses on our own work: the thesis's most falsifiable
  bet. Protocol designed and pre-registered
  (`.scratch/cross-model-probe-design-2026-07-05.md`); the formal run is **deferred past
  the usable-MVP gate by explicit operator call (2026-07-05)** — nrd's own daily
  cross-model review practice is the standing informal evidence (the 2026-07-01
  decorrelated review is a recorded data point: it caught same-model-missed findings),
  and speed-to-usable outranks re-measuring a prior the operator already holds.
  Reopening triggers: post-MVP; a major model-roster change; or any decision that
  actually hinges on the delta's magnitude. The staleness risk is accepted and recorded
  (`foundations.md`, novelty-boundary element 4).
- **Forgebot baseline** (the 2026-07-01 invalidation review's residual empirical question):
  build the minimal forge-native bot — Nickel gates as CI required-checks, branch
  protection as the assent engine, reject-and-redispatch on failure — and run the same
  campaign DAG through it and through the metaharness. Measure tokens-to-accepted-node,
  human-minutes per accepted node, and doomed-walk detection latency. Bounds the
  supervision ladder's value (economy, not correctness — the gates catch the bad deposit
  either way) the way the cross-model probe bounds the decorrelation bet. Protocol:
  `.scratch/forgebot-baseline-design-2026-07-05.md` (carries the attention instrument —
  element 5's measurement). Cheapest run point: **during MVP dogfooding** — once
  librecode drives real campaigns, arm-B data falls out of ordinary use for free.

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
- **Wire `harness-opencode` for real** — pulled forward from a later slot: it derisks H
  (a mature harness to exercise the metaharness against beyond a toy runner) and is the
  heterogeneity play in one move; see "Immediate next." The drive surface is proven
  (2026-07-05 survey, `.scratch/opencode-seam-survey-2026-07-05.md`): `opencode serve`
  HTTP+SSE — dispatch via `POST /session` + `prompt_async`, observe via SSE `/event`,
  complete/fail via `session.idle`/`session.error`, cancel via `/abort`, permission
  interception over HTTP — the same path opencode's own `run --format json` exercises.
  Its restart set is `{redispatch, abort, answer-permission}` with live observation,
  richer than the thin-adapter floor K assumes. **Adapter acceptance criteria** (from
  the survey's risk register): pin the opencode version and diff its `/doc` OpenAPI
  export on upgrade (no wire-protocol versioning exists upstream); empirically verify
  the exit-code ↔ `session.error` interaction before trusting exit codes for failure
  detection.
- Cross-model **verification seats** (different models, not lenses on one).
- **Arms-length proprietary** via terminal-pane reading driven by a cheap local model —
  disparate models for decorrelation without deep coupling (the freedom-preserving path).

### F · The human-seam API + TUI
The daemon↔UI **message-first protocol** = the human-seam API (`foundations.md §7`);
a **Rust/ratatui** client (clean boundary, best-in-class UX), doubling as an alternate
frontend to opencode proper.

### G · opencode seam compatibility *(not spec parity — see the 2026-07-01 invalidation review)*
opencode is the open-source agent harness librecode's runner grew out of porting. The
target going forward is **seam compatibility**, not full opencode-spec compliance: shared
tool schemas and wire shapes so opencode's own TypeScript plugin ecosystem can drive the
runner across a subprocess/JSON boundary, keeping the CL kernel small and letting the
broad community's contribution surface stay in TypeScript rather than Lisp. Full
behavioral parity is explicitly *not* a goal — it would re-couple the runner to an
upstream it exists to not depend on (the runner's justification is the harness-side
supervision contract it proves out, not opencode-equivalence; see `foundations.md`).
- **The augmentation seam:** the runner exposes hooks so the metaharness can enforce its
  invariants on it, while the runner runs standalone as pure-opencode (metaharness an
  *optional* consumer).
- **The load-bearing question — answered** (2026-07-05 prior-art survey of opencode
  at commit `077f83db`, full record with file:line citations:
  `.scratch/opencode-seam-survey-2026-07-05.md`). Findings that shape the seam:
  - opencode has **two plugin systems**: V1 (`@opencode-ai/plugin` Hooks — shipped,
    documented, externally loadable) and an Effect-based V2 (internal-only,
    mid-rearchitecture, explicitly not the current API). V1's `PluginInput` assumes
    in-process Bun execution — no subprocess bridge exists to reuse.
  - opencode already speaks **MCP** for tools — a standards-based process-boundary
    protocol that *is* the subprocess/JSON seam this workstream wants.
  - **Ruling (nrd, 2026-07-05): MCP-first, presumptive.** The runner grows an MCP
    client for the tool/plugin ecosystem; no V1 Hooks bridge is built. The ruling is
    presumptive, not final — it reopens if MCP's reach proves insufficient in
    practice (a needed plugin isn't MCP-reachable) or the seam has unintended
    effects. opencode-interior hooks (auth, chat-params) stay out of scope: where
    opencode is the *harness*, its hooks are reached via E's HTTP surface instead.
  - Wire-protocol fronting (opencode's own clients driving a foreign runner) is a
    large **unversioned** surface — gated on the `harness-opencode` adapter proving
    out first (unchanged sequencing: after H).

### H · Runner capability floor *(prerequisite for meaningfully testing the metaharness)*
A bounded set of the critical features *any* LLM agent harness needs — robust multi-turn
tool use, real file/code editing, dependable error handling — stabilized to a **testable
standard**, so realistic scenarios exist to stress the metaharness. NOT full opencode
parity: enough to exercise supervision and coherence, no more. Keeps us bounded —
stabilize an elegant, minimal-but-capable runner API before broadening the code surface.

### I · The multi-stakeholder commons *(the concrete coordination mechanism — prioritized)*
Make the commons literal — many humans + many sessions under one governance layer — because the
commons is only compelling once concrete (`foundations.md` Positioning, §5; `design.md §2`).
- **Build the assent engine — native, not forge-delegated.** Delegation and sign-off are
  currently stubs (no-ops); implement them machine-enforced against the journal, then
  generalize the table so arbitrary humans are first-class seats and a node can carry a
  hard sign-off gate ("X waits on Alice AND Bob") enforced like any deterministic gate.
  A git forge's review/approval mechanics are **not** a substitute (forge state is
  mutable; the journal is the source of truth) — at most an *outbound projection*, below.
- **Optional outbound forge projection** (not load-bearing; `foundations.md` "The null
  hypothesis"). Campaign nodes, layer merges, and gate states may be mirrored to forge
  objects (issues, PRs, commit statuses) so a stakeholder who never installs librecode can
  still see the commons' progress. Inbound: a forge approval may be mirrored into the
  journal as *evidence* of a human's sign-off, never as the assent record itself.
  **Active as a manual discipline since campaign 6** (2026-07-05; spec:
  `.ledger/process-feedback/forge-projection-discipline.md` — meta-PR per campaign
  branch, draft PR per node, findings issues under a tracking umbrella, git-CLI merges,
  context-free forge prose, durable permalinks). This workstream later mechanizes what
  is now run by hand.
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
- **Nickel as the checker** (decided), run at harness ⊕ CI ⊕ commit gate; **graceful
  degradation — semantics decided** (`design.md §7`): deposits quarantine `validation-pending`,
  the phase never advances past a pending gate (proof advancement deferred, never retracted),
  failed discharge reverts to rework; recorded, never silent. **Non-terminating contracts are
  a bounded-timeout FAIL**, never a pass or a third state.
- **The gate-harness contract protocol — boundary design ratified 2026-07-05** (full record:
  `.scratch/campaign-6-one-calculus/gate-harness-protocol-proposal-2026-07-05.md`).
  Implementation is J's own scope, not pulled forward into campaign 6; this fixes its shape.
  - **Vocabulary corrected.** Deposit (data) ≠ contract (the Nickel checker) ≠ verdict (a
    checker's output). `src/model`'s `deposit` struct is a mis-named verdict; the rename to
    `verdict` is mechanical and deferred to J itself, bundled with introducing the real
    deposit-*data* artifact. Both the work-product deposit and its contract are currently
    missing — J authors both fresh, in a new librecode-owned `.ledger/contracts/`, since
    predicate's own `deposit.ncl` checks process-provenance, not code-content acceptance.
  - **The DAG is two-tiered**, the same pattern as the deposit gate below. `src/model/dag.lisp`
    (`make-dag`/`dag-layers`) becomes the **load-bearing Tier-1 structural authority** — always
    available, no Nickel dependency, validating id-uniqueness/referential-integrity/acyclicity
    and computing the real Kahn layering — and *is* the runtime scheduler once wired
    (`librecode-meta` gains a `librecode-model` dependency edge; `campaign.lisp`'s ad-hoc third
    Kahn, `compute-kahn-layers`, is cut with no fallback). Nickel's `Dag`/`DagNoConflict` become
    **optional Tier-2 enrichment** — concurrent-surface conflict-freedom and discipline
    validation — never a hard dependency for DAG correctness at charter *or* mid-campaign
    amendment (amendment is the norm here, not an edge case). A degraded amendment (Nickel
    absent) lands structurally-quarantined once Tier 1 clears; the composer serializes the
    affected concurrent nodes until Tier 2 discharges.
  - **The deposit gate stays a bare keyword in** (`gate-check`/`discharge` still take
    `:pass`/`:fail`/`:timeout`; `src/model` stays dependency-free) **but a structured verdict
    out**: the deposit contract attaches a normalized deposit, the gate-derived effective phase
    (§7's typestate override), and the durable checked view, which `campaign.lisp` routes
    five ways (pass-and-merge / fail-or-timeout-to-rework / checker-absent-quarantine /
    later discharge-pass / discharge-fail).
  - **Degradation is uniform** across both the DAG and deposits: a Lisp-native Tier-1
    structural floor is always load-bearing; the Nickel Tier-2 semantic layer defers
    gracefully rather than blocking. Nothing is a hard-Nickel precondition anywhere.
  - **Concrete file-level deltas J will make:** add `librecode-model` to
    `librecode-meta.asd`'s `depends-on`; route `campaign.lisp`'s scheduler through
    `librecode-model:make-dag`/`dag-layers` and delete `compute-kahn-layers` (no fallback);
    author `.ledger/contracts/deposit.ncl`; keep `dag.ncl`'s `Dag`/`DagNoConflict` as the
    Tier-2 gate, carrying the conflict-freedom verdict rather than the layering; give
    `gate.lisp` a deposit-gate entry point returning `(values result stdout stderr)` with
    checker-absent distinct from contract-violation; rename
    `src/model/state-machine.lisp`'s `deposit` struct to `verdict`.
- Relationships: **A** authors the immutable-core contracts on this; **D**'s actuator commits
  refinements to the basins; **I**'s assent engine is contracts over it.

### K · The harness supervision contract & the one-event calculus *(ratified 2026-07-05; precedes J)*
Surfaced by the 2026-07-01 invalidation review (full record:
`.scratch/invalidation-dialectic-2026-07-01.md`); ratified by the 2026-07-05
architect pass with the scoping below. Implementation is its own (small) campaign,
chartered separately — this entry fixes its boundary.

Two artifacts:
- **The harness-side supervision contract** — the hooks a walker must expose to be
  governable (freeze mid-turn, offer a restart, resume in place, deposit emission,
  trajectory transparency), formalized independently of any one runner. Other harnesses
  would eventually implement *this*, not the runner. Supervision is reified as
  conditions/restarts advertised over the wire — a frozen walk offers
  `(condition . available-restarts)`; the supervisor selects; harness capability becomes
  simply its restart set (`{redispatch}` for a thin adapter; the full ladder for a fully
  cooperative one) — KU9 capability discovery falls out of this for free. The *contract*
  is committed; the *depth* of the restart ladder built into the runner is scoped by B's
  forgebot baseline — a negative baseline result shrinks the ladder investment, never
  the contract.
- **One event calculus — one *calculus*, not one *log*.** The model's event vocabulary
  (`transition-event`/`replay`, `src/model/`) is the single governance calculus: runtime
  transitions on both sides route through it directly (functional core / imperative
  shell), so conformance holds by construction and the five crown-jewel invariants run
  as boot gates — a replay that violates them refuses to resume. Two granularities stay
  separate by design: the meta journal becomes a *storage backend* for calculus events
  (its private fold in `apply-journal-entry` replaced by the model's), while the
  runner's session event log (turns, compaction, provider config) remains
  *walk-interior* — below the governance boundary, its own event-sourced system.
  What changes runner-side: governance-relevant moments (deposit emission, gate
  outcomes, a raised condition) become emissions *into* the calculus rather than a
  private dialect. This resolves the review's open sub-question — the SQLite store
  survives as the walk-interior log, not as a projection of the calculus; "journal +
  projections" is the answer at the governance level only. (The runner's
  `deposits`/`deposit_cites`/`deposit_refs`/`findings` tables are schema-only — no
  writer exists anywhere in `src/` — and are cut; durable deposit views, where wanted,
  are projections of calculus events.)

**In-scope design work (named, not resolved here):** reconciling the journal dialect
with the calculus — `:node-accepted` ≈ `:gate-checked :pass`; `:node-rework` carries an
IBC payload the calculus's rework outcome does not; `:surface-widened` mutates the DAG
the model holds immutable, so the calculus needs a distinct plan-amendment event class
(mirroring the `dag-amendment` decision-type) or surface-widening folds into rework;
`:layer-advanced` is derivable from the DAG and statuses (cut candidate). The live-image
joint (REPL/SLIME attach to frozen walks; supervisor as a long-lived image
reconstructing from the journal) is ratified as direction, sequenced last within K.

**Sequencing:** precedes J — the contract substrate wants to sit on the unified event
spine, not a fourth event dialect. Timely now: the governance vocabulary has exactly one
live implementation (the meta journal) plus the reference model, so the unification
surface is at its smallest.

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
**E / F / G** (heterogeneity, TUI, opencode seam compat) are the broadening surface,
deliberately after the core is stable per §8 — and G's seam work comes only after H's
bounded floor. **K** (ratified 2026-07-05) precedes J for the same reason J
precedes A, D, and I: the contract substrate wants to sit on the unified event spine.

## The MVP path (plan of record, 2026-07-05)

**Metagoal (nrd):** a usable system as fast as possible without sacrificing the
foundation — then iterate from real use.

**The MVP gate, defined:** librecode replaces the operator's manual campaign
choreography for one real campaign — IBC in, walkers dispatched on a capable harness,
Nickel gates checking deposits, journal + ledger recording everything, the human
surfaced only where judgment is needed, a merged auditable branch out. Graduation test
(unfakeable): **librecode runs its own next campaign.**

The sequence — four campaigns, two design passes:
1. **Campaign 6 — K, the kernel.** Journal fold routed through `transition-event`,
   vocabulary reconciliation (the plan-amendment event class is the one open design
   decision), the five invariants as boot gates on replay, the dead-table cut, and the
   supervision-contract artifact with the minimal restart ladder. ~2 layers, ~6 nodes.
2. **Campaign 7 — the capable harness.** `harness-opencode` on the proven HTTP+SSE
   surface (acceptance criteria in E) plus provider auth (B). Daily use does **not**
   wait on H: opencode is the workhorse walker while the reference runner matures at
   its own pace (its F3 identity).
3. **Campaign 8 — J, the contract substrate** on the unified spine (§7's settled
   shaping design). The largest — may split in two — and cannot be thinned: it is the
   homework premise made real.
4. **Campaign 9 — the seam + the bootstrap.** Minimal message-first human seam
   (CLI/REPL, not the TUI), the attention instrument (element 5), then the graduation
   run: campaign 10 chartered *through* librecode. Forgebot arm-B data accrues from
   here at no extra cost.

**Design passes, not campaigns:** the C memory dialectic runs **before heavy
dogfooding** (C's own warning: cross-session state must not accumulate undesigned);
the README/front-door pass is done (2026-07-05).

**Deliberately post-MVP, pulled by real usage signal:** A (the machine-checked stable
spec), D (the living loop), C's build, H, F (the full TUI), G's MCP client, I
(multi-stakeholder generalization).
