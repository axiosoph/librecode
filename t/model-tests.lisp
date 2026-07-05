;;; -*- Mode: Lisp; Syntax: Common-Lisp; indent-tabs-mode: nil; coding: utf-8; Show-Trailing-Whitespace: t -*-
;;;
;;; model-tests.lisp — Unit, example, and property tests for librecode-model
;;;
;;; The reference model for the metaharness's core state machine (roadmap
;;; workstream A / J). See docs/model.md for the state-machine picture and the
;;; conformance seam this model defines.
;;;

(defpackage #:librecode-test.model
  (:use #:cl #:fiveam #:check-it)
  (:shadowing-import-from #:check-it #:*num-trials*)
  ;; NOTE: LIBRECODE-MODEL:SKIP is not imported — it collides with FIVEAM:SKIP.
  ;; Referenced fully-qualified as LIBRECODE-MODEL:SKIP throughout this file.
  (:import-from #:librecode-model
                #:dag #:dag-p #:dag-node-specs #:make-dag
                #:dag-node #:make-dag-node #:dag-node-p
                #:dag-node-id #:dag-node-dependencies
                #:find-dag-node #:dag-node-ids #:dag-layers
                #:deposit #:deposit-p #:deposit-validation-state
                #:deposit-gate-mode #:deposit-phase
                #:node-state #:node-state-p #:node-state-id
                #:node-state-status #:node-state-phase #:node-state-deposit
                #:node-state-file-surface
                #:model-state #:model-state-p #:model-state-dag
                #:model-state-node-states #:model-state-events
                #:initial-state #:find-node-state
                #:rejected-p #:rejection-reason
                #:dispatch #:land #:gate-check #:quarantine #:discharge #:escalate
                #:widen-surface
                #:transition-event #:replay
                #:phase-monotonic-p #:no-pending-proven-p #:tamper-evident-p
                #:dag-preserved-p #:schedule-correct-p #:surface-monotonic-p)
  (:export #:model-suite))

(in-package #:librecode-test.model)

(def-suite model-suite :description "Test the librecode-model reference state machine")
(in-suite model-suite)

;;; --- Test fixtures ---

(defun linear-dag ()
  "A -> B -> C, a minimal chain exercising dependency-gated dispatch."
  (multiple-value-bind (dag status)
      (make-dag (list (make-dag-node "A" nil)
                       (make-dag-node "B" '("A"))
                       (make-dag-node "C" '("B"))))
    (assert (eq status :ok))
    dag))

;;; --- DAG validity: unit tests ---

(test test-make-dag-valid-linear
  (multiple-value-bind (dag status) (make-dag (list (make-dag-node "A" nil)
                                                     (make-dag-node "B" '("A"))))
    (is (eq :ok status))
    (is (dag-p dag))
    (is (equal '("A" "B") (dag-node-ids dag)))))

(test test-make-dag-duplicate-id
  (multiple-value-bind (dag status) (make-dag (list (make-dag-node "A" nil)
                                                     (make-dag-node "A" nil)))
    (is (null dag))
    (is (eq :duplicate-id (first status)))
    (is (equal "A" (second status)))))

(test test-make-dag-dangling-dependency
  (multiple-value-bind (dag status) (make-dag (list (make-dag-node "A" '("MISSING"))))
    (is (null dag))
    (is (eq :dangling-dependency (first status)))
    (is (equal "A" (second status)))
    (is (equal "MISSING" (third status)))))

(test test-make-dag-cycle
  (multiple-value-bind (dag status) (make-dag (list (make-dag-node "A" '("B"))
                                                     (make-dag-node "B" '("A"))))
    (is (null dag))
    (is (equal '(:cycle) status))))

;;; --- DAG layering: unit tests ---

(test test-dag-layers-linear
  (let ((layers (dag-layers (linear-dag))))
    (is (equal '(("A") ("B") ("C")) layers))))

(test test-dag-layers-branching
  (multiple-value-bind (dag status)
      (make-dag (list (make-dag-node "A" nil)
                       (make-dag-node "B" '("A"))
                       (make-dag-node "C" '("A"))
                       (make-dag-node "D" '("B" "C"))))
    (assert (eq status :ok))
    (let ((layers (dag-layers dag)))
      (is (equal '(("A") ("B" "C") ("D")) layers)))))

(test test-dag-layers-independent
  (multiple-value-bind (dag status)
      (make-dag (list (make-dag-node "B" nil)
                       (make-dag-node "A" nil)))
    (assert (eq status :ok))
    (is (equal '(("A" "B")) (dag-layers dag)))))

;;; --- Transition legality: unit tests ---

(defun prove-node (state id)
  "Test helper: drive ID through the happy path (dispatch/land/gate-check
:pass) to :proven, asserting every step succeeds. Not exported — a fixture,
not part of the model's public API."
  (multiple-value-bind (s o) (dispatch state id) (is (eq :ok o)) (setf state s))
  (multiple-value-bind (s o) (land state id) (is (eq :ok o)) (setf state s))
  (multiple-value-bind (s o) (gate-check state id :pass) (is (eq :ok o)) (setf state s))
  state)

(test test-dispatch-rejects-unproven-dependency
  (let ((state (initial-state (linear-dag))))
    (multiple-value-bind (state2 outcome) (dispatch state "B")
      (is-true (rejected-p outcome))
      (is (eq :dependencies-not-proven (rejection-reason outcome)))
      (is (eq :queued (node-state-status (find-node-state state2 "B")))))))

(test test-dispatch-unknown-node-rejected
  (let ((state (initial-state (linear-dag))))
    (multiple-value-bind (state2 outcome) (dispatch state "NOPE")
      (is (rejected-p outcome))
      (is (eq :unknown-node (rejection-reason outcome)))
      (is (eq state state2)))))

(test test-happy-path-unblocks-dependent
  (let ((state (initial-state (linear-dag))))
    (setf state (prove-node state "A"))
    (is (eq :proven (node-state-status (find-node-state state "A"))))
    (is (= 1 (node-state-phase (find-node-state state "A"))))
    (multiple-value-bind (state2 outcome) (dispatch state "B")
      (is (eq :ok outcome))
      (is (eq :dispatched (node-state-status (find-node-state state2 "B")))))))

;;; --- Decided edge case 1: degraded-mode discharge failure -----------------

(test test-discharge-failure-loses-nothing-proven
  (let ((state (initial-state (linear-dag))))
    (multiple-value-bind (s o) (dispatch state "A") (is (eq :ok o)) (setf state s))
    (multiple-value-bind (s o) (land state "A") (is (eq :ok o)) (setf state s))
    (multiple-value-bind (s o) (quarantine state "A") (is (eq :ok o)) (setf state s))
    (is (eq :quarantined (node-state-status (find-node-state state "A"))))
    (is (eq :pending (deposit-validation-state (node-state-deposit (find-node-state state "A")))))
    (multiple-value-bind (s o) (discharge state "A" :fail) (is (eq :ok o)) (setf state s))
    (let ((a (find-node-state state "A")))
      (is (eq :rework (node-state-status a)))
      (is (eq :failed (deposit-validation-state (node-state-deposit a))))
      ;; Nothing proven was ever lost: A was never :proven in the first place.
      (is-false (some (lambda (ns) (eq (node-state-status ns) :proven)) (model-state-node-states state))))
    ;; The delta-IBC re-dispatch rework promises: A can be dispatched again.
    (multiple-value-bind (s o) (dispatch state "A")
      (is (eq :ok o))
      (is (eq :dispatched (node-state-status (find-node-state s "A")))))))

(test test-discharge-success-proves-quarantined-node
  (let ((state (initial-state (linear-dag))))
    (multiple-value-bind (s o) (dispatch state "A") (is (eq :ok o)) (setf state s))
    (multiple-value-bind (s o) (land state "A") (is (eq :ok o)) (setf state s))
    (multiple-value-bind (s o) (quarantine state "A") (is (eq :ok o)) (setf state s))
    (multiple-value-bind (s o) (discharge state "A" :pass) (is (eq :ok o)) (setf state s))
    (let ((a (find-node-state state "A")))
      (is (eq :proven (node-state-status a)))
      (is (eq :proven (deposit-validation-state (node-state-deposit a))))
      (is (eq :degraded (deposit-gate-mode (node-state-deposit a)))))))

;;; --- Decided edge case 2: non-terminating contract = bounded-timeout fail --

(test test-timeout-is-a-fail-never-a-third-state
  (let ((gated-state (initial-state (linear-dag)))
        (timeout-state (initial-state (linear-dag))))
    (dolist (pair (list (list gated-state :fail) (list timeout-state :timeout)))
      (destructuring-bind (state result) pair
        (multiple-value-bind (s o) (dispatch state "A") (is (eq :ok o)) (setf state s))
        (multiple-value-bind (s o) (land state "A") (is (eq :ok o)) (setf state s))
        (multiple-value-bind (s o) (gate-check state "A" result) (is (eq :ok o)) (setf state s))
        (let ((a (find-node-state state "A")))
          (is (eq :rework (node-state-status a)))
          (is (eq :failed (deposit-validation-state (node-state-deposit a)))))))))

;;; --- Decided edge case 3: degraded quarantine blocks a dependent dispatch --

(test test-quarantine-does-not-advance-past-the-gate
  (let ((state (initial-state (linear-dag))))
    (multiple-value-bind (s o) (dispatch state "A") (is (eq :ok o)) (setf state s))
    (multiple-value-bind (s o) (land state "A") (is (eq :ok o)) (setf state s))
    (multiple-value-bind (s o) (quarantine state "A") (is (eq :ok o)) (setf state s))
    (is (eq :quarantined (node-state-status (find-node-state state "A"))))
    ;; A is durably recorded (landed + quarantined) but NOT proven, so the DAG
    ;; phase does not advance past this gate: B still cannot dispatch.
    (multiple-value-bind (state2 outcome) (dispatch state "B")
      (is (rejected-p outcome))
      (is (eq :dependencies-not-proven (rejection-reason outcome)))
      (is (eq :queued (node-state-status (find-node-state state2 "B")))))))

;;; --- Plan-amendment: WIDEN-SURFACE and INVARIANT 5 (surface monotonicity) -

(test test-widen-surface-grows-file-surface
  (let ((state (initial-state (linear-dag))))
    (is (null (node-state-file-surface (find-node-state state "A"))))
    (multiple-value-bind (s o) (dispatch state "A") (is (eq :ok o)) (setf state s))
    (multiple-value-bind (s o) (widen-surface state "A" '("x.lisp"))
      (is (eq :ok o))
      (setf state s))
    (is (equal '("x.lisp") (node-state-file-surface (find-node-state state "A"))))
    ;; A second widening unions with, rather than replaces, the prior surface.
    (multiple-value-bind (s o) (widen-surface state "A" '("y.lisp"))
      (is (eq :ok o))
      (setf state s))
    (is (null (set-exclusive-or '("x.lisp" "y.lisp")
                                 (node-state-file-surface (find-node-state state "A"))
                                 :test #'string=)))))

(test test-widen-surface-rejects-terminal-node
  (let ((state (initial-state (linear-dag))))
    (multiple-value-bind (s o) (librecode-model:skip state "A") (is (eq :ok o)) (setf state s))
    (multiple-value-bind (state2 outcome) (widen-surface state "A" '("x.lisp"))
      (is (rejected-p outcome))
      (is (eq :already-terminal (rejection-reason outcome)))
      (is (eq state state2)))))

(test test-widen-surface-rejects-malformed-surface
  (let ((state (initial-state (linear-dag))))
    (multiple-value-bind (state2 outcome) (widen-surface state "A" "not-a-list")
      (is (rejected-p outcome))
      (is (eq :invalid-surface (rejection-reason outcome)))
      (is (eq state state2)))
    (multiple-value-bind (state2 outcome) (widen-surface state "A" '("ok" 42))
      (is (rejected-p outcome))
      (is (eq :invalid-surface (rejection-reason outcome)))
      (is (eq state state2)))))

(test test-surface-monotonic-holds-through-widen-surface
  "Positive control: a trajectory built only from the safe WIDEN-SURFACE API
never violates INVARIANT 5."
  (let ((state (initial-state (linear-dag))))
    (multiple-value-bind (s o) (dispatch state "A") (is (eq :ok o)) (setf state s))
    (multiple-value-bind (s o) (widen-surface state "A" '("x.lisp"))
      (is (eq :ok o)) (setf state s))
    (multiple-value-bind (s o) (widen-surface state "A" '("y.lisp"))
      (is (eq :ok o)) (setf state s))
    (is-true (surface-monotonic-p (linear-dag) (model-state-events state)))))

(test test-surface-monotonic-rejects-shrinking-raw-event
  "A raw, directly-constructed event log (bypassing WIDEN-SURFACE's own
union-before-emit safety) can still shrink a FILE-SURFACE — exactly the
DAG-PRESERVED-P blind spot this invariant exists to close. Demonstrates the
invariant correctly returns NIL rather than passing vacuously."
  (let* ((dag (linear-dag))
         (events '((:dispatched "A") (:surface-widened "A" ("x.lisp" "y.lisp"))
                   (:surface-widened "A" ("x.lisp")))))
    (is-false (surface-monotonic-p dag events))))

(test test-surface-monotonic-rejects-malformed-raw-event
  "A raw event can also set a FILE-SURFACE to a non-list-of-strings value;
INVARIANT 5's well-formedness half catches this too."
  (let* ((dag (linear-dag))
         (events '((:dispatched "A") (:surface-widened "A" "not-a-list"))))
    (is-false (surface-monotonic-p dag events))))

;;; --- The conformance seam: replay reconstructs the live trajectory --------

(test test-replay-reconstructs-live-state
  (let ((state (initial-state (linear-dag))))
    (setf state (prove-node state "A"))
    (multiple-value-bind (s o) (dispatch state "B") (is (eq :ok o)) (setf state s))
    (multiple-value-bind (s o) (land state "B") (is (eq :ok o)) (setf state s))
    (multiple-value-bind (s o) (quarantine state "B") (is (eq :ok o)) (setf state s))
    (multiple-value-bind (s o) (discharge state "B" :fail) (is (eq :ok o)) (setf state s))
    (let ((reconstructed (replay (linear-dag) (model-state-events state))))
      (is (equalp state reconstructed)))))

;;; --- Crown-jewel invariants: check-it property tests ----------------------
;;;
;;; One shared generator produces random OP sequences over a fixed branching
;;; DAG (A -> B, A -> C, B & C -> D), deliberately including illegal ops
;;; (e.g. gate-checking a node that never landed) alongside legal ones: a
;;; total model must handle both without ever violating an invariant, so
;;; fuzzing illegal orderings is a stronger test than only generating
;;; already-valid walks.

(defun branching-dag ()
  "A -> B, A -> C, {B, C} -> D — enough branching to exercise multi-dependency
schedule correctness (invariant 4b), still small enough to read at a glance."
  (multiple-value-bind (dag status)
      (make-dag (list (make-dag-node "A" nil)
                       (make-dag-node "B" '("A"))
                       (make-dag-node "C" '("A"))
                       (make-dag-node "D" '("B" "C"))))
    (assert (eq status :ok))
    dag))

(defun %apply-op (state op)
  "Apply one generated OP to STATE, keeping only the resulting state — a
rejected op leaves STATE unchanged (REJECTED-P), which is exactly the
total-function behavior under fuzzing this property suite exists to check."
  (destructuring-bind (kind id &optional arg) op
    (values (ecase kind
              (:dispatch (dispatch state id))
              (:land (land state id))
              (:gate-check (gate-check state id arg))
              (:quarantine (quarantine state id))
              (:discharge (discharge state id arg))
              (:skip (librecode-model:skip state id))
              (:escalate (escalate state id))
              (:widen-surface (widen-surface state id arg))))))

(defun run-ops (dag ops)
  "Fold OPS through the model from DAG's initial state."
  (reduce #'%apply-op ops :initial-value (initial-state dag)))

(defparameter *ops-generator*
  (generator
   (list (or (map (lambda (id) (list :dispatch id))
                  (or (quote "A") (quote "B") (quote "C") (quote "D")))
             (map (lambda (id) (list :land id))
                  (or (quote "A") (quote "B") (quote "C") (quote "D")))
             (map (lambda (id result) (list :gate-check id result))
                  (or (quote "A") (quote "B") (quote "C") (quote "D"))
                  (or (quote :pass) (quote :fail) (quote :timeout)))
             (map (lambda (id) (list :quarantine id))
                  (or (quote "A") (quote "B") (quote "C") (quote "D")))
             (map (lambda (id result) (list :discharge id result))
                  (or (quote "A") (quote "B") (quote "C") (quote "D"))
                  (or (quote :pass) (quote :fail)))
             (map (lambda (id) (list :skip id))
                  (or (quote "A") (quote "B") (quote "C") (quote "D")))
             (map (lambda (id) (list :escalate id))
                  (or (quote "A") (quote "B") (quote "C") (quote "D"))))
         :max-length 40))
  "The ADVERSARIAL generator: all seven op kinds, including :skip/:escalate,
which are legal from any non-terminal status and so — an adversarial-audit
finding surfaced by TEST-PROPERTY-PROVEN-NODES-ACTUALLY-OCCUR below, not
assumed going in — dominate every run: at ~2 of 7 kinds x 4 ids, a node's
cumulative kill probability crosses 50% within its first ~10 steps, so it
almost always terminates skipped/escalated before completing even one
dispatch->land->gate-check chain. That makes this generator excellent for
invariants 1 and 4 (exercised by ANY dispatch/gate attempt, proven or not)
but nearly vacuous for invariants 2 and 3, which only bind on :proven nodes.
See *HAPPY-PATH-GENERATOR* below for the complementary deep coverage.")

(defparameter *happy-path-generator*
  (generator
   (list (or (map (lambda (id) (list :dispatch id))
                  (or (quote "A") (quote "B") (quote "C") (quote "D")))
             (map (lambda (id) (list :land id))
                  (or (quote "A") (quote "B") (quote "C") (quote "D")))
             (map (lambda (id result) (list :gate-check id result))
                  (or (quote "A") (quote "B") (quote "C") (quote "D"))
                  (or (quote :pass) (quote :fail) (quote :timeout)))
             (map (lambda (id) (list :quarantine id))
                  (or (quote "A") (quote "B") (quote "C") (quote "D")))
             (map (lambda (id result) (list :discharge id result))
                  (or (quote "A") (quote "B") (quote "C") (quote "D"))
                  (or (quote :pass) (quote :fail))))
         :max-length 800))
  "Deliberately excludes :skip/:escalate and runs much longer than
*OPS-GENERATOR*: still random and still exercises illegal orderings (a
gate-check before a land, a discharge before a quarantine, and so on) and
:rework loops (gate-check :fail/:timeout, discharge :fail), but without a
permanent-kill op, so nodes reliably reach :proven given enough steps —
exactly what invariants 2 and 3 need to be checked against something.")

(defparameter *ops-list-size* 80)
(defparameter *ops-num-trials* 300)
(defparameter *happy-path-list-size* 800)
(defparameter *happy-path-num-trials* 150)

(defun run-property (generator-obj list-size num-trials predicate)
  "Run PREDICATE (a function of (DAG EVENTS)) as a check-it property:
GENERATOR-OBJ produces an op sequence each trial, applied to a fresh
BRANCHING-DAG via RUN-OPS."
  (let ((*list-size* list-size) (*num-trials* num-trials))
    (check-it generator-obj
              (lambda (ops)
                (let* ((dag (branching-dag))
                       (events (model-state-events (run-ops dag ops))))
                  (funcall predicate dag events))))))

(test test-property-phase-monotonic
  "INVARIANT 1, fuzzed: no random op sequence ever lowers a node's phase."
  (is-true (run-property *ops-generator* *ops-list-size* *ops-num-trials*
                          #'phase-monotonic-p)))

(test test-property-no-pending-proven
  "INVARIANT 2, fuzzed: no random op sequence ever marks a pending deposit
proven — checked under both the broad adversarial generator and the
happy-path generator, since only the latter reaches :proven often (see
TEST-PROPERTY-PROVEN-NODES-ACTUALLY-OCCUR)."
  (is-true (run-property *ops-generator* *ops-list-size* *ops-num-trials*
                         #'no-pending-proven-p))
  (is-true (run-property *happy-path-generator* *happy-path-list-size* *happy-path-num-trials*
                         #'no-pending-proven-p)))

(test test-property-tamper-evident
  "INVARIANT 3, fuzzed: every :proven mark any random op sequence produces
traces to a logged, machine-derived pass event — same dual-generator
rationale as invariant 2."
  (is-true (run-property *ops-generator* *ops-list-size* *ops-num-trials*
                         #'tamper-evident-p))
  (is-true (run-property *happy-path-generator* *happy-path-list-size* *happy-path-num-trials*
                         #'tamper-evident-p)))

(test test-property-dag-soundness
  "INVARIANT 4, fuzzed: DAG structure is preserved and the schedule is
correct across every random op sequence."
  (is-true (run-property *ops-generator* *ops-list-size* *ops-num-trials*
                         (lambda (dag events)
                           (and (dag-preserved-p dag events)
                                (schedule-correct-p dag events))))))

(test test-property-proven-nodes-actually-occur
  "Sanity control: the adversarial generator (skip/escalate included) almost
never reaches :proven — expected, given the analysis in *OPS-GENERATOR*'s
docstring — while the happy-path generator does so often. If either figure
drifted (e.g. a future edit made skip/escalate rarer, or broke the
happy-path generator), invariants 2/3 above would silently go back to being
vacuously green, so this is checked directly rather than assumed."
  (flet ((proven-rate (generator-obj list-size trials)
           (let ((*list-size* list-size) (proven-runs 0))
             (dotimes (_ trials)
               (let* ((dag (branching-dag))
                      (ops (generate generator-obj))
                      (final (run-ops dag ops)))
                 (when (some (lambda (ns) (eq (node-state-status ns) :proven))
                             (model-state-node-states final))
                   (incf proven-runs))))
             (/ proven-runs trials))))
    (let ((adversarial-rate (proven-rate *ops-generator* *ops-list-size* *ops-num-trials*))
          (happy-path-rate (proven-rate *happy-path-generator* *happy-path-list-size*
                                         *happy-path-num-trials*)))
      (is (< adversarial-rate 1/10))
      (is (> happy-path-rate 1/2)))))

;;; --- INVARIANT 5, fuzzed: plan-surface monotonicity -----------------------
;;;
;;; A dedicated generator, deliberately separate from *OPS-GENERATOR* and
;;; *HAPPY-PATH-GENERATOR* above: those two are precision-calibrated against
;;; TEST-PROPERTY-PROVEN-NODES-ACTUALLY-OCCUR's exact proven-rate thresholds,
;;; and folding an eighth op kind into either would perturb those thresholds
;;; for no benefit — WIDEN-SURFACE never changes STATUS, so it has nothing to
;;; contribute to that sanity control. This generator instead mixes
;;; WIDEN-SURFACE with just enough of the other kinds to reach varied
;;; statuses (including terminal ones, to fuzz the :already-terminal
;;; rejection path) while staying decorrelated from the calibrated pair.

(defparameter *surface-generator*
  (generator
   (list (or (map (lambda (id) (list :dispatch id))
                  (or (quote "A") (quote "B") (quote "C") (quote "D")))
             (map (lambda (id) (list :land id))
                  (or (quote "A") (quote "B") (quote "C") (quote "D")))
             (map (lambda (id result) (list :gate-check id result))
                  (or (quote "A") (quote "B") (quote "C") (quote "D"))
                  (or (quote :pass) (quote :fail) (quote :timeout)))
             (map (lambda (id) (list :skip id))
                  (or (quote "A") (quote "B") (quote "C") (quote "D")))
             (map (lambda (id surface) (list :widen-surface id surface))
                  (or (quote "A") (quote "B") (quote "C") (quote "D"))
                  (list (or (quote "x") (quote "y") (quote "z")) :max-length 3)))
         :max-length 60))
  "Mixes WIDEN-SURFACE (with a small-alphabet, up-to-3-element generated
surface) alongside dispatch/land/gate-check/skip — enough to drive nodes
through non-terminal and terminal statuses so both INVARIANT 5's monotonic
and well-formed halves get exercised, without touching the two calibrated
adversarial generators above.")

(defparameter *surface-list-size* 60)
(defparameter *surface-num-trials* 300)

(test test-property-surface-monotonic
  "INVARIANT 5, fuzzed: no random op sequence including WIDEN-SURFACE ever
shrinks or malforms a node's FILE-SURFACE — the safe API's union-before-emit
construction (widen-surface's own precondition checks) holds up under
fuzzing, including illegal orderings (e.g. widening a :skipped node, which
WIDEN-SURFACE itself rejects and so leaves the trajectory untouched)."
  (is-true (run-property *surface-generator* *surface-list-size* *surface-num-trials*
                         #'surface-monotonic-p)))
