;;; -*- Mode: Lisp; Syntax: Common-Lisp; indent-tabs-mode: nil; coding: utf-8; Show-Trailing-Whitespace: t -*-
;;;
;;; harness-librecode.lisp — Stub definition for librecode-runner child harness adapter
;;;

(in-package #:librecode-meta.harness-librecode)

(defvar *active-harnesses-lock* (bt:make-lock "active-harnesses-lock"))
(defvar *active-harnesses* (make-hash-table :test 'equal)
  "Registry of active librecode-harness instances mapping session-id -> harness.")

(defun register-harness (session-id harness)
  (bt:with-lock-held (*active-harnesses-lock*)
    (setf (gethash session-id *active-harnesses*) harness)))

(defun unregister-harness (session-id)
  (bt:with-lock-held (*active-harnesses-lock*)
    (remhash session-id *active-harnesses*)))

(defun harness-event-broadcast-hook (session-id event-type data)
  (let ((harness nil))
    (bt:with-lock-held (*active-harnesses-lock*)
      (setf harness (gethash session-id *active-harnesses*)))
    (when harness
      (sb-concurrency:send-message (harness-event-queue harness)
                                   (list :event-type event-type :data data)))))

(defclass librecode-harness (harness)
  ((thread :initform nil :accessor harness-thread)
   (workspace-root :initarg :workspace-root :reader harness-workspace-root :type pathname)
   (db-path :initarg :db-path :reader harness-db-path)
   (provider :initarg :provider :reader harness-provider :initform "mock-provider")
   (model :initarg :model :reader harness-model :initform "mock-model")
   (max-steps :initarg :max-steps :reader harness-max-steps :initform 10)
   (event-queue :initform (sb-concurrency:make-mailbox) :reader harness-event-queue)
   (lock :initform (bt:make-lock) :reader harness-lock)))

(defmethod harness-spawn ((type (eql 'librecode-harness)) config)
  (let* ((session-id (getf config :id))
         (db-path (getf config :db-path))
         (workspace-root (getf config :workspace-root))
         (provider (getf config :provider "mock-provider"))
         (model (getf config :model "mock-model"))
         (max-steps (getf config :max-steps 10))
         (workspace-pathname (uiop:ensure-directory-pathname workspace-root))
         (instance (make-instance 'librecode-harness
                                  :id session-id
                                  :config config
                                  :workspace-root workspace-pathname
                                  :db-path db-path
                                  :provider provider
                                  :model model
                                  :max-steps max-steps)))
    
    (register-harness session-id instance)
    
    ;; Initialize event store db
    (let* ((librecode-runner.event-store:*workspace-root* workspace-pathname)
           (db (librecode-runner.event-store:connect-db db-path)))
      (unwind-protect
           (progn
             (librecode-runner.event-store:init-db db)
             (librecode-runner.event-store:with-transaction (db)
               (unless (sqlite:execute-single db "SELECT session_id FROM session_state WHERE session_id = ?" session-id)
                 (sqlite:execute-non-query db
                   "INSERT INTO session_state (session_id, agent_id, version, status, last_updated)
                    VALUES (?, 'default-agent', 1, 'idle', ?)"
                   session-id (librecode-runner.event-store::current-timestamp-ms)))))
        (sqlite:disconnect db)))
    
    (unless librecode-runner.protocol:*event-broadcast-hook*
      (setf librecode-runner.protocol:*event-broadcast-hook* #'harness-event-broadcast-hook))
      
    instance))

(defmethod harness-prepare-workspace ((harness-class-symbol (eql 'librecode-harness)) repository-path target-directory)
  (declare (ignore repository-path))
  (ensure-directories-exist (uiop:ensure-directory-pathname target-directory))
  t)

(defmethod harness-cleanup-workspace ((harness-class-symbol (eql 'librecode-harness)) repository-path target-directory &key force)
  (declare (ignore repository-path force))
  (when (uiop:directory-exists-p target-directory)
    (uiop:delete-directory-tree (uiop:ensure-directory-pathname target-directory) :validate (constantly t)))
  t)

(defmethod harness-prompt ((instance librecode-harness) prompt &key (mode :steer))
  (let* ((session-id (harness-id instance))
         (prompt-id (format nil "prompt-~A" (random 1000000)))
         (delivery-mode (if (eq mode :queue) "QUEUE" "STEER"))
         (workspace-root (harness-workspace-root instance))
         (provider-url (getf (harness-config instance) :provider-url))
         (librecode-runner.event-store:*workspace-root* workspace-root)
         (db (librecode-runner.event-store:connect-db (harness-db-path instance))))
    (unwind-protect
         (let ((librecode-runner.event-store:*db* db))
           (librecode-runner.session:admit-input session-id prompt-id prompt delivery-mode))
      (sqlite:disconnect db))
    
    (let ((res (librecode-runner.protocol:wake-session session-id
                 (lambda ()
                   (let ((librecode-runner.runner::*provider-url* (or provider-url librecode-runner.runner::*provider-url*)))
                     (handler-bind
                         ((error (lambda (c)
                                   (setf (%harness-status instance) :error)
                                   (librecode-runner.protocol:broadcast-event session-id :error (format nil "~A" c)))))
                       (setf (%harness-status instance) :running)
                       (librecode-runner.http::call-with-session-drive-loop
                        session-id
                        (harness-max-steps instance)
                        (harness-db-path instance)
                        workspace-root
                        (lambda (withhold-tools)
                          (librecode-runner.runner:execute-provider-turn
                           session-id
                           (harness-provider instance)
                           (harness-model instance)
                           :withhold-tools withhold-tools)))
                       (bt:with-lock-held ((harness-lock instance))
                         (unless (member (%harness-status instance) '(:terminated :error))
                           (setf (%harness-status instance) :idle)))))))))
      (when (typep res 'bt:thread)
        (setf (harness-thread instance) res))
      t)))

(defmethod harness-read-events ((instance librecode-harness))
  (harness-event-queue instance))

(defmethod harness-send-command ((instance librecode-harness) command)
  (cond
    ((string= command "/clear")
     (let* ((workspace-root (harness-workspace-root instance))
            (librecode-runner.event-store:*workspace-root* workspace-root)
            (db (librecode-runner.event-store:connect-db (harness-db-path instance))))
       (unwind-protect
            (progn
              (sqlite:execute-non-query db "DELETE FROM session_history WHERE session_id = ?" (harness-id instance))
              (sqlite:execute-non-query db "DELETE FROM session_input WHERE session_id = ?" (harness-id instance))
              t)
         (sqlite:disconnect db))))
    ((string= command "/compact")
     (let* ((workspace-root (harness-workspace-root instance))
            (librecode-runner.event-store:*workspace-root* workspace-root)
            (db (librecode-runner.event-store:connect-db (harness-db-path instance))))
       (unwind-protect
            (let ((librecode-runner.event-store:*db* db))
              (librecode-runner.compaction:compact-context (harness-id instance))
              t)
         (sqlite:disconnect db))))
    ((and (listp command) (eq (car command) :approve))
     (let ((req-id (second command))
           (decision (third command)))
       (librecode-runner.agent:resolve-permission-request req-id decision)
       t))
    (t
     nil)))

(defmethod harness-inject-conditioning ((instance librecode-harness) persona-text delivery-surface)
  (declare (ignore delivery-surface))
  (let* ((workspace-root (harness-workspace-root instance))
         (db-path (harness-db-path instance))
         (session-id (harness-id instance))
         (librecode-runner.event-store:*workspace-root* workspace-root)
         (db (librecode-runner.event-store:connect-db db-path)))
    (unwind-protect
         (librecode-runner.event-store:with-transaction (db)
           (let ((epoch-id (format nil "epoch-~A" (random 100000)))
                 (now (librecode-runner.event-store::current-timestamp-ms)))
             (sqlite:execute-non-query db
               "INSERT OR REPLACE INTO context_epoch (session_id, epoch_id, baseline_text, created_at)
                VALUES (?, ?, ?, ?)"
               session-id epoch-id persona-text now)
             t))
      (sqlite:disconnect db))))

(defmethod harness-status ((instance librecode-harness))
  (let ((thr (harness-thread instance)))
    (cond
      ((and thr (bt:thread-alive-p thr))
       :running)
      (t
       (%harness-status instance)))))

(defmethod harness-terminate ((instance librecode-harness))
  (let ((session-id (harness-id instance)))
    (unregister-harness session-id)
    (bt:with-lock-held ((harness-lock instance))
      (setf (%harness-status instance) :terminated)
      (librecode-runner.protocol:interrupt-session session-id)
      (let ((thr (harness-thread instance)))
        (when (and thr (bt:thread-alive-p thr))
          (ignore-errors
           (librecode-runner.protocol:join-thread-with-timeout thr 1.0)))))
    t))
