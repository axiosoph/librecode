;;; -*- Mode: Lisp; Syntax: Common-Lisp; indent-tabs-mode: nil; coding: utf-8; Show-Trailing-Whitespace: t -*-
;;;
;;; journal-tests.lisp — Unit tests for campaign journal tracking
;;;

(defpackage #:librecode-test.journal
  (:use #:cl #:fiveam)
  (:import-from #:librecode-meta.campaign
                #:campaign-node
                #:make-campaign-node
                #:campaign-node-id
                #:campaign-node-status
                #:campaign-node-phase
                #:campaign-node-deposit
                #:campaign-node-ibc
                #:campaign-node-file-surface
                #:campaign-node-dependencies
                #:campaign-node-goal
                #:campaign-node-sequential-p
                #:campaign-node-harness-type
                #:campaign-node-harness-instance
                #:campaign-dag
                #:make-campaign-dag
                #:campaign-dag-nodes
                #:write-journal-entry
                #:replay-journal)
  (:export #:journal-suite))
(in-package #:librecode-test.journal)

(def-suite journal-suite :description "Test campaign journal tracking")
(in-suite journal-suite)

(test test-journal-replay-and-crash-safety
  (let* ((nodes (list (make-campaign-node :id "A" :dependencies nil :goal "Goal A" :file-surface '("src/a.lisp"))
                      (make-campaign-node :id "B" :dependencies '("A") :goal "Goal B" :file-surface '("src/b.lisp"))
                      (make-campaign-node :id "C" :dependencies '("B") :goal "Goal C" :file-surface '("src/c.lisp"))))
         (dag (make-campaign-dag :nodes nodes :shared-branch "main"))
         (journal-file "test-campaign-journal.lisp-expr"))
    ;; Ensure clean state
    (when (probe-file journal-file)
      (delete-file journal-file))
    
    (unwind-protect
         (progn
           ;; 1. Replay empty journal should return initial dag with no updates
           (with-open-file (s journal-file :direction :output :if-exists :supersede :if-does-not-exist :create)
             (declare (ignore s))) ; just touch
           (let ((replayed (replay-journal journal-file dag)))
             (is (equal :pending (campaign-node-status (find "A" (campaign-dag-nodes replayed) :key #'campaign-node-id :test #'string=))))
             (is (equal :pending (campaign-node-status (find "B" (campaign-dag-nodes replayed) :key #'campaign-node-id :test #'string=))))
             (is (equal :pending (campaign-node-status (find "C" (campaign-dag-nodes replayed) :key #'campaign-node-id :test #'string=)))))

           ;; 2. Write valid events in append mode
           (with-open-file (s journal-file :direction :output :if-exists :append :if-does-not-exist :create)
             (write-journal-entry s '(:node-dispatched "A"))
             (write-journal-entry s '(:node-landed "A"))
             (write-journal-entry s '(:node-accepted "A"))
             (write-journal-entry s '(:node-dispatched "B"))
             (write-journal-entry s '(:surface-widened "B" ("src/b.lisp" "src/c.lisp")))
             (write-journal-entry s '(:node-rework "B" "Linter error on line 42"))
             (write-journal-entry s '(:node-dispatched "C"))
             (write-journal-entry s '(:node-skipped "C")))

           ;; 3. Replay journal and verify DAG state
           (let ((replayed (replay-journal journal-file dag)))
             (is (equal :accepted (campaign-node-status (find "A" (campaign-dag-nodes replayed) :key #'campaign-node-id :test #'string=))))
             (let ((node-b (find "B" (campaign-dag-nodes replayed) :key #'campaign-node-id :test #'string=)))
               (is (equal :rework (campaign-node-status node-b)))
               (is (equal "Linter error on line 42" (campaign-node-ibc node-b)))
               (is (equal '("src/b.lisp" "src/c.lisp") (campaign-node-file-surface node-b))))
             (is (equal :skipped (campaign-node-status (find "C" (campaign-dag-nodes replayed) :key #'campaign-node-id :test #'string=)))))

           ;; 4. Simulate a partial write (crash mid-write)
           (with-open-file (s journal-file :direction :output :if-exists :append)
             ;; Write a partial S-expression (missing closing paren)
             (format s "~&(:node-dispatched \"B\"")
             (force-output s))

           ;; 5. Replay must succeed by ignoring the trailing malformed entry
           (let ((replayed (replay-journal journal-file dag)))
             (is (equal :accepted (campaign-node-status (find "A" (campaign-dag-nodes replayed) :key #'campaign-node-id :test #'string=))))
             (let ((node-b (find "B" (campaign-dag-nodes replayed) :key #'campaign-node-id :test #'string=)))
               (is (equal :rework (campaign-node-status node-b)))
               (is (equal "Linter error on line 42" (campaign-node-ibc node-b)))
               (is (equal '("src/b.lisp" "src/c.lisp") (campaign-node-file-surface node-b))))
             (is (equal :skipped (campaign-node-status (find "C" (campaign-dag-nodes replayed) :key #'campaign-node-id :test #'string=))))))
      
      ;; Cleanup
      (when (probe-file journal-file)
        (delete-file journal-file)))))

(test test-journal-non-existent-node
  (let* ((nodes (list (make-campaign-node :id "A" :dependencies nil)))
         (dag (make-campaign-dag :nodes nodes :shared-branch "main"))
         (journal-file "test-campaign-journal-error.lisp-expr"))
    (when (probe-file journal-file)
      (delete-file journal-file))
    (unwind-protect
         (progn
           (with-open-file (s journal-file :direction :output :if-exists :supersede :if-does-not-exist :create)
             (write-journal-entry s '(:node-dispatched "NON-EXISTENT")))
           (signals librecode-runner.conditions:protocol-invariant-violation
             (replay-journal journal-file dag)))
      (when (probe-file journal-file)
        (delete-file journal-file)))))

(test test-journal-layer-advanced-cut
  "A retired :layer-advanced entry (as an older on-disk journal might still
contain) is silently ignored on replay -- no reader, no error, no status
effect (a4)."
  (let* ((nodes (list (make-campaign-node :id "A" :dependencies nil)))
         (dag (make-campaign-dag :nodes nodes :shared-branch "main"))
         (journal-file "test-campaign-journal-layer-advanced.lisp-expr"))
    (when (probe-file journal-file)
      (delete-file journal-file))
    (unwind-protect
         (progn
           (with-open-file (s journal-file :direction :output :if-exists :supersede :if-does-not-exist :create)
             (write-journal-entry s '(:layer-advanced 0))
             (write-journal-entry s '(:node-dispatched "A")))
           (let ((replayed (replay-journal journal-file dag)))
             (is (equal :dispatched
                        (campaign-node-status
                         (find "A" (campaign-dag-nodes replayed) :key #'campaign-node-id :test #'string=))))))
      (when (probe-file journal-file)
        (delete-file journal-file)))))

(test test-journal-topology-and-model-fields-survive-resume
  "Topology-only fields (harness-instance/dependencies/goal/sequential-p/
harness-type) are untouched by replay -- same object identity throughout --
while status/phase/deposit/file-surface are correctly threaded forward from
the calculus fold rather than silently discarded (a5)."
  (let* ((harness-sentinel (list :sentinel))
         (node-z (make-campaign-node :id "Z" :dependencies nil :goal "Goal Z"))
         (node-a (make-campaign-node :id "A" :dependencies '("Z") :goal "Goal A"
                                     :sequential-p t
                                     :harness-type 'some-harness-class
                                     :harness-instance harness-sentinel
                                     :file-surface '("src/a.lisp")))
         (dag (make-campaign-dag :nodes (list node-z node-a) :shared-branch "main"))
         (journal-file "test-campaign-journal-merge.lisp-expr"))
    (when (probe-file journal-file)
      (delete-file journal-file))
    (unwind-protect
         (progn
           (with-open-file (s journal-file :direction :output :if-exists :supersede :if-does-not-exist :create)
             (write-journal-entry s '(:node-dispatched "A"))
             (write-journal-entry s '(:node-landed "A")))
           (multiple-value-bind (replayed last-valid-pos model-state)
               (replay-journal journal-file dag)
             (declare (ignore last-valid-pos))
             (let ((replayed-node (find "A" (campaign-dag-nodes replayed) :key #'campaign-node-id :test #'string=)))
               ;; Topology fields: same object identity, never touched by replay.
               (is (eq node-a replayed-node))
               (is (equal '("Z") (campaign-node-dependencies replayed-node)))
               (is (equal "Goal A" (campaign-node-goal replayed-node)))
               (is (eq harness-sentinel (campaign-node-harness-instance replayed-node)))
               (is (eq 'some-harness-class (campaign-node-harness-type replayed-node)))
               (is (eq t (campaign-node-sequential-p replayed-node)))
               ;; Calculus-derived fields: threaded forward, not discarded.
               (is (equal :landed (campaign-node-status replayed-node)))
               (is (equal 0 (campaign-node-phase replayed-node)))
               (is (not (null (campaign-node-deposit replayed-node))))
               (is (equal :pending (librecode-model:deposit-validation-state (campaign-node-deposit replayed-node))))
               (is (equal :gated (librecode-model:deposit-gate-mode (campaign-node-deposit replayed-node))))
               ;; The returned model-state independently agrees.
               (let ((ns (librecode-model:find-node-state model-state "A")))
                 (is (equal :landed (librecode-model:node-state-status ns)))))))
      (when (probe-file journal-file)
        (delete-file journal-file)))))

(test test-journal-accepted-remains-unrouted
  ":node-accepted is journal-only bookkeeping: it must not manufacture
calculus-level proof. This is the exact scenario P4 froze on -- confirm the
resolution holds (a3 regression guard)."
  (let* ((nodes (list (make-campaign-node :id "A" :dependencies nil)))
         (dag (make-campaign-dag :nodes nodes :shared-branch "main"))
         (journal-file "test-campaign-journal-accepted-unrouted.lisp-expr"))
    (when (probe-file journal-file)
      (delete-file journal-file))
    (unwind-protect
         (progn
           (with-open-file (s journal-file :direction :output :if-exists :supersede :if-does-not-exist :create)
             (write-journal-entry s '(:node-dispatched "A"))
             (write-journal-entry s '(:node-accepted "A")))
           (multiple-value-bind (replayed last-valid-pos model-state)
               (replay-journal journal-file dag)
             (declare (ignore last-valid-pos))
             (let ((replayed-node (find "A" (campaign-dag-nodes replayed) :key #'campaign-node-id :test #'string=)))
               ;; Campaign-level bookkeeping reflects :accepted (unchanged behavior).
               (is (equal :accepted (campaign-node-status replayed-node)))
               ;; The model was never told this node landed or passed a gate --
               ;; it remains :dispatched at the calculus level, never :proven.
               (let ((ns (librecode-model:find-node-state model-state "A")))
                 (is (equal :dispatched (librecode-model:node-state-status ns)))
                 (is (null (librecode-model:node-state-deposit ns)))))))
      (when (probe-file journal-file)
        (delete-file journal-file)))))

(test test-journal-boot-gate-invariant-violation
  "A syntactically-valid journal whose replayed trajectory violates a
crown-jewel invariant must refuse to resume, not proceed to dispatch (a2).
Here B is dispatched while its dependency A was never proven --
TRANSITION-EVENT applies :node-dispatched unconditionally (it has no
scheduling guard; enforcing that is SCHEDULE-CORRECT-P's whole job), so the
journal is syntactically valid but the replayed trajectory is not."
  (let* ((nodes (list (make-campaign-node :id "A" :dependencies nil)
                      (make-campaign-node :id "B" :dependencies '("A"))))
         (dag (make-campaign-dag :nodes nodes :shared-branch "main"))
         (journal-file "test-campaign-journal-boot-gate.lisp-expr")
         (campaign (make-instance 'librecode-meta.campaign:campaign
                                  :dag dag
                                  :journal-path journal-file
                                  :repository-path "."
                                  :workspace-dir ".")))
    (when (probe-file journal-file)
      (delete-file journal-file))
    (unwind-protect
         (progn
           (with-open-file (s journal-file :direction :output :if-exists :supersede :if-does-not-exist :create)
             (write-journal-entry s '(:node-dispatched "B")))
           (signals librecode-runner.conditions:journal-invariant-violation
             (librecode-meta.campaign:run-campaign campaign)))
      (when (probe-file journal-file)
        (delete-file journal-file)))))

(test test-journal-rework-before-landing-does-not-error
  "The pre-landing crash-retry ladder (:node-rework written for a node that
never reached :landed) is exactly the scenario this node froze on: there is
no :dispatched -> :rework edge in the calculus. Confirm it still works,
unrouted through the calculus, without signaling (a3 regression guard)."
  (let* ((nodes (list (make-campaign-node :id "A" :dependencies nil)))
         (dag (make-campaign-dag :nodes nodes :shared-branch "main"))
         (journal-file "test-campaign-journal-rework-prelanding.lisp-expr"))
    (when (probe-file journal-file)
      (delete-file journal-file))
    (unwind-protect
         (progn
           (with-open-file (s journal-file :direction :output :if-exists :supersede :if-does-not-exist :create)
             (write-journal-entry s '(:node-dispatched "A"))
             (write-journal-entry s '(:node-rework "A" "Harness crashed: mock error")))
           (let ((replayed (replay-journal journal-file dag)))
             (let ((replayed-node (find "A" (campaign-dag-nodes replayed) :key #'campaign-node-id :test #'string=)))
               (is (equal :rework (campaign-node-status replayed-node)))
               (is (equal "Harness crashed: mock error" (campaign-node-ibc replayed-node))))))
      (when (probe-file journal-file)
        (delete-file journal-file)))))


