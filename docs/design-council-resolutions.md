# librecode Design Council: Deliberation & Resolution Plan

The Design Council (convened on 2026-06-30) has delivered a unanimous **REJECTED** verdict on the initial specifications. This document aggregates all findings from the Architect, Lead Maintainer, and Process Auditor seats and defines their mathematical and structural resolutions.

---

## 1. Architectural & Engineering Resolutions

### [RES-01] Process-Global CWD Safety (Maintainer #1, Architect #2)
* **Finding**: SBCL CWD is process-global. In-process runner threads executing operations in parallel will corrupt paths if they perform thread-level mutations (e.g. `uiop:chdir`), and configuration walks using CWD will leak parent state.
* **Resolution**:
  * The Lisp engine is strictly prohibited from mutating the process-global CWD.
  * We introduce a thread-safe workspace binding model. All file utilities and system context loaders must resolve pathnames relative to a dynamic `*workspace-root*` or pass the path explicitly.
  * All subprocesses spawned via `uiop:launch-program` must explicitly set the `:directory` parameter.

### [RES-02] Circular Workspace Dependency (Architect #1)
* **Finding**: The scheduling loop attempts to call `harness-create-worktree` on a harness `instance` that has not yet been spawned, creating a loop.
* **Resolution**:
  * Decouple workspace provisioning from instance execution.
  * Define `harness-prepare-workspace` as a class method/generic function:
    ```lisp
    (defgeneric harness-prepare-workspace (harness-class repository-path target-directory)
      (:documentation "Prepares the isolated git worktree and storage directories before a harness instance is spawned."))
    ```
  * `harness-spawn` is then called, taking the prepared directory configuration.

### [RES-03] Structured HTTP/SSE vs. Tmux Screen Scraping (Maintainer #3, Architect #3, Auditor #3)
* **Finding**: Tmux keystroke simulation and screen buffer scraping is fragile and highly prone to ANSI and terminal wrap layout drift. OpenCode already supports a structured HTTP REST and SSE events server.
* **Resolution**:
  * Demote Tmux to an optional, local developer visualization helper.
  * The `harness-opencode` adapter will communicate with the child process strictly via OpenCode's native HTTP REST and SSE APIs:
    * Submit prompts via `POST /session/:id/admit` and `POST /session/:id/promote`.
    * Stream thoughts and events via `GET /session/:id/events`.
    * Issue interrupts via `POST /session/:id/interrupt`.
  * Dynamic surface write monitoring is performed at the boundary: when the runner attempts to execute a tool (like `write_to_file`), the Metaharness intercepts the tool call payload via the SSE event stream, runs the surface check, and decides whether to approve or reject the write *before* letting the runner proceed.

### [RES-04] Cross-Process Restart Incoherence (Architect #4)
* **Finding**: Dynamic Common Lisp restarts (`retry-with-backup-provider`, `drop-to-repl-intervention`) cannot cross OS process or language runtime boundaries (e.g. into TS `harness-opencode` or a separate process).
* **Resolution**:
  * CL restarts are strictly bounded to the in-process execution of `librecode-runner` and the Metaharness supervisor.
  * For out-of-process runners, execution errors are mapped to structured error events. The Metaharness catches these events at the campaign layer and raises Metaharness-level restarts (e.g., restarting the runner process, skipping the node, or dropping into the parent REPL).

### [RES-05] Concurrency Blocking on Network/Subprocesses (Maintainer #2)
* **Finding**: Interruption flags are ignored if a runner thread is blocked on a socket read (`dexador`) or synchronously awaiting a subprocess (`uiop:launch-program`).
* **Resolution**:
  * Sockets: Configure dexador read timeouts and check the `stopping` flag inside the SSE line-read iteration loop.
  * Subprocesses: Spawn subprocesses asynchronously. The coordinator thread blocks on a condition variable with a timeout, checking the `stopping` flag. If an interrupt occurs, the Metaharness issues an OS signal (e.g., SIGTERM) to the child process handle.

### [RES-06] Stack-Preserving REPL Debugging (Maintainer #6, Auditor #2)
* **Finding**: Catching and sending condition objects via mailboxes unwinds the worker thread's stack, preventing REPL debugging at the original error site.
* **Resolution**:
  * When a runner thread encounters a serious warning or error, the error handler does not immediately unwind.
  * It writes a signal message to the coordinator's mailbox and blocks the worker thread (e.g. using `bt:condition-wait` on a thread-local CV).
  * This keeps the worker thread stack alive and frozen, allowing the developer to connect via SLIME/Sly, inspect the exact frame, reload definitions, and invoke restarts at the point of origin.

### [RES-07] Complex JSONC Parser & Comma-Stripper (Maintainer #5, Auditor #5)
* **Finding**: Comment stripping via a custom 7-state preprocessor is complex and corrupts commas inside string literals.
* **Resolution**:
  * Remove the custom state-machine parser.
  * Use the standard Lisp JSON reader `com.inuoe.jzon` directly.
  * If comment/JSONC support is required for user configs, implement a simple quote-aware state preprocessor that skips lines starting with `//` and ignores comma stripping inside double-quoted strings.

### [RES-08] Flat vs. Deep Configuration Merge (Architect #5)
* **Finding**: Flat last-write-wins merging corrupts nested properties.
* **Resolution**:
  * Replace the flat merge with a recursive deep-merge helper for plist/map configuration structures.

### [RES-09] SQLite Projection Schemas (Auditor #4)
* **Finding**: The schemas for projected session read models were omitted, violating Invariant I2.
* **Resolution**:
  * Explicitly specify the DDL schemas for read models (`session_state`, `session_history`, `context_epoch`) in [docs/coordination-protocol.md](file:///var/home/nrd/git/github.com/nrdxp/librecode/docs/coordination-protocol.md).

### [RES-10] Verification Dual in Council Delegation (Auditor #1)
* **Finding**: Council delegation checks were post-hoc and delegated to the LLM Process Auditor, violating Prime Invariant 1.
* **Resolution**:
  * The Lisp engine natively evaluates council delegation tables (verifying seat counts, deposit signatures, and verdicts) as a strict symbolic gate before merges. The LLM Auditor acts as a qualitative reviewer only.

### [RES-11] Webhook/Webhook-cli Demotion (Maintainer #4)
* **Finding**: External mobile alerting (`signal-cli`) introduces heavy external dependencies.
* **Resolution**:
  * Demote Signal/webhook alerts to an optional notifier layer. The core harness works headless without them, falling back to local TUI or standard console inputs.

### [RES-12] CLOS Agent Subclass Boilerplate (Maintainer #8)
* **Finding**: Distinct classes (`build-agent`, etc.) are rigid and compile-locked.
* **Resolution**:
  * Collapse the CLOS hierarchy into a single `agent` class parameterized by a dynamic config object (rulesets, contexts, permissions).

---

## 2. DDL Schema Extensions (Projections)

```sql
CREATE TABLE IF NOT EXISTS session_state (
  session_id TEXT PRIMARY KEY,
  agent_id TEXT NOT NULL,
  version INTEGER NOT NULL,
  status TEXT NOT NULL, -- 'idle', 'running', 'error'
  last_updated INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS session_history (
  id TEXT PRIMARY KEY,
  session_id TEXT NOT NULL,
  role TEXT NOT NULL, -- 'system', 'user', 'assistant', 'tool'
  content TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  FOREIGN KEY(session_id) REFERENCES session_state(session_id) ON DELETE CASCADE
);
```

---

## 3. Deliberation Verdict

The Council votes unanimously to **REJECT** the current specifications until these resolutions are fully integrated.
* **Architect**: REJECTED (Pending circular dependency & CWD safety).
* **Lead Maintainer**: REJECTED (Pending CWD safety & stack-freezing mailbox resolution).
* **Process Auditor**: REJECTED (Pending DDL schemas & dynamic collision clarity).

### Action Plan
1. Open a refinement worktree on `agent/reconcile-council-resolutions`.
2. Apply these resolutions across the spec documents.
3. Commit and merge back to `master` and `document-architecture`.
