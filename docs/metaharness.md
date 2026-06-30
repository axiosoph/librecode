# librecode Metaharness (librecode-meta) Architecture

The Metaharness (`librecode-meta`) is the parent supervisor that coordinates multi-agent campaigns across physical process boundaries, establishing a **"Team of Teams"** topology. 

Rather than executing code or communicating with LLMs directly, the Metaharness schedules parallelized tasks, executes verification gates on committed files, and runs the decision council. It delegates actual task execution to independent child harness processes (such as `librecode-runner`, `harness-opencode`, or `harness-claude-code`). Each child harness operates within its own isolated git worktree workspace and manages its own local agent composition and sub-delegation loops.

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
```

### Harness Class Hierarchy

Each supported backend is implemented as a subclass of `harness`:

```lisp
(defclass harness ()
  ((id :initarg :id :reader harness-id :type string)
   (config :initarg :config :reader harness-config)
   (status :initform :idle :accessor %harness-status)))

(defclass harness-opencode (harness)
  ((pane :initarg :pane :reader harness-pane))
  (:documentation "OpenCode CLI wrapper communicating via tmux/terminal multiplexer."))

(defclass harness-librecode (harness)
  ((thread :initarg :thread :reader harness-thread)
   (workspace-root :initarg :workspace-root :reader harness-workspace-root :type pathname))
  (:documentation "Self-hosting: a native librecode runner running in-process on a separate thread.
   In-process threads must NEVER mutate the process-global current working directory (CWD) via chdir. 
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

The Metaharness coordinates the campaign using Kahn's topological sort to group nodes into parallelizable layers:

1. **Partition**: For each layer, group nodes into a `parallel` set (nodes with disjoint `file_surface` lists and no serialization flag) and a `serial` set.
2. **Dispatch**: Spawn a dedicated `harness` instance for each parallel node inside its own git worktree (`.scratch/worktrees/<node-id>`), isolated from other nodes.
3. **Await**: Monitor event streams from each active harness until they freeze or terminate.
4. **Reconcile**: Run validation gates (linters, tests, diff authorization) on the landed work. If verification succeeds, merge the node's branch into the campaign's `shared_branch`. Otherwise, flag the node for `rework` and generate a corrective boundary.
5. **Layer Boundary Check**: After all nodes in a layer land, perform a cumulative-diff gate (such as checking for orphaned references across the cut-set) before moving to the next layer.

### Surface-Exceed Protocol

To enforce strict boundary isolation:
* A child harness is only authorized to edit files declared in its `file_surface`.
* If the child agent attempts to edit a file outside its surface, the Metaharness intercepts the request.
* **Collision Check**: If the target path does not overlap with any concurrent node's surface, the Metaharness widens the node's `file_surface` dynamically and resumes the run.
* **Serialization fallback**: If the path conflicts with a concurrent node, the node is halted, marked for serialization, and rescheduled to run in the serial phase after its conflict satisfies.

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
3. **Recorded Decisions**: Once all seat deposits are collected centrally, the Metaharness Composer parses the files, verifies consensus requirements based on the decision type, and appends a structured entry to the parent campaign decision ledger (`.ledger/decision-log.json`).
4. **Assent Validation**: Merging or closing is gated by the assent ruleset:
   * `:single` — Owner assent is sufficient for routine forward progress.
   * `:subset` — Quorum threshold required for qualitative judgments.
   * `:full` — Unanimous machine consensus (Composer, Architect, Maintainer, Auditor) required.
   * `:human` — Requires the head's explicit approval (the human seam).

### Gate Evaluation Mechanics

To enforce the verification dual, `librecode-meta` implements a dedicated gate runner (`gate.lisp`). Instead of depending on external runtimes for core protocol safety, validation is divided into native invariants and pluggable DSL-based checks.

#### Inherent Protocol Invariants (Native CL Verification)

The core safety rules of the multi-agent coordination protocol are enforced natively inside the Lisp execution engine (`council.lisp` and `campaign.lisp`):
* **Deposit Validation**: When a council seat writes an assessment to `.ledger/`, the Lisp engine directly parses the deposit document (YAML/JSONC) and validates its schema (verifying present fields like `seat-id`, `verdict`, and `rationale`).
* **Consensus Check**: The engine evaluates the assent ruleset (e.g., verifying that `:full` consensus has matching unanimous positive verdicts from all active seats) before allowing any merge gate transitions.
* **Surface Constraints**: The engine checks the git diff and compares it against the node's `file-surface` in-memory. 

If any inherent invariant is violated, the engine signals a `protocol-invariant-violation` condition directly, halting the campaign execution state-freeze immediately.

#### Lisp-Based Verification DSL

For project-specific gates, custom deposit checks, and workflow constraints, `librecode-meta` provides an embedded Lisp DSL to specify rules at campaign DAG boundaries:

```lisp
(defgate check-architect-deposit (node-id)
  "Ensures the architect seat deposited a valid assessment before a plan merge."
  (:target (format nil ".ledger/deposits/~a-architect.yaml" node-id))
  (:verify (and (probe-file target)
                (let ((data (parse-yaml-file target)))
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
* **S-Expression Journal**: The Metaharness persists campaign DAG structures, node statuses, isolated worktree bindings, and current execution layer states as a serialized S-expression journal (`.ledger/campaign-journal.lisp-expr`) under the master project's root directory.
* **Append-Only Operations**: Any scheduling state transition (such as dispatching a node or landing a branch) writes a transition record to the journal file opened in `:append` mode. The write calls `force-output` immediately to ensure the transaction is written to disk before the coordinator issues commands to child processes.
* **State Reconstitution**: Upon process restart, the Metaharness reads the journal file, replays the transitions sequentially to reconstruct the DAG state in-memory, checks the status of active tmux panes or worktree branches, and resumes the campaign execution loop at the exact recovery boundary.

---

## 6. Asynchronous Messaging & Headless Notifications

For headless operation, the Metaharness does not require the developer to sit at a terminal monitoring active tmux sessions. Instead, it exposes an abstract messaging layer that relays alerts and handles blocking gates asynchronously.

### Notification Protocol

```lisp
(defgeneric send-notification (channel recipient message &key status)
  (:documentation "Sends an asynchronous status update or diagnostic alert to the recipient."))

(defgeneric request-decision (channel recipient prompt options)
  (:documentation "Suspends the coordinator execution path, sends a prompt with structured select options (e.g. Accept, Reject, Widen Surface), and returns the selected option once the recipient replies."))
```

### Messaging Adapters

* **Standard Console (Local TUI/REPL)**: The default channel for local interactive execution, prompting the developer in the active Lisp listener or terminal window.
* **Signal Protocol (Signal Messenger)**: A headless channel that communicates with the developer's mobile device by wrapping a local Signal daemon (`signal-cli`). The Metaharness packages gate failures or permission requests into secure messages, transmits them, blocks execution, and resumes once the user sends a response string matching one of the options.
* **Webhook/Matrix**: General purpose HTTP POST adapters to plug the Metaharness into Matrix rooms or chat integrations.

This decoupled layer ensures the campaign runs cheaply and autonomously in the background, but remains bound to the developer's final gate authority.
