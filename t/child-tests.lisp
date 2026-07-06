;;; -*- Mode: Lisp; Syntax: Common-Lisp; indent-tabs-mode: nil; coding: utf-8; Show-Trailing-Whitespace: t -*-
;;;
;;; child-tests.lisp — Unit tests for child harness
;;;

(defpackage #:librecode-test.child
  (:use #:cl
        #:fiveam
        #:librecode-runner.child)
  (:export #:child-suite))

(in-package #:librecode-test.child)

(def-suite child-suite
  :description "Suite for child harness tests.")

(in-suite child-suite)

(test child-lifecycle-and-tool-execution
  "Tests the child entry point lifecycle and tool execution under subprocess-harness supervision."
  (librecode-test.event-store::with-tmp-sandbox (dir)
    (let* ((repo-path dir)
           (target-dir (uiop:merge-pathnames* "target/" dir))
           (db-path "librecode-child.db")
           (session-id "test-child-session")
           (test-file-path (uiop:merge-pathnames* "test-file.txt" target-dir)))

      (ensure-directories-exist target-dir)

      ;; 1. Spin up mock provider server: first turn returns a write_file tool
      ;; call, second turn returns completion text.
      (librecode-test.mock-provider:with-mock-provider
          (port :path "/stream/chat/completions"
                :responder (lambda (request call-index)
                             (declare (ignore request))
                             (if (= call-index 1)
                                 (list (list :tool-calls
                                             (list (list :id "call-1" :name "write_file"
                                                         :arguments "{\"path\": \"test-file.txt\", \"content\": \"hello child tool\"}"))))
                                 (list (list :content "Task complete.")))))
        (let* ((project-root (truename "./"))
               (raw-registry (uiop:getenv "CL_SOURCE_REGISTRY"))
               (paths (and raw-registry (uiop:split-string raw-registry :separator '(#\:))))
               (clean-paths (remove-if (lambda (p) (or (null p) (string= p ""))) paths))
               (directives (mapcar (lambda (p)
                                     (if (alexandria:ends-with-subseq "//" p)
                                         (list :tree (subseq p 0 (- (length p) 2)))
                                         (list :directory p)))
                                   clean-paths))
               (source-registry-sexpr (append (list :source-registry)
                                              directives
                                              (list :ignore-inherited-configuration)))
               (provider-url (format nil "http://127.0.0.1:~A/stream" port))
               (command (list "sbcl" "--noinform" "--non-interactive"
                              "--eval" "(require :sb-posix)"
                              "--eval" "(sb-posix:setenv \"CL_SOURCE_REGISTRY\" \"\" 1)"
                              "--eval" "(require :asdf)"
                              "--eval" (format nil "(asdf:initialize-source-registry '~S)" source-registry-sexpr)
                              "--eval" (format nil "(push (truename ~S) asdf:*central-registry*)" (namestring project-root))
                              "--eval" "(asdf:load-system :librecode-runner)"
                              "--eval" (format nil "(librecode-runner.child:run-child :workspace-root ~S :db-path ~S :provider-url ~S :model ~S :task ~S :session-id ~S)"
                                               (namestring target-dir) db-path provider-url "mock-model" "mock-task" session-id)))
               (config (list :id session-id
                             :workspace-root target-dir
                             :command command))
               (harness (librecode-meta.harness:harness-spawn 'librecode-meta.harness::subprocess-harness config)))

          (unwind-protect
               (progn
                 (is (typep harness 'librecode-meta.harness::subprocess-harness))
                 ;; Wait for events or status to become :idle (successful execution)
                 (let ((start-time (get-universal-time))
                       (timeout 15.0)
                       (landed-status nil))
                   (loop
                     (let* ((elapsed (- (get-universal-time) start-time))
                            (status (librecode-meta.harness:harness-status harness)))
                       (cond
                         ((member status '(:idle :error :terminated))
                          (setf landed-status status)
                          (return))
                         ((>= elapsed timeout)
                          (return))))
                     (sleep 0.1))
                   ;; The child must successfully run, execute the tool, and exit with status :idle
                   (unless (eq landed-status :idle)
                     (let ((events '()))
                       (loop
                         (let ((evt (librecode-meta.harness:harness-read-event harness :timeout 0.1)))
                           (if evt
                               (push evt events)
                               (return))))
                       (format t "~%--- Harness Exit Code: ~S, Error Message: ~S, Command: ~S, Received Events: ~S ---~%"
                               (librecode-meta.harness::harness-exit-code harness)
                               (librecode-meta.harness::harness-error-message harness)
                               command
                               (reverse events))))
                   (is (eq landed-status :idle))
                   ;; And the file must be produced in target-dir (c-real-tool-work)
                   (is-true (probe-file test-file-path))
                   (when (probe-file test-file-path)
                     (is (string= "hello child tool" (uiop:read-file-string test-file-path))))))
            (librecode-meta.harness:harness-terminate harness)))))))
