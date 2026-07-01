;;; -*- Mode: Lisp; Syntax: Common-Lisp; indent-tabs-mode: nil; coding: utf-8; Show-Trailing-Whitespace: t -*-
;;;
;;; gate-tests.lisp — Unit tests for validation gates DSL
;;;

(defpackage #:librecode-test.gate
  (:use #:cl #:fiveam)
  (:export #:gate-suite))
(in-package #:librecode-test.gate)

(def-suite gate-suite :description "Test validation gates DSL")
(in-suite gate-suite)

(defun find-source-contract-dir ()
  (let ((paths (list "/var/home/nrd/git/github.com/nrdxp/predicate/ledger/contracts/"
                     "../../predicate/ledger/contracts/"
                     "../../../predicate/ledger/contracts/")))
    (dolist (p paths (error "Could not locate source contract directory."))
      (when (uiop:directory-exists-p p)
        (return p)))))

(defun call-with-test-contracts (thunk)
  (let* ((temp-dir (uiop:temporary-directory))
         (temp-workspace (uiop:merge-pathnames* "librecode-gate-test-run/" temp-dir))
         (contracts-dir (uiop:merge-pathnames* "ledger/contracts/" temp-workspace))
         (source-dir (find-source-contract-dir)))
    (ensure-directories-exist contracts-dir)
    ;; Copy contracts
    (dolist (file '("dag_apply.ncl" "dag.ncl" "discipline.ncl" "authorized.ncl"))
      (uiop:copy-file (uiop:merge-pathnames* file source-dir)
                      (uiop:merge-pathnames* file contracts-dir)))
    ;; Write test YAMLs
    (with-open-file (s (uiop:merge-pathnames* "valid_dag.yaml" temp-workspace) :direction :output :if-exists :supersede :if-does-not-exist :create)
      (write-string "nodes:
  - id: \"A\"
    depends_on: []
    file_surface: [\"src/a.lisp\"]
    discipline: \"core\"
    mitigates: []
  - id: \"B\"
    depends_on: [\"A\"]
    file_surface: [\"src/b.lisp\"]
    discipline: \"core\"
    mitigates: []
" s))
    (with-open-file (s (uiop:merge-pathnames* "cyclic_dag.yaml" temp-workspace) :direction :output :if-exists :supersede :if-does-not-exist :create)
      (write-string "nodes:
  - id: \"A\"
    depends_on: [\"B\"]
    file_surface: [\"src/a.lisp\"]
    discipline: \"core\"
    mitigates: []
  - id: \"B\"
    depends_on: [\"A\"]
    file_surface: [\"src/b.lisp\"]
    discipline: \"core\"
    mitigates: []
" s))
    (with-open-file (s (uiop:merge-pathnames* "dangling_dag.yaml" temp-workspace) :direction :output :if-exists :supersede :if-does-not-exist :create)
      (write-string "nodes:
  - id: \"A\"
    depends_on: [\"C\"]
    file_surface: [\"src/a.lisp\"]
    discipline: \"core\"
    mitigates: []
" s))
    
    (unwind-protect
         (let ((librecode-runner.event-store:*workspace-root* temp-workspace))
           (funcall thunk))
      (uiop:delete-directory-tree temp-workspace :validate t))))

(test run-gate-valid-dag
  (call-with-test-contracts
   (lambda ()
     (is (eq t (librecode-meta.gate:run-gate "valid_dag.yaml"))))))

(test run-gate-cyclic-dag
  (call-with-test-contracts
   (lambda ()
     (signals librecode-runner.conditions:protocol-invariant-violation
       (librecode-meta.gate:run-gate "cyclic_dag.yaml")))))

(test run-gate-dangling-dag
  (call-with-test-contracts
   (lambda ()
     (signals librecode-runner.conditions:protocol-invariant-violation
       (librecode-meta.gate:run-gate "dangling_dag.yaml")))))

(test run-gate-missing-binary
  (call-with-test-contracts
   (lambda ()
     (signals error
       (librecode-meta.gate:run-gate "valid_dag.yaml" :contract "nonexistent-nickel-contract.ncl")))))

(test defgate-target-and-verify
  (call-with-test-contracts
   (lambda ()
     (let ((temp-json (librecode-meta.gate::resolve-gate-path "test-architect.json")))
       (uiop:delete-file-if-exists temp-json)
       
       (librecode-meta.gate:defgate test-check-architect (node-id)
         (:target (format nil "test-~a.json" node-id))
         (:verify (and (probe-file target)
                       (search "approved" (uiop:read-file-string target))))
         (:on-failure (error 'librecode-runner.conditions:gate-failure
                             :message "Architect check failed"
                             :command "test-check-architect"
                             :exit-code -2)))

       (signals librecode-runner.conditions:gate-failure
         (librecode-meta.gate:run-gate 'test-check-architect :node-id "architect"))
         
       (with-open-file (s temp-json :direction :output :if-exists :supersede :if-does-not-exist :create)
         (write-string "approved" s))
         
       (is (eq t (librecode-meta.gate:run-gate 'test-check-architect :node-id "architect")))
       (uiop:delete-file-if-exists temp-json)))))

(test defgate-worktree-and-execute
  (call-with-test-contracts
   (lambda ()
     (librecode-meta.gate:defgate test-local-lint (node-id)
       (:worktree ".")
       (:execute "echo linting-ok")
       (:on-failure (error 'librecode-runner.conditions:gate-failure
                           :message stderr
                           :command "test-local-lint"
                           :exit-code exit-code)))
                           
     (is (eq t (librecode-meta.gate:run-gate 'test-local-lint :node-id "N1"))))))

(test defgate-worktree-relative-script
  (call-with-test-contracts
   (lambda ()
     (let ((script-path (librecode-meta.gate::resolve-gate-path "test_script.sh")))
       (with-open-file (s script-path :direction :output :if-exists :supersede :if-does-not-exist :create)
         (write-string "#!/bin/sh
echo script-run-ok
exit 0
" s))
       (uiop:run-program (list "chmod" "+x" (namestring script-path)))
       
       (librecode-meta.gate:defgate test-rel-script (node-id)
         (:worktree ".")
         (:execute "./test_script.sh")
         (:on-failure (error 'librecode-runner.conditions:gate-failure
                             :message stderr
                             :command "./test_script.sh"
                             :exit-code exit-code)))
                             
       (is (eq t (librecode-meta.gate:run-gate 'test-rel-script :node-id "N1")))
       (uiop:delete-file-if-exists script-path)))))

(test defgate-execute-failure
  (call-with-test-contracts
   (lambda ()
     (librecode-meta.gate:defgate test-failing-lint (node-id)
       (:execute "false")
       (:on-failure (error 'librecode-runner.conditions:gate-failure
                           :message "Command false failed"
                           :command "false"
                           :exit-code exit-code)))
                           
     (signals librecode-runner.conditions:gate-failure
       (librecode-meta.gate:run-gate 'test-failing-lint :node-id "N1")))))

(test run-gate-non-default-workspace-root
  (call-with-test-contracts
   (lambda ()
     (let ((dag-rel-path "valid_dag.yaml")
           (contract-rel-path "ledger/contracts/dag_apply.ncl"))
       (is (eq t (librecode-meta.gate:run-gate dag-rel-path :contract contract-rel-path)))))))
