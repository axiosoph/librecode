;;; -*- Mode: Lisp; Syntax: Common-Lisp; indent-tabs-mode: nil; coding: utf-8; Show-Trailing-Whitespace: t -*-
;;;
;;; harness-subprocess.lisp — Subprocess supervised harness implementation
;;;

(in-package #:librecode-meta.harness)

(defclass subprocess-harness (harness)
  ((process-info :initform nil :accessor harness-process-info)
   (input-stream :initform nil :accessor harness-input-stream)
   (output-stream :initform nil :accessor harness-output-stream)
   (event-queue :initform (sb-concurrency:make-mailbox) :reader harness-event-queue)
   (monitor-thread :initform nil :accessor harness-monitor-thread)
   (lock :initform (bt:make-lock) :reader harness-lock)
   (exit-code :initform nil :accessor harness-exit-code)
   (error-message :initform nil :accessor harness-error-message)))

(defun start-subprocess-monitor (instance)
  (let ((stream (harness-output-stream instance))
        (mbox (harness-event-queue instance))
        (proc (harness-process-info instance)))
    (bt:make-thread
     (lambda ()
       (unwind-protect
            (handler-case
                (loop
                  (let ((line (read-line stream nil nil)))
                    (unless line
                      (return))
                    ;; Parse line as s-expression safely
                    (let ((event (ignore-errors
                                   (let ((*read-eval* nil))
                                     (read-from-string line)))))
                      (when event
                        (sb-concurrency:send-message mbox event)
                        ;; Check if this is a status transition
                        (bt:with-lock-held ((harness-lock instance))
                          (cond
                            ((and (listp event)
                                  (eq (getf event :status) :idle))
                             (setf (%harness-status instance) :idle))
                            ((and (listp event)
                                  (eq (getf event :status) :error))
                             (setf (%harness-status instance) :error)
                             (setf (harness-error-message instance)
                                   (getf event :message "Fatal event line received.")))))))))
              (error (c)
                (bt:with-lock-held ((harness-lock instance))
                  (setf (%harness-status instance) :error)
                  (setf (harness-error-message instance) (princ-to-string c)))))
         ;; Final cleanups when the thread exits or process terminates
         (let ((code (uiop:wait-process proc)))
           (bt:with-lock-held ((harness-lock instance))
             (setf (harness-exit-code instance) code)
             (unless (member (%harness-status instance) '(:error :terminated :idle))
               (if (= code 0)
                   (setf (%harness-status instance) :idle)
                   (setf (%harness-status instance) :error)))))))
     :name (format nil "subprocess-monitor-~A" (harness-id instance)))))

(defmethod harness-spawn ((type (eql 'subprocess-harness)) config)
  (let* ((session-id (getf config :id))
         (workspace-root (getf config :workspace-root))
         (command (getf config :command))
         ;; Default command if not provided: a simple echo loop
         (resolved-command (or command
                               (list "sbcl" "--noinform" "--non-interactive"
                                     "--eval"
                                     "(loop (let ((line (read-line *standard-input* nil))) (unless line (return)) (format t \"(:echo ~S)~%\" line) (force-output)))"))))
    
    (let* ((proc (uiop:launch-program resolved-command
                                      :input :stream
                                      :output :stream
                                      :directory (and workspace-root (namestring workspace-root))))
           (input (uiop:process-info-input proc))
           (output (uiop:process-info-output proc))
           (instance (make-instance 'subprocess-harness
                                    :id session-id
                                    :config config)))
      (setf (harness-process-info instance) proc)
      (setf (harness-input-stream instance) input)
      (setf (harness-output-stream instance) output)
      (setf (%harness-status instance) :running)
      (setf (harness-monitor-thread instance) (start-subprocess-monitor instance))
      instance)))

(defmethod harness-prepare-workspace ((class (eql 'subprocess-harness)) repository-path target-directory)
  (declare (ignore repository-path))
  (ensure-directories-exist (uiop:ensure-directory-pathname target-directory))
  t)

(defmethod harness-cleanup-workspace ((class (eql 'subprocess-harness)) repository-path target-directory &key force)
  (declare (ignore repository-path force))
  (when (uiop:directory-exists-p target-directory)
    (uiop:delete-directory-tree (uiop:ensure-directory-pathname target-directory) :validate (constantly t)))
  t)

(defmethod harness-prompt ((instance subprocess-harness) prompt &key mode)
  (declare (ignore mode))
  (bt:with-lock-held ((harness-lock instance))
    (when (member (%harness-status instance) '(:terminated :error))
      (error 'librecode-runner.conditions:harness-failure
             :message (format nil "Cannot prompt harness in status: ~S" (%harness-status instance))
             :process-id (harness-id instance)
             :exit-code (harness-exit-code instance))))
  (let ((stream (harness-input-stream instance)))
    (when stream
      (write-line prompt stream)
      (force-output stream)
      t)))

(defmethod harness-read-events ((instance subprocess-harness))
  (harness-event-queue instance))

(defmethod harness-read-event ((instance subprocess-harness) &key timeout)
  (sb-concurrency:receive-message (harness-event-queue instance) :timeout timeout))

(defmethod harness-send-command ((instance subprocess-harness) command)
  (bt:with-lock-held ((harness-lock instance))
    (when (member (%harness-status instance) '(:terminated :error))
      (error 'librecode-runner.conditions:harness-failure
             :message (format nil "Cannot send command to harness in status: ~S" (%harness-status instance))
             :process-id (harness-id instance)
             :exit-code (harness-exit-code instance))))
  (let ((stream (harness-input-stream instance)))
    (when stream
      (format stream "~S~%" command)
      (force-output stream)
      t)))

(defmethod harness-inject-conditioning ((instance subprocess-harness) persona-text delivery-surface)
  (declare (ignore delivery-surface))
  (let ((stream (harness-input-stream instance)))
    (when stream
      (format stream "(:inject-conditioning ~S)~%" persona-text)
      (force-output stream)
      t)))

(defmethod harness-status ((instance subprocess-harness))
  (bt:with-lock-held ((harness-lock instance))
    (let ((current-status (%harness-status instance))
          (proc (harness-process-info instance)))
      (cond
        ((member current-status '(:error :terminated :idle))
         current-status)
        ((null proc)
         :idle)
        ((uiop:process-alive-p proc)
         :running)
        (t
         (let ((code (uiop:wait-process proc)))
           (setf (harness-exit-code instance) code)
           (if (= code 0)
               (progn
                 (setf (%harness-status instance) :idle)
                 :idle)
               (progn
                 (setf (%harness-status instance) :error)
                 :error))))))))

(defmethod harness-terminate ((instance subprocess-harness))
  (bt:with-lock-held ((harness-lock instance))
    (let ((proc (harness-process-info instance)))
      (when (and proc (uiop:process-alive-p proc))
        (ignore-errors (uiop:terminate-process proc :urgent t))
        (ignore-errors (uiop:wait-process proc)))
      (setf (%harness-status instance) :terminated)))
  (let ((thr (harness-monitor-thread instance)))
    (when (and thr (bt:thread-alive-p thr))
      (ignore-errors (librecode-runner.protocol:join-thread-with-timeout thr 1.0))))
  t)
