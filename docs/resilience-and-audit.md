# librecode Resilience & Audit System

This specification defines `librecode`'s condition-restart failure recovery engine and S-expression audit trail, replacing the standard Javascript async error-handling paradigm with interactive and automated repair-in-place semantics.

## 1. Condition-Restart Recovery Engine

Unlike TypeScript/V8, which unwinds the execution stack immediately upon encountering an error (via `try/catch` or Effect's error channels), `librecode` leverages Common Lisp's dynamic condition system (`handler-bind`) to freeze the stack at the error location. This preserves all context and allows handlers to resolve the issue in-band.

### Custom Conditions

Every subsystem defines specialized condition classes inheriting from `serious-condition`:

* **`harness-failure`**: Triggered when a child harness process terminates unexpectedly, returns an exit code error, or exhibits timeout behavior.
* **`provider-error`**: Triggered by API failures, connection drops, or rate limit issues from LLM providers.
* **`context-overflow`**: Triggered when the input context exceeds the target LLM provider's token budget.
* **`tool-timeout`**: Triggered when a materialized tool exceeds its execution time limit.
* **`process-hang`**: Triggered when a child process ceases emitting events without terminating.

### Multi-Tiered Restarts

When a condition is signaled, the system offers targeted restarts:

1. **`retry-with-backup-provider`**
   * *Applicable to*: `provider-error`
   * *Behavior*: Switches the active provider connection to a backup model/API endpoint and re-executes the current turn.
2. **`compact-and-retry`**
   * *Applicable to*: `context-overflow`
   * *Behavior*: Triggers the compaction engine to fold older context history, snapshots a new epoch baseline, and retries the turn.
3. **`inject-corrected-payload`**
   * *Applicable to*: `provider-error` (e.g. invalid JSON response payload)
   * *Behavior*: Allows an auditor agent or human to modify the malformed payload or tool specification inline and retry.
4. **`drop-to-repl-intervention`**
   * *Applicable to*: any serious condition in interactive mode
   * *Behavior*: Suspends the runner thread and drops the human developer into an active REPL session to inspect variables, modify code, or manually force values before resuming.
5. **`skip-and-continue`**
   * *Applicable to*: non-fatal tool or subagent failures
   * *Behavior*: Discards the failed operation, records a warning event, and continues the session execution block.

---

## 2. Cross-Thread & Cross-Process Condition Propagation

Because tool execution runs on separate threads and independent child harnesses execute in external processes, conditions must be propagated across dynamic extent boundaries.

### In-Process: Stack-Preserving Debugging

Within `librecode-runner` (the single-session harness), tool execution runs in separate background worker threads. To transport conditions back to the main runner thread without unwinding:
1. **Intercept**: The worker thread wraps its execution block in a `handler-bind` that intercepts any unhandled `serious-condition`.
2. **Freeze & Mail**: Rather than unwinding the stack, the handler packages the condition diagnostic metadata and writes a message to the coordinator's mailbox. It then freezes the worker thread, blocking it via a condition variable (`bt:condition-wait` on a thread-local CV). This preserves the execution stack frame at the exact error site.
3. **Inspect**: The coordinator thread reads the mailbox at its turn boundary. Finding the error message, it halts execution and alerts the developer. The developer connects via SLIME/Sly, inspects the active frozen stack frames, hot-patches definitions if needed, and triggers a restart directly at the origin of the error (RES-06).

### Cross-Process: Subprocess Event/Exit Mapping

Dynamic Common Lisp restarts cannot cross OS process or language runtime boundaries (e.g. into TS `harness-opencode` or a separate process). Restarts are strictly bounded to the in-process execution of `librecode-runner` and the Metaharness supervisor (RES-04).

For out-of-process runners:
1. **Observation**: The Metaharness monitors the child process's HTTP/SSE event stream, stdout/stderr, and OS exit codes.
2. **Detection**: If the child process exits with a non-zero code or writes a fatal crash/error payload to the event stream, the Metaharness loop detects the error.
3. **Signal**: The Metaharness catches the failure event and signals a `harness-failure` condition within the parent orchestrator's thread.
4. **Restart**: This invokes parent-level restarts, allowing the campaign coordinator to trigger a rework loop (`realign-and-dispatch-rework`) or notify the developer via the optional notification channel.

---

## 3. S-Expression Audit Trail

The Audit Trail records every event, condition signal, restart invocation, and sub-process transition to a thread-safe, append-only log.

### Log Format

The native format is S-expressions, which allows direct reading and writing without parsing overhead in Common Lisp:

```lisp
(:timestamp "2026-06-30T12:00:00Z"
 :session-id "sess-1234"
 :event :tool-dispatched
 :data (:tool-id "write_file" :path "src/packages.lisp"))

(:timestamp "2026-06-30T12:00:02Z"
 :session-id "sess-1234"
 :event :condition-signaled
 :data (:condition-type "context-overflow" :message "Token limit exceeded"))

(:timestamp "2026-06-30T12:00:02Z"
 :session-id "sess-1234"
 :event :restart-invoked
 :data (:restart-name "compact-and-retry"))
```

### Safety Invariants

* **Crash-Safe**: The system calls `force-output` after every write to guarantee that data is flushed to disk before the program proceeds.
* **Append-Only**: Log files are opened exclusively in append mode (`:if-exists :append :if-does-not-exist :create`). In-place modification of existing entries is strictly prohibited.
* **JSONL Exporter**: A background thread or utility reads the S-expression log and serializes it to JSON Lines (JSONL) to support cross-system diagnostic interop with OpenCode's monitoring tools.
