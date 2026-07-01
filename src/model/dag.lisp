;;; -*- Mode: Lisp; Syntax: Common-Lisp; indent-tabs-mode: nil; coding: utf-8; Show-Trailing-Whitespace: t -*-
;;;
;;; dag.lisp — Work DAG structure, validity, and Kahn layering
;;;
;;; A DAG is a proof-carrying value: the only way to build one is MAKE-DAG,
;;; which validates id-uniqueness, referential integrity, and acyclicity before
;;; ever returning a DAG instance. Every other function in this system that
;;; receives a DAG may assume it is valid without re-checking — invariant 4
;;; ("DAG validity is preserved by every transition") holds because no
;;; transition in state-machine.lisp ever constructs a new DAG; they only carry
;;; the one MAKE-DAG produced.
;;;

(in-package #:librecode-model)

(defstruct (dag-node (:constructor make-dag-node (id dependencies)))
  "A single node's structural position in the work DAG: its identity and the
ids of the nodes it depends on. Immutable — the DAG's edges never change
after construction; only per-node runtime status (state-machine.lisp) does."
  (id nil :type string :read-only t)
  (dependencies nil :type list :read-only t))

(defstruct (dag (:constructor %make-dag (node-specs)))
  "A validated work DAG: NODE-SPECS is a list of DAG-NODE, acyclic, with
unique ids and no dangling dependency references. Construct only via MAKE-DAG."
  (node-specs nil :type list :read-only t))

(defun find-dag-node (dag id)
  "Return the DAG-NODE in DAG named ID, or NIL if none exists."
  (find id (dag-node-specs dag) :key #'dag-node-id :test #'string=))

(defun dag-node-ids (dag)
  "Return the list of node ids in DAG, in construction order."
  (mapcar #'dag-node-id (dag-node-specs dag)))

(defun %duplicate-id (node-specs)
  "Return the first id appearing more than once in NODE-SPECS, or NIL."
  (let ((seen nil))
    (dolist (spec node-specs)
      (let ((id (dag-node-id spec)))
        (when (member id seen :test #'string=)
          (return-from %duplicate-id id))
        (push id seen)))
    nil))

(defun %dangling-dependency (node-specs)
  "Return (values node-id dangling-dep-id) for the first dependency reference
that names no node in NODE-SPECS, or NIL if every reference resolves."
  (let ((ids (mapcar #'dag-node-id node-specs)))
    (dolist (spec node-specs)
      (dolist (dep (dag-node-dependencies spec))
        (unless (member dep ids :test #'string=)
          (return-from %dangling-dependency (values (dag-node-id spec) dep)))))
    nil))

(defun %kahn-layers (node-specs)
  "Kahn's algorithm over NODE-SPECS. Returns (values layers t) — LAYERS a list
of lists of ids, each layer alphabetically sorted for determinism — if every
node is reachable (acyclic), or (values nil nil) if a cycle leaves nodes
unprocessed."
  (let* ((remaining (mapcar #'dag-node-id node-specs))
         (satisfied nil)
         (layers nil))
    (loop
      (when (null remaining)
        (return (values (nreverse layers) t)))
      (let ((ready (sort (remove-if-not
                           (lambda (id)
                             (every (lambda (dep) (member dep satisfied :test #'string=))
                                    (dag-node-dependencies (find id node-specs :key #'dag-node-id :test #'string=))))
                           remaining)
                          #'string<)))
        (when (null ready)
          (return (values nil nil)))
        (push ready layers)
        (setf satisfied (append ready satisfied))
        (setf remaining (set-difference remaining ready :test #'string=))))))

(defun make-dag (node-specs)
  "Validate NODE-SPECS (a list of DAG-NODE) and construct a DAG. Total:
returns (values dag :ok) on success, or (values nil rejection) where
REJECTION is one of (:duplicate-id id), (:dangling-dependency node-id dep-id),
or (:cycle) — never signals on a structurally-invalid but well-typed input."
  (let ((dup (%duplicate-id node-specs)))
    (when dup
      (return-from make-dag (values nil (list :duplicate-id dup)))))
  (multiple-value-bind (node-id dep-id) (%dangling-dependency node-specs)
    (when node-id
      (return-from make-dag (values nil (list :dangling-dependency node-id dep-id)))))
  (multiple-value-bind (layers ok-p) (%kahn-layers node-specs)
    (declare (ignore layers))
    (unless ok-p
      (return-from make-dag (values nil (list :cycle)))))
  (values (%make-dag node-specs) :ok))

(defun dag-layers (dag)
  "Return DAG's Kahn layer schedule: a list of lists of node ids, each layer a
conflict-free parallel set, alphabetically sorted within the layer for
determinism. A derived property, not stored state — DAG's validity (checked
once, at MAKE-DAG) guarantees this always succeeds."
  (multiple-value-bind (layers ok-p) (%kahn-layers (dag-node-specs dag))
    (assert ok-p (dag) "Invariant violated: a constructed DAG must be acyclic.")
    layers))
