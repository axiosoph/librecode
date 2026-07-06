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
                              (gethash "bash" (librecode-runner.tool::registry-tools librecode-runner.runner::*tool-registry*))))
        (edit-tool-resolved (bt:with-lock-held ((librecode-runner.tool::registry-lock librecode-runner.runner::*tool-registry*))
                              (gethash "edit" (librecode-runner.tool::registry-tools librecode-runner.runner::*tool-registry*)))))
    (is (not (null read-tool)))
    (is (not (null write-tool)))
    (is (not (null bash-tool-resolved)))
    (is (not (null edit-tool-resolved)))
    (when (and read-tool write-tool bash-tool-resolved edit-tool-resolved)
      (is (string= "read_file" (tool-name read-tool)))
      (is (string= "write_file" (tool-name write-tool)))
      (is (string= "bash" (tool-name bash-tool-resolved)))
      (is (string= "edit" (tool-name edit-tool-resolved))))))

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

(test test-builtin-bash-timeout-subprocess-cleanup
  "Cooperative shutdown: timing out under execute-tool-async must terminate the
tool's subprocess (no orphan) rather than raw-killing the worker thread. A raw
bt:destroy-thread leaves the launched process orphaned and alive; cooperative
termination kills it, so `kill -0 pid` must report the process gone."
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

(test test-builtin-bash-no-stderr-deadlock
  "Regression for the two-pipe deadlock: a child that writes well past a pipe
buffer's worth of bytes to stderr before writing to stdout must not hang the
combined-output slurp. Bounded by join-thread-with-timeout so a real
regression fails this test instead of hanging the whole suite."
  (librecode-test.event-store::with-tmp-sandbox (dir)
    (let* ((*workspace-root* dir)
           (bash-tool (bt:with-lock-held ((librecode-runner.tool::registry-lock librecode-runner.runner::*tool-registry*))
                        (gethash "bash" (librecode-runner.tool::registry-tools librecode-runner.runner::*tool-registry*))))
           (result nil)
           (test-error nil)
           ;; Over 3x a typical 64KB pipe buffer, written to stderr before stdout.
           (cmd "(yes x | head -c 200000) >&2; echo done-stdout")
           (thread (bt:make-thread
                    (lambda ()
                      (handler-case
                          (setf result (execute-tool bash-tool (list :command cmd)))
                        (error (c) (setf test-error c))))
                    :name "bash-deadlock-regression")))
      (let ((join-result (librecode-runner.protocol:join-thread-with-timeout thread 10.0)))
        (is (not (eq join-result :timeout))
            "handle-bash deadlocked: a large stderr write blocked while stdout stayed open.")
        (is (null test-error) (format nil "unexpected error: ~A" test-error))
        (when result
          (is (not (null (search "done-stdout" result)))))))))

(test test-builtin-bash-own-timeout
  "handle-bash's own :timeout argument, on expiry, terminates the subprocess via
the existing cooperative-cancellation cleanup and settles as a tool-timeout
condition (never a raw thread kill). Run on a bounded thread so a red-phase
run (timeout not yet honored) fails fast instead of riding out the child's
full sleep."
  (librecode-test.event-store::with-tmp-sandbox (dir)
    (let* ((*workspace-root* dir)
           (bash-tool (bt:with-lock-held ((librecode-runner.tool::registry-lock librecode-runner.runner::*tool-registry*))
                        (gethash "bash" (librecode-runner.tool::registry-tools librecode-runner.runner::*tool-registry*))))
           (pid-file (merge-pathnames "pid_own_timeout.txt" (uiop:ensure-directory-pathname dir)))
           (cmd (format nil "echo $$ > ~A; sleep 5" (namestring pid-file)))
           (signaled-condition nil)
           (thread (bt:make-thread
                    (lambda ()
                      (handler-case
                          (execute-tool bash-tool (list :command cmd :timeout 0.3))
                        (condition (c) (setf signaled-condition c))))
                    :name "bash-own-timeout-test")))
      (let ((join-result (librecode-runner.protocol:join-thread-with-timeout thread 8.0)))
        (is (not (eq join-result :timeout))
            "handle-bash's :timeout did not settle within the bounded wait."))
      (is (typep signaled-condition 'tool-timeout)
          (format nil "expected a tool-timeout condition, got: ~A" signaled-condition))
      (sleep 0.5)
      (is-true (probe-file pid-file))
      (let ((pid-str (string-trim '(#\Space #\Newline #\Return)
                                  (uiop:read-file-string pid-file))))
        (multiple-value-bind (out err exit-code)
            (uiop:run-program (list "kill" "-0" pid-str) :ignore-error-status t)
          (declare (ignore out err))
          (is (not (= 0 exit-code))))))))

(test test-builtin-bash-output-cap
  "Combined output beyond the named cap constant is truncated with an explicit marker."
  (librecode-test.event-store::with-tmp-sandbox (dir)
    (let* ((*workspace-root* dir)
           (bash-tool (bt:with-lock-held ((librecode-runner.tool::registry-lock librecode-runner.runner::*tool-registry*))
                        (gethash "bash" (librecode-runner.tool::registry-tools librecode-runner.runner::*tool-registry*))))
           (cap librecode-runner.builtin-tools::*bash-output-cap-bytes*)
           (cmd (format nil "yes x | head -c ~D" (+ cap 1000))))
      (let ((res (execute-tool bash-tool (list :command cmd))))
        (is (<= (length res) (+ cap 200)))
        (is (not (null (search "truncated" res))))))))

(defun edit-tool% ()
  (bt:with-lock-held ((librecode-runner.tool::registry-lock librecode-runner.runner::*tool-registry*))
    (gethash "edit" (librecode-runner.tool::registry-tools librecode-runner.runner::*tool-registry*))))

(test test-builtin-edit-schema-field-names
  "Verify the edit tool's schema uses opencode's exact field names: filePath,
oldString, newString, and an optional replaceAll -- matching the shipped
opencode edit tool schema (workstream G seam compatibility)."
  (let* ((edit-tool (edit-tool%)))
    (is (not (null edit-tool)))
    (when edit-tool
      (let* ((schema (tool-parameters edit-tool))
             (properties (getf schema :properties))
             (required (coerce (getf schema :required) 'list)))
        (is (not (null (getf properties :filePath))))
        (is (not (null (getf properties :oldString))))
        (is (not (null (getf properties :newString))))
        (is (not (null (getf properties :replaceAll))))
        (is (not (null (member :filePath required))))
        (is (not (null (member :oldString required))))
        (is (not (null (member :newString required))))
        (is (null (member :replaceAll required)))))))

(test test-builtin-edit-basic-replacement
  "Verify a single exact-string match is replaced correctly."
  (librecode-test.event-store::with-tmp-sandbox (dir)
    (let ((*workspace-root* dir)
          (edit-tool (edit-tool%))
          (write-tool (bt:with-lock-held ((librecode-runner.tool::registry-lock librecode-runner.runner::*tool-registry*))
                        (gethash "write_file" (librecode-runner.tool::registry-tools librecode-runner.runner::*tool-registry*))))
          (read-tool (bt:with-lock-held ((librecode-runner.tool::registry-lock librecode-runner.runner::*tool-registry*))
                       (gethash "read_file" (librecode-runner.tool::registry-tools librecode-runner.runner::*tool-registry*)))))
      (is (not (null edit-tool)))
      (when (and edit-tool write-tool read-tool)
        (execute-tool write-tool (list :path "greeting.txt" :content "Hello, World!"))
        (let ((res (execute-tool edit-tool (list :filePath "greeting.txt" :oldString "World" :newString "Lisp"))))
          (is (stringp res)))
        (is (string= "Hello, Lisp!" (execute-tool read-tool (list :path "greeting.txt"))))))))

(test test-builtin-edit-zero-match-error
  "Verify that an oldString with no match in the file signals a distinguishable error."
  (librecode-test.event-store::with-tmp-sandbox (dir)
    (let ((*workspace-root* dir)
          (edit-tool (edit-tool%))
          (write-tool (bt:with-lock-held ((librecode-runner.tool::registry-lock librecode-runner.runner::*tool-registry*))
                        (gethash "write_file" (librecode-runner.tool::registry-tools librecode-runner.runner::*tool-registry*)))))
      (when (and edit-tool write-tool)
        (execute-tool write-tool (list :path "f.txt" :content "abc def"))
        (signals error
          (execute-tool edit-tool (list :filePath "f.txt" :oldString "zzz" :newString "yyy")))))))

(test test-builtin-edit-multiple-match-without-replaceall-error
  "Verify that more than one match without replaceAll signals a distinguishable error."
  (librecode-test.event-store::with-tmp-sandbox (dir)
    (let ((*workspace-root* dir)
          (edit-tool (edit-tool%))
          (write-tool (bt:with-lock-held ((librecode-runner.tool::registry-lock librecode-runner.runner::*tool-registry*))
                        (gethash "write_file" (librecode-runner.tool::registry-tools librecode-runner.runner::*tool-registry*))))
          (read-tool (bt:with-lock-held ((librecode-runner.tool::registry-lock librecode-runner.runner::*tool-registry*))
                       (gethash "read_file" (librecode-runner.tool::registry-tools librecode-runner.runner::*tool-registry*)))))
      (when (and edit-tool write-tool read-tool)
        (execute-tool write-tool (list :path "f.txt" :content "foo bar foo"))
        (signals error
          (execute-tool edit-tool (list :filePath "f.txt" :oldString "foo" :newString "baz")))
        ;; File must be untouched by the rejected edit.
        (is (string= "foo bar foo" (execute-tool read-tool (list :path "f.txt"))))))))

(test test-builtin-edit-replaceall
  "Verify replaceAll replaces every occurrence of oldString."
  (librecode-test.event-store::with-tmp-sandbox (dir)
    (let ((*workspace-root* dir)
          (edit-tool (edit-tool%))
          (write-tool (bt:with-lock-held ((librecode-runner.tool::registry-lock librecode-runner.runner::*tool-registry*))
                        (gethash "write_file" (librecode-runner.tool::registry-tools librecode-runner.runner::*tool-registry*))))
          (read-tool (bt:with-lock-held ((librecode-runner.tool::registry-lock librecode-runner.runner::*tool-registry*))
                       (gethash "read_file" (librecode-runner.tool::registry-tools librecode-runner.runner::*tool-registry*)))))
      (when (and edit-tool write-tool read-tool)
        (execute-tool write-tool (list :path "f.txt" :content "foo bar foo"))
        (finishes
          (execute-tool edit-tool (list :filePath "f.txt" :oldString "foo" :newString "baz" :replaceAll t)))
        (is (string= "baz bar baz" (execute-tool read-tool (list :path "f.txt"))))))))

(test test-builtin-edit-oldstring-equals-newstring-error
  "Verify oldString == newString is rejected before any file I/O."
  (librecode-test.event-store::with-tmp-sandbox (dir)
    (let ((*workspace-root* dir)
          (edit-tool (edit-tool%))
          (write-tool (bt:with-lock-held ((librecode-runner.tool::registry-lock librecode-runner.runner::*tool-registry*))
                        (gethash "write_file" (librecode-runner.tool::registry-tools librecode-runner.runner::*tool-registry*))))
          (read-tool (bt:with-lock-held ((librecode-runner.tool::registry-lock librecode-runner.runner::*tool-registry*))
                       (gethash "read_file" (librecode-runner.tool::registry-tools librecode-runner.runner::*tool-registry*)))))
      (when (and edit-tool write-tool read-tool)
        (execute-tool write-tool (list :path "f.txt" :content "unchanged content"))
        (signals error
          (execute-tool edit-tool (list :filePath "f.txt" :oldString "same" :newString "same")))
        (is (string= "unchanged content" (execute-tool read-tool (list :path "f.txt"))))))))

(test test-builtin-edit-nonexistent-file-error
  "Verify editing a nonexistent file signals a structured, distinguishable error
rather than a raw file-error condition."
  (librecode-test.event-store::with-tmp-sandbox (dir)
    (let ((*workspace-root* dir)
          (edit-tool (edit-tool%)))
      (when edit-tool
        (handler-case
            (progn
              (execute-tool edit-tool (list :filePath "does-not-exist.txt" :oldString "a" :newString "b"))
              (is nil "Expected an error to be signalled."))
          (error (c)
            (is (typep c 'simple-error))
            (is (not (null (search "not found" (princ-to-string c) :test #'char-equal))))))))))

(test test-builtin-edit-non-utf8-error
  "Verify editing a file with invalid UTF-8 content signals a structured error
rather than a raw stream-decoding condition escaping to the model."
  (librecode-test.event-store::with-tmp-sandbox (dir)
    (let ((*workspace-root* dir)
          (edit-tool (edit-tool%))
          (target (merge-pathnames "bad-utf8.txt" (uiop:ensure-directory-pathname dir))))
      (when edit-tool
        (with-open-file (stream target :direction :output :element-type '(unsigned-byte 8)
                                        :if-exists :supersede :if-does-not-exist :create)
          (write-byte #xFF stream)
          (write-byte #xFE stream)
          (write-byte #x00 stream))
        (handler-case
            (progn
              (execute-tool edit-tool (list :filePath "bad-utf8.txt" :oldString "a" :newString "b"))
              (is nil "Expected an error to be signalled."))
          (error (c)
            (is (typep c 'simple-error))))))))

(test test-builtin-edit-sandbox-denial
  "Verify directory traversal attempts (including symlinks) are blocked for edit,
identically to read_file/write_file, via the same resolve-safe-path."
  (librecode-test.event-store::with-tmp-sandbox (dir)
    (let ((*workspace-root* dir)
          (edit-tool (edit-tool%)))
      (when edit-tool
        (signals denied-error
          (execute-tool edit-tool (list :filePath "../outside-file.txt" :oldString "a" :newString "b")))
        (signals denied-error
          (execute-tool edit-tool (list :filePath "/etc/hosts" :oldString "a" :newString "b")))
        (let ((symlink-path (merge-pathnames "symlink_to_etc" dir)))
          (uiop:run-program (list "ln" "-s" "/etc" (namestring symlink-path)))
          (signals denied-error
            (execute-tool edit-tool (list :filePath "symlink_to_etc/hosts" :oldString "a" :newString "b"))))))))

(test test-builtin-edit-size-cap
  "Verify the 10MB size cap (matching read_file/write_file) applies to edit's
target file."
  (librecode-test.event-store::with-tmp-sandbox (dir)
    (let ((*workspace-root* dir)
          (edit-tool (edit-tool%))
          (target (merge-pathnames "huge.txt" (uiop:ensure-directory-pathname dir))))
      (when edit-tool
        (with-open-file (stream target :direction :output :element-type 'character
                                        :if-exists :supersede :if-does-not-exist :create
                                        :external-format :utf-8)
          (let ((chunk (make-string (* 1024 1024) :initial-element #\a)))
            (dotimes (i 11) (write-sequence chunk stream))))
        (signals error
          (execute-tool edit-tool (list :filePath "huge.txt" :oldString "a" :newString "b")))))))

;;; --- Regression tests for finding F20 (concurrent tool-call file races) ---
;;;
;;; execute-parallel-tools (runner.lisp) spawns one thread per tool_call in a
;;; turn with zero locking between them. edit is read-modify-write (read ->
;;; count -> compute -> write); two concurrent tool_calls resolving to the SAME
;;; path could previously interleave their read-modify-write sections and
;;; silently lose one side's change while both reported success. The fix adds
;;; a per-resolved-path lock (librecode-runner.tool:get-path-lock /
;;; with-path-lock) that read_file/write_file/edit each acquire for the
;;; duration of their file operation.

(test test-builtin-concurrent-same-path-serializes
  "Mechanism-level, deterministic proof of c10-same-path-serializes: a
write_file call against a path whose lock the test itself is holding must
block for as long as the lock is held, and complete only once it is
released. This proves write_file acquires the SAME per-path lock object
get-path-lock returns for that resolved path -- not merely that two calls
happen to finish eventually."
  (librecode-test.event-store::with-tmp-sandbox (dir)
    (let* ((*workspace-root* dir)
           (write-tool (bt:with-lock-held ((librecode-runner.tool::registry-lock librecode-runner.runner::*tool-registry*))
                         (gethash "write_file" (librecode-runner.tool::registry-tools librecode-runner.runner::*tool-registry*))))
           (rel-path "locked.txt")
           (abs-path (merge-pathnames rel-path (uiop:ensure-directory-pathname dir))))
      (is (not (null write-tool)))
      (when write-tool
        (execute-tool write-tool (list :path rel-path :content "original"))
        (let* ((resolved (librecode-runner.builtin-tools::resolve-safe-path rel-path))
               (path-lock (librecode-runner.tool:get-path-lock (namestring resolved)))
               (finished-p nil)
               (finished-lock (bt:make-lock "finished-lock"))
               (worker nil))
          (bt:acquire-lock path-lock)
          (unwind-protect
              (progn
                (setf worker
                      (bt:make-thread
                       (lambda ()
                         (let ((*workspace-root* dir))
                           (execute-tool write-tool (list :path rel-path :content "from-worker")))
                         (bt:with-lock-held (finished-lock) (setf finished-p t)))
                       :name "path-lock-blocking-test"))
                ;; Ample time for the worker to reach and block on the path lock.
                (sleep 0.3)
                (let ((still-blocked-p (not (bt:with-lock-held (finished-lock) finished-p))))
                  (is (eq t still-blocked-p)
                      "write_file completed while the test held the path lock for its resolved path -- write_file is not serializing on get-path-lock.")))
            (bt:release-lock path-lock))
          (when worker
            (let ((join-result (librecode-runner.protocol:join-thread-with-timeout worker 5.0)))
              (is (not (eq join-result :timeout))
                  "write_file never completed after the path lock was released."))
            (let ((finished-after-release-p (bt:with-lock-held (finished-lock) finished-p)))
              (is (eq t finished-after-release-p)))
            (is (string= "from-worker" (uiop:read-file-string abs-path)))))))))

(test test-builtin-concurrent-different-paths-not-serialized
  "c10-different-paths-unaffected: holding one path's lock must NOT block a
concurrent write_file call to a DIFFERENT path -- the lock is per-path, not a
single global mutex over all file tool calls."
  (librecode-test.event-store::with-tmp-sandbox (dir)
    (let* ((*workspace-root* dir)
           (write-tool (bt:with-lock-held ((librecode-runner.tool::registry-lock librecode-runner.runner::*tool-registry*))
                         (gethash "write_file" (librecode-runner.tool::registry-tools librecode-runner.runner::*tool-registry*))))
           (locked-rel-path "held.txt")
           (other-rel-path "unrelated.txt"))
      (is (not (null write-tool)))
      (when write-tool
        (execute-tool write-tool (list :path locked-rel-path :content "original"))
        (let* ((resolved (librecode-runner.builtin-tools::resolve-safe-path locked-rel-path))
               (path-lock (librecode-runner.tool:get-path-lock (namestring resolved))))
          (bt:acquire-lock path-lock)
          (unwind-protect
              (let ((worker (bt:make-thread
                             (lambda ()
                               (let ((*workspace-root* dir))
                                 (execute-tool write-tool (list :path other-rel-path :content "unrelated-content"))))
                             :name "different-path-not-blocked-test")))
                (let ((join-result (librecode-runner.protocol:join-thread-with-timeout worker 3.0)))
                  (is (not (eq join-result :timeout))
                      "write_file to a DIFFERENT path blocked while an unrelated path's lock was held -- the lock is not per-path.")))
            (bt:release-lock path-lock)))))))

(test test-builtin-concurrent-edit-edit-no-lost-write
  "Behavioral proof of c10-same-path-serializes for the exact scenario premise
p10-edit-is-read-modify-write names: two concurrent edit calls against the
same file, each targeting a disjoint substring. Without serialization, both
could read the same stale content and whichever writes last would silently
discard the other's replacement even though both report success. With the
per-path lock making each edit's read+write atomic, whichever edit runs
second always observes the first edit's already-applied change, so BOTH
replacements are present in the final content -- every iteration, not just
probabilistically. Repeated across many trials to make the pre-fix race
(narrow, timing-dependent) reliably surface if it still existed."
  (librecode-test.event-store::with-tmp-sandbox (dir)
    (let* ((*workspace-root* dir)
           (edit-tool (edit-tool%))
           (write-tool (bt:with-lock-held ((librecode-runner.tool::registry-lock librecode-runner.runner::*tool-registry*))
                         (gethash "write_file" (librecode-runner.tool::registry-tools librecode-runner.runner::*tool-registry*))))
           (read-tool (bt:with-lock-held ((librecode-runner.tool::registry-lock librecode-runner.runner::*tool-registry*))
                        (gethash "read_file" (librecode-runner.tool::registry-tools librecode-runner.runner::*tool-registry*))))
           (rel-path "race.txt")
           ;; Padding widens the window between each edit's read and write
           ;; (search/replace over more content takes measurably longer),
           ;; making the pre-fix race far more likely to actually trigger
           ;; across the trials below rather than relying on luck alone.
           (padding (make-string 200000 :initial-element #\x)))
      (is (not (null edit-tool)))
      (is (not (null write-tool)))
      (is (not (null read-tool)))
      (when (and edit-tool write-tool read-tool)
        (dotimes (trial 20)
          (execute-tool write-tool
                        (list :path rel-path
                              :content (format nil "MARKER_A ~A MARKER_B" padding)))
          (let* ((barrier-lock (bt:make-lock "race-barrier-lock"))
                 (ready-count 0)
                 (go-p nil)
                 (t1 (bt:make-thread
                      (lambda ()
                        (let ((*workspace-root* dir))
                          (bt:with-lock-held (barrier-lock) (incf ready-count))
                          (loop until (bt:with-lock-held (barrier-lock) go-p) do (sleep 0.001))
                          (execute-tool edit-tool (list :filePath rel-path :oldString "MARKER_A" :newString "REPLACED_A"))))
                      :name (format nil "race-a-~D" trial)))
                 (t2 (bt:make-thread
                      (lambda ()
                        (let ((*workspace-root* dir))
                          (bt:with-lock-held (barrier-lock) (incf ready-count))
                          (loop until (bt:with-lock-held (barrier-lock) go-p) do (sleep 0.001))
                          (execute-tool edit-tool (list :filePath rel-path :oldString "MARKER_B" :newString "REPLACED_B"))))
                      :name (format nil "race-b-~D" trial))))
            ;; Release both threads together once both have reached the gate,
            ;; so their edit calls genuinely overlap in time rather than
            ;; running sequentially by construction.
            (loop until (>= (bt:with-lock-held (barrier-lock) ready-count) 2) do (sleep 0.001))
            (bt:with-lock-held (barrier-lock) (setf go-p t))
            (let ((j1 (librecode-runner.protocol:join-thread-with-timeout t1 5.0))
                  (j2 (librecode-runner.protocol:join-thread-with-timeout t2 5.0)))
              (is (not (eq j1 :timeout)) (format nil "trial ~D: edit A never completed" trial))
              (is (not (eq j2 :timeout)) (format nil "trial ~D: edit B never completed" trial)))
            (let ((final (execute-tool read-tool (list :path rel-path))))
              (is (not (null (search "REPLACED_A" final)))
                  (format nil "trial ~D: edit A's replacement is missing from the final content -- a concurrent edit silently lost it." trial))
              (is (not (null (search "REPLACED_B" final)))
                  (format nil "trial ~D: edit B's replacement is missing from the final content -- a concurrent edit silently lost it." trial)))))))))

(test test-builtin-concurrent-edit-write-file-no-corruption
  "edit racing write_file: write_file is an unconditional overwrite by design,
so ordering between a concurrent edit and write_file is legitimately
ambiguous (last-to-commit wins, same as two racing write_file calls) -- that
is not the F20 bug. What the per-path lock must still guarantee is that
neither call's critical section ever interleaves with the other's: the
final content must always be one of the two fully-formed, non-corrupted
outcomes (edit's replacement applied on top of write_file's content, or
write_file's content with no trace of edit at all if write_file committed
last) -- never a torn hybrid produced by both writers' bytes interleaving."
  (librecode-test.event-store::with-tmp-sandbox (dir)
    (let* ((*workspace-root* dir)
           (edit-tool (edit-tool%))
           (write-tool (bt:with-lock-held ((librecode-runner.tool::registry-lock librecode-runner.runner::*tool-registry*))
                         (gethash "write_file" (librecode-runner.tool::registry-tools librecode-runner.runner::*tool-registry*))))
           (read-tool (bt:with-lock-held ((librecode-runner.tool::registry-lock librecode-runner.runner::*tool-registry*))
                        (gethash "read_file" (librecode-runner.tool::registry-tools librecode-runner.runner::*tool-registry*))))
           (rel-path "race-write-edit.txt")
           (padding (make-string 200000 :initial-element #\x))
           (write-content (format nil "MARKER_A ~A tail" padding))
           (edit-applied-content (format nil "REPLACED_A ~A tail" padding)))
      (is (not (null edit-tool)))
      (is (not (null write-tool)))
      (is (not (null read-tool)))
      (when (and edit-tool write-tool read-tool)
        (dotimes (trial 20)
          (execute-tool write-tool (list :path rel-path :content write-content))
          (let* ((barrier-lock (bt:make-lock "race-barrier-lock"))
                 (ready-count 0)
                 (go-p nil)
                 (tw (bt:make-thread
                      (lambda ()
                        (let ((*workspace-root* dir))
                          (bt:with-lock-held (barrier-lock) (incf ready-count))
                          (loop until (bt:with-lock-held (barrier-lock) go-p) do (sleep 0.001))
                          (execute-tool write-tool (list :path rel-path :content write-content))))
                      :name (format nil "race-write-~D" trial)))
                 (te (bt:make-thread
                      (lambda ()
                        (let ((*workspace-root* dir))
                          (bt:with-lock-held (barrier-lock) (incf ready-count))
                          (loop until (bt:with-lock-held (barrier-lock) go-p) do (sleep 0.001))
                          (handler-case
                              (execute-tool edit-tool (list :filePath rel-path :oldString "MARKER_A" :newString "REPLACED_A"))
                            ;; A clean, distinguishable error (e.g. write_file
                            ;; already ran and MARKER_A is gone) is an
                            ;; acceptable serialized outcome -- only silent
                            ;; corruption is not.
                            (error () nil))))
                      :name (format nil "race-edit-~D" trial))))
            (loop until (>= (bt:with-lock-held (barrier-lock) ready-count) 2) do (sleep 0.001))
            (bt:with-lock-held (barrier-lock) (setf go-p t))
            (let ((jw (librecode-runner.protocol:join-thread-with-timeout tw 5.0))
                  (je (librecode-runner.protocol:join-thread-with-timeout te 5.0)))
              (is (not (eq jw :timeout)) (format nil "trial ~D: write_file never completed" trial))
              (is (not (eq je :timeout)) (format nil "trial ~D: edit never completed" trial)))
            (let ((final (execute-tool read-tool (list :path rel-path))))
              (is (or (string= final write-content) (string= final edit-applied-content))
                  (format nil "trial ~D: final content is neither write_file's content nor edit-applied-on-top-of-it -- the writers' critical sections interleaved and corrupted the file." trial)))))))))
