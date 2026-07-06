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

(defvar *session-supervised-p* nil
  "Dynamic variable indicating whether a live supervisor is listening for this
session's tool-worker errors and may choose to intervene (skip/retry) via the
failure-relay handshake. When NIL (the default), an ordinary tool handler error
settles locally as an error-as-result tool message instead of relaying.")

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
               (let ((threads-to-join nil))
                 (bt:with-lock-held ((coordinator-entry-lock entry))
                   (dolist (m (coordinator-entry-active-worker-mailboxes entry))
                     (ignore-errors (sb-concurrency:send-message m '(:abort))))
                   (setf (coordinator-entry-active-worker-mailboxes entry) nil)
                   (setf threads-to-join (coordinator-entry-active-worker-threads entry))
                   (setf (coordinator-entry-active-worker-threads entry) nil))
                 (dolist (thr threads-to-join)
                   (ignore-errors (join-thread-with-timeout thr 2.0)))))))
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

(defvar *event-broadcast-hook* nil
  "Function of three arguments (session-id event-type data) to broadcast session events.")

(defun broadcast-event (session-id event-type &optional data)
  "Helper to broadcast a session event using *event-broadcast-hook*."
  (when *event-broadcast-hook*
    (funcall *event-broadcast-hook* session-id event-type data)))

(defun join-thread-with-timeout (thread timeout)
  "Join THREAD with a TIMEOUT in seconds. Returns :timeout if the timeout is reached."
  #+sbcl (sb-thread:join-thread thread :timeout timeout :default :timeout)
  #-sbcl (bt:join-thread thread))

(defmacro with-session-context-captured (&body body)
  "Captures the dynamic variables (*db*, *workspace-root*, *current-session-id*, *session-mailbox*, *interactive-p*, *project-id*)
lexically and returns a lambda that rebinds them and executes BODY."
  (let ((db-val (gensym "DB"))
        (workspace-val (gensym "WORKSPACE"))
        (session-val (gensym "SESSION"))
        (mailbox-val (gensym "MAILBOX"))
        (interactive-val (gensym "INTERACTIVE"))
        (project-val (gensym "PROJECT"))
        (supervised-val (gensym "SUPERVISED")))
    `(let ((,db-val (and (boundp 'librecode-runner.event-store:*db*) librecode-runner.event-store:*db*))
           (,workspace-val (and (boundp 'librecode-runner.event-store:*workspace-root*) librecode-runner.event-store:*workspace-root*))
           (,session-val (and (boundp 'librecode-runner.agent:*current-session-id*) librecode-runner.agent:*current-session-id*))
           (,mailbox-val (and (boundp 'librecode-runner.protocol:*session-mailbox*) librecode-runner.protocol:*session-mailbox*))
           (,interactive-val (and (boundp 'librecode-runner.agent:*interactive-p*) librecode-runner.agent:*interactive-p*))
           (,project-val (and (boundp 'librecode-runner.agent:*project-id*) librecode-runner.agent:*project-id*))
           (,supervised-val (and (boundp 'librecode-runner.protocol:*session-supervised-p*) librecode-runner.protocol:*session-supervised-p*)))
       (lambda ()
         (let ((librecode-runner.event-store:*db* ,db-val)
               (librecode-runner.event-store:*workspace-root* ,workspace-val)
               (librecode-runner.agent:*current-session-id* ,session-val)
               (librecode-runner.protocol:*session-mailbox* ,mailbox-val)
               (librecode-runner.agent:*interactive-p* ,interactive-val)
               (librecode-runner.agent:*project-id* ,project-val)
               (librecode-runner.protocol:*session-supervised-p* ,supervised-val))
           (declare (special librecode-runner.event-store:*db*
                             librecode-runner.event-store:*workspace-root*
                             librecode-runner.agent:*current-session-id*
                             librecode-runner.protocol:*session-mailbox*
                             librecode-runner.agent:*interactive-p*
                             librecode-runner.agent:*project-id*
                             librecode-runner.protocol:*session-supervised-p*))
           ,@body)))))

;;; --- Failure Relay Primitive ---

(defstruct failure-descriptor
  "A serializable descriptor wrapping a condition's type, message, and constructor initargs."
  type
  message
  initargs)

(defun condition-to-descriptor (condition)
  "Convert a condition to a failure-descriptor."
  (let ((type (type-of condition)))
    (make-failure-descriptor
     :type type
     :message (princ-to-string condition)
     :initargs (cond
                 ((subtypep type 'librecode-runner.conditions:provider-error)
                  (list :message (librecode-runner.conditions:provider-error-message condition)
                        :endpoint (librecode-runner.conditions:provider-error-endpoint condition)
                        :provider (librecode-runner.conditions:provider-error-provider condition)))
                 ((subtypep type 'librecode-runner.conditions:harness-failure)
                  (list :message (librecode-runner.conditions:harness-failure-message condition)
                        :exit-code (librecode-runner.conditions:harness-failure-exit-code condition)
                        :process-id (librecode-runner.conditions:harness-failure-process-id condition)))
                 ((subtypep type 'librecode-runner.conditions:context-overflow)
                  (list :message (librecode-runner.conditions:context-overflow-message condition)
                        :budget (librecode-runner.conditions:context-overflow-budget condition)
                        :requested (librecode-runner.conditions:context-overflow-requested condition)))
                 ((subtypep type 'librecode-runner.conditions:tool-timeout)
                  (list :message (librecode-runner.conditions:tool-timeout-message condition)
                        :tool-id (librecode-runner.conditions:tool-timeout-tool-id condition)
                        :duration (librecode-runner.conditions:tool-timeout-duration condition)))
                 ((subtypep type 'librecode-runner.conditions:process-hang)
                  (list :message (librecode-runner.conditions:process-hang-message condition)
                        :process-id (librecode-runner.conditions:process-hang-process-id condition)))
                 ((subtypep type 'librecode-runner.conditions:protocol-invariant-violation)
                  (list :message (librecode-runner.conditions:protocol-invariant-violation-message condition)
                        :invariant (librecode-runner.conditions:protocol-invariant-violation-invariant condition)))
                 ((subtypep type 'librecode-runner.conditions:journal-invariant-violation)
                  (list :message (librecode-runner.conditions:journal-invariant-violation-message condition)
                        :invariant (librecode-runner.conditions:journal-invariant-violation-invariant condition)))
                 ((subtypep type 'librecode-runner.conditions:gate-failure)
                  (list :message (librecode-runner.conditions:gate-failure-message condition)
                        :command (librecode-runner.conditions:gate-failure-command condition)
                        :exit-code (librecode-runner.conditions:gate-failure-exit-code condition)))
                 ((subtypep type 'librecode-runner.conditions:denied-error)
                  (list :message (librecode-runner.conditions:denied-error-message condition)
                        :action (librecode-runner.conditions:denied-error-action condition)
                        :resource (librecode-runner.conditions:denied-error-resource condition)))
                 ((subtypep type 'simple-condition)
                  (list :format-control (simple-condition-format-control condition)
                        :format-arguments (simple-condition-format-arguments condition)))
                 (t
                  (list :message (princ-to-string condition)))))))

(defun known-custom-condition-p (type)
  "Returns true if TYPE is a known custom condition from librecode-runner.conditions."
  (member type '(librecode-runner.conditions:harness-failure
                 librecode-runner.conditions:provider-error
                 librecode-runner.conditions:context-overflow
                 librecode-runner.conditions:tool-timeout
                 librecode-runner.conditions:process-hang
                 librecode-runner.conditions:protocol-invariant-violation
                 librecode-runner.conditions:journal-invariant-violation
                 librecode-runner.conditions:gate-failure
                 librecode-runner.conditions:denied-error)))

(defun descriptor-to-condition (descriptor)
  "Reconstruct a condition object from a failure-descriptor.
Only deserializes known custom conditions or simple-conditions directly; other types fall back to a simple-error."
  (let ((type (failure-descriptor-type descriptor))
        (initargs (failure-descriptor-initargs descriptor)))
    (if (and type
             (find-class type nil)
             (or (known-custom-condition-p type)
                 (subtypep type 'simple-condition)))
        (apply #'make-condition type initargs)
        (make-condition 'simple-error
                        :format-control "Condition of type ~S: ~A"
                        :format-arguments (list type (failure-descriptor-message descriptor))))))

(defun failure-relay (supervisor-mailbox reply-mbox descriptor &key recovery-menu apply-choice message-factory)
  "Signal a failure DESCRIPTOR to a supervising mailbox, block preserving the failing context,
and receive a recovery choice from REPLY-MBOX. Returns (values success-p choice).
RECOVERY-MENU is serialized alongside DESCRIPTOR into the outgoing message (an
additive field) so the supervisor learns which restarts are actually available."
  (let ((message (if message-factory
                     (funcall message-factory descriptor reply-mbox recovery-menu)
                     (list :failure descriptor reply-mbox recovery-menu))))
    (send-message supervisor-mailbox message)
    (let ((reply (receive-message reply-mbox)))
      (cond
        ((or (eq reply :abort)
             (and (listp reply) (eq (car reply) :abort)))
         (values nil :abort))
        ((listp reply)
         (destructuring-bind (choice &rest args) reply
           (if (eq choice :abort)
               (values nil :abort)
               (progn
                 (when apply-choice
                   (funcall apply-choice choice args))
                 (values t choice)))))
        (t
         (values nil reply))))))

(defmacro with-failure-relay ((supervisor-mailbox reply-mailbox &key recovery-menu apply-choice message-factory on-abort) &body body)
  "Binds a serious-condition handler to run failure-relay. If aborted, executes on-abort (defaults to return).
WARNING: The default on-abort executes a (return) which requires an enclosing lexical block named NIL."
  (let ((c-var (gensym "C"))
        (success-var (gensym "SUCCESS"))
        (choice-var (gensym "CHOICE"))
        (supervisor-var (gensym "SUPERVISOR"))
        (reply-var (gensym "REPLY"))
        (menu-var (gensym "MENU"))
        (factory-var (gensym "FACTORY"))
        (apply-var (gensym "APPLY")))
    `(let ((,supervisor-var ,supervisor-mailbox)
           (,reply-var ,reply-mailbox)
           (,menu-var ,recovery-menu)
           (,factory-var ,message-factory)
           (,apply-var ,apply-choice))
       (handler-bind
            ((serious-condition
              (lambda (,c-var)
                (multiple-value-bind (,success-var ,choice-var)
                    (failure-relay ,supervisor-var
                                   ,reply-var
                                   (condition-to-descriptor ,c-var)
                                   :recovery-menu ,menu-var
                                   :message-factory ,factory-var
                                   :apply-choice ,apply-var)
                  (when (and (not ,success-var) (eq ,choice-var :abort))
                    ,(or on-abort `(return)))))))
         ,@body))))
