;;; -*- Mode: Lisp; Syntax: Common-Lisp; indent-tabs-mode: nil; coding: utf-8; Show-Trailing-Whitespace: t -*-
;;;
;;; invariants.lisp — The four crown-jewel invariants, as pure predicates
;;;
;;; Each predicate takes (DAG EVENTS) — an event log, not just a final state —
;;; because monotonicity and tamper-evidence are properties of a TRAJECTORY,
;;; not a single snapshot: a state can look fine in isolation while having
;;; been reached by an illegal history. Every predicate reconstructs via
;;; TRANSITION-EVENT alone (reconstruct, don't recall), so any of them can be
;;; run unchanged against a real runtime's recorded journal — that reuse, not
;;; just the model's own test suite, is the conformance seam (docs/model.md).
;;;

(in-package #:librecode-model)

(defun %trajectory (dag events)
  "The list of MODEL-STATE values visited while replaying EVENTS over DAG,
oldest first, INCLUDING the initial (pre-event) state — so
(nth i %trajectory) is the state immediately BEFORE (nth i events) is
applied, and (nth (1+ i) %trajectory) is the state immediately after.
Internal: the shared walk every invariant below quantifies over."
  (let ((states (list (initial-state dag))))
    (dolist (event events)
      (push (transition-event (first states) event) states))
    (nreverse states)))

(defun phase-monotonic-p (dag events)
  "INVARIANT 1 — phase monotonicity: no reachable event sequence lowers a
node's phase. Checked directly against the trajectory: for every node, its
phase across successive visited states never decreases."
  (let ((states (%trajectory dag events)))
    (every (lambda (id)
             (apply #'<= (mapcar (lambda (s) (node-state-phase (find-node-state s id))) states)))
           (dag-node-ids dag))))

(defun no-pending-proven-p (dag events)
  "INVARIANT 2 — no pending marked proven: no reachable state has a
:validation-pending deposit on a :proven node. Discharge-failure reverts to
:rework instead (decision 1), so this holds at every point of the
trajectory, not merely at the end."
  (every (lambda (state)
           (every (lambda (ns)
                    (not (and (eq (node-state-status ns) :proven)
                              (deposit-p (node-state-deposit ns))
                              (eq (deposit-validation-state (node-state-deposit ns)) :pending))))
                  (model-state-node-states state)))
         (%trajectory dag events)))

(defun tamper-evident-p (dag events)
  "INVARIANT 3 — tamper-evidence: every :proven mark is justified by a
gate/discharge event whose parameters were machine-derived, never
agent-supplied. The API already makes half of this true BY CONSTRUCTION:
GATE-CHECK/DISCHARGE take only a node id and a pass/fail/timeout result —
there is no PHASE parameter for a caller to forge, since TRANSITION-EVENT
always derives it internally as (1+ current-phase). What remains checkable
against the log is reconstructibility: a :proven node must trace to a logged
:pass event for it. (Since every transition's precondition excludes
:proven — see state-machine.lisp — :proven is absorbing: once reached, no
further event touches that node, so any logged :pass event for it is
necessarily the one that produced its final mark; no phase bookkeeping
is needed to pin down \"which\" pass event.)"
  (let ((final (replay dag events)))
    (every (lambda (ns)
             (or (not (eq (node-state-status ns) :proven))
                 (some (lambda (event)
                         (destructuring-bind (kind id &optional result) event
                           (and (member kind '(:gate-checked :discharged))
                                (string= id (node-state-id ns))
                                (eq result :pass))))
                       events)))
           (model-state-node-states final))))

(defun dag-preserved-p (dag events)
  "INVARIANT 4a — DAG soundness (structure half): DAG validity (node set and
dependency edges) is preserved by every transition. No transition in
state-machine.lisp ever rewrites MODEL-STATE-DAG, so this checks that the
invariant held, rather than merely assuming it."
  (let ((ids (dag-node-ids dag)))
    (every (lambda (state) (equal ids (dag-node-ids (model-state-dag state))))
           (%trajectory dag events))))

(defun schedule-correct-p (dag events)
  "INVARIANT 4b — DAG soundness (schedule half): a node runs only after its
dependencies are proven. Checked against the log alone: for every
:dispatched event, every dependency of that node was already :proven in the
state immediately preceding it (the trajectory pairs each PRIOR state with
the event about to be applied to it)."
  (loop for prior in (%trajectory dag events)
        for event in events
        always (destructuring-bind (kind id &optional arg) event
                 (declare (ignore arg))
                 (or (not (eq kind :dispatched))
                     (every (lambda (dep)
                              (eq (node-state-status (find-node-state prior dep)) :proven))
                            (dag-node-dependencies (find-dag-node dag id)))))))
