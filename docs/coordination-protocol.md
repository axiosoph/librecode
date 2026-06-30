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
  (waiters-count 0 :type integer) ; Reference counter to prevent idle deletion races
  (active-thread nil))
```

To interrupt a session:
1. Set the `stopping` flag to `t` on its `coordinator-entry`.
2. Post an explicit control message `(:interrupt)` to the session's dynamic event mailbox. This immediately wakes the coordinator thread if it is blocked on its mailbox waiting for events.
3. The draining thread intercepts the flag, cleans up resources via `unwind-protect` (including terminating any running child tool threads), and exits, allowing the next queued request to acquire the session lock. (Note: Async thread interrupts like `bt:interrupt-thread` are strictly forbidden to prevent mutex corruption).

---

## 2. Event-Sourced Session State

Every change in a session's state is modeled as a sequence of immutable events written to a durable event log.

### Schema & Persistence

Events are stored in a SQLite database. The event store enforces sequencing using aggregate versioning.
* Database connections must be scoped **per thread** (one connection per thread) to ensure thread-safety.
* **Foreign Keys**: Every connection establishment hook must execute `PRAGMA foreign_keys = ON;` immediately to enforce cascading DDL constraints.
* **WAL Mode**: The database operates with `PRAGMA journal_mode=WAL` to allow concurrent readers to query the state while a writer transaction is active.
* **Busy Timeout**: All connections assert `PRAGMA busy_timeout=5000` to handle transient lock contentions gracefully.

### Atomic Projection Invariant

To guarantee that read models are never behind the event log:
* A durable event and its corresponding projection updates must be executed **inside the same SQLite transaction**.
* Every transaction begins with `BEGIN IMMEDIATE` to prevent deadlocks under concurrent write contentions. In Common Lisp, since the default `sqlite:with-transaction` issues a `DEFERRED` transaction, we use a custom `with-immediate-transaction` macro:

```lisp
(defmacro with-immediate-transaction ((db) &body body)
  `(let ((ok nil))
     (sqlite:execute-non-query ,db "BEGIN IMMEDIATE TRANSACTION")
     (unwind-protect
          (multiple-value-prog1
              (progn ,@body)
            (sqlite:execute-non-query ,db "COMMIT")
            (setf ok t))
       (unless ok
         (sqlite:execute-non-query ,db "ROLLBACK")))))

(defun commit-event (session-id event type version)
  (with-immediate-transaction (db)
    (sqlite:execute-non-query db "INSERT INTO event_log ...")
    (apply-projectors db session-id event type version)))
```

---

## 3. Two-Phase Input Admission & Retry Reconciliation

To manage user steering and queued inputs in an asynchronous environment, input delivery is decoupled into two phases:

### Phase 1: Input Admission (`admit`)
Inputs arriving from the user (via HTTP, terminal, or peer mailboxes) are written immediately to a durable `session_input` record in the database. This ensures no input is lost in the event of a system crash.

#### Prompt ID Reuse and Retry Reconciliation
To satisfy OpenCode's retry policy without database primary key conflicts on `session_input.id`:
* When a prompt is admitted, if its ID already exists in the `session_input` table:
  1. Retrieve the existing row.
  2. If the `session_id`, `prompt_text`, and `delivery_mode` match the existing row:
     * If the status is `PROMOTED`, return the existing session state and resume the connection (allowing client reconnection to active streams).
     * If the status is `PENDING`, treat as a no-op (the input is already admitted and awaiting promotion).
     * If the status is `EXPIRED` or the transaction crashed, update the status to `PENDING` to reschedule it.
  3. If the fields do not match (a conflicting message ID reuse), the admission handler must fail immediately and reject the request.

### Phase 2: Input Promotion (`promote`)
Admitted inputs are promoted to become visible to the LLM model at precise turn boundaries:
* **Steer Inputs**: These inputs (e.g. feedback, quick redirects) are promoted immediately at the next safe provider-turn boundary.
* **Queue Inputs**: These inputs remain pending until the session runner has completely processed the current task and is about to go idle. The runner then promotes exactly one queued input, resets the model's turn allowance, and begins a new drain.

---

## 4. LLM Turn Execution Loop

A single session execution drain consists of a sequence of turns. The loop enforces strict invariants on LLM invocations and tool execution.

### Single Provider Call Invariant & Unified Mailbox Event Loop

To eliminate polling latency and solve socket-read blocking issues, the coordinator thread runs a unified event loop blocking exclusively on its mailbox. All I/O and process waiting is delegated to helper threads:

* **SSE Streaming Reader**: The coordinator spawns a dedicated reader thread that performs blocking reads (e.g. `read-line`) on the `dexador` stream (with `:want-stream t`). For every chunk or line read, it posts `(:sse-line line)` to the coordinator mailbox.
* **Socket Interrupts**: To interrupt a blocking socket read, the coordinator thread explicitly calls `close` on the dexador stream. This immediately signals a stream error in the reader thread, causing it to terminate cleanly.
* **Subprocess Waiters**: All external subprocesses (e.g. CLI tools) are spawned asynchronously via `uiop:launch-program` (using absolute binary paths). The coordinator spawns a waiter thread that calls `uiop:wait-process` and posts `(:process-exited exit-code)` to the coordinator mailbox upon completion.
* **Subprocess Interrupts**: If an interrupt is signaled to the session, the coordinator issues an OS signal (e.g. `SIGTERM` or `SIGKILL`) to the child process handle to terminate it immediately.
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
* **Event Replay Self-Containment Invariant**: Every baseline snapshot and compaction summary payload must be saved to the database as a `context-baseline-updated` event inside the immutable `event_log`. This ensures the session state can be fully replayed from sequence 0 without losing historical baselines. The `context_epoch` database table is strictly a fast read-projection cache of the latest baseline.

---

## 5. Configuration Model

`librecode` supports both its native S-expression format for CLI execution and OpenCode's JSON/JSONC documents for workspace compatibility.

### Discovery & Loading

At location context construction, `librecode` builds the configuration by walking the file tree:
1. **Upward Walk**: Walks upward from the dynamically bound `*workspace-root*` or an explicitly passed directory to the project root directory looking for `.opencode/` folders or `opencode.json` / `opencode.jsonc` files. The Lisp engine is strictly prohibited from mutating the process-global CWD (via `chdir`).
2. **Global Config**: Loads the user's global config from `~/.opencode/` or platform equivalent.
3. **Caching**: Config is loaded once when the location context is opened and cached. Changes take effect on session restart or context reload.

### Parsing JSONC (JSON with Comments)

Since Common Lisp's `com.inuoe.jzon` parses strict RFC 8259 JSON, `librecode` preprocesses JSONC files before parsing. To support comments in config files, we use a simple quote-aware comment-stripping preprocessor that skips lines starting with `//` and ignores comment markers/comma stripping inside double-quoted string literals. The preprocessed, valid JSON content is then passed directly to `jzon:parse`.

### Merge Semantics

When multiple config files are discovered (e.g. global, project-root, and subdirectory configs):
* The configuration is resolved by merging the files in order of ascending priority: global config -> project config -> subdirectory config.
* **Field Resolution**: The merge uses a recursive deep-merge helper for plist/map configuration structures to align with OpenCode's configuration merging model, preserving nested properties instead of using flat last-write-wins replacement.
* Once loaded, the JSON document is mapped to an internal CL struct representing the active system config.

---

## 6. HTTP API Server & REPL Interface

`librecode-runner` exposes an external HTTP API and an interactive REPL interface to support integration with the OpenCode UI client and local developer maintenance.

### HTTP REST / SSE Server

The runner initiates a lightweight multi-threaded HTTP server (powered by `Clack` wrapping `Hunchentoot`) to listen for frontend requests.

* **`POST /api/session/:sessionID/prompt`**: Receives user inputs (prompts or steering instructions) and writes them to the durable database inbox (R9).
* **`GET /api/session/:sessionID/event`**: Establishes a server-sent events (SSE) connection, streaming EventV2 events to the UI client as they are committed to the SQLite store (R2).
* **`POST /api/session/:sessionID/interrupt`**: Interrupts active session execution loop (R1/R5).
* **`GET /api/session/:sessionID/history`**: Returns paginated event history from the event store (R2).

All endpoints validate authorization parameters and route requests to the matching session mailbox or key lock (R1, R6).

#### SSE Character Line Processing
Because the streaming reader runs in a dedicated thread as described in Section 4, we offload character decoding and line buffering entirely to standard character streams. Using `read-line` natively resolves character fragments, eliminating the need for custom chunk-splitting or buffer-searching logic. The Hunchentoot event-streaming endpoints (`GET /api/session/:sessionID/event`) must handle `stream-error` (broken pipes or client disconnects) explicitly to prevent thread and socket leaks:
```lisp
(handler-case
    (loop for event = (sb-concurrency:receive-message event-mailbox)
          do (write-event-to-client stream event)
             (force-output stream))
  (stream-error ()
    (cleanup-session-subscription session-id)))
```

#### Session-Local Mailbox Bindings & Dependency Injection
To resolve peer-to-peer mailboxes for concurrent agent threads (R6) without global lock bottlenecks or registry memory leaks:
* We avoid a global agent mailbox lookup table.
* Sibling agents spawned within the same session receive their peer mailboxes directly via constructor injection (slots in the CLOS `agent` class).
* Alternatively, we bind a session-local registry plist `*session-mailboxes*` dynamically using a thread-local special variable. Sibling threads spawned within that session inherit this registry via `:initial-bindings` (see the Guidelines specification).

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
  :depends-on ("bordeaux-threads" "cl-sqlite" "com.inuoe.jzon" "dexador" "uiop" "clack" "hunchentoot")
  :pathname "src/"
  :serial t
  :components ((:file "packages")
               (:module "runner"
                :pathname "runner"
                :components ((:file "conditions")
                             (:file "audit")
                             (:file "protocol")
                             (:file "event-store")
                             (:file "agent")
                             (:file "session")
                             (:file "runner")
                             (:file "compaction")
                             (:file "tool")))))        ; Materialization and execution

(defsystem "librecode-meta"
  :description "The parent orchestrator for multi-agent campaigns (Metaharness)."
  :version "0.1.0"
  :author "nrd"
  :depends-on ("librecode-runner" "trivial-signal")
  :pathname "src/meta/"
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

---

## 8. SQLite DDL Schemas

`librecode-runner` manages its session stores, admitted inputs, and permission history using SQLite. The following schemas define the database structures:

### Event Log Table (`event_log`)

Stores event-sourced EventV2 records sequentially. Atomic updates project logs onto session states inside a single transaction.

```sql
CREATE TABLE IF NOT EXISTS event_log (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id TEXT NOT NULL,
    sequence INTEGER NOT NULL,
    event_type TEXT NOT NULL,
    payload TEXT NOT NULL,          -- JSON serialized EventV2 payload
    timestamp INTEGER NOT NULL,     -- Unix epoch in milliseconds
    UNIQUE(session_id, sequence)
);
CREATE INDEX IF NOT EXISTS idx_event_log_session ON event_log(session_id);
```

### Session Input Table (`session_input`)

Maintains the durable inbox for two-phase input admission (`admit` vs `promote` phases).

```sql
CREATE TABLE IF NOT EXISTS session_input (
    id TEXT PRIMARY KEY,            -- UUID or message identity
    session_id TEXT NOT NULL,
    prompt_text TEXT NOT NULL,
    delivery_mode TEXT NOT NULL,    -- 'STEER' or 'QUEUE'
    status TEXT NOT NULL,           -- 'PENDING', 'PROMOTED', 'EXPIRED'
    timestamp INTEGER NOT NULL      -- Unix epoch in milliseconds
);
CREATE INDEX IF NOT EXISTS idx_session_input_pending ON session_input(session_id, status);
```

### Permission History Table (`permission_saved`)

Caches "always allow" choices made during interactive execution gates.

```sql
CREATE TABLE IF NOT EXISTS permission_saved (
    project_id TEXT NOT NULL,
    action TEXT NOT NULL,
    resource TEXT NOT NULL,
    effect TEXT NOT NULL,           -- 'ALLOW', 'DENY'
    timestamp INTEGER NOT NULL,     -- Unix epoch in milliseconds
    PRIMARY KEY (project_id, action, resource)
);
```

### Session State Table (`session_state`)

Stores the current state projections of active sessions.

```sql
CREATE TABLE IF NOT EXISTS session_state (
  session_id TEXT PRIMARY KEY,
  agent_id TEXT NOT NULL,
  version INTEGER NOT NULL,
  status TEXT NOT NULL, -- 'idle', 'running', 'error'
  last_updated INTEGER NOT NULL
);
```

### Session History Table (`session_history`)

Stores historical message transcripts for model continuation and context building.

```sql
CREATE TABLE IF NOT EXISTS session_history (
  id TEXT PRIMARY KEY,
  session_id TEXT NOT NULL,
  role TEXT NOT NULL, -- 'system', 'user', 'assistant', 'tool'
  content TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  FOREIGN KEY(session_id) REFERENCES session_state(session_id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_session_history_session ON session_history(session_id);
```

### Context Epoch Table (`context_epoch`)

Stores context snapshots used to calculate context updates.

```sql
CREATE TABLE IF NOT EXISTS context_epoch (
  session_id TEXT PRIMARY KEY,
  epoch_id TEXT NOT NULL,
  baseline_text TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  FOREIGN KEY(session_id) REFERENCES session_state(session_id) ON DELETE CASCADE
);
```

### Primitives: Deposit and Findings Tables

The following schemas define the storage model for Predicate's primitive deposits and security findings:

#### Deposits Table (`deposits`)

Stores immutable deposit records for verification tracking.

```sql
CREATE TABLE IF NOT EXISTS deposits (
    id TEXT PRIMARY KEY,
    step TEXT NOT NULL,
    evidence TEXT NOT NULL CHECK(length(evidence) > 0),
    created_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now'))
);
```

#### Deposit Cites Table (`deposit_cites`)

Maps deposits to resolved paths cited as evidence.

```sql
CREATE TABLE IF NOT EXISTS deposit_cites (
    deposit_id TEXT NOT NULL,
    path TEXT NOT NULL,
    PRIMARY KEY (deposit_id, path),
    FOREIGN KEY (deposit_id) REFERENCES deposits(id) ON DELETE CASCADE
);
```

#### Deposit References Table (`deposit_refs`)

Tracks directed reference relationships between deposits.

```sql
CREATE TABLE IF NOT EXISTS deposit_refs (
    source_id TEXT NOT NULL,
    target_id TEXT NOT NULL,
    ref_type TEXT NOT NULL,
    PRIMARY KEY (source_id, target_id, ref_type),
    FOREIGN KEY (source_id) REFERENCES deposits(id) ON DELETE CASCADE,
    FOREIGN KEY (target_id) REFERENCES deposits(id) ON DELETE CASCADE
);
```

#### Findings Table (`findings`)

Maintains security and verification findings linked to their resolving deposits.

```sql
CREATE TABLE IF NOT EXISTS findings (
    id TEXT PRIMARY KEY,
    session_id TEXT NOT NULL,
    rule_id TEXT,
    status TEXT NOT NULL CHECK(status IN ('open', 'resolved')),
    evaluator TEXT,
    resolved_at INTEGER,
    resolution_deposit_id TEXT,
    FOREIGN KEY(id) REFERENCES deposits(id) ON DELETE CASCADE,
    FOREIGN KEY(session_id) REFERENCES session_state(session_id) ON DELETE CASCADE,
    FOREIGN KEY(resolution_deposit_id) REFERENCES deposits(id) ON DELETE SET NULL
);
CREATE INDEX IF NOT EXISTS idx_findings_session ON findings(session_id);
```

