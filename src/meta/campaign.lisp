;;; -*- Mode: Lisp; Syntax: Common-Lisp; indent-tabs-mode: nil; coding: utf-8; Show-Trailing-Whitespace: t -*-
;;;
;;; campaign.lisp — Campaign scheduler and DAG execution
;;;

(in-package #:librecode-meta.campaign)

;;; ============================================================================
;;; campaign-node and campaign-dag structs
;;; ============================================================================

(defstruct campaign-node
  "Represents an execution unit within a campaign DAG."
  (id nil :type (or null string))
  (goal nil :type (or null string))
  (file-surface nil :type list)        ; Paths (files or directories) this node is authorized to touch
  (dependencies nil :type list)        ; List of parent node IDs
  (sequential-p nil :type boolean)     ; Must run sequentially, cannot be parallelized
  (status :pending :type keyword)      ; :pending, :dispatched, :landed, :accepted, :rework
  (harness-type nil :type symbol)      ; Class name of harness (e.g., 'harness-opencode)
  (harness-instance nil)               ; Reference to the active CLOS harness-instance
  (ibc nil :type (or null string)))    ; Initial Boundary Condition text (instructions/goals)

(defstruct (campaign-dag
            (:constructor %make-campaign-dag))
  "Represents the Campaign DAG task graph."
  (nodes nil :type list)               ; List of campaign-nodes
  (layers nil :type vector)            ; Array of layers derived via Kahn's algorithm
  (shared-branch nil :type string))    ; Git integration branch for the campaign

(defun make-campaign-dag (&rest args &key nodes layers shared-branch)
  "Constructor for campaign-dag. Computes Kahn layers if not explicitly provided."
  (declare (ignore shared-branch))
  (let ((computed-layers (or layers
                             (and nodes (compute-kahn-layers nodes))
                             (make-array 0))))
    (apply #'%make-campaign-dag :layers computed-layers args)))

;;; ============================================================================
;;; Kahn's Algorithm Layering Scheduler
;;; ============================================================================

(defun compute-kahn-layers (nodes)
  "Derives a vector of topological layers from NODES list using Kahn's algorithm.
Signals a protocol-invariant-violation error if a dependency cycle is detected
or if any dependency is unresolved."
  (let* ((node-ids (mapcar #'campaign-node-id nodes))
         (in-degrees (make-hash-table :test 'equal))
         (adj (make-hash-table :test 'equal))
         (layers (make-array 0 :adjustable t :fill-pointer 0))
         (processed-count 0))
    ;; Validate that all dependency IDs are present in nodes
    (dolist (n nodes)
      (let ((id (campaign-node-id n))
            (deps (campaign-node-dependencies n)))
        (dolist (dep deps)
          (unless (member dep node-ids :test #'string=)
            (error 'librecode-runner.conditions:protocol-invariant-violation
                   :invariant "dependency-resolution"
                   :message (format nil "Node ~S depends on unresolved node ~S" id dep))))))

    ;; Initialize in-degrees and adjacency lists
    (dolist (n nodes)
      (let ((id (campaign-node-id n))
            (deps (campaign-node-dependencies n)))
        (setf (gethash id in-degrees) 0)
        (dolist (dep deps)
          (when (member dep node-ids :test #'string=)
            (incf (gethash id in-degrees))
            (push id (gethash dep adj))))))

    ;; Kahn's algorithm layering loop
    (loop
      (let ((zero-in-degree-layer nil))
        ;; Find all nodes with 0 in-degree in the remaining graph
        (maphash (lambda (id deg)
                   (when (= deg 0)
                     (push id zero-in-degree-layer)))
                 in-degrees)
        ;; Sort the layer deterministically by ID using string<
        (setf zero-in-degree-layer (sort zero-in-degree-layer #'string<))
        ;; If no nodes have 0 in-degree but we haven't processed all nodes, there is a cycle!
        (when (null zero-in-degree-layer)
          (if (< processed-count (length nodes))
              (error 'librecode-runner.conditions:protocol-invariant-violation
                     :invariant "cyclic-dependency"
                     :message "Cycle detected in campaign DAG. Cannot compute Kahn layers.")
              (return)))
        ;; Remove zero-in-degree nodes from our degrees tracker so they aren't selected again
        (dolist (id zero-in-degree-layer)
          (remhash id in-degrees))
        ;; Add layer to layers vector
        (vector-push-extend zero-in-degree-layer layers)
        (incf processed-count (length zero-in-degree-layer))
        ;; Update dependencies (decrement child in-degrees)
        (dolist (parent zero-in-degree-layer)
          (dolist (child (gethash parent adj))
            (when (gethash child in-degrees)
              (decf (gethash child in-degrees)))))))
    ;; Return the layers as a simple vector
    (coerce layers 'simple-vector)))

;;; ============================================================================
;;; Original campaign stubs to avoid breaking downstreams
;;; ============================================================================

(defclass campaign ()
  ())

(defun campaign-dag (campaign)
  (declare (ignore campaign))
  nil)

(defun run-campaign (campaign)
  (declare (ignore campaign))
  nil)
