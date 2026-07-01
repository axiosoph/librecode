# librecode — Roadmap

Derived from [`foundations.md`](foundations.md); grounded in where we actually stand.
Not a rigid sequence — a dependency-aware set of workstreams with one ordering
principle: **stabilize the core before adding compatibility surface — but do it fast**,
so we can fill in the missing implementation and reach a fully working stack.

---

## Where we are (2026-07-01)

- **Runner:** resilience thesis proven (condition/restart tiers, RES-06 worker
  freeze/handshake, the reusable failure-relay); concurrency hardened; event-sourced
  SQLite; compaction + context epochs.
- **Metaharness:** supervision thesis proven — harness protocol + in-process and
  real cross-process (subprocess) backends; campaign DAG + Kahn + crash-safe journal;
  native `nickel` gate; supervision loop (multi-child, failure→condition→restart via the
  relay, journal resume); autonomous recovery ladder.
- **PoC (campaign-5) — reached:** metaharness → **real subprocess child** → real
  builtin tools (read/write/bash, CWD-safe) → native gate, producing a gated artifact,
  with mid-campaign kill/resume; endpoint-generic OpenAI-compatible provider; a runnable
  `just demo` against local Ollama (`qwen2.5-coder:3b`).
- **Foundations + manifesto:** drafted (`foundations.md`, `../MANIFESTO.md`), pending
  council review.
- **Known regression (must-fix):** campaign-5 reintroduced `bt:destroy-thread`
  (`tool.lisp:270`) and removed test lines — an **I4 violation** (cooperative shutdown).

## Destination

`foundations.md §"what derives"`: **PoC → stable metaharness (§8 invariants enforced) →
opencode-compatible runner** — a libre, heterogeneous, decorrelated commons with a
message-first human-seam API.

---

## Workstreams

### A · Formalize "stable" *(highest leverage; unblocks the rest)*
Turn `foundations.md §8` into a **machine-checked spec** (`/spec` or `/form`) of the
static invariants (monotonic unforgeable progress; bounded+recoverable divergence; seams
surfaced never crossed; decorrelated composition) — grounded against the *now-running*
metaharness (`campaign.lisp`). This converts "stable metaharness" from prose into a gate.
Its own determinization ratchet: every invariant we can make deterministic, we must.

### B · Harden the runner/metaharness core
- **Fix the I4 regression** (restore cooperative shutdown at `tool.lisp:270`; restore
  the deleted tests) — *do this first; it's a proven invariant that slipped.*
- Provider auth + non-OpenAI dialects (beyond the endpoint-generic base).
- The `:accepted`-vs-`:skipped` ladder semantics (landed in c3daf5c — verify).
- Stand up the **coherence telemetry substrate** (the living loop's *sensor*):
  iterations-to-gate, rework/escalation/gate-fail rates, per basin/content-type/time.

### C · Memory & Context *(open design — needs its own dialectic, like the foundations)*
The relationship between **long-term memory** (durable) and the **context map**
(ephemeral). Captured here so it is not lost; **flagged as unresolved.**

**Pieces we already have** (map to `foundations.md §4`, reconstruct-not-recall):
- the append-only, replayable **event log + s-expr journal** — the immutable statespace
  (source of truth);
- the runner's **compaction engine + context epochs** — consolidation + reconstruction;
- predicate's **`.ledger` = a git repo** — a de-facto LTM: cheap, trivially redundant,
  **no lock-in** (git is the right medium, per the freedom stance);
- a working **memory-system prototype** (one-fact-per-file + a searchable index +
  `[[links]]` + dedup/update discipline, git-backed) — a concrete LTM pattern to learn from.

**Open unknowns** (the future dialectic must resolve):
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
   working context; when and how (cf. predicate's scratch→ledger promotion).
5. **Dedup / update** — avoid duplicate/stale memory; update-in-place vs. append; delete
   what proved wrong.

### D · The living coherence loop *(the dynamic stability face)*
Implement the *actuator* over B's sensor: re-derive attention from telemetry each run
(auto), propose rule-promotions for gating (human/collective), with transparency + the
**dual promotion trigger** (deterministic flag + non-deterministic judgment + human
ratification). The human quality scalar at campaign close is the ground-truth anchor.

### E · Heterogeneity / decorrelation-first *(the manifesto's core value)*
- Cross-model **council/verification seats** (different `θ`, not lenses on one).
- `harness-opencode` (real cross-process OpenCode backend) — the heterogeneity play.
- **Arms-length proprietary** via tmux-pane-reading driven by a cheap local model —
  disparate `θ` for decorrelation without deep coupling (the freedom-preserving path).

### F · The human-seam API + TUI
The daemon↔UI **message-first protocol** = the human-seam API (`foundations.md §7`);
a **Rust/ratatui** client (clean boundary, best-in-class UX), doubling as an alternate
frontend to opencode proper.

### G · opencode-compatible runner
Full opencode-spec compliance — the runner's stability measured against its external
standard; the compatibility surface, added *after* the core is stable.

---

## Sequencing

**Stabilize, then broaden.** Core stabilization — **A (formalize stable) + B (harden,
incl. the I4 fix) + the sensor** — comes first and fast. **C (memory)** runs as a
parallel design dialectic (it gates nothing but underpins everything long-horizon).
**D** follows the sensor. **E / F / G** (heterogeneity, TUI, full opencode-compat) are
the broadening surface, deliberately after the core is stable per §8.

## Immediate next
1. **Convene the council** on the doc set (`MANIFESTO.md`, `docs/foundations.md`, this
   roadmap) — the terminal step of this (unorthodox, mostly-dialectic) foundation
   campaign.
2. **Commit** the doc set on council sign-off.
3. **First post-foundation campaign:** B's **I4 fix** (a proven invariant regressed — fix
   before building on it), then A (**formalize stable**).
