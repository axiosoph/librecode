# librecode

**Maturity**: molten (pre-1.0). Refactor and cut freely.

## Goal

Reimplement the core OpenCode multi-agent coordination protocol as a high-performance Common Lisp (SBCL) system (**librecode-runner**), and extend this architecture with a decoupled cross-harness parent orchestrator (**librecode-meta** or the **Metaharness**) capable of supervising multiple child agent harnesses in a "Team of Teams" topology.

The project contains two independent but co-located subsystems:
1. **`librecode-runner` (The Harness)**: The CL native reimplementation of OpenCode's single-agent execution harness (session loops, EventV2 state projection, local tools, dynamic permissions, LLM calls).
2. **`librecode-meta` (The Metaharness)**: The parent coordinator that executes multi-agent campaigns by scheduling DAG tasks, convening councils, and dispatching work across physical process boundaries to heterogeneous child harnesses (e.g. `librecode-runner`, `harness-opencode`, `harness-claude-code`).

## Alignment to Parent

`librecode` is a **reimplementation and extension** of OpenCode. It ports coordination and execution primitives to native CL equivalents (replacing JS/Effect with dynamic binding, condition/restart, SBCL threads, and mailboxes), and introduces the Metaharness layer to coordinate across disparate agent harnesses.

Status tags below reflect the code as built (verified against `src/`), not the
original design intent: **[BUILT]**, **[PARTIAL]**, **[STUB]**.

### Ported from OpenCode (TypeScript source is the reference)

- **[BUILT]** Run coordinator with wake coalescing (R1) — `protocol.lisp`
- **[BUILT]** Event-sourced session state and projectors (R2) — `event-store.lisp`
- **[BUILT]** Unified agent class + permission-driven enforcement (R5). Note: the
  rigid `build-agent`/`plan-agent` subclass hierarchy was collapsed into a single
  parameterized `agent` class (RES-12); there is no CLOS *type* hierarchy.
- **[BUILT]** LLM provider turn execution loop (R8) — `runner.lisp`, one call/turn
- **[BUILT]** Two-phase input admission: admit/promote (R9) — `session.lisp`
- **[PARTIAL]** Context epochs: snapshot, diff, replace (R10). Baseline snapshot +
  replace are built; incremental diff transmission is minimal.
- **[PARTIAL]** Compaction engine — real (`compaction.lisp`) but summarization is a
  naive text concatenation with a heuristic `length/4` token estimate, not an LLM
  summarization pass.
- **[PARTIAL]** Tool registry, materialization, and settlement — the registry,
  permission/capability filtering, JSON-schema materialization, and parallel
  settlement are built and advertised to the model, but only test-fixture tools are
  registered; no real `file`/`bash` tools exist yet.

### Novel to librecode (no TypeScript counterpart)

- **[BUILT]** Condition-restart failure recovery (R3) — `handler-bind` intercepts
  at the signaling site without unwinding; `compact-and-retry` is autonomously
  driven in the HTTP drive loop (`*max-compact-attempts*`); the RES-06 worker
  freeze/handshake and the `with-failure-relay` primitive are real. Caveat: the
  `retry-with-backup-provider` restart is defined but is not yet autonomously
  invoked from `src/` (only exercised by tests).
- **[PARTIAL]** Abstract harness protocol and metaharness supervision (R4).
  **Built**: the abstract harness generic-function protocol, the in-process
  `librecode-harness` backend, the cross-process `subprocess-harness` backend
  (`uiop:launch-program`, exit-code/failure-as-event mapping), the campaign DAG +
  Kahn scheduler + crash-safe journal, the supervision loop, and the autonomous
  recovery ladder. **Stub**: the abstract multiplexer protocol and its tmux
  transport backend (`multiplexer.lisp`, `multiplexer-tmux.lisp`) are bare classes
  with no methods — supervision does *not* run over a terminal multiplexer.
- **[PLANNED / NOT BUILT]** Full-mesh P2P agent mailboxes (R6) — a roadmap
  capability for *direct agent-to-agent collaboration*, required for full OpenCode
  compatibility (agents collaborating as peers, not only under a parent). This is
  DISTINCT from, and not replaced by, the parent↔child failure relay: the
  `sb-concurrency:mailbox` primitive today serves per-session, per-worker, audit, and
  per-SSE-client channels plus the worker→coordinator relay, but there is **no**
  agent-addressed peer-to-peer mesh or agent mailbox registry yet. **Decoupling
  principle:** the runner is usable standalone; the metaharness *augments* it and
  must never be assumed or tightly coupled.
- **[BUILT]** S-expression audit trail (R7) — `audit.lisp`, dual s-expr + JSONL
  writer, append-only, `force-output` per event.
- **[BUILT]** The reference state-machine model (roadmap workstream A's first
  piece, workstream J's spine) — `src/model/`, a pure applicative Common Lisp
  model (dag/status/phase/deposit/event-log/transitions) with the four
  crown-jewel invariants (phase monotonicity, no-pending-proven,
  tamper-evidence, DAG soundness) as `check-it` property tests. Not the
  runtime; defines the conformance seam the runtime will later be checked
  against. See [model.md](file:///var/home/nrd/git/github.com/nrdxp/librecode/docs/model.md).

### Not ported (deliberately excluded)

- Vercel AI SDK bridge (`core/src/aisdk.ts`) — OpenCode uses this as an
  intermediary to resolve `ModelV2.Info` → `LanguageModelV3`. librecode talks
  to LLM provider APIs directly via dexador/SSE, bypassing the SDK layer.
- Subagent communication via event store indirection — OpenCode's `task` tool
  spawns child sessions and blocks on their event streams. librecode uses the
  harness-event / failure-relay pattern for parent↔child cross-process supervision.
  (Direct peer agent-to-agent collaboration — R6 — is a planned *augmentation*, not a
  replacement for this parent-child pattern; not built yet, see above.)

## Requirements & Specifications

The implementation of `librecode` is divided into key modules, each documented exhaustively in the `docs/` folder:

* **[coordination-protocol.md](file:///var/home/nrd/git/github.com/nrdxp/librecode/docs/coordination-protocol.md)**
  * **R1 — Run Coordinator with Wake Coalescing**: Serialized execution per key, wake coalescing, join semantics.
  * **R2 — Event-Sourced Session State**: Durable log in SQLite, aggregate versioning, WAL mode, atomic projection transaction constraint.
  * **R8 — LLM Provider Turn Execution**: dexador `:want-stream t` incremental chunk SSE reading, parallel tool execution, unwind-protect settlement, compaction.
  * **R9 — Two-Phase Input Admission**: Decoupled `admit` (durable inbox) and `promote` (model-visible delivery) phases.
  * **R10 — Context Epochs**: Session-start system context snapshots, diff updates, and baseline resets.

* **[metaharness.md](file:///var/home/nrd/git/github.com/nrdxp/librecode/docs/metaharness.md)**
  * **R4 — Metaharness Supervision**: Decoupled abstract harness interface (generic functions) with in-process and cross-process (`subprocess-harness`) backends. The terminal-multiplexer transport is a stub (see status tags in the doc).
  * **Campaign DAG Engine**: Kahn scheduling scheduler, parallel node worktree isolation, surface-exceed protocol, and boundary check.
  * **Cross-Process Council**: Multi-seat deliberation (composer, maintainer, auditor, architect), consensus/assent rules.

* **[agent-system.md](file:///var/home/nrd/git/github.com/nrdxp/librecode/docs/agent-system.md)**
  * **R5 — Agent Type Hierarchy via CLOS**: Build, plan, explore, and general agent classes. Generic dispatch mode-switching.
  * **Permission Model**: Last-match-wins wildcard rulesets, allow/deny/ask resolution, project-saved database rules, and interactive/headless workflow.
  * **Tool Registry**: Materialization, capability filtering, schema compilation.

* **[resilience-and-audit.md](file:///var/home/nrd/git/github.com/nrdxp/librecode/docs/resilience-and-audit.md)**
  * **R3 — Condition-Restart Failure Recovery**: Dynamic bindings (`handler-bind`), stack-freezing error interception. Conditions (`harness-failure`, `provider-error`, etc.) and multi-tiered restarts (`retry-with-backup`, `compact-and-retry`, `drop-to-repl-intervention`).
  * **R6 — Full-Mesh P2P Agent Mailboxes**: Dynamic extent mailbox relay pattern for thread-safe error propagation.
  * **R7 — Append-Only Audit Trail**: Thread-safe S-expression log writing, crash-safe force-output, and JSONL interop writer.

* **[user-workflows.md](file:///var/home/nrd/git/github.com/nrdxp/librecode/docs/user-workflows.md)**
  * **User Stories & Workflows**: Campaign initiation, asynchronous mobile messaging integration, REPL SLIME/Sly intervention flow, and UI/TUI connection layout.

* **[design-council-resolutions.md](file:///var/home/nrd/git/github.com/nrdxp/librecode/docs/design-council-resolutions.md)**
  * **Council Decisions**: The Design Council's formal critique, unanimous rejection verdict, and resolved architectural directives.

* **[testing.md](file:///var/home/nrd/git/github.com/nrdxp/librecode/docs/testing.md)**
  * **Testing Strategy & Parity**: White-box test porting (FiveAM) and E2E black-box UI/TUI reuse procedures.

* **[cl-guidelines.md](file:///var/home/nrd/git/github.com/nrdxp/librecode/docs/cl-guidelines.md)**
  * **Common Lisp Developer Guidance**: Style constraints, approved library dependencies, and dynamic binding/restarts guidelines.

* **[model.md](file:///var/home/nrd/git/github.com/nrdxp/librecode/docs/model.md)**
  * **The Reference State Machine (roadmap A/J)**: The pure applicative DAG/phase/deposit/gate model, its four crown-jewel invariants, the three decided degraded-mode edge cases, and the conformance seam to the runtime.

## Invariants

The system enforces the following core architectural invariants (status verified
against `src/`):

* **I1 — One provider call per turn** *[holds]*: `execute-provider-turn` issues
  exactly one `dexador:post` per pass (`runner.lisp`); the enclosing loop re-runs
  only when a restart fires, and continuation to the outer drive loop happens only
  on tool calls or promoted inputs.
* **I2 — Events are committed atomically with projections** *[holds]*: `commit-event`
  allocates the sequence (`max(sequence)+1`) and runs the `event_log` INSERT plus
  `apply-projectors` inside one `with-immediate-transaction` (`event-store.lisp`).
* **I3 — Conditions do not unwind unless a restart chooses to** *[holds — changed
  from contradicted]*: resilience sites use `handler-bind` (non-unwinding) — the
  HTTP compact-and-retry driver (`http.lisp`), the in-process harness drive loop,
  and `with-failure-relay`. (Per-node supervision deliberately uses `handler-case`
  to collect failures across independent node threads, which is by-design, not an
  I3 site.)
* **I4 — Different session keys run concurrently; same key is serialized**
  *[serialization holds; the "no raw thread interrupts" clause is currently VIOLATED]*:
  the run coordinator serializes drains per key; `interrupt-session` sets a `stopping`
  flag + CV notification + `(:interrupt)` mailbox post. However `bt:destroy-thread` was
  reintroduced at `src/runner/tool.lisp:270` (tool-timeout worker cleanup, a campaign-5
  regression) — violating the no-raw-thread-interrupts clause: a proven invariant that
  regressed because its test was removed and the gate still passed. Must-fix (roadmap B,
  first).
* **I5 — No busy-polling for message receipt** *[holds, with bounded-wait caveat]*:
  the turn loop, tool loop, and coordinator block on `receive-message` /
  `condition-wait`. Two bounded timed waits exist for liveness, not busy-polling:
  the permission ask-loop (`condition-wait :timeout 0.1`) and SSE keep-alive pings
  (`receive-message :timeout 15`).
* **I6 — Child harness processes are opaque** *[holds for cross-process; relaxed
  in-process]*: the `subprocess-harness` backend shares no memory (stdin/stdout
  s-expr events only) and is driven solely through the abstract harness generics.
  The in-process `librecode-harness` backend, by construction, shares memory with
  the parent (global `*event-broadcast-hook*`, `*active-harnesses*` registry,
  threads).
* **I7 — Audit trail is append-only and crash-safe** *[holds]*: `audit.lisp` opens
  both streams `:if-exists :append` and calls `force-output` per event.

## Architecture

### Module Structure

The tree below mirrors the three ASDF systems: `librecode-runner.asd`
(`src/packages.lisp` + `src/runner/`), `librecode-meta.asd` (`src/meta/`),
and `librecode-model.asd` (`src/model/`).

```
src/
  packages.lisp                — all package definitions (runner + meta)
  runner/                      — librecode-runner.asd
    conditions.lisp            — condition types, restart framework (R3)
    protocol.lisp              — mailboxes, run coordinator, failure-relay (R1, R3)
    event-store.lisp           — durable event sourcing, SQLite (R2)
    agent.lisp                 — CLOS agent class, permissions (R5)
    session.lisp               — session state, two-phase input model (R9)
    tool.lisp                  — tool registry, execution, settlement
    runner.lisp                — LLM provider turn execution (R8)
    compaction.lisp            — context compaction engine
    audit.lisp                 — append-only S-expression + JSONL audit trail (R7)
    http.lisp                  — Clack/Hunchentoot HTTP+SSE bridge, drive loop
  meta/                        — librecode-meta.asd
    multiplexer.lisp           — abstract multiplexer protocol (defgeneric) [stub]
    multiplexer-tmux.lisp      — tmux multiplexer backend [stub, viz-only]
    harness.lisp               — abstract harness interface (defgeneric)
    harness-subprocess.lisp    — cross-process subprocess harness backend
    harness-opencode.lisp      — OpenCode CLI harness adapter [stub]
    harness-librecode.lisp     — self-hosting: librecode as an in-process harness
    journal.lisp               — crash-safe s-expr campaign journal + replay
    campaign.lisp              — campaign DAG, Kahn layering, supervision loop
    gate.lisp                  — gate runner: shell to `nickel export`, exit-code routing
    council.lisp               — council protocol, assent validation [stub]
    conditioning.lisp          — conditioning composition [stub]
    metaharness.lisp           — supervisor entry point (R4)
  model/                       — librecode-model.asd (dependency-free; no CLOS, no threads)
    packages.lisp              — the librecode-model package
    dag.lisp                   — work DAG: validity, Kahn layering
    state-machine.lisp         — node status/phase/deposit, transitions, event log, replay
    invariants.lisp            — the four crown-jewel invariants as pure predicates
```

### Dependency Edges (load order)

Both systems load `:serial t`, so each file may depend on any file above it.

```
librecode-runner.asd:
  packages → runner/conditions → protocol → event-store → agent → session
           → tool → runner → compaction → audit → http

librecode-meta.asd (depends-on librecode-runner):
  meta/multiplexer → multiplexer-tmux → harness → harness-subprocess
           → harness-opencode → harness-librecode → journal → campaign
           → gate → council → conditioning → metaharness

librecode-model.asd (no depends-on — deliberately independent of both the
above; it is the reference model the runtime will later be conformance-
tested against, not a consumer of it):
  model/packages → dag → state-machine → invariants
```

### Technology Stack

| Layer | Choice | Rationale |
|---|---|---|
| Threading | `bordeaux-threads` (bt2) | Portable condition variables |
| Mailboxes | `sb-concurrency:mailbox` | Lock-free CAS, ships with SBCL |
| JSON | `com.inuoe.jzon` | Fast, RFC 8259, streaming |
| SQLite | `cl-sqlite` | Thin CFFI, full SQL control |
| HTTP client | `dexador` | Connection pooling, streaming |
| HTTP server | `clack` + `hunchentoot` (`clack-handler-hunchentoot`) | REST/SSE bridge |
| SSE | hand-rolled | LLM streaming; parsed from the dexador stream (no `cl-sse`) |
| Subprocess | `uiop:launch-program` | Portable async with stream handles |
| Multiplexer | tmux (**stub, viz-only** — RES-03) | Abstract protocol is a bare stub; not wired |
| Signals | `trivial-signal` | Declared dep; graceful shutdown |
| Schema | `cl-jschema` | Tool JSON-schema validation (`tool.lisp`) |

### Translation Map (Effect → CL)

| Effect Pattern | CL Equivalent |
|---|---|
| `Effect.gen(function* () {...})` | Normal function body |
| `yield* SomeService` | Special variable `*some-service*` |
| `Layer.effect(Service, ...)` | `(let ((*service* (make-service ...))) ...)` |
| `Effect.catchTag("Error", ...)` | `(handler-case ... (error-type (c) ...))` |
| `Deferred.await(d)` | `(bt:condition-wait cv lock)` |
| `FiberSet.run(...)` | `(bt:make-thread ...)` |
| `Effect.addFinalizer(...)` | `(unwind-protect ... (cleanup))` |
| `Effect.uninterruptibleMask(...)` | `(without-interrupts ...)` (sb-sys) |

## Known Unknowns & Architectural Decisions

Each entry has a **decision/lean** and a **signpost** tracking its implementation status.

### KU1 — LLM provider scope
* **Decision**: Both (Model C - Layered Bootstrap). `librecode` will support delegating model resolution and execution to child OpenCode harness sessions, but will also implement a native LLM provider wrapper using `dexador` + hand-rolled SSE stream parsing.
* **Status**: **PARTIAL.** The native provider wrapper is built (`runner.lisp`): `dexador:post :stream t` + hand-rolled OpenAI chat-completions SSE parsing. But it speaks only the OpenAI-chat-completions shape to a localhost mock URL (`http://localhost:8080/v1/chat/completions`) with **no auth header**. Real Anthropic + auth is **not wired** (the next campaign's target).

### KU2 — Session identity across process boundaries
* **Decision**: Parent-child hierarchy. The Metaharness maintains parent session contexts which manage one or more child process harness sessions.
* **Status**: **BUILT.** Realized by the `subprocess-harness` backend + `run-campaign` supervision loop; each child is driven only through the abstract harness generics. See [metaharness.md](file:///var/home/nrd/git/github.com/nrdxp/librecode/docs/metaharness.md).

### KU3 — Tool registry scope
* **Decision**: Separated tool scopes. The Metaharness exposes its own high-level orchestrator tools (such as workspace file operations, git branch creation, and gate execution), while child harnesses run their own lower-level tools natively.
* **Status**: **PARTIAL.** The runner tool registry (materialization, filtering, settlement) is built but registers only test-fixture tools. Metaharness orchestration is exposed as gate/campaign functions, not as an advertised tool set. See [agent-system.md](file:///var/home/nrd/git/github.com/nrdxp/librecode/docs/agent-system.md).

### KU4 — MCP integration
* **Decision**: Delegated. `librecode` will not directly implement an MCP client or OAuth flow. All MCP interactions are delegated to child OpenCode process harnesses, which naturally populate context maps.
* **Status**: **DEFERRED.** No MCP code exists; delegation depends on a real OpenCode backend (`harness-opencode` is a stub).

### KU5 — Config document model
* **Decision**: S-expressions + JSONC compatibility. `librecode` uses S-expressions for native configuration, but implements a thin parser (wrapping `jzon`) to read and parse OpenCode's JSON/JSONC documents for workspace compatibility.
* **Status**: **DEFERRED / design-only.** The config discovery + JSONC-loading module described in [coordination-protocol.md](file:///var/home/nrd/git/github.com/nrdxp/librecode/docs/coordination-protocol.md) §5 is not implemented. Only the RES-08 recursive deep-merge helper (`deep-merge-plists`, `tool.lisp`) exists.

### KU6 — Permission model scope
* **Decision**: Dual implementation. A static ruleset handles headless/autonomous execution, while interactive execution uses condition-restart and condition variables to block and request user permission via the UI.
* **Status**: **BUILT.** Implemented and verified by unit and property-based tests in `t/agent-tests.lisp` (`agent.lisp`).

### KU7 — Nickel contract verification
* **Decision**: Shell out. Rather than duplicating predicate's contract verification rules, `librecode`'s gate runner executes `nickel export` directly to validate DAG changes and transition state boundaries.
* **Status**: **BUILT.** `run-gate` (`gate.lisp`) shells `nickel export … --apply-contract …` via `uiop:launch-program` and routes exit codes to `protocol-invariant-violation` / `gate-failure`. Tested in `t/gate-tests.lisp`.

### KU8 — Cross-process gate evaluation
* **Decision**: Isolated worktree execution. Metaharness runs project gates and contracts against the isolated git worktree directories assigned to campaign nodes.
* **Status**: **BUILT.** Per-node worktrees (`get-node-worktree-dir`, `harness-prepare-workspace`) and gate execution scoped to the node workspace (`defgate :worktree`). See [metaharness.md](file:///var/home/nrd/git/github.com/nrdxp/librecode/docs/metaharness.md).

### KU9 — Harness capability discovery
* **Decision**: Polymorphic method dispatch. Each `harness` CLOS subclass exposes its available tools and model capacities. The campaign scheduler maps node requirements to matching harness backends.
* **Status**: **PARTIAL.** Harness-type dispatch is built — `campaign-node-harness-type` names a backend class and the scheduler dispatches the abstract generics polymorphically. Capability/model-capacity *discovery* and requirement-to-backend matching are not implemented.

## Filed Unknown-Unknowns

* Performance and contention characteristics of `sb-concurrency:mailbox` under high thread volume (>50 concurrent agent mailboxes). Benchmarking required during Phase 1.

## Style

All code and packages must conform to the [cl-guidelines.md](file:///var/home/nrd/git/github.com/nrdxp/librecode/docs/cl-guidelines.md) specification (including naming conventions, dynamic variable contexts, and approved library dependencies).

## Commits

Use conventional commit messages: `type(scope): summary`.

Valid types: `feat`, `fix`, `docs`, `chore`, `refactor`, `test`.
Scopes: `core`, `protocol`, `events`, `agent`, `session`, `runner`,
`compaction`, `tool`, `mux`, `metaharness`.

Do not add co-author trailers. Do not push. Do not rewrite history.
