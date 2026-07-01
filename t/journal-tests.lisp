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
                #:campaign-node-ibc
                #:campaign-node-file-surface
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


