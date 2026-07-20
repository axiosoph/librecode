;;; -*- Mode: Lisp; Syntax: Common-Lisp; indent-tabs-mode: nil; coding: utf-8; Show-Trailing-Whitespace: t -*-
;;;
;;; child.lisp — Child harness entry point and session loop
;;;

(in-package #:librecode-runner.child)

(eval-when (:compile-toplevel :load-toplevel :execute)
  #+sbcl (require :sb-posix))

(defun run-child (&key workspace-root db-path provider-url model task session-id (max-steps 10))
  (setf *random-state* (make-random-state t))
  (let* ((workspace-pathname (uiop:ensure-directory-pathname workspace-root))
         (session-id (or session-id (format nil "session-~A-~A" (librecode-runner.event-store::current-timestamp-ms) (random 1000000))))
         (child-mailbox (sb-concurrency:make-mailbox :name "child-main-mailbox"))
         (librecode-runner.agent:*interactive-p* nil)
         (exit-code 0))
    (declare (special librecode-runner.agent:*interactive-p*))
    (handler-case
        (progn
          ;; 1. Set workspace root and event broadcast hook
          (setf librecode-runner.event-store:*workspace-root* workspace-pathname)
          
          (setf librecode-runner.protocol:*event-broadcast-hook*
                (lambda (sess event-type data)
                  (declare (ignore sess))
                  (format t "~S~%" (list :event-type event-type :data data))
                  (force-output)
                  (cond
                    ((eq event-type :session-start)
                     (format t "(:status :running)~%")
                     (force-output))
                    ((eq event-type :session-complete)
                     (format t "(:status :idle)~%")
                     (force-output))
                    ((eq event-type :error)
                     (format t "(:status :error :message ~S)~%" (princ-to-string data))
                     (force-output)
                     (setf exit-code 1)))))

          ;; 2. Initialize DB connection and schema
          (let ((db (librecode-runner.event-store:connect-db db-path)))
            (unwind-protect
                 (progn
                   (librecode-runner.event-store:init-db db)
                   (librecode-runner.event-store:with-transaction (db)
                     (unless (sqlite:execute-single db "SELECT session_id FROM session_state WHERE session_id = ?" session-id)
                       (sqlite:execute-non-query db
                         "INSERT INTO session_state (session_id, agent_id, version, status, last_updated)
                          VALUES (?, 'default-agent', 1, 'idle', ?)"
                         session-id (librecode-runner.event-store::current-timestamp-ms)))
                     (sqlite:execute-non-query db
                       "INSERT OR REPLACE INTO permission_saved (project_id, action, resource, effect, timestamp)
                        VALUES ('default', '*', '*', 'allow', ?)"
                       (librecode-runner.event-store::current-timestamp-ms))))
              (sqlite:disconnect db)))

          ;; 3. Open DB connection for the execution run
          (let ((db (librecode-runner.event-store:connect-db db-path)))
            (unwind-protect
                 (let ((librecode-runner.event-store:*db* db))
                   ;; Configure LLM provider. The credential is sourced here,
                   ;; inside the already-running child, via uiop:getenv on
                   ;; the inherited environment -- never interpolated into
                   ;; this process's own --eval invocation string, so it
                   ;; never appears in argv/ps (C-N4-1). configure-session
                   ;; persists it into the session's DB-backed provider
                   ;; config, so once read it no longer needs to live in
                   ;; this process's OS environment; unset it there
                   ;; immediately so a later-spawned subprocess (e.g. the
                   ;; bash tool, which inherits this process's environment
                   ;; by default) cannot read it back out (F1).
                   (let ((provider-api-key (uiop:getenv "LIBRECODE_PROVIDER_API_KEY")))
                     (librecode-runner.provider:configure-session
                      session-id
                      :base-url provider-url
                      :model model
                      :auth provider-api-key)
                     (when provider-api-key
                       (sb-posix:unsetenv "LIBRECODE_PROVIDER_API_KEY")))

                   ;; Register built-in tools
                   (librecode-runner.builtin-tools:register-builtin-tools librecode-runner.runner::*tool-registry*)

                   ;; 4. Start stdin reader thread
                   (bt:make-thread
                    (lambda ()
                      (handler-case
                          (loop
                            (let ((line (read-line *standard-input* nil nil)))
                              (unless line
                                (return))
                              (let ((trimmed (string-trim '(#\Space #\Tab #\Return #\Newline) line)))
                                (unless (string= trimmed "")
                                  (if (char= (char trimmed 0) #\()
                                      ;; Parse command
                                      (let ((command (ignore-errors
                                                       (let ((*read-eval* nil))
                                                         (read-from-string trimmed)))))
                                        (when command
                                          (cond
                                            ((and (listp command) (eq (car command) :inject-conditioning))
                                             (let ((persona-text (second command)))
                                               (let* ((librecode-runner.event-store:*workspace-root* workspace-pathname)
                                                      (tdb (librecode-runner.event-store:connect-db db-path)))
                                                 (unwind-protect
                                                      (librecode-runner.event-store:with-transaction (tdb)
                                                        (let ((epoch-id (format nil "epoch-~A-~A" (librecode-runner.event-store::current-timestamp-ms) (random 1000000)))
                                                              (now (librecode-runner.event-store::current-timestamp-ms)))
                                                          (sqlite:execute-non-query tdb
                                                            "INSERT OR REPLACE INTO context_epoch (session_id, epoch_id, baseline_text, created_at)
                                                             VALUES (?, ?, ?, ?)"
                                                             session-id epoch-id persona-text now))))))))))
                                      ;; Raw prompt
                                      (progn
                                        (let ((prompt-id (format nil "prompt-~A-~A" (librecode-runner.event-store::current-timestamp-ms) (random 1000000))))
                                          (let* ((librecode-runner.event-store:*workspace-root* workspace-pathname)
                                                 (tdb (librecode-runner.event-store:connect-db db-path)))
                                            (unwind-protect
                                                 (let ((librecode-runner.event-store:*db* tdb))
                                                   (librecode-runner.session:admit-input session-id prompt-id trimmed "STEER"))
                                              (sqlite:disconnect tdb))))
                                        (sb-concurrency:send-message child-mailbox :wake)))))))
                        (error (c)
                          (format *error-output* "Stdin reader error: ~A~%" c)
                          (force-output *error-output*))))
                    :name "child-stdin-reader")

                   ;; 5. If task was provided on command line, admit it immediately and trigger run
                   (when task
                     (let ((prompt-id (format nil "prompt-~A-~A" (librecode-runner.event-store::current-timestamp-ms) (random 1000000))))
                       (librecode-runner.session:admit-input session-id prompt-id task "STEER"))
                     (sb-concurrency:send-message child-mailbox :wake))

                   ;; 6. Wait for a trigger to execute
                   (let ((msg (sb-concurrency:receive-message child-mailbox)))
                     (when (eq msg :wake)
                       ;; Wake/start the session drive loop
                       (let ((thread
                              (librecode-runner.protocol:wake-session session-id
                                (lambda ()
                                  (handler-case
                                      (librecode-runner.http::call-with-session-drive-loop
                                       session-id
                                       max-steps
                                       db-path
                                       workspace-pathname
                                       (lambda (withhold-tools)
                                         (librecode-runner.runner:execute-provider-turn
                                          session-id
                                          "mock-provider"
                                          model
                                          :withhold-tools withhold-tools)))
                                    (serious-condition (c)
                                      (librecode-runner.protocol:broadcast-event session-id :error c)))))))
                         (when (typep thread 'bt:thread)
                           (bt:join-thread thread))))))
              (sqlite:disconnect db))))
      (serious-condition (c)
        (format t "(:status :error :message ~S)~%" (princ-to-string c))
        (force-output)
        (setf exit-code 1)))
    (uiop:quit exit-code)))
