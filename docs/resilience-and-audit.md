# librecode Resilience & Audit System

> **Status legend** (as-built against `src/`): **BUILT** = implemented and tested ·
> **PARTIAL** = core built, gaps noted · **DEFERRED** = design-only, not implemented.
> Overall this document is largely **BUILT**; per-item exceptions are called out inline.

This specification defines `librecode`'s condition-restart failure recovery engine and S-expression audit trail, replacing the standard Javascript async error-handling paradigm with interactive and automated repair-in-place semantics.

## 1. Condition-Restart Recovery Engine — BUILT (restart set partial)

Unlike TypeScript/V8, which unwinds the execution stack immediately upon encountering an error (via `try/catch` or Effect's error channels), `librecode` leverages Common Lisp's dynamic condition system (`handler-bind`) to freeze the stack at the error location. This preserves all context and allows handlers to resolve the issue in-band.

### Custom Conditions

Every subsystem defines specialized condition classes inheriting from `serious-condition`:

* **`harness-failure`**: Triggered when a child harness process terminates unexpectedly, returns an exit code error, or exhibits timeout behavior.
* **`provider-error`**: Triggered by API failures, connection drops, or rate limit issues from LLM providers.
* **`context-overflow`**: Triggered when the input context exceeds the target LLM provider's token budget.
* **`tool-timeout`**: Triggered when a materialized tool exceeds its execution time limit.
* **`process-hang`**: Triggered when a child process ceases emitting events without terminating.

### Multi-Tiered Restarts

When a condition is signaled, the system offers targeted restarts. Restarts actually
defined in `conditions.lisp` / `execute-provider-turn`: `retry-with-backup-provider`,
`compact-and-retry`, `skip-and-continue`, `retry-tool`.

1. **`compact-and-retry`** — **BUILT & autonomously driven**
   * *Applicable to*: `context-overflow`
   * *Behavior*: Triggers the compaction engine to fold older context history, snapshots a new epoch baseline, and retries the turn. Auto-invoked by a `handler-bind` in the HTTP drive loop up to `*max-compact-attempts*` (`http.lisp`).
2. **`retry-with-backup-provider`** — **BUILT (restart), not yet auto-driven**
   * *Applicable to*: `provider-error`
   * *Behavior*: Switches the active provider connection to a backup endpoint (`*backup-provider-url*`) and re-executes the turn. The restart exists in `restart-case` but is currently invoked only by tests — no `src/` `handler-bind` autonomously selects it.
3. **`skip-and-continue`** — **BUILT**
   * *Applicable to*: non-fatal tool or subagent failures
   * *Behavior*: Discards the failed operation, records a warning event, and continues the session execution block.
4. **`inject-corrected-payload`** — **DEFERRED (not defined)**
   * *Applicable to*: `provider-error` (e.g. invalid JSON response payload)
   * *Behavior (design)*: Allows an auditor agent or human to modify the malformed payload or tool specification inline and retry.
5. **`drop-to-repl-intervention`** — **DEFERRED (not defined)**
   * *Applicable to*: any serious condition in interactive mode
   * *Behavior (design)*: Suspends the runner thread and drops the human developer into an active REPL session to inspect variables, modify code, or manually force values before resuming.

---

## 2. Cross-Thread & Cross-Process Condition Propagation — BUILT

Because tool execution runs on separate threads and independent child harnesses execute in external processes, conditions must be propagated across dynamic extent boundaries.

### In-Process: Stack-Preserving Debugging & Asynchronous Handshake

Within `librecode-runner` (the single-session harness), tool execution runs in separate background worker threads. Since restarts are dynamically bound to a thread's control stack, a coordinator thread cannot invoke a restart directly on a worker thread's stack. To transport conditions back to the main thread and invoke restarts cleanly:
1. **Intercept**: The worker thread wraps its execution block in a `handler-bind` that intercepts any unhandled `serious-condition`.
2. **Handshake Message**: Rather than unwinding the stack, the handler creates an ephemeral worker-local mailbox. It packages the condition, the diagnostic metadata, and this reply mailbox, then sends a `(:worker-error :condition c :reply-to reply-mailbox)` message to the coordinator's mailbox.
3. **Freeze & Block**: The worker thread blocks by executing a receive on its local reply mailbox. This preserves the worker execution stack frame at the exact error site.
4. **Deliberation & Restart**: The coordinator thread reads the mailbox at its turn boundary. Upon detecting the error, it halts execution and alerts the developer (who can connect via SLIME/Sly to run `(invoke-debugger c)` inside the worker thread by sending an eval command) or automatically chooses a restart. The coordinator then sends `(restart-name args)` back to the worker's reply mailbox.
5. **Resume**: The worker thread wakes, reads the chosen restart from its reply mailbox, and executes `invoke-restart` natively on its own stack (RES-06). If the coordinator thread itself exits or is interrupted, its `unwind-protect` must drain/terminate all registered worker threads to prevent orphan thread leaks.

### Cross-Process: Subprocess Event/Exit Mapping

Dynamic Common Lisp restarts cannot cross OS process or language runtime boundaries (e.g. into TS `harness-opencode` or a separate process). Restarts are strictly bounded to the in-process execution of `librecode-runner` and the Metaharness supervisor (RES-04).

For out-of-process runners:
1. **Observation**: The Metaharness monitors the child process's HTTP/SSE event stream, stdout/stderr, and OS exit codes.
2. **Detection**: If the child process exits with a non-zero code or writes a fatal crash/error payload to the event stream, the Metaharness loop detects the error.
3. **Signal**: The Metaharness catches the failure event and signals a `harness-failure` condition within the parent orchestrator's thread.
4. **Restart**: This invokes parent-level restarts, allowing the campaign coordinator to trigger a rework loop (`realign-and-dispatch-rework`) or notify the developer via the optional notification channel.

---

## 3. S-Expression Audit Trail — BUILT

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

* **Thread-Safe Queue Logging**: To prevent syntax corruption on concurrent stream writes from multiple threads, all audit events are pushed to a thread-safe `sb-concurrency:queue` consumed by a single background logging thread.
* **Single-Pass dual logging**: Rather than tailing and parsing the S-expression file (which is prone to reader races on incomplete writes), the background logging thread writes directly to *both* `audit.lisp-expr` (S-expressions) and `audit.jsonl` (JSON Lines) files in a single pass.
* **Crash-Safe**: The logging thread calls `force-output` on both file streams immediately after writing each event.
* **Append-Only**: Log files are opened exclusively in append mode (`:if-exists :append :if-does-not-exist :create`). In-place modification of existing entries is strictly prohibited.
