;;; -*- Mode: Lisp; Syntax: Common-Lisp; indent-tabs-mode: nil; coding: utf-8; Show-Trailing-Whitespace: t -*-
;;;
;;; audit.lisp — Thread-safe, append-only S-expression and JSONL audit trail logging
;;;

(in-package #:librecode-runner.audit)

(defvar *audit-mailbox* nil
  "The mailbox used to queue audit events.")

(defvar *audit-thread* nil
  "The background thread running the audit logger consumer.")

(defvar *lisp-stream* nil
  "Stream for audit.lisp-expr.")

(defvar *json-stream* nil
  "Stream for audit.jsonl.")

(defvar *audit-lock* (bt:make-lock "audit-lock")
  "Lock to serialize init and shutdown operations.")

(defun get-audit-paths ()
  "Determine the paths to the audit files, relative to *workspace-root*."
  (let ((root (or librecode-runner.event-store:*workspace-root*
                  *default-pathname-defaults*)))
    (values (uiop:merge-pathnames* #p".ledger/log/audit.lisp-expr" root)
            (uiop:merge-pathnames* #p".ledger/log/audit.jsonl" root))))

(defun key-to-string (key)
  (if (symbolp key)
      (string-downcase (symbol-name key))
      (format nil "~A" key)))

(defun coerce-to-json-compatible (val)
  "Recursively coerce structures to JSON-compatible types (hash-tables for objects, vectors/lists for arrays, downcased strings for symbols)."
  (cond
    ((null val) nil)
    ((symbolp val) (string-downcase (symbol-name val)))
    ((hash-table-p val)
     (let ((new-ht (make-hash-table :test 'equal)))
       (maphash (lambda (k v)
                  (setf (gethash (key-to-string k) new-ht)
                        (coerce-to-json-compatible v)))
                val)
       new-ht))
    ((librecode-runner.event-store:alist-p val)
     (let ((ht (make-hash-table :test 'equal)))
       (dolist (pair val)
         (setf (gethash (key-to-string (car pair)) ht)
               (coerce-to-json-compatible (cdr pair))))
       ht))
    ((librecode-runner.event-store:plist-p val)
     (let ((ht (make-hash-table :test 'equal)))
       (loop for (k v) on val by #'cddr
             do (setf (gethash (key-to-string k) ht)
                      (coerce-to-json-compatible v)))
       ht))
    ((listp val)
     (mapcar #'coerce-to-json-compatible val))
    ((vectorp val)
     (if (stringp val)
         val
         (map 'vector #'coerce-to-json-compatible val)))
    (t val)))

(defun write-event-to-streams (event)
  "Serialize and write event to both Lisp S-expression and JSONL streams with immediate flushing."
  (when *lisp-stream*
    (write event :stream *lisp-stream* :pretty nil)
    (terpri *lisp-stream*)
    (force-output *lisp-stream*))
  (when *json-stream*
    (let ((json-compatible (coerce-to-json-compatible event)))
      (write-line (com.inuoe.jzon:stringify json-compatible) *json-stream*)
      (force-output *json-stream*))))

(defun audit-logger-loop ()
  "The main consumer loop of the background audit logger thread."
  (loop
    (let ((msg (sb-concurrency:receive-message *audit-mailbox*)))
      (cond
        ((eq msg :shutdown)
         ;; Drain remaining events
         (loop until (sb-concurrency:mailbox-empty-p *audit-mailbox*)
               do (let ((remaining-msg (sb-concurrency:receive-message *audit-mailbox*)))
                    (unless (eq remaining-msg :shutdown)
                      (write-event-to-streams remaining-msg))))
         (return))
        (t
         (write-event-to-streams msg))))))

(defun init-audit-logger ()
  "Initialize and start the background audit logger thread and open the file streams."
  (bt:with-lock-held (*audit-lock*)
    (when (and *audit-thread* (bt:thread-alive-p *audit-thread*))
      (return-from init-audit-logger t))
    (let ((success nil)
          (lisp-s nil)
          (json-s nil))
      (unwind-protect
           (multiple-value-bind (lisp-path json-path) (get-audit-paths)
             (ensure-directories-exist lisp-path)
             (ensure-directories-exist json-path)
             (setf lisp-s (open lisp-path
                                :direction :output
                                :if-exists :append
                                :if-does-not-exist :create
                                :external-format :utf-8))
             (setf json-s (open json-path
                                :direction :output
                                :if-exists :append
                                :if-does-not-exist :create
                                :external-format :utf-8))
             (setf *lisp-stream* lisp-s
                   *json-stream* json-s)
             (setf *audit-mailbox* (sb-concurrency:make-mailbox :name "audit-logger-mailbox"))
             (setf *audit-thread*
                   (bt:make-thread
                    (lambda () (audit-logger-loop))
                    :name "audit-logger-thread"))
             (setf success t))
        ;; Cleanup on failure
        (unless success
          (when lisp-s
            (close lisp-s)
            (setf *lisp-stream* nil))
          (when json-s
            (close json-s)
            (setf *json-stream* nil))
          (setf *audit-mailbox* nil)
          (setf *audit-thread* nil))))))


(defun shutdown-audit-logger ()
  "Gracefully stop the background audit logger thread and close file streams."
  (bt:with-lock-held (*audit-lock*)
    (when *audit-thread*
      (when (bt:thread-alive-p *audit-thread*)
        (sb-concurrency:send-message *audit-mailbox* :shutdown)
        (bt:join-thread *audit-thread*))
      (setf *audit-thread* nil))
    (when *lisp-stream*
      (close *lisp-stream*)
      (setf *lisp-stream* nil))
    (when *json-stream*
      (close *json-stream*)
      (setf *json-stream* nil))
    (setf *audit-mailbox* nil)
    t))

(defun write-audit-event (event)
  "Queues an EVENT to be logged by the audit logger."
  (if *audit-mailbox*
      (progn
        (sb-concurrency:send-message *audit-mailbox* event)
        t)
      nil))

(defun start-audit-logger ()
  "For compatibility: starts the audit logger."
  (init-audit-logger))

(defun stop-audit-logger ()
  "For compatibility: stops the audit logger."
  (shutdown-audit-logger))
