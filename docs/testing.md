# librecode Testing Specification

This document defines the testing strategy, frameworks, fixtures, and execution models required to guarantee absolute behavioral parity between `librecode` and OpenCode.

---

## 1. Testing Philosophy & Parity

To ensure that the Common Lisp reimplementation matches the behavior of the original TypeScript/Effect engine, we operate under a two-tiered testing model:
1. **White-Box Porting**: Internal unit and integration tests (previously Effect-based) are translated to native Common Lisp tests using the **FiveAM** framework.
2. **Black-Box Parity**: System-level E2E, CLI, and UI integration tests are run unmodified against `librecode`'s Hunchentoot HTTP subscription server on port 3000.

---

## 2. Core Common Lisp Test Fixtures

Lisp integration tests reside in the `librecode-test` ASDF system. We implement native macros to replicate OpenCode's test context setup.

### 2.1 Temporary Directory Sandbox (`with-tmp-sandbox`)
Replaces OpenCode's `tmpdir` fixture. It creates a temporary directory, optionally initializes a git repository, and cleans it up after execution. To prevent cleanup failures (e.g. file lock contention) from masking the primary test assertion failures, the cleanup handler suppresses directory deletion errors:

```lisp
(defmacro with-tmp-sandbox ((path-var &key git config-plist) &body body)
  "Creates a temporary directory, binds PATH-VAR, and cleans up on exit."
  `(let ((,path-var (create-temp-directory-path)))
     (unwind-protect
          (progn
            (when ,git
              (init-sandbox-git ,path-var))
            (when ,config-plist
              (write-sandbox-config ,path-var ,config-plist))
            ,@body)
       (handler-case
           (delete-directory-and-files ,path-var)
         (serious-condition () nil)))))
```

### 2.2 Mock LLM Server (`with-mock-llm-server`)
Replaces OpenCode's `provideTmpdirServer`. It boots an ephemeral, thread-local HTTP mock server (using Clack) that streams predefined JSON chunk SSE streams on-demand, allowing deterministic testing of LLM client timeouts, retry logic, and tool call interrupts. Returning a flat body list in Clack consolidates the output, so we must use Clack's dynamic callback API to stream chunks progressively:

```lisp
(defmacro with-mock-llm-server ((port-var &key response-chunks) &body body)
  "Boots a local Clack server streaming RESPONSE-CHUNKS, binding PORT-VAR for the body."
  `(let* ((,port-var (find-free-port))
          (handler (clack:clackup
                    (lambda (env)
                      (declare (ignore env))
                      (lambda (responder)
                        (let ((writer (funcall responder '(200 (:content-type "text/event-stream")))))
                          (dolist (chunk ,response-chunks)
                            (funcall writer chunk)
                            (sleep 0.05))))) ; Simulate network latency between chunks
                    :port ,port-var :silent t)))
     (unwind-protect
          (progn ,@body)
        (clack:stop handler))))
```

---

## 3. Test Porting Matrix

The following core integration tests from `packages/opencode/test/session/` must be ported to FiveAM tests in `librecode-test`:

| TypeScript Source Test | Porting Strategy / Parity Focus |
| :--- | :--- |
| `compaction.test.ts` | Token-budget calculation and history summarization checks. |
| `retry.test.ts` | Retry logic on connection timeouts/failures. |
| `revert-compact.test.ts` | Restoring state boundaries when compaction fails. |
| `schema-decoding.test.ts` | Native `jzon` JSON/JSONC parsing validation. |
| `session.test.ts` | Two-phase input admission (admit vs promote) verification. |
| `snapshot-tool-race.test.ts` | Concurrency locks on parallel file writes. |
| `structured-output.test.ts` | Parsing LLM tool call payloads correctly. |

---

## 4. Black-Box E2E Execution

OpenCode's Playwright-based E2E smoke tests (located in `packages/app/e2e/`) run directly against `librecode-runner` to verify REST/SSE API compliance.

### Execution Procedure
1. **Start Lisp Server**:
   ```bash
   # Run from librecode-runner directory
   sbcl --eval '(asdf:load-system :librecode-runner)' \
        --eval '(librecode-runner:start-server :port 3000)'
   ```
2. **Execute E2E Suite**:
   ```bash
   # Run from OpenCode app package directory
   cd packages/app
   bun run test:e2e
   ```
   This validates the REST routes (`POST /session/:id/admit`) and event-stream delivery (`GET /session/:id/events`) under active UI operations.

---

## 5. Testing Invariants

* **No Root Execution**: Tests must never be executed from the repository root. Run tests from the package directories (e.g. `packages/librecode-runner` or system test loader).
* **Isolation**: All tests must use `with-tmp-sandbox`. Mutating the global directory or test databases outside the sandbox is strictly forbidden.
* **ACID Event store tests**: Event sourcing tests must verify that events and read projections are committed inside a single database transaction.
* **Database Isolation**: Since SQLite WAL mode restricts writes to a single thread at a time, tests run in parallel will fail on `sqlite-busy-error` if they share a database file. All tests must target in-memory database connection configurations (`:memory:`) or private database files situated inside their respective sandboxes.
