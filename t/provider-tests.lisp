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

(defun get-free-port ()
  "Generate a random port in user range."
  (+ 15000 (random 5000)))

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
  "Verify that generic session configuration (base-url, model, bearer-auth) is honored by the turn execution loop."
  (let* ((port (get-free-port))
         (acceptor (make-instance 'hunchentoot:easy-acceptor :port port :address "127.0.0.1"))
         (session-id "generic-sess-success")
         (custom-base-url (format nil "http://127.0.0.1:~A/custom-v1" port))
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
        
        ;; Set up custom local route dispatcher for custom-v1/chat/completions endpoint
        (let ((dispatcher (lambda (request)
                            (when (and (equal (hunchentoot:script-name request) "/custom-v1/chat/completions")
                                       (equal (hunchentoot:request-method request) :POST))
                              (setf request-headers (hunchentoot:headers-in request))
                              (let ((body (hunchentoot:raw-post-data :force-text t :request request)))
                                (setf request-body-parsed (com.inuoe.jzon:parse body)))
                              (lambda ()
                                (setf (hunchentoot:content-type*) "text/event-stream")
                                (let ((stream (hunchentoot:send-headers)))
                                  (write-sequence (flexi-streams:string-to-octets (format nil "data: {\"choices\": [{\"delta\": {\"content\": \"Configured response works!\"}}]}~%") :external-format :utf-8) stream)
                                  (force-output stream)
                                  (write-sequence (flexi-streams:string-to-octets (format nil "data: [DONE]~%") :external-format :utf-8) stream)
                                  (force-output stream)
                                  ""))))))
          (push dispatcher hunchentoot:*dispatch-table*)
          (unwind-protect
               (progn
                 (hunchentoot:start acceptor)
                 ;; 1. Configure the session
                 (configure-session session-id
                                    :base-url custom-base-url
                                    :model custom-model
                                    :auth custom-token)
                 
                 ;; 2. Run the turn
                 (let ((librecode-runner.protocol::*session-mailbox* (librecode-runner.protocol:make-mailbox)))
                   (librecode-runner.runner:execute-provider-turn session-id "unused-provider" "unused-model"))
                 
                 ;; 3. Assertions
                 (is-true request-headers)
                 (is (equal custom-model (gethash "model" request-body-parsed)))
                 (is (equal (format nil "Bearer ~A" custom-token)
                            (cdr (assoc :authorization request-headers))))
                 
                 ;; 4. Check that response was saved correctly
                 (let ((content (sqlite:execute-single db "SELECT content FROM session_history WHERE role = 'assistant'")))
                   (is (equal "Configured response works!" content))))
            (progn
              (hunchentoot:stop acceptor)
              (setf hunchentoot:*dispatch-table* (delete dispatcher hunchentoot:*dispatch-table*)))))))))

(test test-provider-configuration-fallback-to-default
  "Verify that if no session-specific configuration is set, it falls back to defaults (mock path) with no authorization header."
  (let* ((port (get-free-port))
         (acceptor (make-instance 'hunchentoot:easy-acceptor :port port :address "127.0.0.1"))
         (session-id "default-sess")
         (request-headers nil)
         (request-body-parsed nil))
    (librecode-test.event-store::with-tmp-sandbox (dir)
      (librecode-test.event-store::with-test-db (db dir)
        ;; Setup session state
        (sqlite:execute-non-query db
          "INSERT INTO session_state (session_id, agent_id, version, status, last_updated)
           VALUES (?, ?, 1, 'active', ?)"
          session-id "agent-1" (librecode-runner.event-store::current-timestamp-ms))
        
        ;; Set up custom local route dispatcher for default mock endpoint path
        (let ((dispatcher (lambda (request)
                            (when (and (equal (hunchentoot:script-name request) "/v1/chat/completions")
                                       (equal (hunchentoot:request-method request) :POST))
                              (setf request-headers (hunchentoot:headers-in request))
                              (let ((body (hunchentoot:raw-post-data :force-text t :request request)))
                                (setf request-body-parsed (com.inuoe.jzon:parse body)))
                              (lambda ()
                                (setf (hunchentoot:content-type*) "text/event-stream")
                                (let ((stream (hunchentoot:send-headers)))
                                  (write-sequence (flexi-streams:string-to-octets (format nil "data: {\"choices\": [{\"delta\": {\"content\": \"Default response works!\"}}]}~%") :external-format :utf-8) stream)
                                  (force-output stream)
                                  (write-sequence (flexi-streams:string-to-octets (format nil "data: [DONE]~%") :external-format :utf-8) stream)
                                  (force-output stream)
                                  ""))))))
          (push dispatcher hunchentoot:*dispatch-table*)
          (unwind-protect
               (progn
                 (hunchentoot:start acceptor)
                 
                 ;; Run the turn with a dynamically bound default *provider-url* pointing to our mock acceptor
                 (let ((librecode-runner.runner::*provider-url* (format nil "http://127.0.0.1:~A/v1/chat/completions" port))
                       (librecode-runner.protocol::*session-mailbox* (librecode-runner.protocol:make-mailbox)))
                   ;; Clear any dynamic settings to force fallback
                   (clear-session-configs)
                   (librecode-runner.runner:execute-provider-turn session-id "default-provider" "default-model"))
                 
                 ;; Assertions
                 (is-true request-headers)
                 (is (equal "default-model" (gethash "model" request-body-parsed)))
                 ;; No Authorization header should be set
                 (is-false (assoc :authorization request-headers))
                 
                 ;; Check that response was saved correctly
                 (let ((content (sqlite:execute-single db "SELECT content FROM session_history WHERE role = 'assistant'")))
                   (is (equal "Default response works!" content))))
            (progn
              (hunchentoot:stop acceptor)
              (setf hunchentoot:*dispatch-table* (delete dispatcher hunchentoot:*dispatch-table*)))))))))
