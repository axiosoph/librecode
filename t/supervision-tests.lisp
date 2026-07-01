;;; -*- Mode: Lisp; Syntax: Common-Lisp; indent-tabs-mode: nil; coding: utf-8; Show-Trailing-Whitespace: t -*-
;;;
;;; supervision-tests.lisp — Unit tests for child harness process supervision
;;;

(defpackage #:librecode-test.supervision
  (:use #:cl #:fiveam)
  (:import-from #:librecode-meta.campaign
                #:campaign
                #:campaign-node
                #:make-campaign-node
                #:campaign-node-id
                #:campaign-node-status
                #:make-campaign-dag
                #:run-campaign
                #:campaign-supervisor-mailbox
                #:campaign-reply-mailbox)
  (:export #:supervision-suite))
(in-package #:librecode-test.supervision)

(def-suite supervision-suite :description "Test child harness processes supervision")
(in-suite supervision-suite)

;;; ============================================================================
;;; Mock harness class for testing supervision protocol without external deps
;;; ============================================================================

(defclass mock-supervision-harness (librecode-meta.harness:harness)
  ((harness-status :initform :idle :accessor harness-status-mock)
   (event-queue :initform (sb-concurrency:make-mailbox) :reader harness-event-queue-mock)
   (fail-p :initarg :fail-p :initform nil :reader mock-fail-p)
   (duration :initarg :duration :initform 0.1 :reader mock-duration)
   (thread :initform nil :accessor mock-thread)))

(defmethod librecode-meta.harness:harness-spawn ((type (eql 'mock-supervision-harness)) config)
  (let* ((session-id (getf config :id))
         (fail-p (search "fail" session-id))
         (instance (make-instance 'mock-supervision-harness
                                  :id session-id
                                  :config config
                                  :fail-p (not (null fail-p))
                                  :duration 0.2)))
    instance))

(defmethod librecode-meta.harness:harness-prepare-workspace ((class (eql 'mock-supervision-harness)) repo-path target-dir)
  (declare (ignore repo-path))
  (ensure-directories-exist target-dir)
  t)

(defmethod librecode-meta.harness:harness-cleanup-workspace ((class (eql 'mock-supervision-harness)) repo-path target-dir &key force)
  (declare (ignore repo-path force))
  (uiop:delete-directory-tree target-dir :validate (constantly t) :if-does-not-exist :keep)
  t)

(defmethod librecode-meta.harness:harness-prompt ((instance mock-supervision-harness) prompt &key mode)
  (declare (ignore prompt mode))
  (setf (harness-status-mock instance) :running)
  (setf (mock-thread instance)
        (bt:make-thread
         (lambda ()
           (sleep (mock-duration instance))
           (if (mock-fail-p instance)
               (setf (harness-status-mock instance) :error)
               (setf (harness-status-mock instance) :idle)))
         :name (format nil "mock-harness-thread-~A" (librecode-meta.harness:harness-id instance))))
  t)

(defmethod librecode-meta.harness:harness-status ((instance mock-supervision-harness))
  (harness-status-mock instance))

(defmethod librecode-meta.harness:harness-read-event ((instance mock-supervision-harness) &key timeout)
  (sb-concurrency:receive-message (harness-event-queue-mock instance) :timeout timeout))

(defmethod librecode-meta.harness:harness-terminate ((instance mock-supervision-harness))
  (setf (harness-status-mock instance) :terminated)
  (let ((thr (mock-thread instance)))
    (when (and thr (bt:thread-alive-p thr))
      (ignore-errors (bt:destroy-thread thr))))
  t)

;;; ============================================================================
;;; Git repository test helpers
;;; ============================================================================

(defun setup-test-git-repo (dir)
  (uiop:run-program '("git" "init") :directory (namestring dir))
  (let ((dummy-file (uiop:merge-pathnames* "dummy.txt" dir)))
    (with-open-file (s dummy-file :direction :output :if-exists :supersede :if-does-not-exist :create)
      (format s "Initial commit~%"))
    (uiop:run-program '("git" "add" "dummy.txt") :directory (namestring dir))
    (uiop:run-program '("env"
                        "GIT_AUTHOR_NAME=Test User"
                        "GIT_AUTHOR_EMAIL=test@example.com"
                        "GIT_COMMITTER_NAME=Test User"
                        "GIT_COMMITTER_EMAIL=test@example.com"
                        "git" "commit" "-m" "initial commit")
                      :directory (namestring dir))))

;;; ============================================================================
;;; Tests
;;; ============================================================================

(test test-concurrent-supervision-and-failure-relay
  "Supervise 2 concurrent child processes, catch failure in failure-relay, and recover via skip restart."
  (librecode-test.event-store::with-tmp-sandbox (dir :git t)
    (setup-test-git-repo dir)
    (let* ((nodes (list (make-campaign-node :id "node-1"
                                            :goal "Success node"
                                            :file-surface '("src/a.lisp")
                                            :harness-type 'mock-supervision-harness
                                            :ibc "ibc-1")
                        (make-campaign-node :id "node-2-fail"
                                            :goal "Fail node"
                                            :file-surface '("src/b.lisp")
                                            :harness-type 'mock-supervision-harness
                                            :ibc "ibc-2")))
           (dag (make-campaign-dag :nodes nodes :shared-branch "master"))
           (journal-file (uiop:merge-pathnames* "campaign-journal.lisp-expr" dir))
           (workspace-dir (uiop:merge-pathnames* "workspace/" dir))
           (campaign (make-instance 'campaign
                                    :dag dag
                                    :journal-path journal-file
                                    :repository-path dir
                                    :workspace-dir workspace-dir))
           (supervisor-mbox (campaign-supervisor-mailbox campaign)))
      
      (let ((campaign-thread
              (bt:make-thread (lambda () (run-campaign campaign))
                              :name "run-campaign-thread")))
        
        ;; Wait for the failure message of node-2-fail to be relayed
        (let ((msg (librecode-runner.protocol:receive-message supervisor-mbox :timeout 5.0)))
          (is (not (null msg)))
          (let* ((desc (second msg))
                 (reply (third msg)))
            (is (typep desc 'librecode-runner.protocol:failure-descriptor))
            (is (search "node-2-fail" (librecode-runner.protocol:failure-descriptor-message desc)))
            ;; Skip the failing node
            (librecode-runner.protocol:send-message reply '(skip-node))))
        
        ;; Wait for the campaign thread to finish
        (let ((res (librecode-runner.protocol:join-thread-with-timeout campaign-thread 5.0)))
          (is (eq t res)))
        
        ;; Verify both nodes have transitioned to :accepted
        (is (eq :accepted (campaign-node-status (first nodes))))
        (is (eq :accepted (campaign-node-status (second nodes))))))))

(test test-journal-resumption
  "Crash/kill a supervisor mid-execution, reconstruct pre-crash state, and resume at recovery boundary."
  (librecode-test.event-store::with-tmp-sandbox (dir :git t)
    (setup-test-git-repo dir)
    (let* ((nodes (list (make-campaign-node :id "node-1"
                                            :goal "Success node"
                                            :file-surface '("src/a.lisp")
                                            :harness-type 'mock-supervision-harness
                                            :ibc "ibc-1")
                        (make-campaign-node :id "node-2-fail"
                                            :goal "Fail node"
                                            :file-surface '("src/b.lisp")
                                            :harness-type 'mock-supervision-harness
                                            :ibc "ibc-2")))
           (dag (make-campaign-dag :nodes nodes :shared-branch "master"))
           (journal-file (uiop:merge-pathnames* "campaign-journal.lisp-expr" dir))
           (workspace-dir (uiop:merge-pathnames* "workspace/" dir))
           (campaign (make-instance 'campaign
                                    :dag dag
                                    :journal-path journal-file
                                    :repository-path dir
                                    :workspace-dir workspace-dir))
           (supervisor-mbox (campaign-supervisor-mailbox campaign)))
      
      ;; 1. Run campaign, wait for node-2-fail failure message, and simulate a crash
      (let ((campaign-thread
              (bt:make-thread (lambda () (run-campaign campaign))
                              :name "run-campaign-thread-crash")))
        (let ((msg (librecode-runner.protocol:receive-message supervisor-mbox :timeout 5.0)))
          (is (not (null msg)))
          ;; Simulating a crash by terminating the thread without reply
          (bt:destroy-thread campaign-thread))
        
        (sleep 0.5)
        
        ;; 2. Now start a fresh campaign instance with the same journal file
        (let* ((nodes-new (list (make-campaign-node :id "node-1"
                                                    :goal "Success node"
                                                    :file-surface '("src/a.lisp")
                                                    :harness-type 'mock-supervision-harness
                                                    :ibc "ibc-1")
                                (make-campaign-node :id "node-2-fail"
                                                    :goal "Fail node"
                                                    :file-surface '("src/b.lisp")
                                                    :harness-type 'mock-supervision-harness
                                                    :ibc "ibc-2")))
               (dag-new (make-campaign-dag :nodes nodes-new :shared-branch "master"))
               (campaign-new (make-instance 'campaign
                                            :dag dag-new
                                            :journal-path journal-file
                                            :repository-path dir
                                            :workspace-dir workspace-dir))
               (supervisor-mbox-new (campaign-supervisor-mailbox campaign-new))
               (campaign-thread-new
                 (bt:make-thread (lambda () (run-campaign campaign-new))
                                 :name "run-campaign-thread-resume")))
          
          ;; Resuming the campaign reads the journal. It detects that node-1 is already done,
          ;; so it skips executing it and only executes/fails node-2-fail again.
          (let ((msg-new (librecode-runner.protocol:receive-message supervisor-mbox-new :timeout 5.0)))
            (is (not (null msg-new)))
            (let ((reply (third msg-new)))
              ;; Skip it to let the campaign complete
              (librecode-runner.protocol:send-message reply '(skip-node))))
          
          (let ((res (librecode-runner.protocol:join-thread-with-timeout campaign-thread-new 5.0)))
            (is (eq t res)))
          
          ;; Verify both are completed now
          (is (eq :accepted (campaign-node-status (first nodes-new))))
          (is (eq :accepted (campaign-node-status (second nodes-new)))))))))

(test test-multi-failure-sequencing
  "Verify that when multiple nodes in a batch fail concurrently, they are processed sequentially by the supervisor."
  (librecode-test.event-store::with-tmp-sandbox (dir :git t)
    (setup-test-git-repo dir)
    (let* ((nodes (list (make-campaign-node :id "node-1-fail"
                                            :goal "Fail node 1"
                                            :file-surface '("src/a.lisp")
                                            :harness-type 'mock-supervision-harness
                                            :ibc "ibc-1")
                        (make-campaign-node :id "node-2-fail"
                                            :goal "Fail node 2"
                                            :file-surface '("src/b.lisp")
                                            :harness-type 'mock-supervision-harness
                                            :ibc "ibc-2")))
           (dag (make-campaign-dag :nodes nodes :shared-branch "master"))
           (journal-file (uiop:merge-pathnames* "campaign-journal.lisp-expr" dir))
           (workspace-dir (uiop:merge-pathnames* "workspace/" dir))
           (campaign (make-instance 'campaign
                                    :dag dag
                                    :journal-path journal-file
                                    :repository-path dir
                                    :workspace-dir workspace-dir))
           (supervisor-mbox (campaign-supervisor-mailbox campaign)))
      
      (let ((campaign-thread
              (bt:make-thread (lambda () (run-campaign campaign))
                              :name "run-campaign-multi-fail")))
        
        ;; Receive first failure
        (let ((msg1 (librecode-runner.protocol:receive-message supervisor-mbox :timeout 5.0)))
          (is (not (null msg1)))
          (let* ((desc (second msg1))
                 (reply (third msg1)))
            (is (typep desc 'librecode-runner.protocol:failure-descriptor))
            (librecode-runner.protocol:send-message reply '(skip-node))))
        
        ;; Receive second failure
        (let ((msg2 (librecode-runner.protocol:receive-message supervisor-mbox :timeout 5.0)))
          (is (not (null msg2)))
          (let* ((desc (second msg2))
                 (reply (third msg2)))
            (is (typep desc 'librecode-runner.protocol:failure-descriptor))
            (librecode-runner.protocol:send-message reply '(skip-node))))
        
        ;; Verify the campaign finishes
        (let ((res (librecode-runner.protocol:join-thread-with-timeout campaign-thread 5.0)))
          (is (eq t res)))
        
        (is (eq :accepted (campaign-node-status (first nodes))))
        (is (eq :accepted (campaign-node-status (second nodes))))))))

(test test-hierarchical-surface-overlaps
  "Assert that hierarchical directory surface overlaps are correctly detected."
  (let ((dir-surface '("src/"))
        (file-surface '("src/packages.lisp"))
        (nested-dir-surface '("src/meta/"))
        (unrelated-surface '("t/supervision-tests.lisp")))
    (is (librecode-meta.campaign::surfaces-overlap-p dir-surface file-surface))
    (is (librecode-meta.campaign::surfaces-overlap-p dir-surface nested-dir-surface))
    (is (librecode-meta.campaign::surfaces-overlap-p file-surface dir-surface))
    (is (librecode-meta.campaign::surfaces-overlap-p nested-dir-surface dir-surface))
    (is (not (librecode-meta.campaign::surfaces-overlap-p file-surface unrelated-surface)))
    (is (not (librecode-meta.campaign::surfaces-overlap-p nested-dir-surface unrelated-surface)))
    ;; Two files in the same directory do not overlap unless they are the same file
    (is (not (librecode-meta.campaign::surfaces-overlap-p '("src/a.lisp") '("src/b.lisp"))))
    (is (librecode-meta.campaign::surfaces-overlap-p '("src/a.lisp") '("src/a.lisp")))))

(test test-journal-truncation-on-recovery
  "Assert that a trailing partial write is truncated and does not corrupt subsequent writes."
  (librecode-test.event-store::with-tmp-sandbox (dir :git t)
    (setup-test-git-repo dir)
    (let* ((nodes (list (make-campaign-node :id "node-1"
                                            :goal "Goal 1"
                                            :file-surface '("src/a.lisp")
                                            :harness-type 'mock-supervision-harness
                                            :ibc "ibc-1")
                        (make-campaign-node :id "node-2"
                                            :goal "Goal 2"
                                            :file-surface '("src/b.lisp")
                                            :harness-type 'mock-supervision-harness
                                            :ibc "ibc-2")))
           (dag (make-campaign-dag :nodes nodes :shared-branch "master"))
           (journal-file (uiop:merge-pathnames* "campaign-journal.lisp-expr" dir))
           (workspace-dir (uiop:merge-pathnames* "workspace/" dir)))
      
      ;; 1. Write a valid entry, then write a partial/corrupt entry at the end of the file
      (with-open-file (s journal-file :direction :output :if-exists :supersede :if-does-not-exist :create)
        (format s "(:layer-advanced 0)~%")
        (format s "(:node-dispatched \"node-1\")~%")
        (format s "(:node-landed \"node-1\")~%")
        (format s "(:node-accepted \"node-1\")~%")
        ;; A corrupt/partial write
        (format s "(:node-dis"))
      
      ;; 2. Run the campaign. It should truncate the corrupt trailing write, read the valid entries,
      ;; and resume by executing node-2 (since node-1 is already :accepted).
      (let* ((campaign (make-instance 'campaign
                                      :dag dag
                                      :journal-path journal-file
                                      :repository-path dir
                                      :workspace-dir workspace-dir))
             (campaign-thread
               (bt:make-thread (lambda () (run-campaign campaign))
                               :name "run-campaign-truncation")))
        
        ;; Wait for campaign to finish
        (let ((res (librecode-runner.protocol:join-thread-with-timeout campaign-thread 5.0)))
          (is (eq t res)))
        
        ;; Verify both are completed now
        (is (eq :accepted (campaign-node-status (first nodes))))
        (is (eq :accepted (campaign-node-status (second nodes))))
        
        ;; 3. Replay the journal file again. It should be fully readable without any reader errors!
        (let* ((fresh-dag (make-campaign-dag :nodes (list (make-campaign-node :id "node-1"
                                                                              :goal "Goal 1"
                                                                              :file-surface '("src/a.lisp")
                                                                              :harness-type 'mock-supervision-harness
                                                                              :ibc "ibc-1")
                                                          (make-campaign-node :id "node-2"
                                                                              :goal "Goal 2"
                                                                              :file-surface '("src/b.lisp")
                                                                              :harness-type 'mock-supervision-harness
                                                                              :ibc "ibc-2"))
                                             :shared-branch "master"))
               (replayed (librecode-meta.campaign:replay-journal journal-file fresh-dag)))
          (is (eq :accepted (campaign-node-status (first (librecode-meta.campaign:campaign-dag-nodes replayed)))))
          (is (eq :accepted (campaign-node-status (second (librecode-meta.campaign:campaign-dag-nodes replayed))))))))))
