# librecode Testing Specification

> **Status (as-built).** The native FiveAM + check-it suite is **BUILT** and green.
> The 21 suites declared in `librecode-test.asd` are: `event-store`, `agent`, `audit`,
> `tool`, `session`, `http`, `resilience`, `campaign`, `journal`, `harness`, `gate`,
> `supervision`, `recovery`, `failure-relay`, `cross-process`, `provider`,
> `builtin-tools`, `child`, `e2e`, `scenario`, `model`. (`t/mock-provider.lisp` is a
> shared fixture, not a suite — see §2.2.) The OpenCode-parity pieces below — the §3
> TypeScript "Test Porting Matrix" and the §4 Playwright black-box E2E run against
> OpenCode's app package — remain **DEFERRED/aspirational**; they describe a parity
> goal, not tests that currently run. §4's body still names
> `librecode-runner:start-server` as the entry point; the actual function is
> `librecode-runner.http:start-http-bridge` (fixed inline below, not just in this
> banner).

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

### 2.2 Mock Provider Fixture (`with-mock-provider`)
Replaces OpenCode's `provideTmpdirServer`. Defined in `t/mock-provider.lisp`, it boots
an ephemeral **Hunchentoot** acceptor (not Clack) on a free local port and installs a
single dispatcher matching a given path (default `/stream`) and that acceptor's own
port — never a different one sharing the process-global `hunchentoot:*dispatch-table*`.
It consolidates the dispatch/acceptor boilerplate that `http-tests`, `session-tests`,
`child-tests`, `harness-tests`, and `provider-tests` used to each hand-roll
independently; it does not replace the real HTTP/SSE transport, so every test using it
still exercises a genuine round-trip.

A `responder` callback is invoked once per matching request as
`(funcall responder request call-index)` (`call-index` starts at 1 and increments per
match) and must return a list of scripted actions to stream back over SSE — `(:content
text)`, `(:tool-calls calls)`, `(:raw json-string)`, or `(:call thunk)` — terminated
automatically with a `data: [DONE]` marker unless `:no-done` is present. Optional
`:method` restricts the dispatcher to one HTTP method, and `:connection-close` sends a
`Connection: close` header for callers whose client relies on connection closure to
signal end-of-stream:

```lisp
(defmacro with-mock-provider ((port-var &key (path "/stream") (host "127.0.0.1")
                                method connection-close responder)
                               &body body)
  "Bind PORT-VAR to a fresh local port, start an ephemeral Hunchentoot acceptor
there, install a single dispatcher matching PATH/METHOD/PORT-VAR's own port, run
BODY with the mock provider live, then always tear the acceptor and dispatcher
back down on exit.")
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
        --eval '(librecode-runner.http:start-http-bridge :port 3000)'
   ```
2. **Execute E2E Suite**:
   ```bash
   # Run from OpenCode app package directory
   cd packages/app
   bun run test:e2e
   ```
    This validates the REST routes (`POST /api/session/:sessionID/prompt`) and event-stream delivery (`GET /api/session/:sessionID/event`) under active UI operations.

---

## 5. Testing Invariants

* **No Root Execution**: Tests must never be executed from the repository root. Run tests from the package directories (e.g. `packages/librecode-runner` or system test loader).
* **Isolation**: All tests must use `with-tmp-sandbox`. Mutating the global directory or test databases outside the sandbox is strictly forbidden.
* **ACID Event store tests**: Event sourcing tests must verify that events and read projections are committed inside a single database transaction.
* **Database Isolation**: Since SQLite WAL mode restricts writes to a single thread at a time, tests run in parallel will fail on `sqlite-busy-error` if they share a database file. All tests must target in-memory database connection configurations (`:memory:`) or private database files situated inside their respective sandboxes.
