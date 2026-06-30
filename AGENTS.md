# librecode

**Maturity**: molten (pre-1.0). Refactor and cut freely.

## Goal

Reimplement the core OpenCode multi-agent coordination protocol as a high-performance Common Lisp (SBCL) system (**librecode-runner**), and extend this architecture with a decoupled cross-harness parent orchestrator (**librecode-meta** or the **Metaharness**) capable of supervising multiple child agent harnesses in a "Team of Teams" topology.

The project contains two independent but co-located subsystems:
1. **`librecode-runner` (The Harness)**: The CL native reimplementation of OpenCode's single-agent execution harness (session loops, EventV2 state projection, local tools, dynamic permissions, LLM calls).
2. **`librecode-meta` (The Metaharness)**: The parent coordinator that executes multi-agent campaigns by scheduling DAG tasks, convening councils, and dispatching work across physical process boundaries to heterogeneous child harnesses (e.g. `librecode-runner`, `harness-opencode`, `harness-claude-code`).

## Alignment to Parent

`librecode` is a **reimplementation and extension** of OpenCode. It ports coordination and execution primitives to native CL equivalents (replacing JS/Effect with dynamic binding, condition/restart, SBCL threads, and mailboxes), and introduces the Metaharness layer to coordinate across disparate agent harnesses.

### Ported from OpenCode (TypeScript source is the reference)

- Run coordinator with wake coalescing (R1)
- Event-sourced session state and projectors (R2)
- Agent type hierarchy and permission-driven mode enforcement (R5)
- LLM provider turn execution loop (R8)
- Two-phase input admission: admit/promote (R9)
- Context epochs: snapshot, diff, replace (R10)
- Compaction engine: token-budget summarization
- Tool registry, materialization, and settlement

### Novel to librecode (no TypeScript counterpart)

- Condition-restart failure recovery (R3) — replaces Effect's try/catch with
  stack-freezing repair-in-place semantics
- Abstract multiplexer protocol and metaharness supervision (R4) — spawning,
  monitoring, and recovering child harness processes across a terminal
  multiplexer; this capability does not exist in OpenCode
- Full-mesh P2P agent mailboxes (R6) — replaces the central async bus with
  direct peer-to-peer `sb-concurrency:mailbox` communication
- S-expression audit trail (R7) — native format with JSONL interop writer

### Not ported (deliberately excluded)

- Vercel AI SDK bridge (`core/src/aisdk.ts`) — OpenCode uses this as an
  intermediary to resolve `ModelV2.Info` → `LanguageModelV3`. librecode talks
  to LLM provider APIs directly via dexador/SSE, bypassing the SDK layer.
- Subagent communication via event store indirection — OpenCode's `task` tool
  spawns child sessions and blocks on their event streams; there is no direct
  message-passing between agents. librecode replaces this with P2P mailboxes
  (R6) for in-process agents while retaining the event-store-mediated pattern
  for cross-process child harness sessions.

## Requirements & Specifications

The implementation of `librecode` is divided into key modules, each documented exhaustively in the `docs/` folder:

* **[coordination-protocol.md](file:///var/home/nrd/git/github.com/nrdxp/librecode/docs/coordination-protocol.md)**
  * **R1 — Run Coordinator with Wake Coalescing**: Serialized execution per key, wake coalescing, join semantics.
  * **R2 — Event-Sourced Session State**: Durable log in SQLite, aggregate versioning, WAL mode, atomic projection transaction constraint.
  * **R8 — LLM Provider Turn Execution**: dexador `:want-stream t` incremental chunk SSE reading, parallel tool execution, unwind-protect settlement, compaction.
  * **R9 — Two-Phase Input Admission**: Decoupled `admit` (durable inbox) and `promote` (model-visible delivery) phases.
  * **R10 — Context Epochs**: Session-start system context snapshots, diff updates, and baseline resets.

* **[metaharness.md](file:///var/home/nrd/git/github.com/nrdxp/librecode/docs/metaharness.md)**
  * **R4 — Metaharness Supervision**: Decoupled abstract harness interface (generic functions) and terminal multiplexer protocol. Initial tmux transport backend.
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

## Invariants

The system enforces the following core architectural invariants:

* **I1 — One provider call per turn**: The session runner performs exactly one LLM call per turn; continuation is only triggered by tool calls or promoted inputs.
* **I2 — Events are committed atomically with projections**: A durable event and its projections run inside the same SQLite transaction.
* **I3 — Conditions do not unwind unless a restart chooses to**: dynamic handlers (`handler-bind`) preserve stack execution contexts at the error signaling site.
* **I4 — Different session keys run concurrently; same key is serialized**: Run coordinator serializes drains per key. Interrupting a session uses a dynamic `stopping` flag + condition notification (avoiding raw thread interrupts).
* **I5 — No polling for message receipt**: Threads block on `bt:condition-wait` or mailbox semaphores, waking up on event arrival.
* **I6 — Child harness processes are opaque**: The Metaharness coordinates child processes strictly through the abstract harness/multiplexer interfaces, with no shared memory access.
* **I7 — Audit trail is append-only and crash-safe**: Log writes use append mode and force-output immediately.

## Architecture

### Module Structure

```
src/
  packages.lisp          — package definitions
  conditions.lisp        — condition types, restart framework (R3)
  protocol.lisp          — mailboxes, run coordinator, event loop (R1, R6)
  event-store.lisp       — durable event sourcing, SQLite (R2)
  agent.lisp             — CLOS agent hierarchy, permissions (R5)
  session.lisp           — session state machine, history, input model (R9)
  runner.lisp            — LLM provider turn execution (R8)
  compaction.lisp        — context compaction engine
  tool.lisp              — tool registry, execution, settlement
  audit.lisp             — append-only S-expression audit trail (R7)

  ;; --- metaharness layer ---
  harness.lisp           — abstract harness interface (defgeneric)
  harness-librecode.lisp — self-hosting: librecode as a managed harness
  harness-opencode.lisp  — OpenCode CLI harness adapter
  multiplexer.lisp       — abstract multiplexer protocol (defgeneric)
  multiplexer-tmux.lisp  — tmux implementation of multiplexer protocol
  campaign.lisp          — campaign DAG, Kahn layering, dispatch/reconcile loop
  council.lisp           — council protocol, delegation table, assent validation
  conditioning.lisp      — conditioning composition + per-harness delivery
  gate.lisp              — gate runner: shell-out, exit-code routing, scope dispatch
  metaharness.lisp       — supervisor entry point (R4)
```

### Dependency Edges (load order)

```
packages → conditions → protocol → event-store → agent → session → runner → compaction → tool
  ↓
multiplexer → multiplexer-tmux → harness → (harness-opencode, harness-librecode)
  ↓
campaign → gate → council → audit → conditioning → metaharness
```

### Technology Stack

| Layer | Choice | Rationale |
|---|---|---|
| Threading | `bordeaux-threads` (bt2) | Portable condition variables |
| Mailboxes | `sb-concurrency:mailbox` | Lock-free CAS, ships with SBCL |
| JSON | `com.inuoe.jzon` | Fast, RFC 8259, streaming |
| SQLite | `cl-sqlite` | Thin CFFI, full SQL control |
| HTTP | `dexador` | Connection pooling, streaming |
| SSE | `cl-sse` or hand-rolled | LLM streaming protocol |
| Subprocess | `uiop:launch-program` | Portable async with stream handles |
| Multiplexer | tmux (initial target) | Abstract protocol; other backends later |
| Signals | `trivial-signal` | Graceful shutdown |
| Dep locking | `qlot` | Reproducible builds in CI |

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
* **Status**: High-level design complete. Detailed stream parsing specification defined in [coordination-protocol.md](file:///var/home/nrd/git/github.com/nrdxp/librecode/docs/coordination-protocol.md).

### KU2 — Session identity across process boundaries
* **Decision**: Parent-child hierarchy. The Metaharness maintains parent session contexts which manage one or more child process harness sessions.
* **Status**: Mapped in [metaharness.md](file:///var/home/nrd/git/github.com/nrdxp/librecode/docs/metaharness.md).

### KU3 — Tool registry scope
* **Decision**: Separated tool scopes. The Metaharness exposes its own high-level orchestrator tools (such as workspace file operations, git branch creation, and gate execution), while child harnesses run their own lower-level tools natively.
* **Status**: Documented in [agent-system.md](file:///var/home/nrd/git/github.com/nrdxp/librecode/docs/agent-system.md).

### KU4 — MCP integration
* **Decision**: Delegated. `librecode` will not directly implement an MCP client or OAuth flow. All MCP interactions are delegated to child OpenCode process harnesses, which naturally populate context maps.
* **Status**: Design locked.

### KU5 — Config document model
* **Decision**: S-expressions + JSONC compatibility. `librecode` uses S-expressions for native configuration, but implements a thin parser (wrapping `jzon`) to read and parse OpenCode's JSON/JSONC documents for workspace compatibility.
* **Status**: Config loading specification defined in [coordination-protocol.md](file:///var/home/nrd/git/github.com/nrdxp/librecode/docs/coordination-protocol.md).

### KU6 — Permission model scope
* **Decision**: Dual implementation. A static ruleset handles headless/autonomous execution, while interactive execution uses condition-restart and condition variables to block and request user permission via the UI.
* **Status**: Mapped in [agent-system.md](file:///var/home/nrd/git/github.com/nrdxp/librecode/docs/agent-system.md).

### KU7 — Nickel contract verification
* **Decision**: Shell out. Rather than duplicating predicate's contract verification rules, `librecode`'s gate runner executes `nickel export` directly to validate DAG changes and transition state boundaries.
* **Status**: Gate integration mapped in [metaharness.md](file:///var/home/nrd/git/github.com/nrdxp/librecode/docs/metaharness.md).

### KU8 — Cross-process gate evaluation
* **Decision**: Isolated worktree execution. Metaharness runs project gates and contracts against the isolated git worktree directories assigned to campaign nodes.
* **Status**: Documented in [metaharness.md](file:///var/home/nrd/git/github.com/nrdxp/librecode/docs/metaharness.md).

### KU9 — Harness capability discovery
* **Decision**: Polymorphic method dispatch. Each `harness` CLOS subclass exposes its available tools and model capacities. The campaign scheduler maps node requirements to matching harness backends.
* **Status**: Outlined in [metaharness.md](file:///var/home/nrd/git/github.com/nrdxp/librecode/docs/metaharness.md).

## Filed Unknown-Unknowns

* Performance and contention characteristics of `sb-concurrency:mailbox` under high thread volume (>50 concurrent agent mailboxes). Benchmarking required during Phase 1.

## Style

- Common Lisp, targeting SBCL exclusively.
- ASDF for build. Single `.asd` initially; split into subsystems when justified.
- `defpackage` per module. Internal symbols are unexported.
- Prefer `handler-bind` over `handler-case` unless unwinding is intentional.
- Prefer `defstruct` over `defclass` for value types (events, messages, config).
  Use `defclass` for entities with polymorphic dispatch (agents, tools).
- Comments say why, not what. Docstrings on exported symbols.
- No `defmethod` without a corresponding `defgeneric`.
- Test with FiveAM. Tests in a separate `librecode-test` system.

## Commits

Use conventional commit messages: `type(scope): summary`.

Valid types: `feat`, `fix`, `docs`, `chore`, `refactor`, `test`.
Scopes: `core`, `protocol`, `events`, `agent`, `session`, `runner`,
`compaction`, `tool`, `mux`, `metaharness`.

Do not add co-author trailers. Do not push. Do not rewrite history.
