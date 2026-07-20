;;; -*- Mode: Lisp; Syntax: Common-Lisp; indent-tabs-mode: nil; coding: utf-8; Show-Trailing-Whitespace: t -*-
;;;
;;; journal.lisp — Metaharness execution journal tracking
;;;
;;; Reconciles the journal's event vocabulary against librecode-model's
;;; calculus (docs/model.md, "the conformance seam"). Four of the journal's
;;; kinds are conformant 1:1 and route through TRANSITION-EVENT/REPLAY:
;;; :node-dispatched, :node-landed, :node-skipped, :surface-widened.
;;; :node-accepted and :node-rework remain journal-only bookkeeping,
;;; deliberately UNROUTED — see
;;; .scratch/campaign-6-one-calculus/gate-harness-protocol-proposal-2026-07-05.md
;;; (Ruling D): campaign.lisp's only live write site for :node-accepted fires
;;; whenever a harness merely does not crash (no real gate ever runs), and its
;;; only live write site for :node-rework fires *before* a node ever lands
;;; (inside the pre-landing harness-crash handler) — there is no
;;; :dispatched -> :rework edge in the calculus to receive it, and routing
;;; either would either manufacture unearned proof or require a model change,
;;; both out of this node's scope. Wiring a real gate is workstream J's job.
;;; :layer-advanced is cut entirely: no emission site exists, and it was
;;; already a no-op here.
;;;

(in-package #:librecode-meta.campaign)

(defun write-journal-entry (stream entry)
  "Writes a journal ENTRY (an S-expression) to STREAM, followed by a newline,
and immediately forces output to ensure crash-safety."
  (let ((*print-readably* t)
        (*print-circle* t))
    (prin1 entry stream)
    (terpri stream)
    (force-output stream)))

(defun %model-dag-from-campaign-dag (dag)
  "Construct a librecode-model:dag mirroring DAG's node ids/dependencies, so
the journal's conformant events can be folded through the calculus. DAG's own
constructor (COMPUTE-KAHN-LAYERS) already validated referential integrity and
acyclicity, so MAKE-DAG is expected to succeed; a rejection here means the two
DAG representations have drifted out of sync, which is a log-integrity
violation, not a legal-domain rejection."
  (multiple-value-bind (model-dag outcome)
      (librecode-model:make-dag
       (mapcar (lambda (n)
                 (librecode-model:make-dag-node (campaign-node-id n) (campaign-node-dependencies n)))
               (campaign-dag-nodes dag)))
    (unless (eq outcome :ok)
      (error 'librecode-runner.conditions:protocol-invariant-violation
             :invariant "journal-model-dag-construction"
             :message (format nil "Cannot construct model dag for journal replay: ~S" outcome)))
    model-dag))

(defun %find-journaled-node (dag entry node-id)
  "Return the campaign-node named NODE-ID in DAG, or signal a
protocol-invariant-violation citing ENTRY if none exists — an event log that
fails to resolve is a log-integrity violation (cf. librecode-model's
TRANSITION-EVENT, which takes the same view of its own event log)."
  (or (find node-id (campaign-dag-nodes dag) :key #'campaign-node-id :test #'string=)
      (error 'librecode-runner.conditions:protocol-invariant-violation
             :invariant "journal-node-existence"
             :message (format nil "Journal entry ~S refers to non-existent node ~S" entry node-id))))

(defun apply-journal-entry (dag model-state entry)
  "Apply a single journal ENTRY, mutating the matching campaign-node in DAG in
place and returning the resulting librecode-model MODEL-STATE. The
calculus-conformant kinds (:node-dispatched/:node-landed/:node-skipped/
:surface-widened) route through librecode-model:transition-event, and the
model's resulting status/phase/deposit/file-surface for that node are mirrored
onto the campaign-node. :node-accepted/:node-rework are journal-only
bookkeeping (see file header) and mutate the campaign-node directly without
consulting the model. Unrecognized entries, including the retired
:layer-advanced, are silently ignored."
  (when (and (listp entry) (keywordp (first entry)))
    (destructuring-bind (event-type &rest args) entry
      (case event-type
        ((:node-dispatched :node-landed :node-skipped :surface-widened)
         (let* ((node-id (first args))
                (node (%find-journaled-node dag entry node-id))
                (calculus-event (ecase event-type
                                  (:node-dispatched (list :dispatched node-id))
                                  (:node-landed (list :landed node-id))
                                  (:node-skipped (list :skipped node-id))
                                  (:surface-widened (list :surface-widened node-id (second args)))))
                (new-model-state (librecode-model:transition-event model-state calculus-event))
                (ns (librecode-model:find-node-state new-model-state node-id)))
           (setf (campaign-node-status node) (librecode-model:node-state-status ns))
           (setf (campaign-node-phase node) (librecode-model:node-state-phase ns))
           (setf (campaign-node-deposit node) (librecode-model:node-state-deposit ns))
           (setf (campaign-node-file-surface node) (librecode-model:node-state-file-surface ns))
           (setf model-state new-model-state)))
        (:node-accepted
         (let ((node (%find-journaled-node dag entry (first args))))
           (setf (campaign-node-status node) :accepted)))
        (:node-rework
         (let ((node (%find-journaled-node dag entry (first args)))
               (diagnostic (second args)))
           (setf (campaign-node-status node) :rework)
           (setf (campaign-node-rework-diagnostic node) diagnostic)))
        (t
         ;; Retired kinds (:layer-advanced) and anything else unrecognized:
         ;; no reader needed (a4).
         nil))))
  model-state)

(defun replay-journal (filepath &optional initial-dag)
  "Reads all S-expressions from FILEPATH, replays them sequentially through
APPLY-JOURNAL-ENTRY, and returns (values dag last-valid-pos model-state): the
reconstructed campaign-dag state (mutated and returned as the SAME object
identity as INITIAL-DAG, so topology-only fields — harness-instance,
dependencies, sequential-p, goal, harness-type — are never touched and
survive unchanged), the last known valid file position (useful for
truncation), and the librecode-model MODEL-STATE the conformant event subset
folded to."
  (let* ((dag (or initial-dag (make-campaign-dag)))
         (model-dag (%model-dag-from-campaign-dag dag))
         (model-state (librecode-model:initial-state model-dag))
         (last-valid-pos 0))
    (with-open-file (stream filepath :direction :input :if-does-not-exist :error)
      (loop
        (let ((entry (handler-bind ((reader-error (lambda (c)
                                                   (declare (ignore c))
                                                   (return-from replay-journal (values dag last-valid-pos model-state))))
                                    (end-of-file (lambda (c)
                                                   (declare (ignore c))
                                                   (return-from replay-journal (values dag last-valid-pos model-state)))))
                       (read stream nil :eof))))
          (when (eq entry :eof)
            (return))
          (setf model-state (apply-journal-entry dag model-state entry))
          (setf last-valid-pos (file-position stream)))))
    (values dag last-valid-pos model-state)))
