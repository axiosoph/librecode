# librecode Metaharness (librecode-meta) Architecture

The Metaharness (`librecode-meta`) is the parent supervisor that coordinates multi-agent campaigns across physical process boundaries, establishing a **"Team of Teams"** topology. 

### Externalized Campaign Workspace

Rather than executing code or communicating with LLMs directly, the Metaharness schedules parallelized tasks, executes verification gates on committed files, and runs the decision council. It delegates actual task execution to independent child harness processes (such as `librecode-runner`, `harness-opencode`, or `harness-claude-code`).

To prevent tight coupling with the active project repository and maintain clean workspaces, the Metaharness manages campaign metadata, node worktrees, and council logs externally. By default, all campaign-related files reside in a project-delimited external storage directory (e.g. `~/.librecode/projects/<project-id>/campaigns/<campaign-id>/` or a user-configured path):
* **`worktrees/`**: Directory containing isolated git worktree checkouts spawned for concurrent campaign nodes.
* **`ledger/deposits/`**: Central folder where individual seat decision deposits are aggregated.
* **`ledger/decision-log.json`**: The parent campaign decision ledger.
* **`campaign-journal.lisp-expr`**: The crash-safe Campaign DAG scheduler journal.

Each child harness operates within its assigned worktree workspace and manages its own local agent composition and sub-delegation loops, writing outputs that cross back over to the campaign's central ledger via the Metaharness protocol.

## 1. Abstract Harness Interface

To support heterogeneous agent systems, the Metaharness decouples itself entirely from any specific runner implementation. Every child agent process is managed through a uniform CLOS protocol.

### Harness Generic Functions

```lisp
(defgeneric harness-spawn (type config)
  (:documentation "Spawns a new child harness instance of the specified TYPE and returns a harness instance."))

(defgeneric harness-prompt (instance prompt &key mode)
  (:documentation "Sends a prompt string to the harness. MODE is either :steer (inline steering input) or :queue (queued input for when the session goes idle)."))

(defgeneric harness-read-events (instance)
  (:documentation "Returns an input stream or queue of structured events/messages emitted by the harness."))

(defgeneric harness-send-command (instance command)
  (:documentation "Sends a control command to the harness (e.g. /clear, /compact, or tool approval)."))

(defgeneric harness-inject-conditioning (instance persona-text delivery-surface)
  (:documentation "Injects system prompt or behavior-conditioning text into the harness's native storage/surface."))

(defgeneric harness-status (instance)
  (:documentation "Queries the harness run state, returning :idle, :running, :error, or :terminated."))

(defgeneric harness-terminate (instance)
  (:documentation "Sends a termination signal to end the harness process gracefully."))

(defgeneric harness-prepare-workspace (harness-class-symbol repository-path target-directory)
  (:documentation "Prepares the isolated git worktree and storage directories before a harness instance is spawned.
   Since generic functions cannot dispatch on class symbols in CLOS directly without instantiating them, we use `eql` specializers on class symbols (e.g. (harness-class-symbol (eql 'harness-opencode))) (RES-02)."))

(defgeneric harness-cleanup-workspace (harness-class-symbol repository-path target-directory &key force)
  (:documentation "Cleans up the isolated workspace and worktree directory after execution completes. Specializes on class symbols."))
```

### Harness Class Hierarchy

Each supported backend is implemented as a subclass of `harness`:

```lisp
(defclass harness ()
  ((id :initarg :id :reader harness-id :type string)
   (config :initarg :config :reader harness-config)
   (status :initform :idle :accessor %harness-status)))

(defclass harness-opencode (harness)
  ((port :initarg :port :reader harness-port :initform nil :documentation "Dynamically allocated port to prevent parallel collision.")
   (pane :initarg :pane :reader harness-pane :initform nil :documentation "Optional tmux pane for developer visualization helper."))
  (:documentation "OpenCode CLI adapter communicating strictly via OpenCode's native HTTP REST and SSE APIs.
   To prevent parallel port collisions under concurrency, the Metaharness leases unique ports from an ephemeral range and injects them on spawn."))

(defclass harness-librecode (harness)
  ((thread :initarg :thread :reader harness-thread)
   (workspace-root :initarg :workspace-root :reader harness-workspace-root :type pathname))
  (:documentation "Self-hosting: a native librecode runner running in-process on a separate thread.
   In-process threads must NEVER mutate the process-global current working directory (CWD) via chdir (RES-01). 
   All file tools and operations must resolve paths relative to the dynamically bound `*workspace-root*` pathname.
   Subprocesses must be launched via `uiop:launch-program` using the `:directory` parameter explicitly."))

(defclass harness-claude-code (harness)
  ((pane :initarg :pane :reader harness-pane))
  (:documentation "Claude Code CLI wrapper communicating via tmux/terminal multiplexer."))
```

---

## 2. Multiplexer Protocol (Transport Layer)

For CLI-based child harnesses, the Metaharness uses a terminal multiplexer to manage physical I/O streams and preserve session workspaces.

```lisp
(defgeneric multiplexer-create-session (mux session-name)
  (:documentation "Creates a new multiplexer session."))

(defgeneric multiplexer-spawn-pane (mux session command &key cwd env)
  (:documentation "Spawns a new pane running COMMAND and returns a pane identifier."))

(defgeneric multiplexer-send-keys (mux pane keys)
  (:documentation "Sends raw input keystrokes or text to the target pane."))

(defgeneric multiplexer-read-buffer (mux pane &key limit)
  (:documentation "Scrapes the screen buffer of the target pane."))

(defgeneric multiplexer-close-pane (mux pane)
  (:documentation "Kills the pane and its running process."))
```

The initial backend target is `multiplexer-tmux`, which implements this interface by wrapping CLI commands (`tmux new-session`, `tmux send-keys`, `tmux capture-pane`). Other backends (e.g., `zellij` or direct PTY management) can be implemented without altering the supervisor logic.

---

## 3. Campaign DAG Execution

A Campaign represents a high-level task structured as a directed acyclic graph (DAG) of independent work nodes.

### Campaign Data Structures

```lisp
(defstruct campaign-node
  (id nil :type string)
  (goal nil :type string)
  (file-surface nil :type list)        ; Paths (files or directories) this node is authorized to touch
  (dependencies nil :type list)        ; List of parent node IDs
  (serialize nil :type boolean)        ; Must run sequentially, cannot be parallelized
  (status :pending :type keyword)      ; :pending, :dispatched, :landed, :accepted, :rework
  (harness-type nil :type symbol)      ; Class name of harness (e.g., 'harness-opencode)
  (harness-instance nil)               ; Reference to the active CLOS harness-instance
  (ibc nil :type string))              ; Initial Boundary Condition text (instructions/goals)

(defstruct campaign-dag
  (nodes nil :type list)               ; List of campaign-nodes
  (layers nil :type vector)            ; Array of layers derived via Kahn's algorithm
  (shared-branch nil :type string))    ; Git integration branch for the campaign
```

### Scheduling & Execution Loop

The Metaharness coordinates campaign execution using a **dynamic graph-based scheduling** model derived from the Campaign DAG, resolving dependencies node-by-node to maximize parallel execution while preventing head-of-line blocking:

1. **Topological Initialization**: The Campaign DAG is parsed and node dependencies are loaded. An in-memory scheduler tracks the status of each node (:pending, :dispatched, :landed, :accepted, :rework).
2. **Dynamic Dispatch Loop**:
   * The scheduler runs continuously. A node is eligible for dispatch as soon as all of its parent dependencies are marked `:accepted`.
   * **Collision Check**: Eligible nodes are grouped. If two eligible nodes have overlapping `file_surface` scopes, the node with higher priority or fewer dependencies is dispatched in parallel, while the conflicting node is deferred and flagged for serialization.
   * **Workspace Preparation**: Prior to spawning, the class-level `harness-prepare-workspace` generic method is called using the class symbol (e.g. `'harness-librecode).
   * **Worktree Synchronization**: If a node was previously deferred (due to collision or rework) and is now dispatched, the Metaharness performs a sync step, merging or rebasing the latest campaign `shared_branch` into the node's private worktree branch to prevent working on stale checkouts.
   * **Spawn**: Spawn the harness instance mapping to its prepared workspace folder (located under `worktrees/<node-id>/`).
   * **CWD Safety Invariant**: To ensure process-global CWD safety (RES-01), the scheduling loop and parent Lisp engine must never mutate the process-global CWD via `chdir`. All file utilities and launched subprocesses must resolve relative pathnames against the thread-local `*workspace-root*` or pass the path explicitly.
3. **Await**: Monitor the session mailbox / event streams of dispatched child harnesses.
4. **Reconcile**: Run validation gates on landed work. If verification succeeds, merge the node's private branch into the campaign's `shared_branch`. Otherwise, compile linter/compiler stderr diagnostics into the node's Initial Boundary Conditions (IBC) and mark it for `:rework` to guide the agent in the next turn.

---

### Surface-Exceed Protocol

To enforce strict boundary isolation:
* A child harness is initialized with a ruleset where writing to any resource *outside* its authorized `file_surface` is treated as a `:ask` permission constraint.
* When the child agent attempts to edit an unauthorized file, the tool execution loop blocks, and the harness posts an `event-permission-asked` event.
* **Collision Check**: The Metaharness intercepts this request via the event stream. If the target path does not overlap with any concurrent node's surface, the Metaharness widens the node's `file_surface` dynamically, persists the permission update to SQLite, and approves the write, resuming the tool execution.
* **Serialization Fallback**: If the path conflicts with a concurrent running node's surface, the Metaharness denies the write, signals a collision, halts the child harness process, and marks the node for serial rescheduling. Once the conflicting node lands and is accepted, the deferred node undergoes a worktree sync and is dispatched sequentially.
* **Context Realignment**: When a halted node is resumed after a collision sync, the Metaharness appends a `context-epoch-reset` event or system update message into its event store to realign the agent's LLM context with the newly merged file contents.

---

## 4. Cross-Process Council Deliberation

The Council model governs high-stakes architectural transitions (e.g., DAG structural changes, merges, and campaign close) through distinct role-based perspectives:
* **Composer**: Orchestrator moderation and schedule derivation.
* **Architect**: Boundary fit, goal alignment, and plan amendments.
* **Lead Maintainer**: Strictly controls the merge gate (verifies code simplicity and patterns).
* **Auditor**: Audits the composer's moderation against the decision log.

### Decentralized Deliberation Protocol

To maintain decorrelation and avoid group-think across isolated workspaces:
1. **Independent-First Deposits**: Each seat (running in a separate, isolated child harness worktree) writes its assessment and commits it as a structured **JSON or JSONC** document (e.g. `.ledger/deposits/<seat-id>.json`) *before* reading any sibling's deposit. Using JSON/JSONC allows `librecode` to parse deposits natively using the `com.inuoe.jzon` library, avoiding external C-bindings and libraries like `libyaml`.
2. **Broker Transport**: Since workspaces are physically isolated on disk under `.scratch/worktrees/<node-id>/`, seats cannot read each other's local deposits. The Metaharness Composer acts as a transport broker: as each child harness completes its task, the Metaharness copies its deposit file from the worktree directory into the parent campaign's central `.ledger/deposits/` directory.
3. **Multi-Phase Deliberation (Auditor Verification)**: To resolve the Auditor's temporal paradox (where the auditor cannot audit a decision before it is made):
   * **Phase 1: Voting**: Active seats (Architect, Maintainer) write and sign their deposits independently.
   * **Phase 2: Moderation**: The Metaharness Composer parses the deposits, compiles the decision, and writes a proposed entry to the parent campaign decision ledger (`.ledger/decision-log.json`).
   * **Phase 3: Verification**: The Auditor seat is dispatched to verify the Composer's moderation against the decision log. It deposits its sign-off deposit, completing the gate.
4. **Recorded Decisions**: Once all seat deposits and Auditor verification are collected centrally, the decision is locked and appended to the ledger.
5. **Assent Validation**: Merging or closing is gated by the assent ruleset:
   * `:single` — Owner assent is sufficient for routine forward progress.
   * `:subset` — Quorum threshold required for qualitative judgments.
   * `:full` — Unanimous machine consensus (Composer, Architect, Maintainer, Auditor) required.
   * `:human` — Requires the head's explicit approval (the human seam).

### Gate Evaluation Mechanics

To enforce the verification dual, `librecode-meta` implements a dedicated gate runner (`gate.lisp`). Instead of depending on external runtimes for core protocol safety, validation is divided into native invariants and pluggable DSL-based checks.

#### Inherent Protocol Invariants (Native CL Verification)

The core safety rules of the multi-agent coordination protocol are enforced natively inside the Lisp execution engine (`council.lisp` and `campaign.lisp`):
* **Deposit Validation**: When a council seat writes an assessment to `.ledger/`, the Lisp engine directly parses the deposit document (JSON/JSONC), validates its schema (verifying fields like `seat-id`, `verdict`, and `rationale`), and verifies its cryptographic signature. Each seat signs its deposit using a private SSH or GPG key linked to the agent's identity, which the Metaharness validates against the registered agent public keys in SQLite.
* **Consensus Check**: The engine evaluates the assent ruleset (e.g., verifying that `:full` consensus has matching unanimous positive verdicts from all active seats) before allowing any merge gate transitions.
* **Surface Constraints**: The engine checks the git diff and compares it against the node's `file-surface` in-memory. 

If any inherent invariant is violated, the engine signals a `protocol-invariant-violation` condition directly, halting the campaign execution state-freeze immediately.

#### Lisp-Based Verification DSL

For project-specific gates, custom deposit checks, and workflow constraints, `librecode-meta` provides an embedded Lisp DSL to specify rules at campaign DAG boundaries:

```lisp
(defgate check-architect-deposit (node-id)
  "Ensures the architect seat deposited a valid assessment before a plan merge."
  (:target (merge-pathnames (format nil "deposits/~a-architect.json" node-id) *campaign-ledger-dir*))
  (:verify (and (probe-file target)
                (let ((data (jzon:parse target)))
                  (string-equal (gethash "verdict" data) "approved"))))
  (:on-failure (error 'missing-architect-approval :node-id node-id)))

(defgate run-local-lint (node-id)
  "Runs a local syntax/style check in the node's workspace."
  (:worktree (get-node-worktree node-id))
  (:execute "bun run lint")
  (:on-failure (error 'lint-failure :node-id node-id :exit-code exit-code)))
```

#### User-Defined External Verification Hooks

Developers can plug user-crafted checkers (e.g., custom Nickel contracts, git hooks, shell scripts, or static analysis tools) into the DAG node definition or configuration:

* **Nickel Contract Integration**: Users can register Nickel contracts using the DSL's external command wrapper:
  ```lisp
  (defgate custom-nickel-contract (node-id contract-path)
    (:execute "nickel" "export" "ledger.yaml" "--apply-contract" contract-path)
    (:on-failure (error 'contract-violation :contract contract-path)))
  ```
* **Git Hook Delegation**: The Metaharness can delegate boundary verification to the project's existing git hooks (e.g., running `.git/hooks/pre-commit` inside the worktree workspace before merging).
* **Execution Capturing**: The gate runner executes these commands via `uiop:launch-program`, captures stderr/stdout, parses exit codes, and wraps any command failure in a `gate-failure` Lisp condition, dropping the harness into the restart or REPL loops.

---

## 5. Campaign Coordination Loop (The Orchestration LLM)

To keep multi-agent campaigns moving forward autonomously while preserving safety boundaries, the Metaharness runs its own **Campaign Coordination Loop** powered by a parent-level LLM context:

* **Task Initiation**: When a campaign begins, the orchestrator constructs the initial task graph and generates the localized Initial Boundary Conditions (IBCs) for each dispatched child harness.
* **Progress Assessment**: The coordinator loop wakes periodically (e.g., when a child harness lands its work, hits a boundary, or triggers a surface collision) to evaluate progress. It analyzes the SQLite event store and the S-expression audit trail, generating prompt updates to steer the active harnesses.
* **Failure Analysis & Realignment**: If a child harness fails a validation gate, the parent coordinator uses the LLM to inspect compilation, test, or linter stderr traces, formulates a corrective design revision, and updates the child's target boundary for dispatching rework.
* **Blocking Determinations**: The loop distinguishes between autonomous progress and non-negotiable checks (e.g., design-rights conflicts, missing third-party dependencies, or non-converging review cycles). If a block is encountered, the coordinator halts the campaign and delegates the decision to the human seam.

### Campaign State Persistence

To recover from supervisor process crashes or system reboots during long-running campaigns:
* **S-Expression Journal**: The Metaharness persists campaign DAG structures, node statuses, isolated worktree bindings, and current execution layer states as a serialized S-expression journal (`campaign-journal.lisp-expr`) stored centrally in the campaign's external ledger directory.
* **Append-Only Operations**: Any scheduling state transition (such as dispatching a node or landing a branch) writes a transition record to the journal file opened in `:append` mode. The write calls `force-output` immediately to ensure the transaction is written to disk before the coordinator issues commands to child processes.
* **State Reconstitution**: Upon process restart, the Metaharness reads the journal file, replays the transitions sequentially to reconstruct the DAG state in-memory, checks the status of active tmux panes or worktree branches, and resumes the campaign execution loop at the exact recovery boundary.

---

## 6. Asynchronous Messaging & Headless Notifications

The Metaharness operates as a long-running background daemon (`librecode-metad`) that coordinates campaigns headlessly. It exposes a Clack/Hunchentoot-based HTTP server for programmatic control:
* **REST Endpoints**: `/campaign/:id/status`, `/campaign/:id/nodes`, and `/campaign/:id/gate/approve`.
* **Server-Sent Events (SSE)**: `GET /campaign/:id/events` to stream real-time progress, node dispatches, linter outputs, and council votes.

This architecture decouples execution from monitoring: the campaign runs autonomously in the background while developers connect via headless messaging channels or the native dashboard.

### Notification Protocol

```lisp
(defgeneric send-notification (channel recipient message &key status)
  (:documentation "Sends an asynchronous status update or diagnostic alert to the recipient."))

(defgeneric request-decision (channel recipient prompt options)
  (:documentation "Suspends the coordinator execution path, sends a prompt with structured select options (e.g. Accept, Reject, Widen Surface), and returns the selected option once the recipient replies."))
```

### Messaging Adapters

* **Metaharness Native TUI (librecode-meta-tui)**: A terminal user interface that connects to the local daemon port. It renders the active campaign DAG, tracks node lifecycle states (pending, dispatched, landed, accepted, rework), displays consolidated linter/test logs, and lets the developer inspect council deposits or co-sign merge gates.
* **Standard Console (Local TUI/REPL)**: A fallback interactive channel prompting the developer in the active Lisp listener or terminal window.
* **Signal Protocol (Signal Messenger) [Optional]**: An optional, headless channel that communicates with the developer's mobile device by wrapping a local Signal daemon (`signal-cli`). If unavailable or disabled, the system automatically falls back to local console/TUI input (RES-11).
* **Webhook/Matrix [Optional]**: Optional general purpose HTTP POST adapters to plug the Metaharness into Matrix rooms or chat integrations.

This decoupled layer ensures the campaign runs cheaply and autonomously in the background, but remains bound to the developer's final gate authority.

---

## 7. Metaharness Native TUI (librecode-meta-tui) Design

The native TUI (`librecode-meta-tui`) is built on **Croatoan** to provide a real-time, pane-partitioned campaign dashboard.

### 7.1 Panel Layout Grid

The terminal screen is split into three main Croatoan window panels:

```
+-----------------------------------------------------------------------+
|                         DAG VIEW PANEL (Top 40%)                      |
|                                                                       |
|  [Node A: Accepted] --+--> [Node B: Running] --> [Node D: Pending]    |
|                       |                                               |
|                       +--> [Node C: Landed]  --> [Node E: Pending]    |
+---------------------------------------------------+-------------------+
|               LOG VIEW PANEL (Bottom-Left 60%)    | INTERACT PANEL    |
|                                                   | (Bottom-Right 40%)|
| [Node B] src/main.lisp: compiled successfully     | Node: Node C      |
| [Node B] test: 12 tests passed, 0 failed          | Gate: Co-Sign     |
| [Node C] linter: warning: unused symbol *val*     |                   |
|                                                   | [A] Approve       |
|                                                   | [R] Rework        |
|                                                   | [T] Attach Tmux   |
+---------------------------------------------------+-------------------+
```

1. **DAG View Panel (Top, 40% height)**: Displays the campaign task graph. Nodes are rendered as interactive boxes with Unicode boundary lines. Colors indicate lifecycle status:
   * **Green**: Accepted (successfully merged).
   * **Yellow**: Running (actively executing child agent).
   * **Blue**: Landed/Reconciled (awaiting gate verification or merge authorization).
   * **Red**: Rework (gate failed, generating correction loop).
   * **Grey**: Pending (waiting for dependencies to satisfy).
2. **Log View Panel (Bottom-Left, 60% width, 60% height)**: A scrolling viewport displaying combined, color-coded stdout/stderr streams from all active subprocesses and child harnesses.
3. **Interaction Panel (Bottom-Right, 40% width, 60% height)**: Context-aware interactive prompt panel showing details of the currently selected DAG node, validation diagnostics, council votes, and key-activated options.

### 7.2 Thread-Safe Rendering Architecture

Because `ncurses` is not thread-safe, all drawing operations must run strictly within the main TUI event loop thread. 

* **UI Event Mailbox**: The TUI initializes a thread-safe `sb-concurrency:mailbox` named `*tui-mailbox*`.
* **State Updates**: When background Metaharness daemon threads process campaign state changes (e.g. node dispatches, log outputs, gate results), they push a structured UI update event to `*tui-mailbox*`:
  ```lisp
  (defstruct ui-event
    (type nil :type symbol) ; :node-state-change, :log-append, :prompt-gate
    (node-id nil :type (or null string))
    (payload nil))
  ```
* **Event Dispatch Loop**: The main thread runs a Croatoan loop that blocks on `sb-concurrency:receive-mailbox` with a non-blocking timeout (e.g., 50ms). When an event arrives, it updates the in-memory UI model, triggers a targeted panel redraw, and calls `croatoan:refresh`.

### 7.3 Tmux Attachment Subprocess Handshake

When a user selects a running node in the DAG View Panel and triggers the **Attach Tmux** command (key `T`):

1. **Suspend Ncurses**: The TUI suspends ncurses mode and restores the normal terminal screen using:
   ```lisp
   (croatoan:end-screen)
   ```
2. **Launch Subprocess**: It runs the local tmux attach command inside the foreground shell process:
   ```lisp
   (uiop:run-program "tmux attach-session -t librecode-<node-id>"
                     :input :interactive
                     :output :interactive
                     :error-output :interactive)
   ```
   This hands raw terminal control and keystrokes directly over to tmux.
3. **Restore Ncurses**: When the user detaches (`Ctrl-b d`), the subprocess exits, and the TUI executes:
   ```lisp
   (croatoan:refresh)
   ```
   This rebuilds the panel grid and redraws the TUI dashboard at its exact pre-suspension state.
