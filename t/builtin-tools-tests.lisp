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
