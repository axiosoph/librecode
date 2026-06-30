# librecode Metaharness Architecture

The Metaharness is the parent orchestrator of `librecode`. It coordinates multi-agent campaigns by spawning, monitoring, and communicating with multiple child harness instances (heterogeneous backends such as OpenCode, Claude Code, or native `librecode` sessions) across physical process boundaries.

## 1. Abstract Harness Interface

To support heterogeneous agent systems, the Metaharness decouples itself from any specific runner implementation. Every child agent process is managed through a uniform CLOS protocol.

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
  ((thread :initarg :thread :reader harness-thread))
  (:documentation "Self-hosting: a native librecode runner running in-process on a separate thread."))

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

To maintain decorrelation and avoid group-think:
1. **Independent-First Deposits**: Each seat (running in a separate, isolated harness context) writes its assessment and commits it as a structured YAML footprint (a deposit) under the `.ledger/` directory *before* reading any sibling's deposit.
2. **Recorded Decisions**: Once all seat deposits are collected, the Metaharness Composer parses the deposits, verifies consensus requirements based on the decision type, and appends a structured entry to the decision ledger.
3. **Assent Validation**: Merging or closing is gated by the assent ruleset:
   * `:single` — Owner assent is sufficient for routine forward progress.
   * `:subset` — Quorum threshold required for qualitative judgments.
   * `:full` — Unanimous machine consensus (Composer, Architect, Maintainer, Auditor) required.
   * `:human` — Requires the head's explicit approval (the human seam).
