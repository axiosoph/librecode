;;; -*- Mode: Lisp; Syntax: Common-Lisp; indent-tabs-mode: nil; coding: utf-8; Show-Trailing-Whitespace: t -*-
;;;
;;; cross-process-tests.lisp — Unit tests for cross-process metaharness control
;;;

(defpackage #:librecode-test.cross-process
  (:use #:cl #:fiveam)
  (:export #:cross-process-suite))
(in-package #:librecode-test.cross-process)

(def-suite cross-process-suite :description "Test cross process metaharness control")
(in-suite cross-process-suite)

(test c-protocol-unchanged
  "Confirm that harness.lisp and metaharness.lisp are completely untouched."
  (multiple-value-bind (stdout stderr exit-code)
      (uiop:run-program '("git" "diff" "--exit-code" "src/meta/harness.lisp" "src/meta/metaharness.lisp") :ignore-error-status t)
    (declare (ignore stdout stderr))
    (is (zerop exit-code))))

(test c-real-subprocess
  "Verify the child runs as a distinct OS subprocess and is supervised purely via stdout events."
  (librecode-test.event-store::with-tmp-sandbox (dir)
    (let* ((session-id "c-real-subprocess-test")
           (config (list :id session-id
                         :workspace-root dir
                         :command (list "sbcl" "--noinform" "--non-interactive"
                                        "--eval"
                                        "(progn (format t \"(:status :running)~%\") (force-output) (sleep 0.1) (format t \"(:status :idle)~%\") (force-output))")))
           (harness (librecode-meta.harness:harness-spawn 'librecode-meta.harness::subprocess-harness config)))
      (unwind-protect
           (progn
             (is (typep harness 'librecode-meta.harness::subprocess-harness))
             (is (string= (librecode-meta.harness:harness-id harness) session-id))
             
             ;; Wait for the running event
             (let ((ev1 (librecode-meta.harness:harness-read-event harness :timeout 2.0)))
               (is (not (null ev1)))
               (is (eq (getf ev1 :status) :running)))
             
             ;; Status should be :running
             (is (eq (librecode-meta.harness:harness-status harness) :running))
             
             ;; Wait for the idle event
             (let ((ev2 (librecode-meta.harness:harness-read-event harness :timeout 2.0)))
               (is (not (null ev2)))
               (is (eq (getf ev2 :status) :idle)))
             
             ;; Status should eventually be :idle
             (is (eq (librecode-meta.harness:harness-status harness) :idle)))
        (librecode-meta.harness:harness-terminate harness)))))

(test c-cross-process-failure-restart
  "Verify that a subprocess child failure (non-zero exit code) maps to a parent harness-failure condition that triggers a restart."
  (librecode-test.event-store::with-tmp-sandbox (dir)
    (let* ((session-id "c-failure-test")
           (config (list :id session-id
                         :workspace-root dir
                         :command (list "sbcl" "--noinform" "--non-interactive"
                                        "--eval"
                                        "(progn (sleep 0.1) (uiop:quit 1))")))
           (harness (librecode-meta.harness:harness-spawn 'librecode-meta.harness::subprocess-harness config)))
      (unwind-protect
           (let ((signaled nil))
             (handler-bind
                 ((librecode-runner.conditions:harness-failure
                    (lambda (c)
                      (setf signaled t)
                      (is (eql (librecode-runner.conditions:harness-failure-exit-code c) 1))
                      (is (string= (librecode-runner.conditions:harness-failure-process-id c) session-id))
                      (invoke-restart 'recovery-restart))))
               (restart-case
                   (progn
                     (loop
                       (let ((status (librecode-meta.harness:harness-status harness)))
                         (cond
                           ((eq status :error)
                            (error 'librecode-runner.conditions:harness-failure
                                   :message "Subprocess failed with exit code 1"
                                   :process-id session-id
                                   :exit-code (librecode-meta.harness::harness-exit-code harness)))
                           ((eq status :idle)
                            (return))
                           (t
                            (librecode-meta.harness:harness-read-event harness :timeout 0.1))))))
                 (recovery-restart ()
                   :report "Recover from failure"
                   :recovered)))
             (is-true signaled))
        (librecode-meta.harness:harness-terminate harness)))))

(test c-cross-process-fatal-event-failure
  "Verify that a subprocess child failure via a fatal event line maps to a parent harness-failure condition."
  (librecode-test.event-store::with-tmp-sandbox (dir)
    (let* ((session-id "c-fatal-event-test")
           (config (list :id session-id
                         :workspace-root dir
                         :command (list "sbcl" "--noinform" "--non-interactive"
                                        "--eval"
                                        "(progn (format t \"(:status :error :message \\\"Fatal error\\\")~%\") (force-output))")))
           (harness (librecode-meta.harness:harness-spawn 'librecode-meta.harness::subprocess-harness config)))
      (unwind-protect
           (let ((signaled nil))
             (handler-bind
                 ((librecode-runner.conditions:harness-failure
                    (lambda (c)
                      (setf signaled t)
                      (is (string= (librecode-runner.conditions:harness-failure-message c) "Fatal error"))
                      (is (string= (librecode-runner.conditions:harness-failure-process-id c) session-id))
                      (invoke-restart 'recovery-restart))))
               (restart-case
                   (progn
                     (loop
                       (let ((status (librecode-meta.harness:harness-status harness)))
                         (cond
                           ((eq status :error)
                            (error 'librecode-runner.conditions:harness-failure
                                   :message (or (librecode-meta.harness::harness-error-message harness) "Subprocess error")
                                   :process-id session-id
                                   :exit-code (librecode-meta.harness::harness-exit-code harness)))
                           ((eq status :idle)
                            (return))
                           (t
                            (librecode-meta.harness:harness-read-event harness :timeout 0.1))))))
                 (recovery-restart ()
                   :report "Recover from failure"
                   :recovered)))
             (is-true signaled))
        (librecode-meta.harness:harness-terminate harness)))))

(test c-subprocess-stream-cleanup
  "Verify that subprocess streams are closed and set to nil after termination."
  (librecode-test.event-store::with-tmp-sandbox (dir)
    (let* ((session-id "c-stream-cleanup-test")
           (config (list :id session-id
                         :workspace-root dir
                         :command (list "sbcl" "--noinform" "--non-interactive"
                                        "--eval"
                                        "(progn (format t \"(:status :running)~%\") (force-output))")))
           (harness (librecode-meta.harness:harness-spawn 'librecode-meta.harness::subprocess-harness config)))
      ;; Wait for running status to ensure stream is initialized and active
      (let ((ev (librecode-meta.harness:harness-read-event harness :timeout 2.0)))
        (is (not (null ev)))
        (is (eq (getf ev :status) :running)))
      ;; Verify streams are not nil initially
      (is (not (null (librecode-meta.harness::harness-input-stream harness))))
      (is (not (null (librecode-meta.harness::harness-output-stream harness))))
      ;; Terminate
      (librecode-meta.harness:harness-terminate harness)
      ;; Verify streams are set to nil
      (is (null (librecode-meta.harness::harness-input-stream harness)))
      (is (null (librecode-meta.harness::harness-output-stream harness))))))

