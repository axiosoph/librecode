# librecode

**Maturity**: molten (pre-1.0). Refactor and cut freely.

## Goal

Reimplement the core OpenCode multi-agent coordination protocol as a
high-performance Common Lisp (SBCL) system that simultaneously serves as a
**Metaharness** — a parent orchestrator process capable of spawning, monitoring,
and supervising multiple child harness instances inside a multiplexed terminal
session.

The system translates OpenCode's TypeScript/Effect coordination primitives into
native CL mechanical equivalents, replacing the V8 runtime with SBCL threading,
the Effect algebraic effect system with dynamic binding and condition/restart, and
the central async bus with thread-safe non-blocking mailboxes.

## Alignment to Parent

librecode is a **reimplementation** of the OpenCode codebase in Common Lisp. It
ports the coordination protocol, session execution model, event sourcing, agent
hierarchy, and runner loop into native CL equivalents, and extends the result
with metaharness supervisor capabilities that don't exist in the original
TypeScript implementation.

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

## Requirements

### R1 — Run Coordinator with Wake Coalescing
Faithful port of OpenCode's `SessionRunCoordinator`: per-key serialized execution,
coalesced advisory wakes, successor drain chaining, join-existing-drain semantics.
Built on `sb-concurrency:mailbox` + `bt:condition-variable`.

### R2 — Event-Sourced Session State
Durable event log in SQLite with aggregate sequencing, synchronous projectors
inside the commit transaction, and PubSub notification after commit. Events are
the source of truth; all read models are projections.

### R3 — Condition-Restart Failure Recovery
Custom conditions (`harness-failure`, `provider-error`, `context-overflow`,
`tool-timeout`, `process-hang`) with multi-tiered restarts (`retry-with-backup-provider`,
`compact-and-retry`, `inject-corrected-payload`, `drop-to-repl-intervention`,
`skip-and-continue`). The stack freezes at the failure point — no unwinding
unless a restart explicitly chooses to.

### R4 — Metaharness Supervision via Multiplexer Protocol
Spawn and monitor child harness processes (including native OpenCode CLI instances)
through an abstract multiplexer protocol (`defgeneric`). The initial concrete
implementation targets tmux, but the protocol must not leak tmux-specific
concepts — other multiplexers (zellij, screen, direct PTY management) must be
implementable without changing the supervisor. Continuously scrape pane buffers
for health/output. Supervisor loop uses the condition-restart engine for
recovery. Track global state in SQLite or in-memory hash table.

### R5 — Agent Type Hierarchy via CLOS
Agent types (`build-agent`, `plan-agent`, `explore-agent`, `general-agent`) as
CLOS classes. Tool availability and permission enforcement dispatch on agent type
via `defgeneric`. Mode switching (build ↔ plan) is agent switching with different
permission rulesets — no hardcoded guards.

### R6 — Full-Mesh P2P Agent Mailboxes
Replace the central async bus. Each agent gets an `sb-concurrency:mailbox`.
Agents communicate peer-to-peer via direct `send-message` / `receive-message`.
Auto-wake via `bt:condition-variable` — no polling.

### R7 — O(1) Append-Only Audit Trail
Thread-safe streaming to S-expression log files (native format) with JSONL
writer for cross-system interop. Every event, condition signal, restart
invocation, and sub-harness lifecycle transition is logged.

### R8 — LLM Provider Turn Execution
Single explicit `llm.stream(request)` call per provider turn. Load projected
history before each turn. Parallel tool execution via threads with
`unwind-protect` settlement. Compaction when context budget overflows.

### R9 — Two-Phase Input Admission
Separate `admit` (durable inbox record) from `promote` (model-visible delivery).
Steer inputs promote at the next safe provider-turn boundary. Queue inputs
promote one-at-a-time when the session would otherwise go idle.

### R10 — Context Epochs
Snapshot system context at session start. On subsequent turns, diff against the
snapshot and emit only delta `context-updated` events. Post-compaction: replace
the epoch entirely with a fresh baseline.

## Invariants

### I1 — One provider call per turn
The runner issues exactly one streaming LLM call per turn. The loop continues
only when tool calls require continuation or pending inputs need promotion.

### I2 — Events are committed atomically with projections
A durable event and its projector(s) execute inside the same SQLite transaction.
The read model is never behind the event log.

### I3 — Conditions do not unwind unless a restart chooses to
`handler-bind` is the default, not `handler-case`. The stack is preserved at the
signal site. A restart may choose to unwind, but the default posture is repair
in place.

### I4 — Different session keys run concurrently; same key is serialized
The coordinator permits unbounded concurrency across session keys. Within a
single key, execution is strictly serial with coalesced wakes.

### I5 — No polling for message receipt
Agent mailboxes wake blocked receivers via condition variables. The event loop
blocks on `bt:condition-wait`, not `sleep`+check.

### I6 — Child harness processes are opaque
The metaharness interacts with child processes only through the multiplexer
protocol (pane I/O and exit codes). It does not link to or share memory with
child process internals.

### I7 — Audit trail is append-only and crash-safe
`force-output` after every audit write. No in-place mutation of log entries.

## Architecture

### Module Structure

```
src/
  packages.lisp          — package definitions
  conditions.lisp        — condition types, restart framework
  protocol.lisp          — mailboxes, run coordinator, event loop
  event-store.lisp       — durable event sourcing (SQLite)
  agent.lisp             — CLOS agent hierarchy, permissions
  session.lisp           — session state machine, history, input model
  runner.lisp            — LLM provider turn execution
  compaction.lisp        — context compaction engine
  tool.lisp              — tool registry, execution, settlement
  multiplexer.lisp       — abstract multiplexer protocol (defgeneric)
  multiplexer-tmux.lisp  — tmux implementation of multiplexer protocol
  metaharness.lisp       — supervisor entry point
```

### Dependency Edges (load order)

```
packages → conditions → protocol → event-store → agent → session → runner
                                                              ↓
                                                          compaction
                                                              ↓
                                                            tool
                                                              ↓
                                              multiplexer → metaharness
                                                   ↑
                                            multiplexer-tmux
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

## Known Unknowns

Each entry has a **signpost** — the specific action that resolves it.

### KU1 — LLM provider scope
**Question**: Does librecode make its own LLM API calls (reimplementing the
provider abstraction with dexador/SSE), or does it delegate all LLM work to
managed OpenCode child instances and only orchestrate?

**Source finding**: OpenCode's LLM pipeline is a `Route` composing four axes
(Protocol + Endpoint + Auth + Framing). The `fromCatalogModel()` bridge maps
`api.package` strings to protocol routes. Reimplementing the streaming pipeline
with dexador/SSE is ~500 LoC; reimplementing the full catalog/model-resolution
layer on top is another ~300 LoC.

**Signpost**: nrd decision. If librecode makes its own calls, we reimplement
Route construction and SSE streaming. If it delegates, the runner module
becomes a child-session dispatcher. The cleanest delegation boundary is at the
session level — let a child process own model resolution, config, permissions,
MCP, and system context; the parent creates sessions and observes events.

**Current lean**: Both — librecode has a native LLM client for direct use,
*and* can orchestrate child OpenCode instances for cases where the full
OpenCode tool/plugin ecosystem is needed.

### KU2 — Session identity across process boundaries
**Question**: Does the metaharness have its own session concept that wraps child
harness sessions? Is there a parent-child session hierarchy across the process
boundary, or are they flat/independent?

**Signpost**: Resolve by deciding the metaharness's coordination model. If it
runs its own sessions that spawn child harness tasks (like OpenCode's `task`
tool spawns subagent sessions), the hierarchy is natural. If the metaharness is
purely a process supervisor with no session concept, sessions live only inside
children.

### KU3 — Tool registry scope
**Question**: Does the metaharness expose its own tool set to agents it runs
directly, or does it purely supervise child instances that have their own tools?

**Signpost**: Follows from KU1. If librecode runs its own LLM sessions, it
needs a tool registry. If it only orchestrates children, tools live in children.

### KU4 — MCP integration
**Question**: Does librecode need to connect to MCP servers directly, or does
it delegate MCP to child OpenCode instances?

**Source finding**: MCP lives in `packages/opencode` (not `core`) — ~1000 lines
of client lifecycle, transport setup (stdio/SSE/StreamableHTTP), OAuth, and tool
conversion. It is purely a tool-discovery and execution mechanism. MCP
instructions are injected as system context. No V2 tool registry integration yet
(still V1 path). `40ants/mcp` exists as a CL MCP server implementation if we
need the server side.

**Signpost**: nrd decision. Delegating MCP to child OpenCode instances is the
path of least resistance. Reimplementing MCP natively requires a CL MCP client
library (none exists for the client side — `40ants/mcp` is server-only). Build
a client only if librecode needs MCP tools without a child process.

### KU5 — Config document model
**Question**: What config formats does librecode support? Does it read
OpenCode's config format for compatibility, define its own, or both?

**Source finding**: OpenCode config is JSONC (`opencode.json`/`opencode.jsonc`),
discovered by walking upward from CWD to project root + global config dir.
Merge is simple last-write-wins per top-level field. The schema (`Config.Info`)
has ~25 top-level fields covering shell, model, agents, MCP, permissions,
providers, plugins, etc. V1 migration is built in.

**Signpost**: If librecode reads OpenCode configs for compatibility, it needs a
JSONC parser (jzon handles standard JSON; trailing-comma JSONC needs a small
preprocessor or a different parser). If it defines its own, S-expressions or a
CL-native format. Resolve after KU1.

### KU6 — Permission model scope
**Question**: Does librecode need the interactive ask/reply permission flow, or
is a static ruleset sufficient?

**Source finding**: OpenCode's `PermissionV2` uses a last-match-wins evaluation
with three effects: `allow`, `deny`, `ask`. The `ask` flow creates a pending
`Deferred`, publishes an event, and blocks until the TUI sends a reply.
Rejection cascades to all pending requests for the same session. Saved
"always allow" decisions persist to SQLite per project.

**Signpost**: If librecode runs headless/autonomous, supply a static ruleset
resolving everything to `allow` (or per-tool deny) — the ask/deferred mechanism
is unnecessary. If it has a REPL or TUI, the interactive flow needs
reimplementation. The condition/restart system is a natural fit for the
ask-and-block pattern.

## Filed Unknown-Unknowns

- Performance characteristics of `sb-concurrency:mailbox` under high
  contention with many agent threads (>50). May need benchmarking.
- SBCL's behavior when `bt:interrupt-thread` targets a thread blocked on
  `bt:condition-wait`. Need to verify this works reliably for coordinator
  interrupt semantics.
- Whether `cl-sqlite` supports WAL mode and concurrent readers during a write
  transaction, which the event store's projector-in-transaction pattern requires.
- Whether the `cl-sse` client library handles reconnection and partial-line
  buffering correctly for long-running LLM streams, or whether we need a
  hand-rolled SSE reader.
- Whether `calispel` (CSP channels with blocking `select`/`fair-alt`) would
  complement raw mailboxes for structured inter-component pipelines, or whether
  the added abstraction is unjustified complexity at this scale.

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
