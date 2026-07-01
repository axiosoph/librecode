# Common Lisp Developer & Style Guidelines

This document outlines the architectural paradigms, style requirements, and library dependencies for developing `librecode`. It is designed to ensure developers and AI agents write idiomatic Common Lisp rather than awkwardly mapping imperative TypeScript patterns.

---

## 1. Core Lisp Paradigms & Guidelines

### 1.1 Dynamic Extent & Context Propagation
* **Paradigm**: Do not parameter-drill context objects (like session settings, credentials, or current task boundaries) through the call stack. 
* **Guidelines**: Use thread-local special variables (dynamic variables) bound via `let`.
  ```lisp
  ;; Good: dynamic extent handles scope cleanly
  (defvar *active-purpose* nil)

  (defun run-task ()
    (format t "Purpose is: ~A~%" *active-purpose*))

  (let ((*active-purpose* "Reconcile specifications"))
    (run-task))
  ```

### 1.2 Values vs. Entities (Structs vs. Classes)
* **Paradigm**: Distinguish between immutable value types (events, configuration snapshots, deposit records) and stateful or polymorphic entities (agents, tool registries).
* **Guidelines**:
  * Use `defstruct` (with `:read-only t` where appropriate) for value types. Structures are lightweight, compiler-optimized, and represent pure data.
  * Use `defclass` strictly for objects requiring polymorphic method dispatch (CLOS) or mutable state encapsulation.
  * **Always** declare a `defgeneric` before writing a `defmethod` for polymorphic dispatch.

### 1.3 Stack-Preserving Failure Recovery (Condition-Restart)
* **Paradigm**: Do not use `handler-case` as a default try/catch block. `handler-case` unwinds the stack, destroying the debugging context.
* **Guidelines**:
  * Use `handler-bind` to intercept conditions at the signaling site. This preserves the stack, enabling SLIME/Sly live inspection or automated restarts to fix defects in-place.
  ```lisp
  ;; Good: stack is kept intact for the handler
  (handler-bind ((provider-error (lambda (c)
                                   (invoke-restart 'retry-with-backup))))
    (execute-provider-turn))
  ```

### 1.4 Macros: Declarative DSLs, Not Boilerplate Hiding
* **Paradigm**: Only use macros to create syntax boundaries or declarative DSLs (like `defprocedure` or `with-boundary`).
* **Guidelines**: If a task can be accomplished with a normal function, use a function. If a macro is needed, write a functional helper to do the heavy lifting, keeping the macro expansion thin.

---

## 2. Library Dependency Surface

To keep the system lean and maintainable, the dependency list is restricted to the
following approved packages. This table is reconciled to the actual
`depends-on` clauses of `librecode-runner.asd`, `librecode-meta.asd`, and
`librecode-test.asd`.

### Runtime dependencies

| Library | System declared in | Subsystem | Purpose |
| :--- | :--- | :--- | :--- |
| `cl-sqlite` (system `sqlite`) | runner | Database | Direct SQLite WAL engine connection management. |
| `bordeaux-threads` | runner | Concurrency | Portable multithreading (bt2) and condition variables. |
| `com.inuoe.jzon` | runner | JSON | Stream-oriented, compliant JSON parsing. |
| `dexador` | runner | HTTP client / SSE | HTTP queries and SSE event-stream consumption. |
| `trivial-signal` | runner | Signals | Graceful shutdown signal handling. |
| `cl-jschema` | runner | JSON Schema | Tool parameter schema validation (`tool.lisp`). |
| `clack` | runner + test | HTTP Server | Booting the REST/SSE API server. |
| `hunchentoot` | runner + test | HTTP Server | Backing web server for Clack. |
| `clack-handler-hunchentoot` | runner + test | HTTP Server | Clack ⇄ Hunchentoot handler bridge. |
| `sb-concurrency` | (SBCL `require`, not quicklisp) | Concurrency | Lock-free mailboxes and queues (native to SBCL). |

### Test-only dependencies

| Library | System declared in | Purpose |
| :--- | :--- | :--- |
| `fiveam` | test | Unit/integration test framework. |
| `check-it` | test | Property-based testing (generators). |
| `usocket` | test | Free-port discovery for cross-process/HTTP tests. |

> **Note:** `alexandria` is referenced in `src/runner/runner.lisp` and
> `src/runner/http.lisp` but is not declared in any `depends-on` clause — it loads
> only transitively (via `dexador`/`clack`). This is a latent fragility, not an
> approved direct dependency; declare it explicitly if the code keeps using it.
>
> The libraries `croatoan`, `local-time`, `uuid`, and `split-sequence` previously
> listed here are **not used anywhere** in `src/` or `t/` and have been removed.

---

## 3. Style & Layout Conventions

### 3.1 Naming Conventions
* Use lowercase, hyphen-separated names for symbols (kebab-case), e.g., `execute-state-and-deposit`.
* Wrap global/special variables in asterisks: `*active-tracker*`.
* Wrap constants in plus signs: `+max-token-budget+`.
* Predicates (functions returning boolean) must end in `-p`, e.g., `goal-overlap-p` (or `?` if matching a specific DSL convention).

### 3.2 Documentation
* All exported functions, macros, structures, classes, and variables **must** carry a descriptive docstring explaining *why* it exists and its invariants.
* Use inline comments sparingly, explaining non-obvious constraints rather than describing what the code is doing.

### 3.3 Packages & Imports
* Define one package per module using `defpackage` in `src/packages.lisp`.
* Explicitly import external symbols (e.g., using `:import-from :alexandria :when-let`) to prevent namespace collisions and keep dependency imports auditable.
