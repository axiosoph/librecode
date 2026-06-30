# librecode CLOS Agent & Permission System

`librecode` replaces ad-hoc flags and structural checks with polymorphic generic dispatch over CLOS classes for agent definitions, tool permissions, and dynamic behaviors.

## 1. CLOS Agent Hierarchy

Instead of managing agent modes via boolean flags (e.g. `isBuildMode`), agents are modeled as distinct CLOS classes inheriting from a common base class.

```lisp
(defclass agent ()
  ((id :initarg :id :reader agent-id :type string)
   (permissions :initarg :permissions :accessor agent-permissions :type list)
   (system-context :initarg :system-context :accessor agent-system-context :type string)))

(defclass build-agent (agent) ()
  (:documentation "Highly privileged agent class authorized to execute modifying shell commands, write files, and run test suites."))

(defclass plan-agent (agent) ()
  (:documentation "Read-only planning agent focused on analyzing codebase structure, drawing task DAGs, and writing text specs."))

(defclass explore-agent (agent) ()
  (:documentation "Search and research agent focused on semantic searches, prior-art surveys, and code diagnostics."))

(defclass general-agent (agent) ()
  (:documentation "Fallback agent with standard interactive capabilities."))
```

### Dynamic Mode Switching
Mode switching is implemented by instantiating a new agent class with different permission rulesets. Polymorphic methods dispatch directly on the agent's class type:

```lisp
(defgeneric execute-agent-turn (agent session-id)
  (:documentation "Runs a single turn loop, checking permissions and tool definitions specific to the agent class."))
```

---

## 2. Tool Registry & Settlement

The `tool-registry` manages available system functions. Tools are modeled as CLOS objects to support polymorphic capability checks.

### Materialization

Before an LLM call, the runner materializes the set of active tool definitions:
1. Fetch all tools registered globally or via loaded plugins.
2. Filter the tools against the current agent's ruleset.
3. Filter the tools against the target LLM model's capabilities (e.g., exclude structural patch tools if the model only supports raw edit commands).
4. Map the remaining tool objects into JSON Schemas matching the LLM provider's format.

### Settlement

During execution:
* Every tool call is validated against the schema.
* The run coordinator checks for staleness (verifying that no newer session inputs have arrived since the tool was scheduled).
* The tool runs in its isolated thread, wrapped in `unwind-protect` for clean resource recovery.

---

## 3. Permission Model

Permissions govern whether an agent is allowed to execute a specific tool on a target resource (e.g. executing `write_file` on `/etc/hosts` or `run_command` on `rm -rf /`).

### Wildcard Evaluation Algorithm

A ruleset is a list of rule structures:

```lisp
(defstruct permission-rule
  (action nil :type string)
  (resource nil :type string)
  (effect nil :type keyword)) ; :allow, :deny, :ask
```

Rules are evaluated using a **last-match-wins** algorithm within a flat list of rules. The runner searches from the end of the rules list for the first rule whose `action` and `resource` match the request via wildcard pattern matching (e.g. `git*` matches `git commit`, `*` matches anything).

If no matching rule is found in the ruleset, the evaluation falls back to a default:
`(:action "*" :resource "*" :effect :ask)`

### Resolution Workflow

For a requested action and target resources:
1. **Agent Rules Check**: Load the current agent's static ruleset. If any resource matches with a `:deny` effect, the request is immediately rejected, returning a `denied-error`.
2. **Saved Rules Merge**: Merge the agent's ruleset with the project's saved rules (persisted in SQLite per-project from previous "always allow" decisions).
3. **Resolve Effect**:
   * **`:allow`** — Permit execution immediately.
   * **`:deny`** — Reject immediately.
   * **`:ask`** — Halt execution.
     * In **Headless/Autonomous mode**: The ruleset resolves `:ask` to `:deny` dynamically, or uses a static override configuration.
     * In **Interactive mode**: Publish an `event-permission-asked` event. The coordinator allocates a `deferred` handle and blocks the draining thread on a condition variable until the user replies via the UI/REPL with `accept`, `reject`, or `always`.
     * **Saved decisions**: If the user selects `always`, the permission rule is written to the SQLite `permission_saved` table:
       ```sql
       INSERT INTO permission_saved (project_id, action, resource) VALUES (?, ?, ?);
       ```
     * **Cascading rejection**: If the user rejects the permission, all other pending permission requests for the same session are automatically rejected to prevent hanging pipelines.
