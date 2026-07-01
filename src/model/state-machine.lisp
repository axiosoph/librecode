;;; -*- Mode: Lisp; Syntax: Common-Lisp; indent-tabs-mode: nil; coding: utf-8; Show-Trailing-Whitespace: t -*-
;;;
;;; state-machine.lisp — Node status, deposits, the event log, and transitions
;;;
;;; Vocabulary (docs/model.md has the full picture):
;;;   STATUS  the regressable plan-level lifecycle of a node: :queued ->
;;;           :dispatched -> :landed -> {:proven | :quarantined -> :proven |
;;;           :rework (-> :dispatched again) | :skipped | :escalated}.
;;;   PHASE   a per-node integer that only GATE-CHECK and DISCHARGE ever touch,
;;;           and only ever increment. DISPATCH/LAND/SKIP/ESCALATE — the
;;;           agent-driven events — never read or write it. This is what makes
;;;           phase monotonicity (invariant 1) and tamper-evidence (invariant
;;;           3) hold BY CONSTRUCTION: there is no parameter through which an
;;;           agent could supply, and no transition through which it could
;;;           lower, a phase value.
;;;   DEPOSIT the record of a landed node's gate check: a VALIDATION-STATE of
;;;           :pending | :proven | :failed, plus which GATE-MODE (:gated |
;;;           :degraded) produced it.
;;;
;;; Every public transition is total: (values new-state outcome), where
;;; OUTCOME is :ok or (:rejected reason) — illegal calls never signal, they
;;; leave STATE untouched (see REJECTED-P). TRANSITION-EVENT is the one
;;; exception: given a well-formed event referencing a node that does not
;;; exist, it signals — an event log that fails to resolve is a log-integrity
;;; violation, not a legitimate domain rejection (cf. the existing runtime's
;;; APPLY-JOURNAL-ENTRY in src/meta/journal.lisp, which takes the same view).
;;;

(in-package #:librecode-model)

(defstruct (deposit (:constructor make-deposit (validation-state gate-mode phase)))
  "A node's landed work, as gated. VALIDATION-STATE is :pending | :proven |
:failed. GATE-MODE records whether it was checked :gated (a checker was
present) or :degraded (quarantined, checker absent — decision 1). PHASE is
the phase value stamped when this deposit was created or last resolved."
  (validation-state nil :type (member :pending :proven :failed) :read-only t)
  (gate-mode nil :type (member :gated :degraded) :read-only t)
  (phase nil :type (integer 0) :read-only t))

(defstruct (node-state (:constructor make-node-state (id status phase deposit)))
  "A node's runtime state: its plan-level STATUS, its monotonic gate PHASE,
and its current DEPOSIT (or NIL before it has ever landed)."
  (id nil :type string :read-only t)
  (status nil :type keyword :read-only t)
  (phase nil :type (integer 0) :read-only t)
  (deposit nil :read-only t))

(defstruct (model-state (:constructor make-model-state (dag node-states events)))
  "The full reference-model state: the immutable DAG, the current NODE-STATES
(one per DAG node), and the append-only EVENTS log (oldest first). State is a
fold over EVENTS — see REPLAY — never a store consulted independently of it."
  (dag nil :read-only t)
  (node-states nil :type list :read-only t)
  (events nil :type list :read-only t))

(defun find-node-state (state id)
  "Return the NODE-STATE in STATE named ID, or NIL if none exists."
  (find id (model-state-node-states state) :key #'node-state-id :test #'string=))

(defun initial-state (dag)
  "The state of a freshly-constructed campaign over DAG: every node :queued,
phase 0, no deposit, an empty event log."
  (make-model-state dag
                     (mapcar (lambda (spec) (make-node-state (dag-node-id spec) :queued 0 nil))
                             (dag-node-specs dag))
                     nil))

(defun rejected-p (outcome)
  "True if OUTCOME (the second value of a transition) is a rejection."
  (and (consp outcome) (eq (car outcome) :rejected)))

(defun rejection-reason (outcome)
  "The reason keyword of a rejection OUTCOME, or NIL if it was :ok."
  (and (rejected-p outcome) (second outcome)))

(defun %replace-node-state (state new-node-state)
  "Return a new MODEL-STATE with NEW-NODE-STATE substituted for the node-state
sharing its id; every other node-state is unchanged. Never mutates STATE."
  (make-model-state (model-state-dag state)
                     (mapcar (lambda (ns)
                               (if (string= (node-state-id ns) (node-state-id new-node-state))
                                   new-node-state
                                   ns))
                             (model-state-node-states state))
                     (model-state-events state)))

(defun %append-event (state event)
  "Return a new MODEL-STATE with EVENT appended to the (oldest-first) log."
  (make-model-state (model-state-dag state)
                     (model-state-node-states state)
                     (append (model-state-events state) (list event))))

;;; --- TRANSITION-EVENT: the pure fold primitive; REPLAY's only mover -------

(defun transition-event (state event)
  "Apply one well-formed EVENT to STATE, returning the resulting MODEL-STATE.
This is the single source of truth for \"what does event E do to state S\" —
both the live transitions below and REPLAY route through it, so a recorded
runtime trace replayed here reconstructs the identical trajectory (the
conformance seam). Signals an ERROR if EVENT names a node absent from STATE's
DAG: that is a malformed log, not a legal-domain rejection."
  (destructuring-bind (kind id &optional arg) event
    (let ((ns (find-node-state state id)))
      (unless ns
        (error "Malformed event log: ~S references non-existent node ~S." event id))
      (%append-event
       (%replace-node-state
        state
        (ecase kind
          (:dispatched
           (make-node-state id :dispatched (node-state-phase ns) (node-state-deposit ns)))
          (:landed
           (make-node-state id :landed (node-state-phase ns)
                             (make-deposit :pending :gated (node-state-phase ns))))
          (:gate-checked
           (let ((phase (1+ (node-state-phase ns))))
             (if (eq arg :pass)
                 (make-node-state id :proven phase (make-deposit :proven :gated phase))
                 (make-node-state id :rework phase (make-deposit :failed :gated phase)))))
          (:quarantined
           (let ((phase (1+ (node-state-phase ns))))
             (make-node-state id :quarantined phase (make-deposit :pending :degraded phase))))
          (:discharged
           (let ((phase (1+ (node-state-phase ns)))
                 (mode (deposit-gate-mode (node-state-deposit ns))))
             (if (eq arg :pass)
                 (make-node-state id :proven phase (make-deposit :proven mode phase))
                 (make-node-state id :rework phase (make-deposit :failed mode phase)))))
          (:skipped
           (make-node-state id :skipped (node-state-phase ns) (node-state-deposit ns)))
          (:escalated
           (make-node-state id :escalated (node-state-phase ns) (node-state-deposit ns)))))
       event))))

(defun replay (dag events)
  "Reconstruct a MODEL-STATE from EVENTS alone, by folding TRANSITION-EVENT
over the empty state for DAG — \"state is a fold over the log\": the
conformance seam a recorded runtime trace can be checked against."
  (reduce #'transition-event events :initial-value (initial-state dag)))

;;; --- Public transitions: validate, then delegate to TRANSITION-EVENT ------

(defmacro define-transition (name (state-var node-id-var &rest extra-args) &body body)
  "Define a public transition NAME(STATE-VAR NODE-ID-VAR &rest EXTRA-ARGS)
returning (values new-state outcome). BODY binds NS to the looked-up
node-state (already checked non-nil) and must return either
(VALUES :REJECTED reason) or an EVENT s-expr to apply via TRANSITION-EVENT."
  `(defun ,name (,state-var ,node-id-var ,@extra-args)
     (let ((ns (find-node-state ,state-var ,node-id-var)))
       (if (null ns)
           (values ,state-var (list :rejected :unknown-node))
           (multiple-value-bind (result reason) (progn ,@body)
             (if (eq result :rejected)
                 (values ,state-var (list :rejected reason))
                 (values (transition-event ,state-var result) :ok)))))))

(define-transition dispatch (state id)
  "Move ID from :queued or :rework to :dispatched — legal only once every
dependency is :proven (invariant 4: schedule correctness)."
  (cond
    ((not (member (node-state-status ns) '(:queued :rework)))
     (values :rejected :wrong-status))
    ((notevery (lambda (dep) (eq (node-state-status (find-node-state state dep)) :proven))
               (dag-node-dependencies (find-dag-node (model-state-dag state) id)))
     (values :rejected :dependencies-not-proven))
    (t (list :dispatched id))))

(define-transition land (state id)
  "Move a :dispatched ID to :landed, creating a :pending deposit."
  (if (eq (node-state-status ns) :dispatched)
      (list :landed id)
      (values :rejected :wrong-status)))

(define-transition gate-check (state id result)
  "Gated-mode gate check on a :landed ID. RESULT is :pass, :fail, or
:timeout — decision 3: a bounded-timeout contract is a fail, never a pass,
never a third state, so :timeout is folded into the :fail path by
TRANSITION-EVENT."
  (cond
    ((not (eq (node-state-status ns) :landed))
     (values :rejected :wrong-status))
    ((not (member result '(:pass :fail :timeout)))
     (values :rejected :invalid-result))
    (t (list :gate-checked id result))))

(define-transition quarantine (state id)
  "Degraded-mode gate check on a :landed ID: the checker is absent, so the
deposit lands durably but quarantined :pending (decision 1) rather than
resolved either way."
  (if (eq (node-state-status ns) :landed)
      (list :quarantined id)
      (values :rejected :wrong-status)))

(define-transition discharge (state id result)
  "Resolve a :quarantined ID once the checker returns. RESULT is :pass or
:fail. A failed discharge reverts to :rework, losing nothing proven — it was
never :proven in the first place (invariant 2)."
  (cond
    ((not (eq (node-state-status ns) :quarantined))
     (values :rejected :wrong-status))
    ((not (member result '(:pass :fail)))
     (values :rejected :invalid-result))
    (t (list :discharged id result))))

(define-transition skip (state id)
  "Abandon ID (terminal, non-blocking for siblings — but per invariant 4 a
node depending on a :skipped id still cannot DISPATCH, since its dependency
was never :proven). Illegal once terminal (:proven/:skipped/:escalated)."
  (if (member (node-state-status ns) '(:proven :skipped :escalated))
      (values :rejected :already-terminal)
      (list :skipped id)))

(define-transition escalate (state id)
  "Surface ID to the human (terminal). Illegal once terminal."
  (if (member (node-state-status ns) '(:proven :skipped :escalated))
      (values :rejected :already-terminal)
      (list :escalated id)))
