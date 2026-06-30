# librecode User Workflows & Developer Stories

This document specifies the intended user experience (UX) and developer workflows for interacting with `librecode-runner` (the harness) and `librecode-meta` (the Metaharness).

---

## 1. Campaign Initiation Workflow

A developer initiates a multi-agent campaign via the Metaharness CLI to execute a coordinated engineering task (such as a multi-module refactoring campaign).

### CLI Command

```bash
librecode-meta start-campaign \
  --dag .opencode/campaigns/refactor-auth.yaml \
  --branch refactor-auth-layer
```

### Execution Behavior

1. **DAG Parsing**: The Metaharness parses the campaign DAG YAML, runs Kahn's algorithm to schedule the topological layers, and checks for initial file surface collisions.
2. **Workspace Isolation**: For each concurrent node in the current layer, the Metaharness spawns a dedicated git worktree under the external campaign directory (e.g. `worktrees/<node-id>/` inside the external project-delimited campaign storage folder) linked to a private tracking branch (e.g. `agent/node-<node-id>`).
3. **Pane Multiplexing**: The Metaharness launches a multiplexed terminal session (such as `tmux` or `zellij`):
   * A main pane is created for the coordinator process.
   * Dedicated panes are created for each concurrent child harness instance (running `librecode-runner` or `harness-opencode`).
   * The developer can attach to the multiplexer session at any time to monitor stdout streams:
     ```bash
     tmux attach-session -t librecode-campaign-refactor-auth
     ```

---

## 2. Asynchronous Mobile Messaging Workflow

For headless or background campaign runs, the developer does not need to monitor terminal panes. The Metaharness runs autonomously and can optionally prompt the developer on high-stakes decisions via secure open-source messaging (Signal Protocol). If the Signal channel is disabled or unavailable, the system transparently falls back to local console/TUI input (RES-11).

### Scenario: Interactive Permission Gate

A child harness executing task `auth-db-migration` needs to run a database migration script. Since the action is flagged as `:ask` in the permissions ruleset (R5), the harness halts, and the Metaharness transmits a notification to the developer's mobile device:

```
[librecode] Session sess-982 (auth-db-migration) requests permission:
Action: run_command
Resource: "bun run db:migrate --env production"

Reply with option:
1. Allow (once)
2. Always Allow (persists rule to SQLite)
3. Deny (aborts request)
4. Deny & Abort Campaign
```

### Resolution Flow

1. The developer receives the message via Signal and replies with `2`.
2. The local `signal-cli` daemon receives the reply and updates the Metaharness supervisor.
3. The Metaharness writes the rule to the local SQLite database (`permission_saved` table), clears the permission block, and notifies the runner.
4. The runner thread resumes execution immediately.

---

## 3. Stack-Freezing REPL Debugging Workflow

When a serious error occurs in an active worker thread (such as an LLM provider connection drop, a tool timeout, or a gate verification failure), the system intercepts the condition and freezes the thread's execution stack in place (e.g., by waiting on a thread-local condition variable CV) instead of unwinding it. This keeps the exact stack context alive and inspectable for inline SLIME/Sly debugger interaction (RES-06).

### Scenario: Tool Execution Timeout

A custom search tool hangs. The runner thread signals a `tool-timeout` condition and immediately freezes, maintaining its stack frame at the error site.

### Notification Flow

The Metaharness sends an alert:

```
[librecode] Session sess-982 halted on Tool Timeout in node: auth-db-migration.
Condition: Serious warning - tool 'search_code' exceeded limit of 30s.

Restarts available:
1. retry-with-backup-provider
2. compact-and-retry
3. drop-to-repl-intervention
4. skip-and-continue

Select restart index or connect to REPL on port 4005.
```

### REPL Intervention Flow

1. The developer runs `SLIME` (or `Sly`) from Emacs and connects to the running Lisp image:
   * `M-x sly-connect` -> `localhost:4005`
2. The Lisp debugger (`SLDB`) opens, showing the frozen stack frames exactly where the timeout occurred.
3. The developer inspects the variables, finds that the tool process hung on a socket lock, edits the tool implementation in `src/tool.lisp`, and evaluates the updated definition inside the running image.
4. The developer selects the `retry-with-backup-provider` (or another custom restart) from the SLDB restart list.
5. The runner thread resumes from the exact signal point, now using the hot-patched tool logic.

---

## 4. UI Integration & Local TUI

Developers can monitor and interact with active harnesses locally using the OpenCode UI client.

### Client-Server Handshake

1. **Launch Server**: The developer runs `librecode-runner start-server --port 3000`. This starts the Hunchentoot HTTP listener.
2. **Open TUI/GUI**: The developer opens the OpenCode UI application.
3. **Connection**: The UI connects to `localhost:3000` via:
   * **REST endpoints** to query system config, retrieve project files, and submit admitted prompts (`POST /session/:id/admit`).
   * **Server-Sent Events (SSE)** (`GET /session/:id/events`) to receive real-time, event-sourced notifications of agent thoughts, tool executions, and file diffs.
4. The developer types a prompt in the GUI; the server admits it to SQLite, promotes it at the turn boundary, runs the LLM client, and streams output chunks back to the screen instantly.
