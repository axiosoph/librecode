# librecode Multi-Agent Coordination Protocol

This specification outlines the event-sourced session coordination engine and turn-based LLM execution loop ported from OpenCode.

## 1. Run Coordinator with Wake Coalescing

The Run Coordinator enforces serialized execution per session key while permitting full parallel concurrency across different session keys.

### Design Principles

* **Single Writer**: Only one thread can active-drain a session's pending inputs at a time.
* **Coalesced Wakes**: Multiple wake signals received during an active drain do not spawn multiple successor drains. They are coalesced into a single wake indicator. When the current drain completes, it immediately chains into a successor drain if the wake indicator is active.
* **Join Semantics**: If a run request is received for a session that is already draining on a thread, the new request blocks on a condition variable until the active drain completes.

### CL Implementation

The coordinator tracks active sessions using a hash table protected by a global lock. Each session's execution state is represented by a `coordinator-entry` structure:

```lisp
(defstruct coordinator-entry
  (id nil :type string)
  (lock (bt:make-lock) :read-only t)
  (cv (bt:make-condition-variable) :read-only t)
  (pending-wake nil :type boolean)
  (stopping nil :type boolean)
  (active-thread nil))
```

To interrupt a session:
1. Set the `stopping` flag to `t` on its `coordinator-entry`.
2. Notify the condition variable to wake the draining thread if it is blocked on tool execution.
3. The draining thread intercepts the flag, cleans up resources via `unwind-protect`, and exits, allowing the next queued request to acquire the session lock. (Note: Async thread interrupts like `bt:interrupt-thread` are strictly forbidden to prevent mutex corruption).

---

## 2. Event-Sourced Session State

Every change in a session's state is modeled as a sequence of immutable events written to a durable event log.

### Schema & Persistence

Events are stored in a SQLite database. The event store enforces sequencing using aggregate versioning.
* Database connections must be scoped **per thread** (one connection per thread) to ensure thread-safety.
* **WAL Mode**: The database operates with `PRAGMA journal_mode=WAL` to allow concurrent readers to query the state while a writer transaction is active.
* **Busy Timeout**: All connections assert `PRAGMA busy_timeout=5000` to handle transient lock contentions gracefully.

### Atomic Projection Invariant

To guarantee that read models are never behind the event log:
* A durable event and its corresponding projection updates must be executed **inside the same SQLite transaction**.
* Every transaction begins with `BEGIN IMMEDIATE` to prevent deadlocks under concurrent write contentions.

```lisp
(defun commit-event (session-id event type version)
  (sqlite:with-transaction (db)
    (sqlite:execute-non-query db "INSERT INTO event_log ...")
    (apply-projectors db session-id event type version)))
```

---

## 3. Two-Phase Input Admission

To manage user steering and queued inputs in an asynchronous environment, input delivery is decoupled into two phases:

### Phase 1: Input Admission (`admit`)
Inputs arriving from the user (via HTTP, terminal, or peer mailboxes) are written immediately to a durable `session_input` record in the database. This ensures no input is lost in the event of a system crash.

### Phase 2: Input Promotion (`promote`)
Admitted inputs are promoted to become visible to the LLM model at precise turn boundaries:
* **Steer Inputs**: These inputs (e.g. feedback, quick redirects) are promoted immediately at the next safe provider-turn boundary.
* **Queue Inputs**: These inputs remain pending until the session runner has completely processed the current task and is about to go idle. The runner then promotes exactly one queued input, resets the model's turn allowance, and begins a new drain.

---

## 4. LLM Turn Execution Loop

A single session execution drain consists of a sequence of turns. The loop enforces strict invariants on LLM invocations and tool execution.

### Single Provider Call Invariant

* The runner issues **exactly one** streaming LLM call per turn using `dexador` with `:want-stream t` for incremental line-by-line SSE chunk parsing.
* Loop continuation is only permitted if the model returned tool calls requiring execution, or if new steering inputs require immediate promotion.

### Parallel Tool Execution & Settlement

When the model emits multiple tool calls:
1. The runner resolves and materializes the tools from the `tool-registry`.
2. Each tool executes concurrently in its own thread.
3. Tool execution is wrapped in `unwind-protect` to ensure that even if a tool times out, is interrupted, or crashes, its resource bounds are cleaned up and its final result (or failure diagnostic) is settled.
4. If a tool fails, its exception is captured and relayed to the coordinator thread using a mailbox message (see the Resilience specification for details).

### Compaction & Context Epochs

* **Context Epochs**: To conserve context budget, `librecode` snapshots the system context at the start of a session. On subsequent turns, it computes a diff against this snapshot and transmits only a `context-updated` delta event.
* **Compaction**: When the context size exceeds a threshold, the compaction engine runs a summarization pass (folding older context while preserving recent messages) and replaces the epoch baseline entirely.

---

## 5. Configuration Model

`librecode` supports both its native S-expression format for CLI execution and OpenCode's JSON/JSONC documents for workspace compatibility.

### Discovery & Loading

At location context construction, `librecode` builds the configuration by walking the file tree:
1. **Upward Walk**: Walks upward from the current working directory (CWD) to the project root directory looking for `.opencode/` folders or `opencode.json` / `opencode.jsonc` files.
2. **Global Config**: Loads the user's global config from `~/.opencode/` or platform equivalent.
3. **Caching**: Config is loaded once when the location context is opened and cached. Changes take effect on session restart or context reload.

### Parsing JSONC (JSON with Comments)

Since Common Lisp's `com.inuoe.jzon` parses strict RFC 8259 JSON, `librecode` implements a lightweight preprocessor to load JSONC files:
* Strip all single-line comments (`// ...`).
* Strip all multi-line comments (`/* ... */`).
* Strip trailing commas before closing braces `}` or brackets `]`.
* Pass the cleaned string to `jzon:parse`.

### Merge Semantics

When multiple config files are discovered (e.g. global, project-root, and subdirectory configs):
* The configuration is resolved by merging the files in order of ascending priority: global config -> project config -> subdirectory config.
* **Field Resolution**: The merge uses a flat **last-write-wins** replacement policy per top-level key. `librecode` does not perform deep recursive merging on nested config objects.
* Once loaded, the JSON document is mapped to an internal CL struct representing the active system config.

---

## 6. HTTP API Server & REPL Interface

`librecode-runner` exposes an external HTTP API and an interactive REPL interface to support integration with the OpenCode UI client and local developer maintenance.

### HTTP REST / SSE Server

The runner initiates a lightweight multi-threaded HTTP server (powered by `Clack` wrapping `Hunchentoot`) to listen for frontend requests.

* **`POST /session/:id/admit`**: Receives user inputs (prompts or steering instructions) and writes them to the durable database inbox (R9).
* **`GET /session/:id/events`**: Establishes a server-sent events (SSE) connection, streaming EventV2 events to the UI client as they are committed to the SQLite store (R2).
* **`POST /session/:id/control`**: Handles control commands (such as waking the run coordinator or signaling an interrupt to active session execution).
* **`GET /status`**: Returns health diagnostics and run status of the active runner process.

All endpoints validate authorization parameters and route requests to the matching session mailbox or key lock (R1, R6).

### Interactive REPL Boundary

In interactive execution mode, `librecode-runner` provides a REPL listener:
* **Interactive Restarts**: Serious conditions signaled during a turn drop the runner thread into an interactive REPL interface (`drop-to-repl-intervention`).
* **Stack Inspection**: Developers can query active session coordinates, examine the execution stack trace, inspect local variable values, and force custom recovery states.
* **Dynamic Rebinds**: The REPL allows hot-reloading package functions and tool definitions on the fly, resuming execution at the exact signal boundary without losing the dynamic context.

---

## 7. ASDF System & Package Layout

`librecode` is organized as a single directory repository containing two decoupled ASDF systems to maintain clean boundaries between the runner execution engine and the metaharness coordinator.

### System Definitions (`librecode.asd`)

```lisp
(defsystem "librecode-runner"
  :description "The Common Lisp reimplementation of OpenCode's single-agent harness."
  :version "0.1.0"
  :author "nrd"
  :depends-on ("bordeaux-threads" "cl-sqlite" "com.inuoe.jzon" "dexador" "uiop")
  :pathname "src/"
  :serial t
  :components ((:file "packages")
               (:file "conditions")
               (:file "protocol")
               (:file "event-store")
               (:file "agent")
               (:file "session")
               (:file "runner")
               (:file "compaction")
               (:file "tool")
               (:file "audit")))

(defsystem "librecode-meta"
  :description "The parent orchestrator for multi-agent campaigns (Metaharness)."
  :version "0.1.0"
  :author "nrd"
  :depends-on ("librecode-runner" "trivial-signal")
  :pathname "src/"
  :serial t
  :components ((:file "multiplexer")
               (:file "multiplexer-tmux")
               (:file "harness")
               (:file "harness-opencode")
               (:file "harness-librecode")
               (:file "campaign")
               (:file "gate")
               (:file "council")
               (:file "conditioning")
               (:file "metaharness")))
```

### Package Structure (`src/packages.lisp`)

To prevent dependency cycles and maintain isolation:
* **`librecode-runner.*`**: Standard package naming partition for harness layers (e.g. `librecode-runner.event-store` exports `commit-event` and `apply-projectors` but has no knowledge of campaigns or tmux multiplexers).
* **`librecode-meta.*`**: Package partition for Metaharness layers (e.g. `librecode-meta.campaign` imports the abstract `harness` protocol and schedules DAG nodes).
* All internal variables and helper functions remain unexported, forcing all components to interact exclusively through their public API functions.

