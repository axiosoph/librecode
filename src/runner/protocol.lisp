;;; -*- Mode: Lisp; Syntax: Common-Lisp; indent-tabs-mode: nil; coding: utf-8; Show-Trailing-Whitespace: t -*-
;;;
;;; protocol.lisp — Run coordinator with wake coalescing, subprocess tracking, and mailboxes
;;;

(in-package #:librecode-runner.protocol)

(defstruct coordinator-entry
  (id nil :type string)
  (lock (bt:make-lock) :read-only t)
  (cv (bt:make-condition-variable) :read-only t)
  (pending-wake nil :type boolean)
  (stopping nil :type boolean)
  (waiters-count 0 :type integer) ; Reference counter to prevent idle deletion races
  (active-thread nil)
  (mailbox nil)
  (active-worker-threads nil)
  (active-worker-mailboxes nil))

(defvar *coordinator-lock* (bt:make-lock "global-coordinator-lock"))
(defvar *coordinator-entries* (make-hash-table :test 'equal))

(defvar *session-stopping* nil
  "Dynamic variable indicating whether the current execution turn should stop.")

(defvar *session-mailbox* nil
  "Dynamic variable for the active session's mailbox.")

(defun register-worker-mailbox (session-id mbox)
  "Register an active worker mailbox."
  (bt:with-lock-held (*coordinator-lock*)
    (let ((entry (gethash session-id *coordinator-entries*)))
      (when entry
        (bt:with-lock-held ((coordinator-entry-lock entry))
          (push mbox (coordinator-entry-active-worker-mailboxes entry)))))))

(defun unregister-worker-mailbox (session-id mbox)
  "Unregister an active worker mailbox."
  (bt:with-lock-held (*coordinator-lock*)
    (let ((entry (gethash session-id *coordinator-entries*)))
      (when entry
        (bt:with-lock-held ((coordinator-entry-lock entry))
          (setf (coordinator-entry-active-worker-mailboxes entry)
                (delete mbox (coordinator-entry-active-worker-mailboxes entry))))))))

(defun register-worker-thread (session-id thread)
  "Register an active worker thread."
  (bt:with-lock-held (*coordinator-lock*)
    (let ((entry (gethash session-id *coordinator-entries*)))
      (when entry
        (bt:with-lock-held ((coordinator-entry-lock entry))
          (push thread (coordinator-entry-active-worker-threads entry)))))))

(defun unregister-worker-thread (session-id thread)
  "Unregister an active worker thread."
  (bt:with-lock-held (*coordinator-lock*)
    (let ((entry (gethash session-id *coordinator-entries*)))
      (when entry
        (bt:with-lock-held ((coordinator-entry-lock entry))
          (setf (coordinator-entry-active-worker-threads entry)
                (delete thread (coordinator-entry-active-worker-threads entry))))))))

(defun flush-mailbox (mbox)
  "Drain and discard all messages currently queued in MBOX."
  (when mbox
    (loop
      (multiple-value-bind (msg val) (sb-concurrency:receive-message-no-hang mbox)
        (declare (ignore msg))
        (unless val (return))))))

(defun session-stopping-p (&optional session-id)
  "Check if the current session has been requested to stop."
  (declare (special librecode-runner.agent:*current-session-id*))
  (let ((sid (or session-id
                 (and (boundp 'librecode-runner.agent:*current-session-id*)
                      librecode-runner.agent:*current-session-id*))))
    (or *session-stopping*
        (and sid
             (bt:with-lock-held (*coordinator-lock*)
               (let ((entry (gethash sid *coordinator-entries*)))
                 (and entry (coordinator-entry-stopping entry))))))))

(defun get-or-create-entry (session-id)
  "Thread-safely retrieve or create the coordinator entry for SESSION-ID, incrementing waiters-count."
  (bt:with-lock-held (*coordinator-lock*)
    (let ((entry (gethash session-id *coordinator-entries*)))
      (unless entry
        (setf entry (make-coordinator-entry :id session-id))
        (setf (gethash session-id *coordinator-entries*) entry))
      (incf (coordinator-entry-waiters-count entry))
      entry)))

(defun release-entry (session-id)
  "Thread-safely decrement waiters-count and remove the coordinator entry if no longer needed."
  (bt:with-lock-held (*coordinator-lock*)
    (let ((entry (gethash session-id *coordinator-entries*)))
      (when entry
        (decf (coordinator-entry-waiters-count entry))
        (when (and (<= (coordinator-entry-waiters-count entry) 0)
                   (null (coordinator-entry-active-thread entry)))
          (remhash session-id *coordinator-entries*))))))

(defun run-coordinator (session-id function)
  "Run the session coordinator executing FUNCTION. Enforces serialized execution.
Blocks if another thread is already draining this session."
  (let ((entry (get-or-create-entry session-id))
        (mbox (make-mailbox :name (format nil "session-mbox-~A" session-id))))
    (unwind-protect
         (progn
           ;; 1. Wait for any active drain thread to finish (unless we are the spawned thread, indicated by :spawning)
           (bt:with-lock-held (*coordinator-lock*)
             (loop while (and (coordinator-entry-active-thread entry)
                              (not (eq (coordinator-entry-active-thread entry) :spawning)))
                   do (bt:condition-wait (coordinator-entry-cv entry) *coordinator-lock*))
             ;; Start execution: clear flags and register current thread/mailbox
             (setf (coordinator-entry-stopping entry) nil)
             (setf (coordinator-entry-active-thread entry) (bt:current-thread))
             (setf (coordinator-entry-mailbox entry) mbox))

           ;; 2. Run the execution turn loop with dynamic variables for coordinator state tracking
           (let ((*session-stopping* nil)
                 (*session-mailbox* mbox)
                 (librecode-runner.agent:*current-session-id* session-id))
             (declare (special librecode-runner.agent:*current-session-id*))
             (unwind-protect
                  (loop
                    (when (session-stopping-p session-id)
                      (return))
                    (funcall function)
                    (when (session-stopping-p session-id)
                      (return))
                    ;; Check and consume pending wake for wake coalescing
                    (bt:with-lock-held (*coordinator-lock*)
                      (if (coordinator-entry-pending-wake entry)
                          (setf (coordinator-entry-pending-wake entry) nil)
                          (return))))
               ;; Cleanup block for threads and mailboxes upon abort, interrupt, or exit
               (bt:with-lock-held ((coordinator-entry-lock entry))
                 (dolist (m (coordinator-entry-active-worker-mailboxes entry))
                   (ignore-errors (sb-concurrency:send-message m '(:abort))))
                 (setf (coordinator-entry-active-worker-mailboxes entry) nil)
                 (dolist (thr (coordinator-entry-active-worker-threads entry))
                   (ignore-errors (bt:destroy-thread thr)))
                 (setf (coordinator-entry-active-worker-threads entry) nil)))))
      ;; 3. Release entry ownership and notify next thread
      (unwind-protect
           (bt:with-lock-held (*coordinator-lock*)
             (setf (coordinator-entry-active-thread entry) nil)
             (setf (coordinator-entry-mailbox entry) nil)
             (dotimes (i (coordinator-entry-waiters-count entry))
               (bt:condition-notify (coordinator-entry-cv entry))))
        (release-entry session-id)))))

(defun wake-session (session-id function)
  "Wake a session drain execution. Spawns a thread if idle, or coalesces the wake if running."
  (let ((entry (get-or-create-entry session-id)))
    (unwind-protect
         (bt:with-lock-held (*coordinator-lock*)
           (let ((thread (coordinator-entry-active-thread entry)))
             (cond
               (thread
                ;; Session is currently draining or spawning; set pending-wake to coalesce
                (setf (coordinator-entry-pending-wake entry) t))
               (t
                ;; Set state to :spawning to prevent other calls from spawning duplicate threads
                (setf (coordinator-entry-active-thread entry) :spawning)
                (bt:make-thread
                 (lambda ()
                   (unwind-protect
                        (run-coordinator session-id function)
                     ;; Safety fallback in case of errors before run-coordinator assigns active-thread
                     (bt:with-lock-held (*coordinator-lock*)
                       (when (eq (coordinator-entry-active-thread entry) :spawning)
                         (setf (coordinator-entry-active-thread entry) nil)
                         (dotimes (i (coordinator-entry-waiters-count entry))
                           (bt:condition-notify (coordinator-entry-cv entry)))))))
                 :name (format nil "session-drain-~A" session-id))))))
      (release-entry session-id))))

(defun interrupt-session (session-id &optional mailbox)
  "Interrupt a session's drain thread safely without using raw thread interrupts.
Sets the stopping flag and posts an interrupt message to the event loop mailbox."
  (bt:with-lock-held (*coordinator-lock*)
    (let ((entry (gethash session-id *coordinator-entries*)))
      (when entry
        (setf (coordinator-entry-stopping entry) t)
        (dotimes (i (coordinator-entry-waiters-count entry))
          (bt:condition-notify (coordinator-entry-cv entry)))
        (let ((mbox (or mailbox (coordinator-entry-mailbox entry))))
          (when mbox
            (ignore-errors (sb-concurrency:send-message mbox '(:interrupt)))))))))

;;; --- Mailbox Wrapper Functions ---

(defun make-mailbox (&key name)
  "Create an sb-concurrency mailbox."
  (sb-concurrency:make-mailbox :name name))

(defun send-message (mailbox message)
  "Send a message to MAILBOX."
  (sb-concurrency:send-message mailbox message))

(defun receive-message (mailbox &key timeout)
  "Wait for and receive a message from MAILBOX. Supports an optional TIMEOUT in seconds."
  (sb-concurrency:receive-message mailbox :timeout timeout))
