;;; -*- Mode: Lisp; Syntax: Common-Lisp; indent-tabs-mode: nil; coding: utf-8; Show-Trailing-Whitespace: t -*-
;;;
;;; harness-tests.lisp — Unit tests for child harness interfaces
;;;

(defpackage #:librecode-test.harness
  (:use #:cl #:fiveam #:librecode-meta.harness #:librecode-meta.harness-librecode)
  (:export #:harness-suite))
(in-package #:librecode-test.harness)

(def-suite harness-suite :description "Test child harness management")
(in-suite harness-suite)

(defvar *mock-stream-mailbox* (sb-concurrency:make-mailbox))

(defun wait-for-harness-event (harness target-event-type &key (timeout 5.0))
  "Block until the target event type is received, or timeout occurs."
  (let ((start-time (get-universal-time)))
    (loop
      (let* ((elapsed (- (get-universal-time) start-time))
             (rem-timeout (max 0.1 (- timeout elapsed)))
             (msg (harness-read-event harness :timeout rem-timeout)))
        (cond
          ((null msg)
           (return nil))
          ((eq (getf msg :event-type) target-event-type)
           (return t))
          ((>= elapsed timeout)
           (return nil)))))))

(test test-harness-lifecycle
  "Exercises the abstract harness protocol on the in-process librecode-harness backend."
  (librecode-test.event-store::with-tmp-sandbox (dir)
    (let* ((repo-path dir)
           (target-dir (uiop:merge-pathnames* "target/" dir))
           (db-path "librecode.db")
           (session-id "test-lifecycle-session"))

      ;; 1. Prepare workspace
      (harness-prepare-workspace 'librecode-harness repo-path target-dir)

      ;; Drain any stale signal from a prior test before the mock stream can pause on it
      (loop while (sb-concurrency:receive-message-no-hang *mock-stream-mailbox*))

      ;; Mock stream: emits "Hello ", pauses mid-stream until the test thread
      ;; signals *mock-stream-mailbox*, then emits "world!" -- proves genuine
      ;; mid-turn interleaving rather than pre-scripted turns.
      (librecode-test.mock-provider:with-mock-provider
          (port :path "/stream"
                :responder (lambda (request call-index)
                             (declare (ignore request call-index))
                             (list (list :content "Hello ")
                                   (list :call (lambda () (sb-concurrency:receive-message *mock-stream-mailbox*)))
                                   (list :content "world!"))))
        (let* ((provider-url (format nil "http://127.0.0.1:~A/stream" port))
               (config (list :id session-id
                             :db-path db-path
                             :workspace-root target-dir
                             :provider "mock-provider"
                             :provider-url provider-url
                             :model "mock-model"
                             :max-steps 3))
               (librecode-runner.runner::*provider-url* provider-url)
               (harness (harness-spawn 'librecode-harness config)))

          (is (typep harness 'librecode-harness))
          (is (string= (harness-id harness) session-id))
          (is (equal (harness-config harness) config))

          ;; Status should initially be :idle
          (is (eq (harness-status harness) :idle))

          ;; 2. Prompt the harness
          (harness-prompt harness "hello test agent" :mode :steer)

          ;; Block until status is :running via :session-start event
          (is-true (wait-for-harness-event harness :session-start))
          (is (eq (harness-status harness) :running))

          ;; 3. Read events (verify event stream is accessible)
          (let ((msg (harness-read-event harness :timeout 0.1)))
            (declare (ignore msg)))

          ;; Signal mock stream to continue
          (sb-concurrency:send-message *mock-stream-mailbox* :continue)

          ;; Block until status goes back to :idle via :session-complete event
          (is-true (wait-for-harness-event harness :session-complete))
          (let ((thr (librecode-meta.harness-librecode::harness-thread harness)))
            (when thr
              (librecode-runner.protocol:join-thread-with-timeout thr 2.0)))
          (is (eq (harness-status harness) :idle))

          ;; 4. Terminate harness
          (harness-terminate harness)
          (sleep 0.1)
          (is (eq (harness-status harness) :terminated))

          ;; 5. Cleanup workspace
          (harness-cleanup-workspace 'librecode-harness repo-path target-dir :force t)
          (is (not (uiop:directory-exists-p target-dir))))))))

(test test-harness-cwd-safety
  "Verifies that running the harness in-process does not mutate the process-global CWD."
  (librecode-test.event-store::with-tmp-sandbox (dir)
    (let* ((repo-path dir)
           (target-dir (uiop:merge-pathnames* "target/" dir))
           (db-path "librecode.db")
           (session-id "test-cwd-session")
           (initial-cwd (uiop:getcwd)))

      (harness-prepare-workspace 'librecode-harness repo-path target-dir)

      (librecode-test.mock-provider:with-mock-provider
          (port :path "/stream"
                :responder (lambda (request call-index)
                             (declare (ignore request call-index))
                             (list (list :content "assert CWD"))))
        (let* ((provider-url (format nil "http://127.0.0.1:~A/stream" port))
               (config (list :id session-id
                             :db-path db-path
                             :workspace-root target-dir
                             :provider "mock-provider"
                             :provider-url provider-url
                             :model "mock-model"
                             :max-steps 1))
               (librecode-runner.runner::*provider-url* provider-url)
               (harness (harness-spawn 'librecode-harness config)))

          (harness-prompt harness "assert cwd" :mode :steer)
          (is-true (wait-for-harness-event harness :session-complete))
          (let ((thr (librecode-meta.harness-librecode::harness-thread harness)))
            (when thr
              (librecode-runner.protocol:join-thread-with-timeout thr 2.0)))

          ;; Check that global CWD has not changed
          (is (equal (namestring initial-cwd) (namestring (uiop:getcwd))))

          (harness-terminate harness))))))

(test test-harness-prompt-terminated-guard
  "Verifies that calling harness-prompt on a terminated harness signals a harness-failure error."
  (librecode-test.event-store::with-tmp-sandbox (dir)
    (let* ((repo-path dir)
           (target-dir (uiop:merge-pathnames* "target/" dir))
           (db-path "librecode.db")
           (session-id "test-guard-session")
           (config (list :id session-id
                         :db-path db-path
                         :workspace-root target-dir
                         :provider "mock-provider"
                         :model "mock-model"
                         :max-steps 1)))
      
      (harness-prepare-workspace 'librecode-harness repo-path target-dir)
      (let ((harness (harness-spawn 'librecode-harness config)))
        (unwind-protect
             (progn
               (harness-terminate harness)
               (is (eq (harness-status harness) :terminated))
               ;; Prompting a terminated harness should fail with harness-failure
               (signals librecode-runner.conditions:harness-failure
                 (harness-prompt harness "fail me" :mode :steer)))
          (harness-cleanup-workspace 'librecode-harness repo-path target-dir :force t))))))


