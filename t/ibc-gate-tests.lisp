;;; -*- Mode: Lisp; Syntax: Common-Lisp; indent-tabs-mode: nil; coding: utf-8; Show-Trailing-Whitespace: t -*-
;;;
;;; ibc-gate-tests.lisp — Unit/integration tests for the pre-dispatch IBC-sufficiency gate
;;;
;;; Red-first per /core: this file is authored BEFORE the gate's serializer,
;;; contract-check, and run-node-execution wiring exist.
;;; Every test below is expected to fail against current HEAD, either with an
;;; UNDEFINED-FUNCTION condition (the serializer/gate functions do not exist
;;; yet) or a wrong final node status (the gate is not wired into
;;; run-node-execution yet) -- never a compile error or a typo.
;;;

(defpackage #:librecode-test.ibc-gate
  (:use #:cl #:fiveam)
  (:import-from #:librecode-meta.campaign
                #:campaign
                #:campaign-node
                #:make-campaign-node
                #:campaign-node-id
                #:campaign-node-status
                #:campaign-node-boundary
                #:boundary
                #:make-boundary
                #:make-boundary-from-prompt
                #:make-campaign-dag
                #:run-campaign
                #:campaign-failure-counts)
  (:import-from #:librecode-test.supervision
                #:setup-test-git-repo)
  (:export #:ibc-gate-suite))
(in-package #:librecode-test.ibc-gate)

(def-suite ibc-gate-suite :description "Test the pre-dispatch IBC-sufficiency gate")
(in-suite ibc-gate-suite)

;;; ============================================================================
;;; Harness instrumentation -- a NEW harness class, never an edit to
;;; t/supervision-tests.lisp's mock-supervision-harness (outside this file's
;;; declared surface). harness-prompt/harness-status/
;;; harness-terminate/harness-read-event dispatch on the INSTANCE, so a plain
;;; CLOS subclass inherits them and only needs to override harness-prompt (to
;;; count invocations, then call-next-method to preserve mock-supervision-
;;; harness's existing timing/threading/fail-p behavior verbatim). But
;;; harness-spawn/harness-prepare-workspace/harness-cleanup-workspace dispatch
;;; on an EQL-specialized type-name symbol, which does NOT participate in
;;; class-based inheritance -- this new type-symbol needs its own
;;; eql-specialized methods for those three, mirroring mock-supervision-
;;; harness's own (t/supervision-tests.lisp:36-53).
;;;
;;; The counter itself is a plain special variable, not a CLOS class-
;;; allocated slot: the gate under test rejects the node before ANY harness
;;; instance is ever constructed -- the insertion point is the
;;; first statement inside run-node-execution, before prepare-node-worktree,
;;; earlier even than harness-spawn -- so there is no single instance whose
;;; slot could accumulate a count across the retry ladder's repeated
;;; attempts; a special variable observed across the whole test body is the
;;; correct shape for "was harness-prompt ever reached, on any attempt."
;;; ============================================================================

(defvar *gate-test-prompt-count* 0
  "Count of harness-prompt invocations on GATE-TEST-HARNESS instances across
the current test body. Reset to 0 at the start of every test that reads it.")

(defclass gate-test-harness (librecode-test.supervision::mock-supervision-harness)
  ()
  (:documentation "mock-supervision-harness subclass instrumented to prove
the \"harness never received a prompt\" claim -- see file header."))

(defmethod librecode-meta.harness:harness-prompt ((instance gate-test-harness) prompt &key mode)
  (incf *gate-test-prompt-count*)
  (call-next-method))

(defmethod librecode-meta.harness:harness-spawn ((type (eql 'gate-test-harness)) config)
  (let* ((session-id (getf config :id))
         (fail-p (search "fail" session-id)))
    (make-instance 'gate-test-harness
                   :id session-id
                   :config config
                   :fail-p (not (null fail-p))
                   :duration 0.2)))

(defmethod librecode-meta.harness:harness-prepare-workspace ((class (eql 'gate-test-harness)) repo-path target-dir)
  (declare (ignore repo-path))
  (ensure-directories-exist target-dir)
  t)

(defmethod librecode-meta.harness:harness-cleanup-workspace ((class (eql 'gate-test-harness)) repo-path target-dir &key force)
  (declare (ignore repo-path force))
  (uiop:delete-directory-tree target-dir :validate (constantly t) :if-does-not-exist :keep)
  t)

;;; ============================================================================
;;; kebab->snake serializer, verified independent of any nickel
;;; invocation (a pure unit test on the hash-table shape).
;;; ============================================================================

(test t-boundary-serializer-field-mapping
  "boundary->json-hash-table maps the 4 kebab-case slots to the contract's
exact 4 snake_case keys, 1:1, no extra/missing keys."
  (let* ((b (make-boundary :may-commit t
                           :file-surface '("src/a.lisp" "src/b.lisp")
                           :halt-conditions '("a cited premise is refuted")
                           :prompt "do the thing"))
         (ht (librecode-meta.campaign::boundary->json-hash-table b)))
    (is (hash-table-p ht))
    (is (= 4 (hash-table-count ht)))
    (is (eq t (gethash "may_commit" ht)))
    (is (equal '("src/a.lisp" "src/b.lisp") (gethash "file_surface" ht)))
    (is (equal '("a cited premise is refuted") (gethash "halt_conditions" ht)))
    (is (equal "do the thing" (gethash "prompt" ht)))
    ;; None of the kebab-case slot names must leak through as JSON keys.
    (is (null (nth-value 1 (gethash "may-commit" ht))))
    (is (null (nth-value 1 (gethash "file-surface" ht))))
    (is (null (nth-value 1 (gethash "halt-conditions" ht))))))

(test t-boundary-serializer-false-and-empty-fields
  "may-commit NIL serializes to JSON false (not a missing key), and empty
file-surface/halt-conditions serialize to an empty array (not null/missing) --
these three fields have no null/non-null mismatch against the
contract, unlike prompt."
  (let* ((b (make-boundary :may-commit nil :file-surface nil :halt-conditions nil :prompt "x"))
         (ht (librecode-meta.campaign::boundary->json-hash-table b)))
    (is (= 4 (hash-table-count ht)))
    (multiple-value-bind (val present-p) (gethash "may_commit" ht)
      (is-true present-p)
      (is (eq nil val)))
    (multiple-value-bind (val present-p) (gethash "file_surface" ht)
      (is-true present-p)
      (is (null val)))
    (multiple-value-bind (val present-p) (gethash "halt_conditions" ht)
      (is-true present-p)
      (is (null val)))))

;;; ============================================================================
;;; Any nickel export --apply-contract failure against the boundary
;;; contract is classified as gate-failure, never protocol-invariant-
;;; violation. Exercised at the raw-hash-table
;;; level (bypassing the boundary struct entirely) to prove the missing-
;;; field shape specifically -- a defstruct's 4 slots always round-trip to
;;; 4 JSON keys, so a genuine "some required key is absent" case can
;;; only be constructed below the struct layer, directly against the
;;; contract-checking primitive.
;;; ============================================================================

(test t-missing-required-field-rejected
  "A hash-table missing halt_conditions entirely (not merely empty) fails
contracts/ibc-boundary.ncl's built-in presence check and is classified
gate-failure, never protocol-invariant-violation."
  (let ((ht (make-hash-table :test 'equal)))
    (setf (gethash "may_commit" ht) t)
    (setf (gethash "file_surface" ht) '("src/a.lisp"))
    (setf (gethash "prompt" ht) "hi")
    ;; halt_conditions intentionally omitted -- the property under test.
    (signals librecode-runner.conditions:gate-failure
      (librecode-meta.campaign::run-boundary-contract-gate ht))))

;;; ============================================================================
;;; prompt = nil is legal at the Lisp
;;; level (defstruct's (or null string) type) but must be REJECTED by the
;;; gate, exercised end-to-end through the full struct->hash-table->nickel
;;; pipeline (gate-check-boundary), never a silent pass, never a raw Lisp
;;; crash in the serializer.
;;; ============================================================================

(test t-null-prompt-rejected
  "A boundary with prompt = nil is legal Lisp but fails the contract's
non-null String requirement for prompt -- gate-failure signaled."
  (let ((b (make-boundary :may-commit t :file-surface nil :halt-conditions nil :prompt nil)))
    (signals librecode-runner.conditions:gate-failure
      (librecode-meta.campaign::gate-check-boundary b))))

;;; ============================================================================
;;; A complete boundary (all 4 fields present, prompt non-null) passes
;;; the gate silently.
;;; ============================================================================

(test t-complete-boundary-passes
  "A boundary with all 4 fields present and a non-null prompt passes the
gate without signaling any condition."
  (let ((b (make-boundary :may-commit t
                          :file-surface '("src/a.lisp")
                          :halt-conditions '("halt-condition-a")
                          :prompt "Implement the thing.")))
    (finishes (librecode-meta.campaign::gate-check-boundary b))
    (is (eq t (librecode-meta.campaign::gate-check-boundary b)))))

;;; ============================================================================
;;; A nil-boundary node is unaffected: the existing goal-fallback
;;; (campaign-node-effective-prompt) still drives dispatch, and the gate is a
;;; no-op for it -- a nil boundary is deliberately not gated.
;;; ============================================================================

(test t-nil-boundary-node-unaffected
  "A node whose boundary slot is nil (the pre-existing goal-fallback path)
still dispatches and lands normally under the mock harness, unchanged from
prior behavior."
  (librecode-test.event-store::with-tmp-sandbox (dir :git t)
    (setup-test-git-repo dir)
    (let* ((node (make-campaign-node :id "node-nil-boundary-ok"
                                     :goal "Goal-fallback node, no boundary set"
                                     :file-surface '("src/a.lisp")
                                     :harness-type 'librecode-test.supervision::mock-supervision-harness))
           (dag (make-campaign-dag :nodes (list node) :shared-branch "master"))
           (journal-file (uiop:merge-pathnames* "campaign-journal.lisp-expr" dir))
           (workspace-dir (uiop:merge-pathnames* "workspace/" dir))
           (campaign (make-instance 'campaign
                                    :dag dag
                                    :journal-path journal-file
                                    :repository-path dir
                                    :workspace-dir workspace-dir)))
      (is (null (campaign-node-boundary node)))
      (run-campaign campaign)
      (is (eq :accepted (campaign-node-status node))))))

;;; ============================================================================
;;; Integration proof: a node with an insufficient boundary never
;;; reaches harness-prompt (the instrumented counter stays at 0) and ends the
;;; run in :rework or :skipped via the existing, unmodified autonomous
;;; retry/rework/skip ladder (execute-node-batch, campaign.lisp:443-523) --
;;; never :landed, never an unhandled Lisp error escaping run-campaign.
;;;
;;; max-retries 5 mirrors t/recovery-tests.lisp's c-bounded-ladder precedent
;;; exactly: the ladder's own cond drives count 1 -> :pending (retry), count
;;; 2 -> :rework, count 3 -> :skipped (since 3 >= 3 and 3 < (1- 5)) -- always
;;; resolved via the autonomous retry-count path, never via the escalation-
;;; required/supervisor-mailbox path (which only fires once count reaches the
;;; limit itself), so this test needs no escalation-hook.
;;; ============================================================================

(test t-insufficient-boundary-gated-before-dispatch
  "A node with prompt = nil never advances the instrumented harness's
prompt-received counter past zero, and ends in :rework or :skipped -- never
:landed -- via the existing autonomous retry/rework/skip ladder."
  (setf *gate-test-prompt-count* 0)
  (librecode-test.event-store::with-tmp-sandbox (dir :git t)
    (setup-test-git-repo dir)
    (let* ((node (make-campaign-node :id "node-insufficient-boundary"
                                     :goal "Should never reach this goal text -- boundary is gated"
                                     :file-surface '("src/a.lisp")
                                     :harness-type 'gate-test-harness
                                     :boundary (make-boundary :may-commit t
                                                              :file-surface nil
                                                              :halt-conditions nil
                                                              :prompt nil)))
           (dag (make-campaign-dag :nodes (list node) :shared-branch "master"))
           (journal-file (uiop:merge-pathnames* "campaign-journal.lisp-expr" dir))
           (workspace-dir (uiop:merge-pathnames* "workspace/" dir))
           (campaign (make-instance 'campaign
                                    :dag dag
                                    :journal-path journal-file
                                    :repository-path dir
                                    :workspace-dir workspace-dir
                                    :autonomous-p t
                                    :max-retries 5)))
      (run-campaign campaign)
      (is (member (campaign-node-status node) '(:rework :skipped)))
      (is (not (eq :landed (campaign-node-status node))))
      (is (= 0 *gate-test-prompt-count*)))))

(test t-complete-boundary-node-still-dispatches
  "A node WITH a complete, sufficient boundary still reaches harness-prompt
and lands normally -- the gate must not reject valid grants (a regression
companion to the insufficient-boundary rejection proof above)."
  (setf *gate-test-prompt-count* 0)
  (librecode-test.event-store::with-tmp-sandbox (dir :git t)
    (setup-test-git-repo dir)
    (let* ((node (make-campaign-node :id "node-complete-boundary-ok"
                                     :goal "Fallback goal, unused -- boundary prompt wins"
                                     :file-surface '("src/a.lisp")
                                     :harness-type 'gate-test-harness
                                     :boundary (make-boundary :may-commit t
                                                              :file-surface '("src/a.lisp")
                                                              :halt-conditions '("halt-a")
                                                              :prompt "Do the authorized thing.")))
           (dag (make-campaign-dag :nodes (list node) :shared-branch "master"))
           (journal-file (uiop:merge-pathnames* "campaign-journal.lisp-expr" dir))
           (workspace-dir (uiop:merge-pathnames* "workspace/" dir))
           (campaign (make-instance 'campaign
                                    :dag dag
                                    :journal-path journal-file
                                    :repository-path dir
                                    :workspace-dir workspace-dir)))
      (run-campaign campaign)
      (is (eq :accepted (campaign-node-status node)))
      (is (> *gate-test-prompt-count* 0)))))
