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

(defun get-free-port ()
  "Find a free port on localhost."
  (let ((socket (usocket:socket-listen "127.0.0.1" 0)))
    (unwind-protect
         (usocket:get-local-port socket)
      (usocket:socket-close socket))))

(defvar *mock-stream-mailbox* (sb-concurrency:make-mailbox))

(test test-harness-lifecycle
  "Exercises the abstract harness protocol on the in-process librecode-harness backend."
  (librecode-test.event-store::with-tmp-sandbox (dir)
    (let* ((repo-path dir)
           (target-dir (uiop:merge-pathnames* "target/" dir))
           (db-path "librecode.db")
           (session-id "test-lifecycle-session")
           (port (get-free-port))
           (acceptor (make-instance 'hunchentoot:easy-acceptor :port port)))
      
      ;; Clear mailbox
      (loop while (sb-concurrency:receive-message-no-hang *mock-stream-mailbox*))
      
      ;; 1. Prepare workspace
      (harness-prepare-workspace 'librecode-harness repo-path target-dir)
      
      ;; Set up custom local route dispatcher for SSE stream
      (let ((dispatcher (lambda (request)
                          (when (equal (hunchentoot:script-name request) "/stream")
                            (lambda ()
                              (setf (hunchentoot:content-type*) "text/event-stream")
                              (let ((stream (hunchentoot:send-headers)))
                                (write-sequence (flexi-streams:string-to-octets (format nil "data: {\"choices\": [{\"delta\": {\"content\": \"Hello \"}}]}~%") :external-format :utf-8) stream)
                                (force-output stream)
                                ;; Wait for the test thread to signal us to continue
                                (sb-concurrency:receive-message *mock-stream-mailbox*)
                                (write-sequence (flexi-streams:string-to-octets (format nil "data: {\"choices\": [{\"delta\": {\"content\": \"world!\"}}]}~%") :external-format :utf-8) stream)
                                (force-output stream)
                                (write-sequence (flexi-streams:string-to-octets (format nil "data: [DONE]~%") :external-format :utf-8) stream)
                                (force-output stream)
                                ""))))))
        (push dispatcher hunchentoot:*dispatch-table*)
        (unwind-protect
             (progn
               (hunchentoot:start acceptor)
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
                 
                 ;; Loop/poll until status is :running
                 (let ((status-ok nil))
                   (dotimes (i 100)
                     (when (eq (harness-status harness) :running)
                       (setf status-ok t)
                       (return))
                     (sleep 0.01))
                   (is-true status-ok))
                 
                 ;; 3. Read events (verify event stream is accessible)
                 (let ((events (harness-read-events harness))
                       (has-events nil))
                   (is (not (null events)))
                   ;; Try reading a message from mailbox
                   (let ((msg (sb-concurrency:receive-message events :timeout 1.0)))
                     (when msg
                       (setf has-events t)))
                   (is-true has-events))
                 
                 ;; Signal mock stream to continue
                 (sb-concurrency:send-message *mock-stream-mailbox* :continue)
                 
                 ;; Loop/poll until status goes back to :idle
                 (let ((idle-ok nil))
                   (dotimes (i 100)
                     (when (eq (harness-status harness) :idle)
                       (setf idle-ok t)
                       (return))
                     (sleep 0.01))
                   (is-true idle-ok))
                 
                 ;; 4. Terminate harness
                 (harness-terminate harness)
                 (sleep 0.1)
                 (is (eq (harness-status harness) :terminated))
                 
                 ;; 5. Cleanup workspace
                 (harness-cleanup-workspace 'librecode-harness repo-path target-dir :force t)
                 (is (not (uiop:directory-exists-p target-dir)))))
          (progn
            (hunchentoot:stop acceptor)
            (setf hunchentoot:*dispatch-table* (delete dispatcher hunchentoot:*dispatch-table*))))))))

(test test-harness-cwd-safety
  "Verifies that running the harness in-process does not mutate the process-global CWD."
  (librecode-test.event-store::with-tmp-sandbox (dir)
    (let* ((repo-path dir)
           (target-dir (uiop:merge-pathnames* "target/" dir))
           (db-path "librecode.db")
           (session-id "test-cwd-session")
           (initial-cwd (uiop:getcwd))
           (port (get-free-port))
           (acceptor (make-instance 'hunchentoot:easy-acceptor :port port)))
      
      (harness-prepare-workspace 'librecode-harness repo-path target-dir)
      
      ;; Set up custom local route dispatcher for SSE stream
      (let ((dispatcher (lambda (request)
                          (when (equal (hunchentoot:script-name request) "/stream")
                            (lambda ()
                              (setf (hunchentoot:content-type*) "text/event-stream")
                              (let ((stream (hunchentoot:send-headers)))
                                (write-sequence (flexi-streams:string-to-octets (format nil "data: {\"choices\": [{\"delta\": {\"content\": \"assert CWD\"}}]}~%") :external-format :utf-8) stream)
                                (force-output stream)
                                (write-sequence (flexi-streams:string-to-octets (format nil "data: [DONE]~%") :external-format :utf-8) stream)
                                (force-output stream)
                                ""))))))
        (push dispatcher hunchentoot:*dispatch-table*)
        (unwind-protect
             (progn
               (hunchentoot:start acceptor)
               (let* ((provider-url (format nil "http://127.0.0.1:~A/stream" port))
                      (config (list :id session-id
                                    :db-path db-path
                                    :workspace-root target-dir
                                    :provider "mock-provider"
                                    :model "mock-model"
                                    :max-steps 1))
                      (librecode-runner.runner::*provider-url* provider-url)
                      (harness (harness-spawn 'librecode-harness config)))
                 
                 (harness-prompt harness "assert cwd" :mode :steer)
                 (sleep 0.2)
                 
                 ;; Check that global CWD has not changed
                 (is (equal (namestring initial-cwd) (namestring (uiop:getcwd))))
                 
                 (harness-terminate harness)))
          (progn
            (hunchentoot:stop acceptor)
            (setf hunchentoot:*dispatch-table* (delete dispatcher hunchentoot:*dispatch-table*))))))))


