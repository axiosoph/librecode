;;; -*- Mode: Lisp; Syntax: Common-Lisp; indent-tabs-mode: nil; coding: utf-8; Show-Trailing-Whitespace: t -*-
;;;
;;; provider-tests.lisp — Unit tests for LLM provider interface and SSE parsing
;;;

(defpackage #:librecode-test.provider
  (:use #:cl
        #:fiveam
        #:librecode-runner.provider)
  (:export #:provider-suite))

(in-package #:librecode-test.provider)

(def-suite provider-suite
  :description "Suite for LLM provider tests.")

(in-suite provider-suite)

;;; ============================================================================
;;; OLLAMA / OPENAI MANUAL SMOKE TEST INSTRUCTIONS (Acceptance Criteria Requirement)
;;; ============================================================================
;;; To manually run a smoke test against a local Ollama server:
;;;
;;; 1. Start Ollama locally:
;;;    $ ollama run llama3
;;;
;;; 2. Start an interactive SBCL REPL:
;;;    $ just repl
;;;
;;; 3. In the REPL:
;;;    (in-package #:librecode-runner.runner)
;;;    ;; Set up database context
;;;    (librecode-runner.event-store::with-tmp-sandbox (dir)
;;;      (let ((librecode-runner.event-store:*db* (librecode-runner.event-store:connect-db (merge-pathnames "test.db" dir))))
;;;        (librecode-runner.event-store:init-db librecode-runner.event-store:*db*)
;;;        ;; Insert session
;;;        (sqlite:execute-non-query librecode-runner.event-store:*db*
;;;          "INSERT INTO session_state (session_id, agent_id, version, status, last_updated)
;;;           VALUES ('smoke-sess', 'agent-1', 1, 'active', 0)")
;;;        ;; Configure Ollama local endpoint
;;;        (librecode-runner.provider:configure-session "smoke-sess"
;;;          :base-url "http://localhost:11434/v1"
;;;          :model "llama3"
;;;          :auth "optional-token")
;;;        ;; Add a user message
;;;        (librecode-runner.session:admit-input "smoke-sess" "prompt-1" "Say hello!")
;;;        (librecode-runner.session:promote-input "smoke-sess" "prompt-1")
;;;        ;; Execute turn
;;;        (let ((librecode-runner.protocol:*session-mailbox* (librecode-runner.protocol:make-mailbox)))
;;;          (execute-provider-turn "smoke-sess" "openai" "llama3"))
;;;        ;; Verify response
;;;        (format t "Response: ~A~%"
;;;                (sqlite:execute-single librecode-runner.event-store:*db*
;;;                  "SELECT content FROM session_history WHERE role = 'assistant'"))))
;;; ============================================================================

(test test-generic-provider-configuration
  "Verify that generic session configuration (base-url, model, bearer-auth) is projected and honored."
  (let ((session-id "generic-sess-success")
        (custom-model "custom-gpt-5")
        (custom-token "my-secret-key")
        (request-headers nil)
        (request-body-parsed nil))
    (librecode-test.event-store::with-tmp-sandbox (dir)
      (librecode-test.event-store::with-test-db (db dir)
        ;; Setup session state
        (sqlite:execute-non-query db
          "INSERT INTO session_state (session_id, agent_id, version, status, last_updated)
           VALUES (?, ?, 1, 'active', ?)"
          session-id "agent-1" (librecode-runner.event-store::current-timestamp-ms))

        (librecode-test.mock-provider:with-mock-provider
            (port :path "/custom-v1/chat/completions"
                  :method :post
                  :responder (lambda (request call-index)
                               (declare (ignore call-index))
                               (setf request-headers (hunchentoot:headers-in request))
                               (setf request-body-parsed
                                     (com.inuoe.jzon:parse (hunchentoot:raw-post-data :force-text t :request request)))
                               (list (list :content "Configured response works!"))))
          (let ((custom-base-url (format nil "http://127.0.0.1:~A/custom-v1" port)))
            ;; 1. Configure the session (this must commit an event and trigger dynamic projections)
            (configure-session session-id
                               :base-url custom-base-url
                               :model custom-model
                               :auth custom-token)

            ;; 2. Verify that the event was actually written to the event log
            (let ((logged-event (sqlite:execute-to-list db
                                  "SELECT event_type, payload FROM event_log WHERE session_id = ? ORDER BY sequence DESC LIMIT 1"
                                  session-id)))
              (is-true logged-event)
              (destructuring-bind (event-type payload-str) (car logged-event)
                (is (string= "SESSION-PROVIDER-CONFIGURED" event-type))
                (let ((payload (com.inuoe.jzon:parse payload-str)))
                  (is (equal custom-base-url (gethash "base-url" payload)))
                  (is (equal custom-model (gethash "model" payload)))
                  (is (equal custom-token (gethash "auth" payload))))))

            ;; 3. Verify that the read model was correctly projected into the DB
            (let ((config (get-session-config session-id)))
              (is-true config)
              (is (equal custom-base-url (getf config :base-url)))
              (is (equal custom-model (getf config :model)))
              (is (equal custom-token (getf config :auth))))

            ;; 4. Run the turn
            (let ((librecode-runner.protocol::*session-mailbox* (librecode-runner.protocol:make-mailbox)))
              (librecode-runner.runner:execute-provider-turn session-id "unused-provider" "unused-model"))

            ;; 5. Assertions on the request sent to our mock generic server
            (is-true request-headers)
            (is (equal custom-model (gethash "model" request-body-parsed)))
            (is (equal (format nil "Bearer ~A" custom-token)
                       (cdr (assoc :authorization request-headers))))

            ;; 6. Check that response was saved correctly
            (let ((content (sqlite:execute-single db "SELECT content FROM session_history WHERE role = 'assistant'")))
              (is (equal "Configured response works!" content)))))))))

(test test-provider-configuration-fallback-to-default
  "Verify that if no session-specific configuration is set, it falls back to defaults (mock path) with no authorization header."
  (let ((session-id "default-sess")
        (request-headers nil)
        (request-body-parsed nil))
    (librecode-test.event-store::with-tmp-sandbox (dir)
      (librecode-test.event-store::with-test-db (db dir)
        ;; Setup session state
        (sqlite:execute-non-query db
          "INSERT INTO session_state (session_id, agent_id, version, status, last_updated)
           VALUES (?, ?, 1, 'active', ?)"
          session-id "agent-1" (librecode-runner.event-store::current-timestamp-ms))

        (librecode-test.mock-provider:with-mock-provider
            (port :path "/v1/chat/completions"
                  :method :post
                  :responder (lambda (request call-index)
                               (declare (ignore call-index))
                               (setf request-headers (hunchentoot:headers-in request))
                               (setf request-body-parsed
                                     (com.inuoe.jzon:parse (hunchentoot:raw-post-data :force-text t :request request)))
                               (list (list :content "Default response works!"))))
          ;; Run the turn with a dynamically bound default *provider-url* pointing to our mock acceptor
          (let ((librecode-runner.runner::*provider-url* (format nil "http://127.0.0.1:~A/v1/chat/completions" port))
                (librecode-runner.protocol::*session-mailbox* (librecode-runner.protocol:make-mailbox)))
            ;; Clear any configurations to force fallback
            (clear-session-configs)
            (librecode-runner.runner:execute-provider-turn session-id "default-provider" "default-model"))

          ;; Assertions
          (is-true request-headers)
          (is (equal "default-model" (gethash "model" request-body-parsed)))
          ;; No Authorization header should be set
          (is-false (assoc :authorization request-headers))

          ;; Check that response was saved correctly
          (let ((content (sqlite:execute-single db "SELECT content FROM session_history WHERE role = 'assistant'")))
            (is (equal "Default response works!" content))))))))

(test test-mock-provider-branches-on-request-body
  "Constraint [c6-fixture-supports-scripting]: the shared mock-provider
fixture can branch its streamed response on the inbound request body, not
just on call order -- closing the capability gap where existing mocks
parsed request bodies for post-hoc assertions but never used them to select
a response (premise p6-request-body-inspected-but-not-branched)."
  (let ((session-id "branch-sess"))
    (librecode-test.event-store::with-tmp-sandbox (dir)
      (librecode-test.event-store::with-test-db (db dir)
        (sqlite:execute-non-query db
          "INSERT INTO session_state (session_id, agent_id, version, status, last_updated)
           VALUES (?, ?, 1, 'active', ?)"
          session-id "agent-1" (librecode-runner.event-store::current-timestamp-ms))

        (librecode-test.mock-provider:with-mock-provider
            (port :path "/v1/chat/completions"
                  :method :post
                  :responder (lambda (request call-index)
                               (declare (ignore call-index))
                               (let* ((body (com.inuoe.jzon:parse (hunchentoot:raw-post-data :force-text t :request request)))
                                      (model (gethash "model" body)))
                                 (list (list :content (if (search "poem" model)
                                                           "Roses are red."
                                                           "Default response."))))))
          (let ((librecode-runner.runner::*provider-url* (format nil "http://127.0.0.1:~A/v1/chat/completions" port))
                (librecode-runner.protocol::*session-mailbox* (librecode-runner.protocol:make-mailbox)))
            (clear-session-configs)
            (librecode-runner.runner:execute-provider-turn session-id "branch-provider" "poem-model"))

          (let ((content (sqlite:execute-single db "SELECT content FROM session_history WHERE role = 'assistant'")))
            (is (equal "Roses are red." content))))))))

(test test-resolve-provider-endpoint
  "Verify resolve-provider-endpoint generic path suffix and query parameter rules."
  ;; 1. Suffix checks without query parameters
  (is (equal "http://localhost:8000/v1/chat/completions"
             (resolve-provider-endpoint "http://localhost:8000/v1/chat/completions")))
  (is (equal "http://localhost:8000/chat/completions"
             (resolve-provider-endpoint "http://localhost:8000/chat/completions")))
  (is (equal "http://localhost:8000/v1/messages"
             (resolve-provider-endpoint "http://localhost:8000/v1/messages")))
  (is (equal "http://localhost:8000/v1/chat/completions"
             (resolve-provider-endpoint "http://localhost:8000/v1")))
  (is (equal "http://localhost:8000/chat/completions"
             (resolve-provider-endpoint "http://localhost:8000")))
  (is (equal nil
             (resolve-provider-endpoint nil)))

  ;; 2. Suffix checks with query parameters (Acceptance Criteria Requirement)
  (is (equal "http://localhost/v1/chat/completions?api-version=2023-05-15"
             (resolve-provider-endpoint "http://localhost/v1?api-version=2023-05-15")))
  (is (equal "http://localhost:8000/v1/messages?some-arg=1&other-arg=2"
             (resolve-provider-endpoint "http://localhost:8000/v1/messages?some-arg=1&other-arg=2")))
  (is (equal "http://localhost/chat/completions?q=hello"
             (resolve-provider-endpoint "http://localhost?q=hello"))))
