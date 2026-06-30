;;; -*- Mode: Lisp; Syntax: Common-Lisp; indent-tabs-mode: nil; coding: utf-8; Show-Trailing-Whitespace: t -*-
;;;
;;; session-tests.lisp — Unit tests for runner session, run coordinator, SSE, and compaction
;;;

(defpackage #:librecode-test.session
  (:use #:cl
        #:fiveam
        #:librecode-runner.protocol
        #:librecode-runner.session
        #:librecode-runner.runner
        #:librecode-runner.compaction
        #:librecode-runner.event-store
        #:librecode-runner.conditions)
  (:export #:session-suite))

(in-package #:librecode-test.session)

(def-suite session-suite
  :description "Suite for session, run coordinator, input admission, SSE, and compaction tests.")

(in-suite session-suite)

(defun get-free-port ()
  "Generate a random port in user range."
  (+ 15000 (random 5000)))

;;; --- Tests ---

(test test-wake-coalescing
  "Verify that concurrent wakeups do not spawn duplicate draining threads and are serialized."
  (let ((active-threads 0)
        (max-active-threads 0)
        (run-count 0)
        (lock (bt:make-lock "coalesce-test-lock")))
    (flet ((drain-fn ()
             (bt:with-lock-held (lock)
               (incf active-threads)
               (setf max-active-threads (max max-active-threads active-threads))
               (incf run-count))
             (sleep 0.1)
             (bt:with-lock-held (lock)
               (decf active-threads))))
      ;; Wake the session initially
      (wake-session "session-coalesce" #'drain-fn)
      ;; Immediately issue multiple wakeups concurrently while it is executing
      (dotimes (i 15)
        (wake-session "session-coalesce" #'drain-fn))
      ;; Wait for execution passes to complete
      (sleep 1.0)
      ;; Verify that at no point were there more than 1 active threads draining the session
      (is (= 1 max-active-threads))
      ;; Verify that it actually executed at least once and coalesced most of them
      (is (>= run-count 1))
      (is (<= run-count 3)))))

(test test-two-phase-admission
  "Verify that admitted inputs are not visible in history until promoted."
  (librecode-test.event-store::with-tmp-sandbox (dir)
    (librecode-test.event-store::with-test-db (db dir)
      (let ((session-id "session-admission"))
        ;; Create the projected session state first
        (sqlite:execute-non-query db
          "INSERT INTO session_state (session_id, agent_id, version, status, last_updated)
           VALUES (?, ?, 1, 'active', ?)"
          session-id "agent-1" (librecode-runner.event-store::current-timestamp-ms))

        ;; 1. Admit a prompt
        (let ((status (admit-input session-id "prompt-1" "Hello model!" "STEER")))
          (is (eq :pending status)))

        ;; Verify it is PENDING in the database inbox
        (let ((db-status (sqlite:execute-single db "SELECT status FROM session_input WHERE id = ?" "prompt-1")))
          (is (equal "PENDING" db-status)))

        ;; Verify it is not yet visible in history
        (is (null (sqlite:execute-single db "SELECT id FROM session_history WHERE id = ?" "prompt-1")))

        ;; 2. Promote the prompt
        (let ((promoted-count (promote-pending-inputs session-id :mode :steer)))
          (is (= 1 promoted-count)))

        ;; Verify status is updated to PROMOTED
        (let ((db-status (sqlite:execute-single db "SELECT status FROM session_input WHERE id = ?" "prompt-1")))
          (is (equal "PROMOTED" db-status)))

        ;; Verify it is now visible in history
        (is (equal "Hello model!" (sqlite:execute-single db "SELECT content FROM session_history WHERE id = ?" "prompt-1")))))))

(test test-sse-parsing
  "Verify correct chunk-by-chunk extraction from a mocked SSE HTTP streaming server."
  (librecode-test.event-store::with-tmp-sandbox (dir)
    (librecode-test.event-store::with-test-db (db dir)
      (let* ((session-id "session-sse")
             (port (get-free-port))
             (acceptor (make-instance 'hunchentoot:easy-acceptor :port port)))
        ;; Create projected session state
        (sqlite:execute-non-query db
          "INSERT INTO session_state (session_id, agent_id, version, status, last_updated)
           VALUES (?, ?, 1, 'active', ?)"
          session-id "agent-1" (librecode-runner.event-store::current-timestamp-ms))

        ;; Set up custom local route dispatcher for SSE stream
        (let ((dispatcher (lambda (request)
                            (when (equal (hunchentoot:script-name request) "/stream")
                              (lambda ()
                                (setf (hunchentoot:content-type*) "text/event-stream")
                                (let ((stream (hunchentoot:send-headers)))
                                  (write-sequence (flexi-streams:string-to-octets (format nil "data: {\"choices\": [{\"delta\": {\"content\": \"Hello \"}}]}~%") :external-format :utf-8) stream)
                                  (force-output stream)
                                  (write-sequence (flexi-streams:string-to-octets (format nil "data: {\"choices\": [{\"delta\": {\"content\": \"world!\"}}]}~%") :external-format :utf-8) stream)
                                  (force-output stream)
                                  (write-sequence (flexi-streams:string-to-octets (format nil "data: [DONE]~%") :external-format :utf-8) stream)
                                  (force-output stream)
                                  ""))))))
          (push dispatcher hunchentoot:*dispatch-table*)
          (unwind-protect
               (progn
                 (hunchentoot:start acceptor)
                 (let ((librecode-runner.runner::*provider-url* (format nil "http://127.0.0.1:~A/stream" port))
                       (librecode-runner.protocol::*session-mailbox* (librecode-runner.protocol:make-mailbox)))
                   (execute-provider-turn session-id "mock-provider" "mock-model")
                   ;; Verify the assistant message was correctly compiled and saved in history
                   (let ((content (sqlite:execute-single db "SELECT content FROM session_history WHERE role = 'assistant'")))
                     (is (equal "Hello world!" content)))))
            (progn
              (hunchentoot:stop acceptor)
              (setf hunchentoot:*dispatch-table* (delete dispatcher hunchentoot:*dispatch-table*)))))))))

(test test-transaction-atomicity-rollback
  "Verify that if a projection fails inside commit-event, the entire event is rolled back."
  (librecode-test.event-store::with-tmp-sandbox (dir)
    (librecode-test.event-store::with-test-db (db dir)
      (let ((session-id "session-atomicity"))
        ;; Insert event sequence 1 successfully
        (commit-event session-id
                      '((:agent-id . "agent-good") (:status . "active"))
                      :test-event
                      1)
        (is (equal 1 (sqlite:execute-single db "SELECT sequence FROM event_log WHERE session_id = ?" session-id)))

        ;; Try to commit sequence 1 again (should fail with UNIQUE constraint on session_id + sequence)
        (handler-case
            (commit-event session-id
                          '((:agent-id . "agent-bad") (:status . "error"))
                          :test-event
                          1)
          (error () nil))

        ;; Verify that sequence 1 payload remains the good one (it was not modified/overwritten/partially applied)
        (let ((row (sqlite:execute-to-list db "SELECT payload FROM event_log WHERE session_id = ? AND sequence = 1" session-id)))
          (is-true row)
          (is-true (search "agent-good" (caar row))))))))

(test test-context-compaction
  "Verify that context compaction engine summarizes older history under token budget constraint."
  (librecode-test.event-store::with-tmp-sandbox (dir)
    (librecode-test.event-store::with-test-db (db dir)
      (let ((session-id "session-compact"))
        ;; Setup session state
        (sqlite:execute-non-query db
          "INSERT INTO session_state (session_id, agent_id, version, status, last_updated)
           VALUES (?, ?, 1, 'active', ?)"
          session-id "agent-1" (librecode-runner.event-store::current-timestamp-ms))

        ;; Commit a dummy session event to establish sequence 1
        (librecode-runner.event-store:commit-event
         session-id
         '((:agent-id . "agent-1"))
         :session-started
         1)

        ;; Insert 4 historical messages
        (sqlite:execute-non-query db
          "INSERT INTO session_history (id, session_id, role, content, created_at)
           VALUES (?, ?, 'user', 'Message number one', ?)"
          "msg-1" session-id 1000)
        (sqlite:execute-non-query db
          "INSERT INTO session_history (id, session_id, role, content, created_at)
           VALUES (?, ?, 'assistant', 'Message number two', ?)"
          "msg-2" session-id 2000)
        (sqlite:execute-non-query db
          "INSERT INTO session_history (id, session_id, role, content, created_at)
           VALUES (?, ?, 'user', 'Message number three', ?)"
          "msg-3" session-id 3000)
        (sqlite:execute-non-query db
          "INSERT INTO session_history (id, session_id, role, content, created_at)
           VALUES (?, ?, 'assistant', 'Message number four', ?)"
          "msg-4" session-id 4000)

        ;; Compact with max-tokens = 5.
        ;; Since keep-count keeps at least 2 messages (msg-3 and msg-4),
        ;; msg-1 and msg-2 will be compacted and deleted.
        (let ((compacted-p (compact-context session-id :max-tokens 5)))
          (is-true compacted-p))

        ;; Verify baseline is updated in context_epoch
        (let ((baseline (sqlite:execute-single db "SELECT baseline_text FROM context_epoch WHERE session_id = ?" session-id)))
          (is-true baseline)
          (is-true (search "Message number one" baseline))
          (is-true (search "Message number two" baseline))
          (is-false (search "Message number three" baseline))
          (is-false (search "Message number four" baseline)))

        ;; Verify that compacted messages are deleted from history but the recent ones remain
        (is (null (sqlite:execute-single db "SELECT id FROM session_history WHERE id = 'msg-1'")))
        (is (null (sqlite:execute-single db "SELECT id FROM session_history WHERE id = 'msg-2'")))
        (is (equal "msg-3" (sqlite:execute-single db "SELECT id FROM session_history WHERE id = 'msg-3'")))
        (is (equal "msg-4" (sqlite:execute-single db "SELECT id FROM session_history WHERE id = 'msg-4'")))

        ;; Verify context-baseline-updated event exists in event_log at sequence 2
        (is (equal "CONTEXT-BASELINE-UPDATED"
                   (sqlite:execute-single db "SELECT event_type FROM event_log WHERE session_id = ? AND sequence = 2" session-id)))))))
