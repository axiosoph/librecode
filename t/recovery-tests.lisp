;;; -*- Mode: Lisp; Syntax: Common-Lisp; indent-tabs-mode: nil; coding: utf-8; Show-Trailing-Whitespace: t -*-
;;;
;;; recovery-tests.lisp — Unit tests for recovery / condition restart strategies
;;;

(defpackage #:librecode-test.recovery
  (:use #:cl #:fiveam)
  (:import-from #:librecode-meta.campaign
                #:campaign
                #:campaign-node
                #:make-campaign-node
                #:campaign-node-id
                #:campaign-node-status
                #:campaign-node-ibc
                #:campaign-node-goal
                #:make-campaign-dag
                #:run-campaign
                #:campaign-supervisor-mailbox
                #:campaign-reply-mailbox
                #:campaign-autonomous-p
                #:campaign-escalation-hook
                #:campaign-max-retries
                #:campaign-failure-counts
                #:escalation-required
                #:escalation-required-campaign
                #:escalation-required-node
                #:escalation-required-failure-descriptor)
  (:import-from #:librecode-test.supervision
                #:setup-test-git-repo)
  (:export #:recovery-suite))
(in-package #:librecode-test.recovery)

(def-suite recovery-suite :description "Test condition restart and harness recovery")
(in-suite recovery-suite)

(test c-bounded-ladder
  "Verify retry -> rework -> skip sequence autonomously for a persistently failing node."
  (librecode-test.event-store::with-tmp-sandbox (dir :git t)
    (setup-test-git-repo dir)
    (let* ((node (make-campaign-node :id "node-1-fail"
                                     :goal "Fail node"
                                     :file-surface '("src/a.lisp")
                                     :harness-type 'librecode-test.supervision::mock-supervision-harness
                                     :ibc "ibc-1"))
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
      
      ;; The node should have gone through retry -> rework -> skip (accepted)
      (is (eq :skipped (campaign-node-status node)))
      ;; Verify that the IBC was updated during the rework step with the error trace
      (is (not (null (campaign-node-ibc node))))
      (is (search "Error trace from failure:" (campaign-node-ibc node)))
      ;; Assert the exact number of attempts made for the persistently failing node
      (is (= 3 (gethash "node-1-fail" (campaign-failure-counts campaign)))))))

(test c-skip-and-continue
  "Skipping a failed node allows independent concurrent siblings to complete and land without blocking."
  (librecode-test.event-store::with-tmp-sandbox (dir :git t)
    (setup-test-git-repo dir)
    (let* ((success-node (make-campaign-node :id "node-1-success"
                                             :goal "Success node"
                                             :file-surface '("src/a.lisp")
                                             :harness-type 'librecode-test.supervision::mock-supervision-harness
                                             :ibc "ibc-1"))
           (fail-node (make-campaign-node :id "node-2-fail"
                                          :goal "Fail node"
                                          :file-surface '("src/b.lisp")
                                          :harness-type 'librecode-test.supervision::mock-supervision-harness
                                          :ibc "ibc-2"))
           (dag (make-campaign-dag :nodes (list success-node fail-node) :shared-branch "master"))
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
      
      ;; Verify nodes have transitioned to correct statuses
      (is (eq :accepted (campaign-node-status success-node)))
      (is (eq :skipped (campaign-node-status fail-node))))))

(test c-escalate-seam
  "The escalation hook/condition fires correctly with node context."
  (librecode-test.event-store::with-tmp-sandbox (dir :git t)
    (setup-test-git-repo dir)
    (let* ((node (make-campaign-node :id "node-1-fail"
                                     :goal "Fail node"
                                     :file-surface '("src/a.lisp")
                                     :harness-type 'librecode-test.supervision::mock-supervision-harness
                                     :ibc "ibc-1"))
           (dag (make-campaign-dag :nodes (list node) :shared-branch "master"))
           (journal-file (uiop:merge-pathnames* "campaign-journal.lisp-expr" dir))
           (workspace-dir (uiop:merge-pathnames* "workspace/" dir))
           (hook-called-p nil)
           (campaign (make-instance 'campaign
                                    :dag dag
                                    :journal-path journal-file
                                    :repository-path dir
                                    :workspace-dir workspace-dir
                                    :autonomous-p t
                                    :max-retries 3))) ; Set limit to 3 so it escalates on the 3rd failure
      
      ;; Setup hook to handle escalation autonomously by skipping
      (setf (campaign-escalation-hook campaign)
            (lambda (condition)
              (setf hook-called-p t)
              ;; Verify condition context
              (is (typep condition 'escalation-required))
              (is (eq campaign (escalation-required-campaign condition)))
              (is (eq node (escalation-required-node condition)))
              (is (typep (escalation-required-failure-descriptor condition)
                         'librecode-runner.protocol:failure-descriptor))
              (is (= 3 (gethash "node-1-fail" (campaign-failure-counts campaign))))
              ;; Invoke the restart to skip the node and let campaign finish
              (let ((restart (find 'librecode-meta.campaign::resume-escalation (compute-restarts) :key #'restart-name)))
                (if restart
                    (invoke-restart restart 'skip-node)
                    (error "resume-escalation restart not found")))))
      
      (run-campaign campaign)
      
      (is-true hook-called-p)
      (is (eq :skipped (campaign-node-status node))))))

(test c-escalate-max-retries-4
  "Verify escalation is triggered at exactly max-retries when set to 4."
  (librecode-test.event-store::with-tmp-sandbox (dir :git t)
    (setup-test-git-repo dir)
    (let* ((node (make-campaign-node :id "node-1-fail"
                                     :goal "Fail node"
                                     :file-surface '("src/a.lisp")
                                     :harness-type 'librecode-test.supervision::mock-supervision-harness
                                     :ibc "ibc-1"))
           (dag (make-campaign-dag :nodes (list node) :shared-branch "master"))
           (journal-file (uiop:merge-pathnames* "campaign-journal.lisp-expr" dir))
           (workspace-dir (uiop:merge-pathnames* "workspace/" dir))
           (hook-called-p nil)
           (campaign (make-instance 'campaign
                                    :dag dag
                                    :journal-path journal-file
                                    :repository-path dir
                                    :workspace-dir workspace-dir
                                    :autonomous-p t
                                    :max-retries 4)))
      
      ;; Setup hook to handle escalation autonomously by skipping
      (setf (campaign-escalation-hook campaign)
            (lambda (condition)
              (setf hook-called-p t)
              (is (typep condition 'escalation-required))
              (is (eq campaign (escalation-required-campaign condition)))
              (is (eq node (escalation-required-node condition)))
              ;; Assert that it escalated on the 4th failure
              (is (= 4 (gethash "node-1-fail" (campaign-failure-counts campaign))))
              ;; Invoke the restart to skip the node and let campaign finish
              (let ((restart (find 'librecode-meta.campaign::resume-escalation (compute-restarts) :key #'restart-name)))
                (if restart
                    (invoke-restart restart 'skip-node)
                    (error "resume-escalation restart not found")))))
      
      (run-campaign campaign)
      
      (is-true hook-called-p)
      (is (eq :skipped (campaign-node-status node))))))
