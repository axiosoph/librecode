;;; -*- Mode: Lisp; Syntax: Common-Lisp; indent-tabs-mode: nil; coding: utf-8; Show-Trailing-Whitespace: t -*-
;;;
;;; provider-integration-tests.lisp — Real authenticated provider reach
;;;
;;; Proves the credential path end to end: an env-var-sourced secret set in
;;; the parent test process, inherited by a genuinely spawned run-child
;;; subprocess (never interpolated into its --eval argv), read there via
;;; uiop:getenv, threaded through configure-session :auth, and surfaced as
;;; an outbound `Authorization: Bearer <token>` header against a
;;; with-mock-provider stand-in whose host:port is asserted to differ from
;;; both of runner.lisp's hardcoded unauthenticated defaults.
;;;

(defpackage #:librecode-test.provider-integration
  (:use #:cl
        #:fiveam
        #:librecode-runner.child)
  (:export #:provider-integration-suite))

(in-package #:librecode-test.provider-integration)

(def-suite provider-integration-suite
  :description "Suite for real authenticated provider reach (child subprocess -> provider) integration tests.")

(in-suite provider-integration-suite)

(defparameter +auth-env-var+ "LIBRECODE_PROVIDER_API_KEY"
  "Env var name run-child reads its provider credential from.")

(test test-child-authenticated-provider-reach
  "run-child, spawned as a genuine subprocess with the credential only ever
reaching it via inherited environment (never argv), must configure the
session with :auth and cause execute-provider-turn to send an outbound
Authorization: Bearer <token> header to the session's configured
(non-default) endpoint."
  (let ((session-id "n4-auth-reach-session")
        (api-token "n4-integration-secret-token-do-not-log")
        (request-headers nil))
    (librecode-test.event-store::with-tmp-sandbox (dir)
      (let* ((target-dir (uiop:merge-pathnames* "target/" dir))
             (db-path "librecode-child.db"))
        (ensure-directories-exist target-dir)

        (librecode-test.mock-provider:with-mock-provider
            (port :path "/stream/chat/completions"
                  :method :post
                  :responder (lambda (request call-index)
                               (declare (ignore call-index))
                               (setf request-headers (hunchentoot:headers-in request))
                               (list (list :content "Task complete."))))
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
                 ;; The api-token never appears below -- only the env var
                 ;; NAME is referenced in this --eval string; the VALUE
                 ;; reaches the child solely through inherited environment.
                 (command (list "sbcl" "--noinform" "--non-interactive"
                                "--eval" "(require :sb-posix)"
                                "--eval" "(sb-posix:setenv \"CL_SOURCE_REGISTRY\" \"\" 1)"
                                "--eval" "(require :asdf)"
                                "--eval" (format nil "(asdf:initialize-source-registry '~S)" source-registry-sexpr)
                                "--eval" (format nil "(push (truename ~S) asdf:*central-registry*)" (namestring project-root))
                                "--eval" "(asdf:load-system :librecode-runner)"
                                "--eval" (format nil "(librecode-runner.child:run-child :workspace-root ~S :db-path ~S :provider-url ~S :model ~S :task ~S :session-id ~S)"
                                                 (namestring target-dir) db-path provider-url "mock-model" "say hello" session-id)))
                 (config (list :id session-id
                               :workspace-root target-dir
                               :command command))
                 (harness nil))

            (sb-posix:setenv +auth-env-var+ api-token 1)
            (unwind-protect
                 (progn
                   (setf harness (librecode-meta.harness:harness-spawn 'librecode-meta.harness::subprocess-harness config))
                   (is (typep harness 'librecode-meta.harness::subprocess-harness))
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
                     (is (eq landed-status :idle)))

                   ;; Assert the outbound Authorization header carries the
                   ;; env-sourced token as a Bearer credential.
                   (is-true request-headers)
                   (is (equal (format nil "Bearer ~A" api-token)
                              (cdr (assoc :authorization request-headers))))

                   ;; Assert host:port explicitly differs from both
                   ;; hardcoded unauthenticated defaults -- not merely
                   ;; structurally distinct by construction.
                   (let ((received-host (cdr (assoc :host request-headers))))
                     (is-true received-host)
                     (is (not (equal "localhost:8080" received-host)))
                     (is (not (equal "localhost:8081" received-host)))))

              ;; Unconditionally unset the credential, regardless of outcome,
              ;; so no later suite in this just-test SBCL image observes it.
              (sb-posix:unsetenv +auth-env-var+)
              (when harness
                (librecode-meta.harness:harness-terminate harness)))))))))

;;; ============================================================================
;;; N7 -- at-rest credential redaction + fail-safe send guard
;;; ============================================================================
;;;
;;; N4's real-credential wiring (above) activated two decorrelated findings
;;; from the hacker-seat review: the token it threads reaches durable
;;; storage in cleartext (event_log.payload and session_provider_config.auth),
;;; and an unauthenticated non-loopback send is never refused. These three
;;; tests are the RED half of N7's /core cycle -- they assert the target
;;; (still-unimplemented) behavior and are expected to fail against the
;;; current tip. The symbols they reference fully-qualified
;;; (librecode-runner.provider:configure-session,
;;; librecode-runner.runner:execute-provider-turn) are unqualified here
;;; deliberately -- this package only :use's librecode-runner.child, and
;;; widening its :use clause is unnecessary churn for three call sites.
;;;
;;; Delegated design decisions (logged per N7's IBC S3 delegation):
;;;
;;; - Guard condition type: librecode-runner.runner::unauthenticated-send-refused
;;;   (unexported -- packages.lisp is outside N7's file_surface, so the
;;;   implementation worker must define it directly in runner.lisp without
;;;   an :export; tests reach it via :: internal access). Below, the assert
;;;   goes through (find-class ... nil) before typep so referencing the
;;;   not-yet-defined class never trips a hard error pre-implementation --
;;;   only an intelligible assertion failure.
;;; - Network-free guard verification: the refusal test swaps
;;;   (fdefinition 'dexador:post) for a counting stub for its duration
;;;   (restored via unwind-protect) rather than pointing at a real
;;;   non-loopback host. This is deliberate -- a real non-loopback address
;;;   is either flaky (real DNS/network dependency in CI) or, if it happens
;;;   to resolve locally, not actually testing the loopback/non-loopback
;;;   classification. Stubbing dexador:post directly gives an exact,
;;;   deterministic "was a request ever attempted" signal regardless of
;;;   classification-predicate internals, which are the implementer's call.
;;; - Loopback-classification boundary exercised: "example.com" (clearly
;;;   non-loopback) vs "127.0.0.1" (the existing suite's loopback default).

(defun n7-insert-session-state (db session-id)
  "Minimal session_state row -- mirrors the setup already used by
test-generic-provider-configuration in provider-tests.lisp; execute-provider-turn
only needs this row to resolve an agent-id and does not require
session_history/context_epoch rows for a bare turn."
  (sqlite:execute-non-query db
    "INSERT INTO session_state (session_id, agent_id, version, status, last_updated)
     VALUES (?, ?, 1, 'active', ?)"
    session-id "agent-1" (librecode-runner.event-store::current-timestamp-ms)))

(test test-n7-credential-redacted-at-rest-live-header-intact
  "C-N7-1 + C-N7-2: after configure-session commits a real token, neither
event_log.payload for the :session-provider-configured event nor the
projected session_provider_config.auth column may contain that token's
cleartext -- checked before any turn runs, so this is purely an at-rest
property. A live same-process turn immediately afterward must still send
the correct `Authorization: Bearer <token>` header: redaction must not
break the authenticated path it protects."
  (let ((session-id "n7-redaction-session")
        (real-token "n7-real-secret-do-not-persist-at-rest")
        (request-headers nil))
    (librecode-test.event-store::with-tmp-sandbox (dir)
      (librecode-test.event-store::with-test-db (db dir)
        (n7-insert-session-state db session-id)

        (librecode-test.mock-provider:with-mock-provider
            (port :path "/n7-redact-v1/chat/completions"
                  :method :post
                  :responder (lambda (request call-index)
                               (declare (ignore call-index))
                               (setf request-headers (hunchentoot:headers-in request))
                               (list (list :content "Redaction turn works!"))))
          (let ((base-url (format nil "http://127.0.0.1:~A/n7-redact-v1" port)))
            (librecode-runner.provider:configure-session session-id
                                                          :base-url base-url
                                                          :model "n7-redact-model"
                                                          :auth real-token)

            ;; C-N7-1: at-rest, in BOTH durable sinks.
            (let ((logged-payload (sqlite:execute-single db
                                     "SELECT payload FROM event_log WHERE session_id = ? AND event_type = 'SESSION-PROVIDER-CONFIGURED' ORDER BY sequence DESC LIMIT 1"
                                     session-id)))
              (is-true logged-payload)
              (is (not (search real-token logged-payload))
                  "event_log.payload must not contain the real credential in cleartext (found it verbatim)"))

            (let ((column-auth (sqlite:execute-single db
                                  "SELECT auth FROM session_provider_config WHERE session_id = ?"
                                  session-id)))
              (is (not (equal real-token column-auth))
                  "session_provider_config.auth must not contain the real credential in cleartext"))

            ;; C-N7-2: the SAME-process live turn must still authenticate.
            (let ((librecode-runner.protocol::*session-mailbox* (librecode-runner.protocol:make-mailbox)))
              (librecode-runner.runner:execute-provider-turn session-id "unused-provider" "n7-redact-model"))

            (is-true request-headers)
            (is (equal (format nil "Bearer ~A" real-token)
                       (cdr (assoc :authorization request-headers)))
                "the live same-process turn must still send the correct Bearer token despite at-rest redaction")))))))

(test test-n7-fail-safe-send-guard-refuses-non-loopback-nil-auth
  "C-N7-3: execute-provider-turn with a resolved endpoint whose host is
non-loopback (\"example.com\", not one of 127.*/localhost/::1) and nil
session auth must refuse -- signal a condition, dispatch zero requests --
rather than silently POSTing the full request body unauthenticated to a
remote host. dexador:post is stubbed for this test's duration (see file
header) so the assertion is network-free and deterministic."
  (let ((session-id "n7-guard-refuse-session")
        (call-count 0)
        (refused nil)
        (refusal-condition nil)
        (original-post (fdefinition 'dexador:post)))
    (librecode-test.event-store::with-tmp-sandbox (dir)
      (librecode-test.event-store::with-test-db (db dir)
        (n7-insert-session-state db session-id)

        (librecode-runner.provider:configure-session session-id
                                                      :base-url "http://example.com/v1"
                                                      :model "n7-guard-model"
                                                      :auth nil)

        (unwind-protect
             (progn
               (setf (fdefinition 'dexador:post)
                     (lambda (&rest args)
                       (declare (ignore args))
                       (incf call-count)
                       (make-string-input-stream (format nil "data: [DONE]~%"))))
               (handler-case
                   (let ((librecode-runner.protocol::*session-mailbox* (librecode-runner.protocol:make-mailbox)))
                     (librecode-runner.runner:execute-provider-turn session-id "unused-provider" "n7-guard-model"))
                 (error (c)
                   (setf refused t)
                   (setf refusal-condition c))))
          (setf (fdefinition 'dexador:post) original-post))

        (is-true refused
                 "execute-provider-turn must refuse (signal a condition) for a non-loopback endpoint with nil auth; it currently sends silently")
        (is (and refused
                 (find-class 'librecode-runner.runner::unauthenticated-send-refused nil)
                 (typep refusal-condition 'librecode-runner.runner::unauthenticated-send-refused))
            "the guard must signal the dedicated librecode-runner.runner::unauthenticated-send-refused condition, not an incidental error")
        (is (= 0 call-count)
            "dexador:post must never be invoked once the fail-safe guard refuses a non-loopback, unauthenticated send")))))

(test test-n7-fail-safe-send-guard-exempts-loopback-nil-auth
  "Non-regression companion to C-N7-3: the fail-safe guard must NOT fire
for a loopback endpoint (127.0.0.1) even with nil auth, so
test-provider-configuration-fallback-to-default and every other
loopback-mock-based test keep passing unchanged. Unlike the refusal test,
this exercises a real local mock round-trip rather than a dexador:post
stub, since the point is proving the send still actually happens."
  (let ((session-id "n7-loopback-exempt-session")
        (request-headers nil))
    (librecode-test.event-store::with-tmp-sandbox (dir)
      (librecode-test.event-store::with-test-db (db dir)
        (n7-insert-session-state db session-id)

        (librecode-test.mock-provider:with-mock-provider
            (port :path "/n7-loopback-v1/chat/completions"
                  :method :post
                  :responder (lambda (request call-index)
                               (declare (ignore call-index))
                               (setf request-headers (hunchentoot:headers-in request))
                               (list (list :content "Loopback unauth still works!"))))
          (let ((base-url (format nil "http://127.0.0.1:~A/n7-loopback-v1" port)))
            (librecode-runner.provider:configure-session session-id
                                                          :base-url base-url
                                                          :model "n7-loopback-model"
                                                          :auth nil)

            (let ((librecode-runner.protocol::*session-mailbox* (librecode-runner.protocol:make-mailbox)))
              (librecode-runner.runner:execute-provider-turn session-id "unused-provider" "n7-loopback-model"))

            (is-true request-headers
                     "the fail-safe guard must not fire for a loopback endpoint even with nil auth")
            (is-false (assoc :authorization request-headers))))))))
