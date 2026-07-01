;;; -*- Mode: Lisp; Syntax: Common-Lisp; indent-tabs-mode: nil; coding: utf-8; Show-Trailing-Whitespace: t -*-
;;;
;;; resilience-tests.lisp — Resilience and condition/restart recovery tests
;;;

(defpackage #:librecode-test.resilience
  (:use #:cl
        #:fiveam
        #:librecode-runner.runner
        #:librecode-runner.conditions
        #:librecode-runner.tool
        #:librecode-runner.event-store)
  (:export #:resilience-suite))

(in-package #:librecode-test.resilience)

(def-suite resilience-suite
  :description "Suite for condition/restart recovery and freeze-and-handshake tests.")

(in-suite resilience-suite)

(defun get-free-port ()
  "Generate a random port in user range."
  (+ 16000 (random 5000)))

(test test-compact-and-retry
  "Verify that context-overflow triggers compaction and retry."
  (librecode-test.event-store::with-tmp-sandbox (dir)
    (librecode-test.event-store::with-test-db (db dir)
      (let* ((session-id "sess-compact-retry")
             (port (get-free-port))
             (acceptor (make-instance 'hunchentoot:easy-acceptor :port port))
             (req-count 0)
             (dispatcher (lambda (request)
                           (when (equal (hunchentoot:script-name request) "/stream")
                             (lambda ()
                               (setf (hunchentoot:content-type*) "text/event-stream")
                               (incf req-count)
                               (let ((stream (hunchentoot:send-headers)))
                                 (if (= req-count 1)
                                     (write-sequence (flexi-streams:string-to-octets
                                                      (format nil "data: {\"error\": \"context_length_exceeded\"}~%")
                                                      :external-format :utf-8)
                                                     stream)
                                     (progn
                                       (write-sequence (flexi-streams:string-to-octets
                                                        (format nil "data: {\"choices\": [{\"delta\": {\"content\": \"Success!\"}}]}~%")
                                                        :external-format :utf-8)
                                                       stream)
                                       (write-sequence (flexi-streams:string-to-octets
                                                        (format nil "data: [DONE]~%")
                                                        :external-format :utf-8)
                                                       stream)))
                                 (force-output stream)
                                 ""))))))
        (sqlite:execute-non-query db
          "INSERT INTO session_state (session_id, agent_id, version, status, last_updated)
           VALUES (?, ?, 1, 'active', ?)"
          session-id "agent-1" (librecode-runner.event-store::current-timestamp-ms))
        
        ;; Populate history so compaction has enough data
        (dotimes (i 10)
          (let ((msg-id (format nil "msg-pre-~A" i))
                (now (librecode-runner.event-store::current-timestamp-ms)))
            (sqlite:execute-non-query db
              "INSERT INTO session_history (id, session_id, role, content, created_at)
               VALUES (?, ?, 'user', 'some long history message content here', ?)"
              msg-id session-id now)))

        (push dispatcher hunchentoot:*dispatch-table*)
        (unwind-protect
             (progn
               (hunchentoot:start acceptor)
               (let ((librecode-runner.runner::*provider-url* (format nil "http://127.0.0.1:~A/stream" port))
                     (librecode-runner.protocol::*session-mailbox* (librecode-runner.protocol:make-mailbox))
                     (overflow-caught nil))
                 (handler-bind
                     ((context-overflow
                        (lambda (c)
                          (declare (ignore c))
                          (setf overflow-caught t)
                          (invoke-restart 'compact-and-retry))))
                   (execute-provider-turn session-id "mock-provider" "mock-model"))
                 (is-true overflow-caught)
                 (is (= 2 req-count))
                 (let ((content (sqlite:execute-single db "SELECT content FROM session_history WHERE role = 'assistant'")))
                   (is (equal "Success!" content)))))
          (progn
            (hunchentoot:stop acceptor)
            (setf hunchentoot:*dispatch-table* (delete dispatcher hunchentoot:*dispatch-table*))))))))

(test test-backup-failover
  "Verify that provider-error triggers retry-with-backup-provider."
  (librecode-test.event-store::with-tmp-sandbox (dir)
    (librecode-test.event-store::with-test-db (db dir)
      (let* ((session-id "sess-backup-failover")
             (port1 (get-free-port))
             (port2 (get-free-port))
             (acceptor1 (make-instance 'hunchentoot:easy-acceptor :port port1))
             (acceptor2 (make-instance 'hunchentoot:easy-acceptor :port port2))
             (req1-count 0)
             (req2-count 0)
             (dispatcher1 (lambda (request)
                            (when (equal (hunchentoot:script-name request) "/stream1")
                              (lambda ()
                                (setf (hunchentoot:content-type*) "text/event-stream")
                                (incf req1-count)
                                (let ((stream (hunchentoot:send-headers)))
                                  (write-sequence (flexi-streams:string-to-octets
                                                   (format nil "data: {\"error\": \"Internal server error\"}~%")
                                                   :external-format :utf-8)
                                                  stream)
                                  (force-output stream)
                                  "")))))
             (dispatcher2 (lambda (request)
                            (when (equal (hunchentoot:script-name request) "/stream2")
                              (lambda ()
                                (setf (hunchentoot:content-type*) "text/event-stream")
                                (incf req2-count)
                                (let ((stream (hunchentoot:send-headers)))
                                  (write-sequence (flexi-streams:string-to-octets
                                                   (format nil "data: {\"choices\": [{\"delta\": {\"content\": \"Backup Success!\"}}]}~%")
                                                   :external-format :utf-8)
                                                  stream)
                                  (write-sequence (flexi-streams:string-to-octets
                                                   (format nil "data: [DONE]~%")
                                                   :external-format :utf-8)
                                                  stream)
                                  (force-output stream)
                                  ""))))))
        (sqlite:execute-non-query db
          "INSERT INTO session_state (session_id, agent_id, version, status, last_updated)
           VALUES (?, ?, 1, 'active', ?)"
          session-id "agent-1" (librecode-runner.event-store::current-timestamp-ms))
        (push dispatcher1 hunchentoot:*dispatch-table*)
        (push dispatcher2 hunchentoot:*dispatch-table*)
        (unwind-protect
             (progn
               (hunchentoot:start acceptor1)
               (hunchentoot:start acceptor2)
               (let ((librecode-runner.runner::*provider-url* (format nil "http://127.0.0.1:~A/stream1" port1))
                     (librecode-runner.runner::*backup-provider-url* (format nil "http://127.0.0.1:~A/stream2" port2))
                     (librecode-runner.protocol::*session-mailbox* (librecode-runner.protocol:make-mailbox))
                     (provider-error-caught nil))
                 (handler-bind
                     ((provider-error
                        (lambda (c)
                          (declare (ignore c))
                          (setf provider-error-caught t)
                          (invoke-restart 'retry-with-backup-provider))))
                   (execute-provider-turn session-id "mock-provider" "mock-model"))
                 (is-true provider-error-caught)
                 (is (= 1 req1-count))
                 (is (= 1 req2-count))
                 (let ((content (sqlite:execute-single db "SELECT content FROM session_history WHERE role = 'assistant'")))
                   (is (equal "Backup Success!" content)))))
          (progn
            (hunchentoot:stop acceptor1)
            (hunchentoot:stop acceptor2)
            (setf hunchentoot:*dispatch-table* (delete dispatcher1 hunchentoot:*dispatch-table*))
            (setf hunchentoot:*dispatch-table* (delete dispatcher2 hunchentoot:*dispatch-table*))))))))

(test test-no-unwind-handshake
  "Verify that a worker serious-condition is resolved on its own stack via handshake restarts."
  (librecode-test.event-store::with-tmp-sandbox (dir)
    (librecode-test.event-store::with-test-db (db dir)
      (let* ((session-id "sess-no-unwind")
             (port (get-free-port))
             (acceptor (make-instance 'hunchentoot:easy-acceptor :port port))
             (test-registry (make-instance 'tool-registry))
             (mock-tool (make-instance 'tool
                                       :name "mock_failing_tool"
                                       :description "Tool that fails to verify stack state in restart"
                                       :parameters nil
                                       :capabilities nil
                                       :handler (lambda (args)
                                                  (declare (ignore args))
                                                  (let ((*worker-marker* :active))
                                                    (error 'provider-error :message "Mock tool error")))))
             (dispatcher (lambda (request)
                           (when (equal (hunchentoot:script-name request) "/stream")
                             (lambda ()
                               (setf (hunchentoot:content-type*) "text/event-stream")
                               (let ((stream (hunchentoot:send-headers))
                                     (tool-call-payload "{\"id\": \"call-tool-123\", \"type\": \"function\", \"function\": {\"name\": \"mock_failing_tool\", \"arguments\": \"{}\"}}"))
                                 (write-sequence (flexi-streams:string-to-octets
                                                  (format nil "data: {\"choices\": [{\"delta\": {\"tool_calls\": [~A]}}]}~%" tool-call-payload)
                                                  :external-format :utf-8)
                                                 stream)
                                 (write-sequence (flexi-streams:string-to-octets
                                                  (format nil "data: [DONE]~%")
                                                  :external-format :utf-8)
                                                 stream)
                                 (force-output stream)
                                 ""))))))
        (register-tool test-registry mock-tool)
        (sqlite:execute-non-query db
          "INSERT INTO session_state (session_id, agent_id, version, status, last_updated)
           VALUES (?, ?, 1, 'active', ?)"
          session-id "agent-1" (librecode-runner.event-store::current-timestamp-ms))
        
        (sqlite:execute-non-query db
          "INSERT INTO permission_saved (project_id, action, resource, effect, timestamp)
           VALUES ('default', 'execute_tool', 'mock_failing_tool', 'allow', 123456)")

        (push dispatcher hunchentoot:*dispatch-table*)
        (unwind-protect
             (progn
               (hunchentoot:start acceptor)
               (let ((librecode-runner.runner::*provider-url* (format nil "http://127.0.0.1:~A/stream" port))
                     (librecode-runner.runner::*tool-registry* test-registry)
                     (librecode-runner.protocol::*session-mailbox* (librecode-runner.protocol:make-mailbox))
                     (worker-error-caught nil))
                 (handler-bind
                     ((provider-error
                        (lambda (c)
                          (declare (ignore c))
                          (setf worker-error-caught t)
                          (invoke-restart 'skip-and-continue))))
                   (execute-provider-turn session-id "mock-provider" "mock-model"))
                 (is-true worker-error-caught)
                 (let ((content (sqlite:execute-single db "SELECT content FROM session_history WHERE role = 'tool'")))
                   (is (equal "Marker active! No unwind!" content)))))
          (progn
            (hunchentoot:stop acceptor)
            (setf hunchentoot:*dispatch-table* (delete dispatcher hunchentoot:*dispatch-table*))))))))

(test test-worker-retry-tool
  "Verify that a worker serious-condition can be retried and successfully completes."
  (librecode-test.event-store::with-tmp-sandbox (dir)
    (librecode-test.event-store::with-test-db (db dir)
      (let* ((session-id "sess-worker-retry")
             (port (get-free-port))
             (acceptor (make-instance 'hunchentoot:easy-acceptor :port port))
             (test-registry (make-instance 'tool-registry))
             (call-count 0)
             (mock-tool (make-instance 'tool
                                       :name "mock_retryable_tool"
                                       :description "Tool that succeeds on second call"
                                       :parameters nil
                                       :capabilities nil
                                       :handler (lambda (args)
                                                  (declare (ignore args))
                                                  (incf call-count)
                                                  (if (= call-count 1)
                                                      (error 'provider-error :message "Mock tool error")
                                                      "Success on retry!"))))
             (dispatcher (lambda (request)
                           (when (equal (hunchentoot:script-name request) "/stream")
                             (lambda ()
                               (setf (hunchentoot:content-type*) "text/event-stream")
                               (let ((stream (hunchentoot:send-headers))
                                     (tool-call-payload "{\"id\": \"call-tool-456\", \"type\": \"function\", \"function\": {\"name\": \"mock_retryable_tool\", \"arguments\": \"{}\"}}"))
                                 (write-sequence (flexi-streams:string-to-octets
                                                  (format nil "data: {\"choices\": [{\"delta\": {\"tool_calls\": [~A]}}]}~%" tool-call-payload)
                                                  :external-format :utf-8)
                                                 stream)
                                 (write-sequence (flexi-streams:string-to-octets
                                                  (format nil "data: [DONE]~%")
                                                  :external-format :utf-8)
                                                 stream)
                                 (force-output stream)
                                 ""))))))
        (register-tool test-registry mock-tool)
        (sqlite:execute-non-query db
          "INSERT INTO session_state (session_id, agent_id, version, status, last_updated)
           VALUES (?, ?, 1, 'active', ?)"
          session-id "agent-1" (librecode-runner.event-store::current-timestamp-ms))
        
        (sqlite:execute-non-query db
          "INSERT INTO permission_saved (project_id, action, resource, effect, timestamp)
           VALUES ('default', 'execute_tool', 'mock_retryable_tool', 'allow', 123456)")

        (push dispatcher hunchentoot:*dispatch-table*)
        (unwind-protect
             (progn
               (hunchentoot:start acceptor)
               (let ((librecode-runner.runner::*provider-url* (format nil "http://127.0.0.1:~A/stream" port))
                     (librecode-runner.runner::*tool-registry* test-registry)
                     (librecode-runner.protocol::*session-mailbox* (librecode-runner.protocol:make-mailbox))
                     (worker-error-caught nil))
                 (handler-bind
                     ((provider-error
                        (lambda (c)
                          (declare (ignore c))
                          (setf worker-error-caught t)
                          (invoke-restart 'retry-tool))))
                   (execute-provider-turn session-id "mock-provider" "mock-model"))
                 (is-true worker-error-caught)
                 (is (= 2 call-count))
                 (let ((content (sqlite:execute-single db "SELECT content FROM session_history WHERE role = 'tool'")))
                   (is (equal "Success on retry!" content)))))
          (progn
            (hunchentoot:stop acceptor)
            (setf hunchentoot:*dispatch-table* (delete dispatcher hunchentoot:*dispatch-table*))))))))

(defvar *test-worker-thread* nil)

(test test-worker-handshake-abort
  "Verify that if the coordinator aborts during a worker error handshake, the worker exits immediately."
  (librecode-test.event-store::with-tmp-sandbox (dir)
    (librecode-test.event-store::with-test-db (db dir)
      (let* ((session-id "sess-worker-abort")
             (port (get-free-port))
             (acceptor (make-instance 'hunchentoot:easy-acceptor :port port))
             (test-registry (make-instance 'tool-registry))
             (mock-tool (make-instance 'tool
                                       :name "mock_abort_tool"
                                       :description "Tool that triggers handshake and waits for abort"
                                       :parameters nil
                                       :capabilities nil
                                       :handler (lambda (args)
                                                  (declare (ignore args))
                                                  (setf *test-worker-thread* (bt:current-thread))
                                                  (error 'provider-error :message "Mock tool error"))))
             (dispatcher (lambda (request)
                           (when (equal (hunchentoot:script-name request) "/stream")
                             (lambda ()
                               (setf (hunchentoot:content-type*) "text/event-stream")
                               (let ((stream (hunchentoot:send-headers))
                                     (tool-call-payload "{\"id\": \"call-tool-789\", \"type\": \"function\", \"function\": {\"name\": \"mock_abort_tool\", \"arguments\": \"{}\"}}"))
                                 (write-sequence (flexi-streams:string-to-octets
                                                  (format nil "data: {\"choices\": [{\"delta\": {\"tool_calls\": [~A]}}]}~%" tool-call-payload)
                                                  :external-format :utf-8)
                                                 stream)
                                 (write-sequence (flexi-streams:string-to-octets
                                                  (format nil "data: [DONE]~%")
                                                  :external-format :utf-8)
                                                 stream)
                                 (force-output stream)
                                 ""))))))
        (register-tool test-registry mock-tool)
        (sqlite:execute-non-query db
          "INSERT INTO session_state (session_id, agent_id, version, status, last_updated)
           VALUES (?, ?, 1, 'active', ?)"
          session-id "agent-1" (librecode-runner.event-store::current-timestamp-ms))
        
        (sqlite:execute-non-query db
          "INSERT INTO permission_saved (project_id, action, resource, effect, timestamp)
           VALUES ('default', 'execute_tool', 'mock_abort_tool', 'allow', 123456)")

        (push dispatcher hunchentoot:*dispatch-table*)
        (setf *test-worker-thread* nil)
        (unwind-protect
             (progn
               (hunchentoot:start acceptor)
               (let ((librecode-runner.runner::*provider-url* (format nil "http://127.0.0.1:~A/stream" port))
                     (librecode-runner.runner::*tool-registry* test-registry)
                     (librecode-runner.protocol::*session-mailbox* (librecode-runner.protocol:make-mailbox))
                     (aborted nil))
                 (catch 'abort-tag
                   (handler-bind
                       ((provider-error
                          (lambda (c)
                            (declare (ignore c))
                            (setf aborted t)
                            (throw 'abort-tag :aborted))))
                     (execute-provider-turn session-id "mock-provider" "mock-model")))
                 (is-true aborted)
                 ;; Wait a small amount of time for cleanup to finish
                 (sleep 0.1)
                 ;; Verify the worker thread was unregistered and has exited cleanly
                 (is (not (null *test-worker-thread*)))
                 (is (not (bt:thread-alive-p *test-worker-thread*)))))
          (progn
            (hunchentoot:stop acceptor)
            (setf hunchentoot:*dispatch-table* (delete dispatcher hunchentoot:*dispatch-table*))))))))

