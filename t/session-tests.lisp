;;; -*- Mode: Lisp; Syntax: Common-Lisp; indent-tabs-mode: nil; coding: utf-8; Show-Trailing-Whitespace: t -*-
;;;
;;; session-tests.lisp — Unit tests for runner session, run coordinator, SSE, and compaction
;;;

(defpackage #:librecode-test.session
  (:use #:cl
        #:fiveam
        #:check-it
        #:librecode-runner.protocol
        #:librecode-runner.session
        #:librecode-runner.runner
        #:librecode-runner.compaction
        #:librecode-runner.event-store
        #:librecode-runner.conditions)
  (:shadowing-import-from #:check-it #:*num-trials*)
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

(test test-compaction-replayability
  "Verify that replaying a compaction event from sequence 0 reproduces the identical database state."
  (librecode-test.event-store::with-tmp-sandbox (dir)
    ;; Create two separate test databases (db1 and db2) in the same sandbox
    (let ((db1-path (merge-pathnames "db1.sqlite" dir))
          (db2-path (merge-pathnames "db2.sqlite" dir))
          (session-id "session-replay"))
      (sqlite:with-open-database (db1 db1-path)
        (init-db db1)
        ;; Setup session state in db1
        (sqlite:execute-non-query db1
          "INSERT INTO session_state (session_id, agent_id, version, status, last_updated)
           VALUES (?, ?, 1, 'active', ?)"
          session-id "agent-1" (librecode-runner.event-store::current-timestamp-ms))
        ;; Commit a dummy session started event to establish sequence 1
        (let ((*db* db1))
          (declare (special *db*))
          (commit-event session-id '((:agent-id . "agent-1")) :session-started 1))
        ;; Insert 4 historical messages in db1
        (sqlite:execute-non-query db1
          "INSERT INTO session_history (id, session_id, role, content, created_at)
           VALUES (?, ?, 'user', 'Message number one', ?)"
          "msg-1" session-id 1000)
        (sqlite:execute-non-query db1
          "INSERT INTO session_history (id, session_id, role, content, created_at)
           VALUES (?, ?, 'assistant', 'Message number two', ?)"
          "msg-2" session-id 2000)
        (sqlite:execute-non-query db1
          "INSERT INTO session_history (id, session_id, role, content, created_at)
           VALUES (?, ?, 'user', 'Message number three', ?)"
          "msg-3" session-id 3000)
        (sqlite:execute-non-query db1
          "INSERT INTO session_history (id, session_id, role, content, created_at)
           VALUES (?, ?, 'assistant', 'Message number four', ?)"
          "msg-4" session-id 4000)

        ;; Compact in db1 with max-tokens = 5.
        (let ((*db* db1))
          (declare (special *db*))
          (compact-context session-id :max-tokens 5))

        ;; Extract final database state of db1
        (let* ((db1-session-state (sqlite:execute-to-list db1 "SELECT version, status FROM session_state WHERE session_id = ?" session-id))
               (db1-context-epoch (sqlite:execute-to-list db1 "SELECT epoch_id, baseline_text FROM context_epoch WHERE session_id = ?" session-id))
               (db1-history (sqlite:execute-to-list db1 "SELECT id, role, content FROM session_history WHERE session_id = ? ORDER BY created_at ASC" session-id))
               (db1-events (sqlite:execute-to-list db1 "SELECT sequence, event_type, payload FROM event_log WHERE session_id = ? ORDER BY sequence ASC" session-id)))

          ;; Initialize db2
          (sqlite:with-open-database (db2 db2-path)
            (init-db db2)
            ;; Insert the identical initial 4 historical messages in db2
            (sqlite:execute-non-query db2
              "INSERT INTO session_history (id, session_id, role, content, created_at)
               VALUES (?, ?, 'user', 'Message number one', ?)"
              "msg-1" session-id 1000)
            (sqlite:execute-non-query db2
              "INSERT INTO session_history (id, session_id, role, content, created_at)
               VALUES (?, ?, 'assistant', 'Message number two', ?)"
              "msg-2" session-id 2000)
            (sqlite:execute-non-query db2
              "INSERT INTO session_history (id, session_id, role, content, created_at)
               VALUES (?, ?, 'user', 'Message number three', ?)"
              "msg-3" session-id 3000)
            (sqlite:execute-non-query db2
              "INSERT INTO session_history (id, session_id, role, content, created_at)
               VALUES (?, ?, 'assistant', 'Message number four', ?)"
              "msg-4" session-id 4000)

            ;; Replay the events from db1 onto db2 using apply-projectors
            (dolist (evt db1-events)
              (let ((seq (first evt))
                    (type-str (second evt))
                    (payload (third evt)))
                ;; We insert the event into db2's event_log first to replicate event logs
                (sqlite:execute-non-query db2
                  "INSERT INTO event_log (session_id, sequence, event_type, payload, timestamp)
                   VALUES (?, ?, ?, ?, ?)"
                  session-id seq type-str payload (librecode-runner.event-store::current-timestamp-ms))
                ;; Apply projection onto db2
                (apply-projectors db2 session-id payload type-str seq)))

            ;; Extract final database state of db2
            (let ((db2-session-state (sqlite:execute-to-list db2 "SELECT version, status FROM session_state WHERE session_id = ?" session-id))
                  (db2-context-epoch (sqlite:execute-to-list db2 "SELECT epoch_id, baseline_text FROM context_epoch WHERE session_id = ?" session-id))
                  (db2-history (sqlite:execute-to-list db2 "SELECT id, role, content FROM session_history WHERE session_id = ? ORDER BY created_at ASC" session-id)))

              ;; Assert that final states are identical
              (is (equalp db1-session-state db2-session-state))
              (is (equalp db1-context-epoch db2-context-epoch))
              (is (equalp db1-history db2-history)))))))))

(test test-worker-thread-termination
  "Assert that worker threads are terminated when the session coordinator is aborted/interrupted."
  (let* ((session-id "session-terminate-test")
         (worker-thread nil)
         (drain-fn (lambda ()
                     ;; Spawn a worker thread and block on mailbox
                      (bt:make-thread
                       (lambda ()
                         (let ((this (bt:current-thread)))
                           (setf worker-thread this)
                           (librecode-runner.protocol:register-worker-thread session-id this)
                           (unwind-protect
                               (loop until (librecode-runner.protocol:session-stopping-p session-id)
                                     do (sleep 0.1))
                             (librecode-runner.protocol:unregister-worker-thread session-id this))))
                       :name "mock-infinite-worker")
                     (loop
                       (let ((msg (librecode-runner.protocol:receive-message librecode-runner.protocol:*session-mailbox*)))
                         (when (eq (car msg) :interrupt)
                           (error "Interrupted!")))))))
    ;; Spawn the coordinator
    (let ((coord-thread (bt:make-thread
                         (lambda ()
                           (handler-case
                               (run-coordinator session-id drain-fn)
                             (error () nil)))
                         :name "coordinator-terminate-test-thread")))
      ;; Wait for coordinator to start and spawn the worker thread
      (loop repeat 10
            while (null worker-thread)
            do (sleep 0.1))
      (is-true worker-thread)
      (is-true (bt:thread-alive-p worker-thread))
      ;; Interrupt the session
      (interrupt-session session-id)
      ;; Wait for cleanup to finish
      (sleep 0.5)
      ;; Verify coordinator and worker thread are dead
      (is-false (bt:thread-alive-p coord-thread))
      (is-false (bt:thread-alive-p worker-thread)))))

(test test-sequential-turns-no-contamination
  "Run two sequential execution turns where the first turn simulates an SSE stream error, verifying that the second turn executes cleanly without mailbox contamination."
  (librecode-test.event-store::with-tmp-sandbox (dir)
    (librecode-test.event-store::with-test-db (db dir)
      (let* ((session-id "session-sequential")
             (port (get-free-port))
             (acceptor (make-instance 'hunchentoot:easy-acceptor :port port))
             (request-count 0))
        ;; Create projected session state
        (sqlite:execute-non-query db
          "INSERT INTO session_state (session_id, agent_id, version, status, last_updated)
           VALUES (?, ?, 1, 'active', ?)"
          session-id "agent-1" (librecode-runner.event-store::current-timestamp-ms))

        ;; Set up custom local route dispatcher
        (let ((dispatcher (lambda (request)
                            (when (equal (hunchentoot:script-name request) "/stream")
                              (lambda ()
                                (incf request-count)
                                (setf (hunchentoot:content-type*) "text/event-stream")
                                (let ((stream (hunchentoot:send-headers)))
                                  (cond
                                    ((= request-count 1)
                                     ;; First turn: send some data, then send error JSON, followed by more data to guarantee mailbox contamination
                                     (write-sequence (flexi-streams:string-to-octets (format nil "data: {\"choices\": [{\"delta\": {\"content\": \"Stale data\"}}]}~%") :external-format :utf-8) stream)
                                     (force-output stream)
                                     (write-sequence (flexi-streams:string-to-octets (format nil "data: {\"error\": \"Simulated stream error\"}~%") :external-format :utf-8) stream)
                                     (force-output stream)
                                     (write-sequence (flexi-streams:string-to-octets (format nil "data: {\"choices\": [{\"delta\": {\"content\": \"More stale data\"}}]}~%") :external-format :utf-8) stream)
                                     (force-output stream)
                                     "")
                                    (t
                                     ;; Second turn: send clean data
                                     (write-sequence (flexi-streams:string-to-octets (format nil "data: {\"choices\": [{\"delta\": {\"content\": \"Hello \"}}]}~%") :external-format :utf-8) stream)
                                     (force-output stream)
                                     (write-sequence (flexi-streams:string-to-octets (format nil "data: {\"choices\": [{\"delta\": {\"content\": \"world!\"}}]}~%") :external-format :utf-8) stream)
                                     (force-output stream)
                                     (write-sequence (flexi-streams:string-to-octets (format nil "data: [DONE]~%") :external-format :utf-8) stream)
                                     (force-output stream)
                                     ""))))))))
          (push dispatcher hunchentoot:*dispatch-table*)
          (hunchentoot:start acceptor)
          (unwind-protect
               (let ((librecode-runner.runner::*provider-url* (format nil "http://127.0.0.1:~A/stream" port)))
                 ;; Bind session mailbox dynamically
                 (let ((mbox (librecode-runner.protocol:make-mailbox :name "test-seq-mbox")))
                   (let ((librecode-runner.protocol:*session-mailbox* mbox))
                     ;; First turn: should fail with provider-error
                     (signals provider-error
                       (execute-provider-turn session-id "mock-provider" "mock-model"))
                     
                     ;; Manually push a stale message to simulate mailbox contamination
                     (librecode-runner.protocol:send-message mbox '(:sse-line :stale-rid "data: {\"choices\": [{\"delta\": {\"content\": \"Stale data\"}}]}"))
                     
                     ;; Second turn: should succeed because it flushes the mailbox first
                     (execute-provider-turn session-id "mock-provider" "mock-model")
                     
                     ;; Verify assistant message has correct content from second turn only (stale content is discarded)
                     (let ((content (sqlite:execute-single db "SELECT content FROM session_history WHERE role = 'assistant'")))
                       (is (equal "Hello world!" content))))))
            (progn
              (hunchentoot:stop acceptor)
              (setf hunchentoot:*dispatch-table* (delete dispatcher hunchentoot:*dispatch-table*)))))))))

(test test-session-permission-asked-event-logging
  "Assert that interactive permission check triggers :event-permission-asked and logs to event_log."
  (librecode-test.event-store::with-tmp-sandbox (dir)
    (librecode-test.event-store::with-test-db (db dir)
      (let* ((session-id "session-permission-test")
             (agent-id "agent-permission-test")
             (action "execute_tool")
             (resource "shell_command")
             (req-id nil)
             (bound-session-id nil)
             (ruleset (list (librecode-runner.agent:make-permission-rule :action "*" :resource "*" :effect :ask)))
             (agent (make-instance 'librecode-runner.agent:agent
                                   :id agent-id
                                   :ruleset ruleset
                                   :system-context ""))
             (drain-fn (lambda ()
                         (setf bound-session-id (and (boundp 'librecode-runner.agent:*current-session-id*)
                                                     librecode-runner.agent:*current-session-id*))
                         (librecode-runner.agent:check-permission agent action resource))))
        
        ;; Clear any existing pending requests
        (bt:with-lock-held (librecode-runner.agent::*pending-requests-lock*)
          (clrhash librecode-runner.agent::*pending-requests*))

        ;; Initialize projected session state
        (sqlite:execute-non-query db
          "INSERT INTO session_state (session_id, agent_id, version, status, last_updated)
           VALUES (?, ?, 1, 'active', ?)"
          session-id agent-id (librecode-runner.event-store::current-timestamp-ms))

        (let* ((librecode-runner.agent:*interactive-p* t)
               (coord-thread (bt:make-thread
                              (lambda ()
                                (let ((librecode-runner.event-store:*db* db)
                                      (librecode-runner.agent:*interactive-p* t))
                                  (declare (special librecode-runner.event-store:*db*
                                                    librecode-runner.agent:*interactive-p*))
                                  (run-coordinator session-id drain-fn)))
                              :name "coordinator-permission-test")))
          
          ;; Wait for request to register in *pending-requests*
          (loop repeat 20
                while (= (hash-table-count librecode-runner.agent::*pending-requests*) 0)
                do (sleep 0.05))

          ;; Retrieve the pending request ID
          (setf req-id (let ((keys nil))
                         (bt:with-lock-held (librecode-runner.agent::*pending-requests-lock*)
                           (maphash (lambda (k v)
                                      (declare (ignore v))
                                      (push k keys))
                                    librecode-runner.agent::*pending-requests*))
                         (first keys)))
          (is-true req-id)

          ;; Resolve the pending request to :allow
          (librecode-runner.agent:resolve-permission-request req-id :allow)

          ;; Wait for coordinator thread to finish
          (loop repeat 20
                while (bt:thread-alive-p coord-thread)
                do (sleep 0.05))

          ;; Assert that *current-session-id* inside the run loop was correctly bound
          (is (equal session-id bound-session-id))

          ;; Assert that the event was logged to SQLite event_log
          (let* ((event-row (sqlite:execute-to-list db
                             "SELECT event_type, payload, sequence FROM event_log WHERE session_id = ? ORDER BY sequence DESC LIMIT 1"
                             session-id))
                 (first-row (first event-row))
                 (event-type (first first-row))
                 (payload-str (second first-row))
                 (seq (third first-row)))
            (is (equal "EVENT-PERMISSION-ASKED" event-type))
            (is (equal 1 seq))
            (let ((payload (com.inuoe.jzon:parse payload-str)))
              (is (equal req-id (gethash "req-id" payload)))
              (is (equal action (gethash "action" payload)))
              (is (equal resource (gethash "resource" payload)))
              (is (equal "asked" (gethash "status" payload))))))))))

(test test-parallel-tool-context-propagation
  "Verify that tool workers executed via execute-parallel-tools inherit *db*, *workspace-root*, etc. and can write events/query db."
  (librecode-test.event-store::with-tmp-sandbox (dir)
    (librecode-test.event-store::with-test-db (db dir)
      (let* ((session-id "session-parallel-context-test")
             (agent-id "agent-parallel-context")
             (registry (make-instance 'librecode-runner.tool:tool-registry))
             (captured-db nil)
             (captured-workspace nil)
             (captured-session nil)
             (captured-mailbox nil)
             (test-tool (make-instance 'librecode-runner.tool:tool
                                       :name "db-checking-tool"
                                       :description "Checks if db binding is inherited"
                                       :parameters '(:type "object" :properties (:dummy (:type "string")))
                                       :capabilities nil
                                       :handler (lambda (args)
                                                  (declare (ignore args))
                                                  (setf captured-db (and (boundp 'librecode-runner.event-store:*db*)
                                                                         librecode-runner.event-store:*db*))
                                                  (setf captured-workspace (and (boundp 'librecode-runner.event-store:*workspace-root*)
                                                                                librecode-runner.event-store:*workspace-root*))
                                                  (setf captured-session (and (boundp 'librecode-runner.agent:*current-session-id*)
                                                                              librecode-runner.agent:*current-session-id*))
                                                  (setf captured-mailbox (and (boundp 'librecode-runner.protocol:*session-mailbox*)
                                                                              librecode-runner.protocol:*session-mailbox*))
                                                  ;; Attempt to ask permission to trigger database logging from inside tool
                                                  (let ((agent (make-instance 'librecode-runner.agent:agent
                                                                             :id agent-id
                                                                             :ruleset (list (librecode-runner.agent:make-permission-rule :action "*" :resource "*" :effect :ask))
                                                                             :system-context "")))
                                                    ;; Let's temporarily bind *interactive-p* to T so it triggers resolve-ask-permission
                                                    (let ((librecode-runner.agent:*interactive-p* t))
                                                      (handler-case
                                                          (librecode-runner.agent:check-permission agent "test-action" "test-resource")
                                                        (error () nil))))
                                                  "done"))))
        
        ;; Register the custom tool
        (librecode-runner.tool:register-tool registry test-tool)

        ;; Initialize database session state
        (sqlite:execute-non-query db
          "INSERT INTO session_state (session_id, agent_id, version, status, last_updated)
           VALUES (?, ?, 1, 'active', ?)"
          session-id agent-id (librecode-runner.event-store::current-timestamp-ms))

        ;; Run coordinator with db bound
        (let ((librecode-runner.agent:*interactive-p* t))
          ;; Clear pending requests
          (bt:with-lock-held (librecode-runner.agent::*pending-requests-lock*)
            (clrhash librecode-runner.agent::*pending-requests*))
          
          (let ((coord-thread
                  (bt:make-thread
                   (lambda ()
                     (let ((librecode-runner.event-store:*db* db)
                           (librecode-runner.event-store:*workspace-root* dir)
                           (librecode-runner.agent:*interactive-p* t))
                       (declare (special librecode-runner.event-store:*db*
                                         librecode-runner.event-store:*workspace-root*
                                         librecode-runner.agent:*interactive-p*))
                       (run-coordinator session-id
                                        (lambda ()
                                          ;; Execute parallel tool call
                                          (librecode-runner.runner::execute-parallel-tools session-id
                                                                  `((:id "call-1" :name "db-checking-tool" :arguments "{}"))
                                                                  registry)))))
                   :name "coordinator-parallel-context-thread")))
            
            ;; Wait for a pending permission request to appear (indicating worker ran check-permission)
            (loop repeat 20
                  while (= (hash-table-count librecode-runner.agent::*pending-requests*) 0)
                  do (sleep 0.05))

            ;; Resolve it
            (let ((req-id (first (let ((keys nil))
                                   (bt:with-lock-held (librecode-runner.agent::*pending-requests-lock*)
                                     (maphash (lambda (k v) (declare (ignore v)) (push k keys))
                                              librecode-runner.agent::*pending-requests*))
                                   keys))))
              (is-true req-id)
              (librecode-runner.agent:resolve-permission-request req-id :allow))

            ;; Wait for coordinator to finish
            (loop repeat 20
                  while (bt:thread-alive-p coord-thread)
                  do (sleep 0.05))

            ;; Assertions
            ;; c-db-inherited:
            (is-true captured-db)
            (is (eq db captured-db))
            (is (equal dir captured-workspace))
            (is (equal session-id captured-session))
            (is-true captured-mailbox)
            
            ;; c-perm-event-from-worker:
            (let ((event-row (sqlite:execute-to-list db
                               "SELECT event_type FROM event_log WHERE session_id = ? ORDER BY sequence DESC LIMIT 1"
                               session-id)))
              (is-true event-row)
              (is (equal "EVENT-PERMISSION-ASKED" (caar event-row))))))))))

;;; --- Wire fidelity: tool_calls/tool_call_id round-trip ---

(defun %seed-session-state (db session-id)
  "Insert a minimal session_state row so session_history's FK is satisfied."
  (sqlite:execute-non-query db
    "INSERT INTO session_state (session_id, agent_id, version, status, last_updated)
     VALUES (?, ?, 1, 'active', ?)"
    session-id "agent-1" (librecode-runner.event-store::current-timestamp-ms)))

(defun %wire-tool-calls-match-p (expected wire-assistant-msg)
  "Check that WIRE-ASSISTANT-MSG's :tool_calls array matches EXPECTED
(a list of (:id :name :arguments :result) plists) in order, id/name/arguments intact."
  (let ((wire-tcs (getf wire-assistant-msg :tool_calls)))
    (and (equal "assistant" (getf wire-assistant-msg :role))
         wire-tcs
         (= (length wire-tcs) (length expected))
         (every (lambda (exp wtc)
                  (and (equal (getf exp :id) (getf wtc :id))
                       (equal "function" (getf wtc :type))
                       (equal (getf exp :name) (getf (getf wtc :function) :name))
                       (equal (getf exp :arguments) (getf (getf wtc :function) :arguments))))
                expected (coerce wire-tcs 'list)))))

(defun %wire-tool-messages-match-p (expected wire-tool-msgs)
  "Check that WIRE-TOOL-MSGS (the N role:\"tool\" messages following the
assistant message) each carry the matching tool_call_id and result content,
in the same order EXPECTED's tool calls were emitted."
  (and (= (length wire-tool-msgs) (length expected))
       (every (lambda (exp msg)
                (and (equal "tool" (getf msg :role))
                     (equal (getf exp :id) (getf msg :tool_call_id))
                     (equal (getf exp :result) (getf msg :content))))
              expected wire-tool-msgs)))

(test test-tool-call-wire-roundtrip-property
  "Property [c2-roundtrip]: for any turn emitting N tool calls, reconstructing
the outbound wire messages from persisted history produces an assistant
message carrying a spec-form tool_calls array (ids, names, argument strings
intact) followed by exactly one role:\"tool\" message per call, each carrying
the matching tool_call_id."
  (let ((*num-trials* 25))
    (is-true
     (check-it
      (generator (list (tuple (string :min-length 1 :max-length 10)
                              (string :min-length 1 :max-length 10)
                              (string :min-length 1 :max-length 10))
                       :min-length 1 :max-length 4))
      (lambda (calls)
        (librecode-test.event-store::with-tmp-sandbox (dir)
          (librecode-test.event-store::with-test-db (db dir)
            (let ((session-id "wire-roundtrip-session"))
              (%seed-session-state db session-id)
              (let ((expected (loop for (name arguments result) in calls
                                    for i from 0
                                    collect (list :id (format nil "call-~D" i)
                                                  :name name
                                                  :arguments arguments
                                                  :result result))))
                (librecode-runner.runner::save-assistant-message
                 session-id ""
                 (mapcar (lambda (tc) (list :id (getf tc :id)
                                           :name (getf tc :name)
                                           :arguments (getf tc :arguments)))
                         expected))
                (dolist (tc expected)
                  (librecode-runner.runner::save-tool-message
                   session-id (getf tc :id) (getf tc :name) (getf tc :result)))
                (let ((wire (librecode-runner.runner::get-wire-history-messages session-id)))
                  (and (= (length wire) (1+ (length expected)))
                       (%wire-tool-calls-match-p expected (first wire))
                       (%wire-tool-messages-match-p expected (rest wire)))))))))))))

(test test-tool-call-wire-roundtrip-survives-restart
  "Constraint [c2-persisted-across-restart]: wire reconstruction must succeed
from a fresh database connection (simulating a process restart) rather than
relying on any in-memory state carried across the turn."
  (librecode-test.event-store::with-tmp-sandbox (dir)
    (let* ((db-path (uiop:merge-pathnames* "test.db" dir))
           (session-id "wire-restart-session")
           (expected (list (list :id "call-0" :name "read_file" :arguments "{\"path\":\"a.txt\"}" :result "contents-a")
                           (list :id "call-1" :name "write_file" :arguments "{\"path\":\"b.txt\"}" :result "ok"))))
      ;; Turn 1: persist an assistant message with 2 tool calls and their results.
      (let ((librecode-runner.event-store:*workspace-root* dir))
        (let ((librecode-runner.event-store:*db* (librecode-runner.event-store:connect-db "test.db")))
          (unwind-protect
               (progn
                 (librecode-runner.event-store:init-db librecode-runner.event-store:*db*)
                 (%seed-session-state librecode-runner.event-store:*db* session-id)
                 (librecode-runner.runner::save-assistant-message
                  session-id ""
                  (mapcar (lambda (tc) (list :id (getf tc :id) :name (getf tc :name) :arguments (getf tc :arguments)))
                          expected))
                 (dolist (tc expected)
                   (librecode-runner.runner::save-tool-message
                    session-id (getf tc :id) (getf tc :name) (getf tc :result))))
            (sqlite:disconnect librecode-runner.event-store:*db*))))
      ;; Simulate a process restart: fresh connection, no carried-over in-memory state.
      (let ((librecode-runner.event-store:*workspace-root* dir))
        (let ((librecode-runner.event-store:*db* (librecode-runner.event-store:connect-db "test.db")))
          (unwind-protect
               (let ((wire (librecode-runner.runner::get-wire-history-messages session-id)))
                 (is (= (length wire) 3))
                 (is-true (%wire-tool-calls-match-p expected (first wire)))
                 (is-true (%wire-tool-messages-match-p expected (rest wire))))
            (sqlite:disconnect librecode-runner.event-store:*db*)))))))

(test test-legacy-tool-row-rejected-not-corrupted
  "Constraint [c2-legacy-rejected-not-corrupted]: a pre-existing tool-role
history row with no tool_call_id (the old, pre-linkage schema shape) must be
rejected with a clear, typed condition during wire reconstruction -- never
silently corrupted into an unlinked tool message, never an obscure crash."
  (librecode-test.event-store::with-tmp-sandbox (dir)
    (librecode-test.event-store::with-test-db (db dir)
      (let ((session-id "wire-legacy-session"))
        (%seed-session-state db session-id)
        ;; A legacy-shape tool row: written before tool_call_id tracking existed,
        ;; so the column is left NULL (as any old row necessarily would be).
        (sqlite:execute-non-query db
          "INSERT INTO session_history (id, session_id, role, content, created_at)
           VALUES (?, ?, 'tool', ?, ?)"
          "legacy-tool-1" session-id "some old tool result" 1000)
        (signals librecode-runner.conditions:legacy-history-row
          (librecode-runner.runner::get-wire-history-messages session-id))
        ;; The condition names the offending row so the failure is diagnosable, not obscure.
        (handler-case
            (librecode-runner.runner::get-wire-history-messages session-id)
          (librecode-runner.conditions:legacy-history-row (c)
            (is (equal "legacy-tool-1" (librecode-runner.conditions:legacy-history-row-row-id c)))
            (is (equal session-id (librecode-runner.conditions:legacy-history-row-session-id c)))))))))

;;; --- Compaction pairing: never orphan a tool-call/result group across the split ---

(defun %pad-content (label)
  "A content string long enough that a handful of rows reliably exceed a
small MAX-TOKENS budget in COMPACT-CONTEXT's floor(length/4) estimator."
  (format nil "~A ~A" label (make-string 36 :initial-element #\x)))

(defun %insert-plain-row (db session-id id role created-at)
  (sqlite:execute-non-query db
    "INSERT INTO session_history (id, session_id, role, content, created_at)
     VALUES (?, ?, ?, ?, ?)"
    id session-id role (%pad-content id) created-at))

(defun %tool-calls-payload (call-ids)
  "Build the {text, tool_calls: [...]} JSON payload SAVE-ASSISTANT-MESSAGE
would have written for an assistant turn emitting CALL-IDS."
  (com.inuoe.jzon:stringify
   (librecode-runner.event-store::coerce-to-hash-table
    `((:text . "")
      (:tool_calls . ,(map 'vector
                           (lambda (id)
                             `((:id . ,id)
                               (:type . "function")
                               (:function . ((:name . "tool") (:arguments . "{}")))))
                           call-ids))))))

(defun %insert-tool-call-row (db session-id id created-at call-ids)
  (sqlite:execute-non-query db
    "INSERT INTO session_history (id, session_id, role, content, created_at)
     VALUES (?, ?, 'assistant', ?, ?)"
    id session-id (%tool-calls-payload call-ids) created-at))

(defun %insert-tool-result-row (db session-id id created-at call-id)
  (sqlite:execute-non-query db
    "INSERT INTO session_history (id, session_id, role, content, created_at, tool_call_id)
     VALUES (?, ?, 'tool', ?, ?, ?)"
    id session-id (%pad-content call-id) created-at call-id))

(defun %build-pairing-history (db session-id segments)
  "Insert SEGMENTS (each the symbol :PLAIN or a list (:GROUP N)) into
SESSION-ID's history in order, one CREATED-AT tick per row. Returns an
ordered list of (:id ID :group-key KEY) plists, independently derived from
the segment spec (not from re-parsing what got written), where every row
belonging to the same assistant-tool-call/tool-result group shares KEY."
  (let ((clock 0)
        (rows nil))
    (dolist (seg segments)
      (if (eq seg :plain)
          (let ((id (format nil "row-~D" (incf clock))))
            (%insert-plain-row db session-id id "user" clock)
            (push (list :id id :group-key id) rows))
          (destructuring-bind (tag n) seg
            (declare (ignore tag))
            (let* ((base-id (format nil "row-~D" (incf clock)))
                   (call-ids (loop for i from 1 to n
                                    collect (format nil "~A-call-~D" base-id i))))
              (%insert-tool-call-row db session-id base-id clock call-ids)
              (push (list :id base-id :group-key base-id) rows)
              (dolist (call-id call-ids)
                (incf clock)
                (let ((tool-id (format nil "~A-result-~A" base-id call-id)))
                  (%insert-tool-result-row db session-id tool-id clock call-id)
                  (push (list :id tool-id :group-key base-id) rows)))))))
    (nreverse rows)))

(defun %groups-never-split-p (db session-id rows)
  "Verify [c5-no-orphans]/[c5-group-never-split]: for every group of ROWS
sharing a :group-key (an assistant tool-call row and its linked tool-result
rows), the rows still present in SESSION-ID's history are either all of the
group or none of it -- never a strict subset."
  (let ((remaining (mapcar #'car
                            (sqlite:execute-to-list db
                             "SELECT id FROM session_history WHERE session_id = ?"
                             session-id)))
        (groups (make-hash-table :test 'equal)))
    (dolist (row rows)
      (push row (gethash (getf row :group-key) groups)))
    (loop for group-rows being the hash-values of groups
          always (let ((present (mapcar (lambda (r) (and (member (getf r :id) remaining :test #'equal) t))
                                        group-rows)))
                   (or (every #'identity present) (notany #'identity present))))))

(test test-compaction-preserves-tool-pairs
  "Property [c5-no-orphans]: a naive position-only split that would fall
strictly between an assistant tool-call message and its tool-result row must
instead move to keep the whole group on one side. Red-first: with a
6-message history (u1 a1 u2 [assistant-call a2 -> tool-result t1] u3), the
naive floor(6/3)=2 keep-count puts split-idx at 4, landing between a2 (index
3, would be summarized) and t1 (index 4, would be kept) -- an orphan."
  (librecode-test.event-store::with-tmp-sandbox (dir)
    (librecode-test.event-store::with-test-db (db dir)
      (let ((session-id "session-pairing"))
        (%seed-session-state db session-id)
        (let ((rows (%build-pairing-history
                     db session-id
                     (list :plain :plain :plain (list :group 1) :plain))))
          (is-true (compact-context session-id :max-tokens 10))
          (is-true (%groups-never-split-p db session-id rows)))))))

(test test-compaction-keeps-oversized-group-whole
  "Constraint [a2]: a group that alone exceeds MAX-TOKENS is kept whole
rather than split, even though this means compaction cannot hit the token
target exactly."
  (librecode-test.event-store::with-tmp-sandbox (dir)
    (librecode-test.event-store::with-test-db (db dir)
      (let ((session-id "session-oversized-group"))
        (%seed-session-state db session-id)
        (let ((rows (%build-pairing-history
                     db session-id
                     (list :plain (list :group 3)))))
          (is-true (compact-context session-id :max-tokens 10))
          (is-true (%groups-never-split-p db session-id rows))
          ;; The group (4 rows: 1 assistant tool-call + 3 tool-results) is the
          ;; tail of history and alone exceeds max-tokens; it must still be
          ;; kept whole rather than split, per the group-never-split rule.
          (let* ((group-ids (mapcar (lambda (r) (getf r :id))
                                    (remove-if-not (lambda (r) (equal (getf r :group-key) "row-2"))
                                                    rows)))
                 (remaining (mapcar #'car
                                    (sqlite:execute-to-list db
                                     "SELECT id FROM session_history WHERE session_id = ?"
                                     session-id))))
            (is-true group-ids)
            (dolist (id group-ids)
              (is-true (member id remaining :test #'equal)))))))))

(test test-compaction-pairing-property
  "Property [c5-no-orphans]/[c5-group-never-split]: over varied generated
histories mixing plain messages and tool-call/result groups of varying
size, after compaction no group is ever split across the keep/summarize
boundary."
  (let ((*num-trials* 30))
    (is-true
     (check-it
      (generator (list (or (quote :plain) (tuple (quote :group) (integer 1 3)))
                       :min-length 4 :max-length 8))
      (lambda (segments)
        (librecode-test.event-store::with-tmp-sandbox (dir)
          (librecode-test.event-store::with-test-db (db dir)
            (let ((session-id "session-pairing-property"))
              (%seed-session-state db session-id)
              (let ((rows (%build-pairing-history db session-id segments)))
                (compact-context session-id :max-tokens 10)
                (%groups-never-split-p db session-id rows))))))))))

