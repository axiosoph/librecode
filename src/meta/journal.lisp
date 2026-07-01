;;; -*- Mode: Lisp; Syntax: Common-Lisp; indent-tabs-mode: nil; coding: utf-8; Show-Trailing-Whitespace: t -*-
;;;
;;; journal.lisp — Metaharness execution journal tracking
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

(defun apply-journal-entry (dag entry)
  "Applies a single transition ENTRY to update the DAG state in place."
  (when (and (listp entry) (keywordp (first entry)))
    (destructuring-bind (event-type &rest args) entry
      (case event-type
        ((:node-dispatched :node-landed :node-accepted :node-rework :surface-widened)
         (let* ((node-id (first args))
                (node (find node-id (campaign-dag-nodes dag) :key #'campaign-node-id :test #'string=)))
           (unless node
             (error 'librecode-runner.conditions:protocol-invariant-violation
                    :invariant "journal-node-existence"
                    :message (format nil "Journal entry ~S refers to non-existent node ~S" entry node-id)))
           (case event-type
             (:node-dispatched
              (setf (campaign-node-status node) :dispatched))
             (:node-landed
              (setf (campaign-node-status node) :landed))
             (:node-accepted
              (setf (campaign-node-status node) :accepted))
             (:node-rework
              (let ((ibc (second args)))
                (setf (campaign-node-status node) :rework)
                (setf (campaign-node-ibc node) ibc)))
             (:surface-widened
              (let ((new-surface (second args)))
                (setf (campaign-node-file-surface node) new-surface))))))
        (:layer-advanced
         ;; No-op or diagnostic log as layers are not a mutable slot in campaign-dag
         nil))))
  dag)

(defun replay-journal (filepath &optional initial-dag)
  "Reads all S-expressions from FILEPATH, replays them sequentially, and returns the
reconstructed campaign-dag state. If a partial or malformed write is encountered at
the end of the file, it is skipped to protect against crash corruption."
  (let ((dag (or initial-dag (make-campaign-dag))))
    (with-open-file (stream filepath :direction :input :if-does-not-exist :error)
      (loop
        (let ((entry (handler-bind ((reader-error (lambda (c)
                                                   (declare (ignore c))
                                                   (return-from replay-journal dag)))
                                    (end-of-file (lambda (c)
                                                   (declare (ignore c))
                                                   (return-from replay-journal dag))))
                       (read stream nil :eof))))
          (when (eq entry :eof)
            (return))
          (setf dag (apply-journal-entry dag entry)))))
    dag))
