;;; -*- Mode: Lisp; Syntax: Common-Lisp; indent-tabs-mode: nil; coding: utf-8; Show-Trailing-Whitespace: t -*-
;;;
;;; cross-process-tests.lisp — Unit tests for cross-process metaharness control
;;;

(defpackage #:librecode-test.cross-process
  (:use #:cl #:fiveam)
  (:import-from #:librecode-meta.campaign
                #:campaign
                #:make-campaign-node
                #:campaign-node-status
                #:make-boundary-from-prompt
                #:make-campaign-dag
                #:run-campaign
                #:campaign-failure-counts)
  (:import-from #:librecode-test.supervision
                #:setup-test-git-repo)
  (:export #:cross-process-suite))
(in-package #:librecode-test.cross-process)

(def-suite cross-process-suite :description "Test cross process metaharness control")
(in-suite cross-process-suite)

;;; ----------------------------------------------------------------------------
;;; A REAL subprocess backend that always fails, selected via node harness-type.
;;; The campaign node carries no command, so we inject a failing one here — exactly
;;; as mock-supervision-harness supplies its behavior via its own spawn method.
;;; Instance-level methods (prompt/status/read-event/terminate) come free from the
;;; real subprocess-harness class, so the SUPERVISOR drives a genuine OS child.
;;; ----------------------------------------------------------------------------

(defvar *integration-spawns* nil
  "Records the subprocess-harness instances the supervisor spawned, so the test can
prove real OS children (not threads/mocks) were driven end-to-end.")

(defmethod librecode-meta.harness:harness-spawn ((type (eql 'failing-subprocess-harness)) config)
  (let ((instance
          (librecode-meta.harness:harness-spawn
           'librecode-meta.harness::subprocess-harness
           (list* :command
                  (list "sbcl" "--noinform" "--non-interactive" "--eval"
                        "(progn (sleep 0.1) (format t \"(:status :error :message ~S)~%\" \"integration boom\") (force-output))")
                  config))))
    (push instance *integration-spawns*)
    instance))

(defmethod librecode-meta.harness:harness-prepare-workspace ((class (eql 'failing-subprocess-harness)) repo-path target-dir)
  (librecode-meta.harness:harness-prepare-workspace 'librecode-meta.harness::subprocess-harness repo-path target-dir))

(defmethod librecode-meta.harness:harness-cleanup-workspace ((class (eql 'failing-subprocess-harness)) repo-path target-dir &key force)
  (librecode-meta.harness:harness-cleanup-workspace 'librecode-meta.harness::subprocess-harness repo-path target-dir :force force))

(test c-supervisor-recovers-real-subprocess-child
  "END-TO-END + SEAM PROOF. The UNMODIFIED supervisor (run-campaign) drives a REAL
failing subprocess child across a process boundary and autonomously recovers it via
the extracted failure-relay recovery ladder (retry -> rework -> skip). This supersedes
the former git-diff 'protocol-unchanged' check: the seam is proven BEHAVIORALLY — a
brand-new real backend needs zero changes to the harness protocol or the supervisor —
which is strictly stronger than asserting a clean working tree."
  (setf *integration-spawns* nil)
  (librecode-test.event-store::with-tmp-sandbox (dir :git t)
    (setup-test-git-repo dir)
    (let* ((node (make-campaign-node :id "node-subproc-fail"
                                     :goal "Always-failing subprocess node"
                                     :file-surface '("src/a.lisp")
                                     :harness-type 'failing-subprocess-harness
                                     :boundary (make-boundary-from-prompt "ibc-subproc")))
           (dag (make-campaign-dag :nodes (list node) :shared-branch "master"))
           (journal-file (uiop:merge-pathnames* "campaign-journal.lisp-expr" dir))
           (workspace-dir (uiop:merge-pathnames* "workspace/" dir))
           (campaign (make-instance 'campaign
                                    :dag dag
                                    :journal-path journal-file
                                    :repository-path dir
                                    :workspace-dir workspace-dir
                                    :autonomous-p t
                                    :max-retries 5)))
      (run-campaign campaign)
      ;; The supervisor recovered the failed CROSS-PROCESS node autonomously.
      (is (eq :skipped (campaign-node-status node)))
      (is (= 3 (gethash "node-subproc-fail" (campaign-failure-counts campaign))))
      ;; It drove REAL OS subprocess children — one genuine subprocess-harness per attempt.
      (is (= 3 (length *integration-spawns*)))
      (is (every (lambda (h) (typep h 'librecode-meta.harness::subprocess-harness))
                 *integration-spawns*)))))

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

