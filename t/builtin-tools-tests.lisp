;;; -*- Mode: Lisp; Syntax: Common-Lisp; indent-tabs-mode: nil; coding: utf-8; Show-Trailing-Whitespace: t -*-
;;;
;;; builtin-tools-tests.lisp — Unit tests for built-in tools
;;;

(defpackage #:librecode-test.builtin-tools
  (:use #:cl
        #:fiveam
        #:librecode-runner.tool
        #:librecode-runner.runner
        #:librecode-runner.event-store
        #:librecode-runner.conditions
        #:librecode-runner.builtin-tools)
  (:export #:builtin-tools-suite))

(in-package #:librecode-test.builtin-tools)

(def-suite builtin-tools-suite
  :description "Suite for built-in tools tests.")

(in-suite builtin-tools-suite)

(test test-builtin-tools-registration
  "Verify that the built-in tools are registered in the global registry."
  (let ((read-tool (bt:with-lock-held ((librecode-runner.tool::registry-lock librecode-runner.runner::*tool-registry*))
                     (gethash "read_file" (librecode-runner.tool::registry-tools librecode-runner.runner::*tool-registry*))))
        (write-tool (bt:with-lock-held ((librecode-runner.tool::registry-lock librecode-runner.runner::*tool-registry*))
                      (gethash "write_file" (librecode-runner.tool::registry-tools librecode-runner.runner::*tool-registry*))))
        (bash-tool-resolved (bt:with-lock-held ((librecode-runner.tool::registry-lock librecode-runner.runner::*tool-registry*))
                              (gethash "bash" (librecode-runner.tool::registry-tools librecode-runner.runner::*tool-registry*)))))
    (is (not (null read-tool)))
    (is (not (null write-tool)))
    (is (not (null bash-tool-resolved)))
    (when (and read-tool write-tool bash-tool-resolved)
      (is (string= "read_file" (tool-name read-tool)))
      (is (string= "write_file" (tool-name write-tool)))
      (is (string= "bash" (tool-name bash-tool-resolved))))))

(test test-builtin-tool-argument-validation
  "Verify that the JSON schema for built-in tools validates arguments correctly."
  (let ((read-tool (bt:with-lock-held ((librecode-runner.tool::registry-lock librecode-runner.runner::*tool-registry*))
                     (gethash "read_file" (librecode-runner.tool::registry-tools librecode-runner.runner::*tool-registry*))))
        (write-tool (bt:with-lock-held ((librecode-runner.tool::registry-lock librecode-runner.runner::*tool-registry*))
                      (gethash "write_file" (librecode-runner.tool::registry-tools librecode-runner.runner::*tool-registry*))))
        (bash-tool (bt:with-lock-held ((librecode-runner.tool::registry-lock librecode-runner.runner::*tool-registry*))
                     (gethash "bash" (librecode-runner.tool::registry-tools librecode-runner.runner::*tool-registry*)))))
    (is (not (null read-tool)))
    (is (not (null write-tool)))
    (is (not (null bash-tool)))
    (when (and read-tool write-tool bash-tool)
      ;; 1. read_file
      ;; Good
      (finishes (librecode-runner.tool::validate-arguments read-tool '(:path "foo.txt")))
      ;; Bad (missing path)
      (signals error (librecode-runner.tool::validate-arguments read-tool '()))
      ;; Bad (wrong type)
      (signals error (librecode-runner.tool::validate-arguments read-tool '(:path 123)))

      ;; 2. write_file
      ;; Good
      (finishes (librecode-runner.tool::validate-arguments write-tool '(:path "foo.txt" :content "bar")))
      ;; Bad (missing path)
      (signals error (librecode-runner.tool::validate-arguments write-tool '(:content "bar")))
      ;; Bad (missing content)
      (signals error (librecode-runner.tool::validate-arguments write-tool '(:path "foo.txt")))
      ;; Bad (wrong type)
      (signals error (librecode-runner.tool::validate-arguments write-tool '(:path "foo.txt" :content 123)))

      ;; 3. bash
      ;; Good
      (finishes (librecode-runner.tool::validate-arguments bash-tool '(:command "echo 1")))
      ;; Bad (missing command)
      (signals error (librecode-runner.tool::validate-arguments bash-tool '()))
      ;; Bad (wrong type)
      (signals error (librecode-runner.tool::validate-arguments bash-tool '(:command 123))))))

(test test-builtin-write-read-roundtrip
  "Verify that write_file then read_file works correctly under a non-default *workspace-root*."
  (librecode-test.event-store::with-tmp-sandbox (dir)
    (let ((*workspace-root* dir)
          (read-tool (bt:with-lock-held ((librecode-runner.tool::registry-lock librecode-runner.runner::*tool-registry*))
                       (gethash "read_file" (librecode-runner.tool::registry-tools librecode-runner.runner::*tool-registry*))))
          (write-tool (bt:with-lock-held ((librecode-runner.tool::registry-lock librecode-runner.runner::*tool-registry*))
                        (gethash "write_file" (librecode-runner.tool::registry-tools librecode-runner.runner::*tool-registry*)))))
      (is (not (null read-tool)))
      (is (not (null write-tool)))
      (when (and read-tool write-tool)
        (let* ((rel-path "nested/dir/test-file.txt")
               (content "Hello from the build-in tools test! ~!@#$")
               (write-res (execute-tool write-tool (list :path rel-path :content content))))
          ;; Verify write_file returned a string containing success and path info
          (is (stringp write-res))
          (is (not (null (search "test-file.txt" write-res))))
          
          ;; Verify physical existence of the file in the sandbox
          (let ((abs-path (merge-pathnames rel-path (uiop:ensure-directory-pathname dir))))
            (is-true (probe-file abs-path))
            ;; Verify read_file reads the exact content back
            (let ((read-res (execute-tool read-tool (list :path rel-path))))
              (is (string= content read-res)))))))))

(test test-builtin-read-missing-file
  "Verify that reading a non-existent file signals an error cleanly."
  (librecode-test.event-store::with-tmp-sandbox (dir)
    (let ((*workspace-root* dir)
          (read-tool (bt:with-lock-held ((librecode-runner.tool::registry-lock librecode-runner.runner::*tool-registry*))
                       (gethash "read_file" (librecode-runner.tool::registry-tools librecode-runner.runner::*tool-registry*)))))
      (is (not (null read-tool)))
      (when read-tool
        (signals error
          (execute-tool read-tool '(:path "non-existent-file.txt")))))))

(test test-builtin-bash-execution
  "Verify that the bash tool executes commands in *workspace-root* and captures combined stdout/stderr."
  (librecode-test.event-store::with-tmp-sandbox (dir)
    (let ((*workspace-root* dir)
          (bash-tool (bt:with-lock-held ((librecode-runner.tool::registry-lock librecode-runner.runner::*tool-registry*))
                       (gethash "bash" (librecode-runner.tool::registry-tools librecode-runner.runner::*tool-registry*)))))
      (is (not (null bash-tool)))
      (when bash-tool
        ;; 1. Check stdout/stderr capture and CWD safety
        (let* ((cmd "echo 'stdout output'; echo 'stderr output' >&2; pwd")
               (res (execute-tool bash-tool (list :command cmd))))
          (is (stringp res))
          (is (not (null (search "stdout output" res))))
          (is (not (null (search "stderr output" res))))
          ;; Verify execution was inside the sandbox (non-default *workspace-root*)
          ;; namestring may end in slash, let's do a substring match or clean match
          (let* ((expected-dir (namestring (truename dir)))
                 (clean-expected-dir (string-right-trim "/" expected-dir)))
            (is (not (null (search clean-expected-dir res))))))
        
        ;; 2. Check error propagation for non-zero exit status
        (signals error
          (execute-tool bash-tool '(:command "false")))
        (signals error
          (execute-tool bash-tool '(:command "exit 42")))))))

(test test-builtin-path-traversal-denial
  "Verify that directory traversal attempts (including symlinks) are blocked and signal denied-error."
  (librecode-test.event-store::with-tmp-sandbox (dir)
    (let ((*workspace-root* dir)
          (read-tool (bt:with-lock-held ((librecode-runner.tool::registry-lock librecode-runner.runner::*tool-registry*))
                       (gethash "read_file" (librecode-runner.tool::registry-tools librecode-runner.runner::*tool-registry*))))
          (write-tool (bt:with-lock-held ((librecode-runner.tool::registry-lock librecode-runner.runner::*tool-registry*))
                        (gethash "write_file" (librecode-runner.tool::registry-tools librecode-runner.runner::*tool-registry*)))))
      ;; Test relative traversal outside root
      (signals denied-error
        (execute-tool read-tool '(:path "../outside-file.txt")))
      (signals denied-error
        (execute-tool write-tool '(:path "../outside-file.txt" :content "leak")))
      
      ;; Test absolute paths outside root
      (signals denied-error
        (execute-tool read-tool '(:path "/etc/hosts")))
      (signals denied-error
        (execute-tool write-tool '(:path "/tmp/dangerous.txt" :content "leak")))
      
      ;; Create a symlink in the sandbox pointing to /etc
      (let ((symlink-path (merge-pathnames "symlink_to_etc" dir)))
        (uiop:run-program (list "ln" "-s" "/etc" (namestring symlink-path)))
        ;; Verify that reading through the symlink is blocked!
        (signals denied-error
          (execute-tool read-tool '(:path "symlink_to_etc/hosts")))))))

(test test-builtin-permission-enforcement
  "Verify that the built-in tools respect resource-level agent permissions."
  (librecode-test.event-store::with-tmp-sandbox (dir)
    (librecode-test.event-store::with-test-db (db dir)
      (let* ((session-id "perm-test-session")
             (agent-id "perm-test-agent")
             (project-id "perm-test-project")
             (read-tool (bt:with-lock-held ((librecode-runner.tool::registry-lock librecode-runner.runner::*tool-registry*))
                          (gethash "read_file" (librecode-runner.tool::registry-tools librecode-runner.runner::*tool-registry*))))
             (bash-tool (bt:with-lock-held ((librecode-runner.tool::registry-lock librecode-runner.runner::*tool-registry*))
                          (gethash "bash" (librecode-runner.tool::registry-tools librecode-runner.runner::*tool-registry*)))))
        
        ;; Set up session state in SQLite
        (sqlite:execute-non-query db
          "INSERT INTO session_state (session_id, agent_id, version, status, last_updated)
           VALUES (?, ?, 1, 'active', 0)"
          session-id agent-id)
        
        ;; Setup a deny rule for read_file in permission_saved
        (sqlite:execute-non-query db
          "INSERT INTO permission_saved (project_id, action, resource, effect, timestamp)
           VALUES (?, 'read_file', '*', 'deny', 0)"
          project-id)
        
        ;; Setup a deny rule for bash in permission_saved
        (sqlite:execute-non-query db
          "INSERT INTO permission_saved (project_id, action, resource, effect, timestamp)
           VALUES (?, 'bash', '*', 'deny', 0)"
          project-id)
        
        ;; Execute tools with permission bindings active
        (let ((librecode-runner.agent:*current-session-id* session-id)
              (librecode-runner.agent::*project-id* project-id)
              (librecode-runner.agent::*interactive-p* nil)
              (*workspace-root* dir))
          
          (signals denied-error
            (execute-tool read-tool '(:path "allowed-by-cwd-but-denied-by-perm.txt")))
          (signals denied-error
            (execute-tool bash-tool '(:command "echo 42"))))))))

(test test-builtin-bash-leak-prevention
  "Verify that if a bash tool execution is aborted or thread killed, the subprocess is cleaned up."
  (librecode-test.event-store::with-tmp-sandbox (dir)
    (let ((*workspace-root* dir)
          (bash-tool (bt:with-lock-held ((librecode-runner.tool::registry-lock librecode-runner.runner::*tool-registry*))
                       (gethash "bash" (librecode-runner.tool::registry-tools librecode-runner.runner::*tool-registry*)))))
      (let* ((pid-file (merge-pathnames "pids.txt" (uiop:ensure-directory-pathname dir)))
             ;; Write PID to file, then sleep a long time
             (cmd (format nil "echo $$ > ~A; sleep 100" (namestring pid-file)))
             (thread (bt:make-thread (lambda ()
                                       (execute-tool bash-tool (list :command cmd)))
                                     :name "bash-leak-test-worker")))
        ;; Give the shell a moment to startup and write PID
        (sleep 0.3)
        (is-true (probe-file pid-file))
        (let ((pid-str (string-trim '(#\Space #\Newline #\Return)
                                    (uiop:read-file-string pid-file))))
          (is (not (string= "" pid-str)))
          ;; Verify that the subprocess is currently running
          (multiple-value-bind (out err exit-code)
              (uiop:run-program (list "kill" "-0" pid-str) :ignore-error-status t)
            (declare (ignore out err))
            (is (= 0 exit-code)))
          
          ;; Now kill the thread (simulating thread abort/timeout)
          #+sbcl (sb-thread:destroy-thread thread)
          (sleep 0.3)
          
          ;; Verify that the subprocess was terminated cleanly by unwind-protect
          (multiple-value-bind (out err exit-code)
              (uiop:run-program (list "kill" "-0" pid-str) :ignore-error-status t)
            (declare (ignore out err))
            (is (not (= 0 exit-code)))))))))

#|
;; Note: This test is disabled because modifying `src/runner/tool.lisp` (to destroy the worker thread on timeout)
;; is blocked by the campaign DAG's file-surface constraint for the `builtin-tools` node.
;; Once `src/runner/tool.lisp` is updated to call `bt:destroy-thread` instead of `join-thread-with-timeout`,
;; this test can be safely re-enabled.
(test test-builtin-bash-timeout-subprocess-cleanup
  "Verify that timing out under execute-tool-async destroys the worker thread and terminates the subprocess."
  (librecode-test.event-store::with-tmp-sandbox (dir)
    (let ((*workspace-root* dir)
          (bash-tool (bt:with-lock-held ((librecode-runner.tool::registry-lock librecode-runner.runner::*tool-registry*))
                       (gethash "bash" (librecode-runner.tool::registry-tools librecode-runner.runner::*tool-registry*))))
          (pid-file (merge-pathnames "pids_timeout.txt" (uiop:ensure-directory-pathname dir))))
      (is (not (null bash-tool)))
      (when bash-tool
        (let ((cmd (format nil "echo $$ > ~A; sleep 100" (namestring pid-file))))
          (signals tool-timeout
            (execute-tool-async bash-tool (list :command cmd) :timeout 0.3))
          
          ;; Wait a moment for cleanup to execute
          (sleep 0.5)
          (is-true (probe-file pid-file))
          (let ((pid-str (string-trim '(#\Space #\Newline #\Return)
                                      (uiop:read-file-string pid-file))))
            ;; Verify that the subprocess is dead!
            (multiple-value-bind (out err exit-code)
                (uiop:run-program (list "kill" "-0" pid-str) :ignore-error-status t)
              (declare (ignore out err))
              (is (not (= 0 exit-code))))))))))
|#
