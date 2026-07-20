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
;;; At-rest credential redaction + fail-safe send guard
;;; ============================================================================
;;;
;;; The real-credential wiring added earlier in this branch (above) activated
;;; two decorrelated findings from the hacker-seat review: the token it
;;; threads reaches durable storage in cleartext (event_log.payload and
;;; session_provider_config.auth), and an unauthenticated non-loopback send
;;; is never refused. These three tests are the RED half of the /core cycle
;;; for this behavior -- they assert the target (still-unimplemented)
;;; behavior and are expected to fail against the current tip. The symbols
;;; they reference fully-qualified
;;; (librecode-runner.provider:configure-session,
;;; librecode-runner.runner:execute-provider-turn) are unqualified here
;;; deliberately -- this package only :use's librecode-runner.child, and
;;; widening its :use clause is unnecessary churn for three call sites.
;;;
;;; Delegated design decisions (logged per this branch's IBC S3 delegation):
;;;
;;; - Guard condition type: librecode-runner.runner::unauthenticated-send-refused
;;;   (unexported -- packages.lisp is outside this file's declared surface, so
;;;   the implementation worker must define it directly in runner.lisp without
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
  "After configure-session commits a real token, neither
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

            ;; At-rest, in BOTH durable sinks.
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

            ;; The SAME-process live turn must still authenticate.
            (let ((librecode-runner.protocol::*session-mailbox* (librecode-runner.protocol:make-mailbox)))
              (librecode-runner.runner:execute-provider-turn session-id "unused-provider" "n7-redact-model"))

            (is-true request-headers)
            (is (equal (format nil "Bearer ~A" real-token)
                       (cdr (assoc :authorization request-headers)))
                "the live same-process turn must still send the correct Bearer token despite at-rest redaction")))))))

(test test-n7-fail-safe-send-guard-refuses-non-loopback-nil-auth
  "execute-provider-turn with a resolved endpoint whose host is
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
  "Non-regression companion to the fail-safe send guard refusal test above:
the fail-safe guard must NOT fire for a loopback endpoint (127.0.0.1) even with nil auth, so
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

;;; ============================================================================
;;; N7 REWORK: loopback-classification bypass + guard TOCTOU
;;; ============================================================================
;;;
;;; A decorrelated security review of the fail-safe send guard above found
;;; two real defects, fixed in this branch's rework commits and regression-
;;; tested here. Two further independently-decorrelated reviewers converged
;;; on the same core defect and surfaced two further bypass variants of the
;;; first finding, also tested here:
;;;
;;; - LOOPBACK-HOST-P's IPv4 clause was a bare 4-character prefix check
;;;   ((string= host "127." :end1 4)), so "127.evil.com" -- not actually in
;;;   127.0.0.0/8 -- was misclassified as loopback and exempted from the
;;;   guard. Fixed by validating HOST is a well-formed 4-octet dotted-quad
;;;   whose first octet is 127.
;;; - The guard ran once before the retry loop, not on every iteration, so
;;;   RETRY-WITH-BACKUP-PROVIDER (whose lambda list accepts an arbitrary
;;;   caller-supplied URL) could swap in a new endpoint that was never
;;;   re-checked. Fixed by moving the check inside the loop body so it
;;;   re-evaluates the freshly-bound *PROVIDER-URL* every iteration.
;;; - Bypass variant on the first finding: the original hand-rolled URL-HOST
;;;   did not strip a "user@" / "user:pass@" userinfo component, so a
;;;   base-url like "http://127.0.0.1@evil.com/v1" resolved to the raw host
;;;   string "127.0.0.1@evil.com". Against the ORIGINAL 4-character prefix
;;;   check this would have passed as loopback (it starts with "127."). The
;;;   dotted-quad fix closed this bypass too (the unstripped string does not
;;;   decompose into 4 all-digit components) but for the wrong reason: the
;;;   real destination was always "evil.com", never even examined.
;;; - Third, more serious variant, independently verified by executing code
;;;   against this exact worktree: for
;;;   "http://127.0.0.1:secretpass@evil.com/v1/chat/completions", the
;;;   hand-rolled scanner stopped at the FIRST of "/", ":", "?" -- the colon
;;;   right after "127.0.0.1" -- misreading userinfo syntax as a port
;;;   separator, and returned host "127.0.0.1" (a clean dotted-quad, so
;;;   LOOPBACK-HOST-P classified it as loopback). The REAL parser DEXADOR
;;;   uses to open the connection -- QURI, already a transitive dependency
;;;   via DEXADOR -- correctly parses this same URL as host "evil.com".
;;;   The guard would have exempted an unauthenticated request whose actual
;;;   TCP destination was an arbitrary attacker-controlled host. Fixed by
;;;   replacing URL-HOST's hand-rolled scanning entirely with
;;;   QURI:URI-HOST -- the same parser DEXADOR itself uses -- so the
;;;   guard's understanding of the destination host can never diverge from
;;;   where the request is actually sent. This closes all three variants
;;;   above by construction (userinfo is now correctly parsed out of the
;;;   host in every case) rather than by accretion of ad hoc checks.

(test test-n7-loopback-bypass-prefix-match-refused
  "The loopback classifier must not treat a host that merely STARTS WITH the
literal prefix \"127.\" as loopback -- \"127.evil.com\" is not in
127.0.0.0/8, so an unauthenticated send to it must be refused exactly like
any other non-loopback host. This is the exact bypass a decorrelated
reviewer demonstrated against (string= host \"127.\" :end1 4): that
prefix check returns T for this host, so pre-fix the guard silently
exempted it and dexador:post would have been invoked."
  (let ((session-id "n7-loopback-bypass-session")
        (call-count 0)
        (refused nil)
        (refusal-condition nil)
        (original-post (fdefinition 'dexador:post)))
    (librecode-test.event-store::with-tmp-sandbox (dir)
      (librecode-test.event-store::with-test-db (db dir)
        (n7-insert-session-state db session-id)

        (librecode-runner.provider:configure-session session-id
                                                      :base-url "http://127.evil.com/v1"
                                                      :model "n7-bypass-model"
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
                     (librecode-runner.runner:execute-provider-turn session-id "unused-provider" "n7-bypass-model"))
                 (error (c)
                   (setf refused t)
                   (setf refusal-condition c))))
          (setf (fdefinition 'dexador:post) original-post))

        (is-true refused
                 "execute-provider-turn must refuse a host that merely starts with the literal prefix \"127.\" but is not a genuine loopback dotted-quad")
        (is (and refused
                 (find-class 'librecode-runner.runner::unauthenticated-send-refused nil)
                 (typep refusal-condition 'librecode-runner.runner::unauthenticated-send-refused))
            "the guard must signal the dedicated unauthenticated-send-refused condition for the bypass host, not silently classify it as loopback")
        (is (= 0 call-count)
            "dexador:post must never be invoked once the guard correctly classifies \"127.evil.com\" as non-loopback")))))

(test test-n7-loopback-bypass-userinfo-prefix-refused
  "Bypass variant of the prefix-match finding above: a base-url of
\"http://127.0.0.1@evil.com/v1\" carries \"127.0.0.1\" as bare userinfo (no
port-like colon) ahead of the real host. QURI:URI-HOST -- the same parser
DEXADOR uses to open the connection -- correctly strips the userinfo and
resolves this to host \"evil.com\", the actual destination; the guard must
refuse it as non-loopback and never invoke dexador:post."
  (let ((session-id "n7-loopback-userinfo-bypass-session")
        (call-count 0)
        (refused nil)
        (refusal-condition nil)
        (original-post (fdefinition 'dexador:post)))
    (librecode-test.event-store::with-tmp-sandbox (dir)
      (librecode-test.event-store::with-test-db (db dir)
        (n7-insert-session-state db session-id)

        (librecode-runner.provider:configure-session session-id
                                                      :base-url "http://127.0.0.1@evil.com/v1"
                                                      :model "n7-userinfo-bypass-model"
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
                     (librecode-runner.runner:execute-provider-turn session-id "unused-provider" "n7-userinfo-bypass-model"))
                 (error (c)
                   (setf refused t)
                   (setf refusal-condition c))))
          (setf (fdefinition 'dexador:post) original-post))

        (is-true refused
                 "execute-provider-turn must refuse a host with an unstripped userinfo prefix (\"127.0.0.1@evil.com\") -- it is not a genuine loopback dotted-quad")
        (is (and refused
                 (find-class 'librecode-runner.runner::unauthenticated-send-refused nil)
                 (typep refusal-condition 'librecode-runner.runner::unauthenticated-send-refused))
            "the guard must signal the dedicated unauthenticated-send-refused condition for the userinfo-prefixed host, not silently classify it as loopback")
        (is (equal "evil.com"
                   (librecode-runner.runner::unauthenticated-send-refused-host refusal-condition))
            "the refused host must be the real, userinfo-stripped destination \"evil.com\" (what QURI/DEXADOR actually resolve), confirming this test exercised the userinfo bypass path and that the guard now sees the true target rather than a confused raw string")
        (is (= 0 call-count)
            "dexador:post must never be invoked once the guard correctly classifies the userinfo-prefixed host as non-loopback")))))

(test test-n7-loopback-bypass-userinfo-colon-port-refused
  "Third, more serious bypass variant against the same hand-rolled
URL-HOST that the first two exploited: a base-url of
\"http://127.0.0.1:secretpass@evil.com/v1\" places a COLON inside the
userinfo component (as if \"secretpass\" were a port), which the pre-fix
hand-rolled scanner -- stopping at the first \":\", \"/\", or \"?\" --
misread as \"host 127.0.0.1, port secretpass\", returning the clean
dotted-quad \"127.0.0.1\" and passing the (already-fixed) dotted-quad
check as genuine loopback. QURI:URI-HOST -- the same parser DEXADOR uses
to open the connection -- correctly parses the userinfo
\"127.0.0.1:secretpass\" and the real host \"evil.com\": the guard must
refuse this as non-loopback and never invoke dexador:post, or an
unauthenticated request (full body, no Authorization header) would reach
an arbitrary attacker-controlled host believing it was talking to
loopback."
  (let ((session-id "n7-loopback-userinfo-colon-port-bypass-session")
        (call-count 0)
        (refused nil)
        (refusal-condition nil)
        (original-post (fdefinition 'dexador:post)))
    (librecode-test.event-store::with-tmp-sandbox (dir)
      (librecode-test.event-store::with-test-db (db dir)
        (n7-insert-session-state db session-id)

        (librecode-runner.provider:configure-session session-id
                                                      :base-url "http://127.0.0.1:secretpass@evil.com/v1"
                                                      :model "n7-userinfo-colon-port-bypass-model"
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
                     (librecode-runner.runner:execute-provider-turn session-id "unused-provider" "n7-userinfo-colon-port-bypass-model"))
                 (error (c)
                   (setf refused t)
                   (setf refusal-condition c))))
          (setf (fdefinition 'dexador:post) original-post))

        (is-true refused
                 "execute-provider-turn must refuse a host reached via a colon-bearing userinfo prefix (\"127.0.0.1:secretpass@evil.com\") that a hand-rolled scanner would misparse as loopback port syntax")
        (is (and refused
                 (find-class 'librecode-runner.runner::unauthenticated-send-refused nil)
                 (typep refusal-condition 'librecode-runner.runner::unauthenticated-send-refused))
            "the guard must signal the dedicated unauthenticated-send-refused condition for the userinfo-colon-port bypass host, not silently classify it as loopback")
        (is (equal "evil.com"
                   (librecode-runner.runner::unauthenticated-send-refused-host refusal-condition))
            "the refused host must be the real destination \"evil.com\" that QURI/DEXADOR agree on, proving the guard's host extraction matches where the request actually goes")
        (is (= 0 call-count)
            "dexador:post must never be invoked once the guard correctly classifies the userinfo-colon-port bypass host as non-loopback")))))

(test test-n7-toctou-guard-refires-on-backup-provider-retry
  "The fail-safe send guard must not be a one-shot check performed only
before the retry loop starts: RETRY-WITH-BACKUP-PROVIDER can swap in an
arbitrary caller-supplied URL between iterations, so the guard must
re-evaluate against the freshly-mutated endpoint on every iteration, not
just the first. Reproduces the TOCTOU gap the reviewer demonstrated:
the initial endpoint is loopback (guard exempt) with nil auth; the first
dexador:post attempt is forced to fail, driving a handler-bind that
invokes RETRY-WITH-BACKUP-PROVIDER with an explicit non-loopback backup
URL (mirroring the restart's own lambda list, which accepts one); the
guard must then refuse before any second dexador:post attempt is ever
made. Network-free and deterministic: dexador:post is stubbed for this
test's duration, same pattern as the refusal test above."
  (let ((session-id "n7-toctou-session")
        (call-count 0)
        (retried nil)
        (refused nil)
        (refusal-condition nil)
        (original-post (fdefinition 'dexador:post)))
    (librecode-test.event-store::with-tmp-sandbox (dir)
      (librecode-test.event-store::with-test-db (db dir)
        (n7-insert-session-state db session-id)

        (librecode-runner.provider:configure-session session-id
                                                      :base-url "http://127.0.0.1:1/v1"
                                                      :model "n7-toctou-model"
                                                      :auth nil)

        (unwind-protect
             (progn
               (setf (fdefinition 'dexador:post)
                     (lambda (&rest args)
                       (declare (ignore args))
                       (incf call-count)
                       (error "n7-toctou-forced-first-attempt-failure")))
               (handler-case
                   (handler-bind
                       ((librecode-runner.conditions:provider-error
                          (lambda (c)
                            (declare (ignore c))
                            (unless retried
                              (setf retried t)
                              (invoke-restart 'librecode-runner.conditions:retry-with-backup-provider
                                               "http://example.com/v1")))))
                     (let ((librecode-runner.protocol::*session-mailbox* (librecode-runner.protocol:make-mailbox)))
                       (librecode-runner.runner:execute-provider-turn session-id "unused-provider" "n7-toctou-model")))
                 (error (c)
                   (setf refused t)
                   (setf refusal-condition c))))
          (setf (fdefinition 'dexador:post) original-post))

        (is-true retried
                 "test setup must actually exercise the retry-with-backup-provider restart, or this test proves nothing about the TOCTOU gap")
        (is-true refused
                 "the guard must refuse once the retry swaps in a non-loopback endpoint with nil auth, rather than reaching a second dexador:post unguarded")
        (is (and refused
                 (find-class 'librecode-runner.runner::unauthenticated-send-refused nil)
                 (typep refusal-condition 'librecode-runner.runner::unauthenticated-send-refused))
            "the second-iteration refusal must be the dedicated unauthenticated-send-refused condition, confirming the guard -- not some other failure -- is what fired")
        (is (= 1 call-count)
            "dexador:post must be called exactly once (the forced first-attempt failure); the guard must block the retried second attempt before any second dexador:post call, proving the TOCTOU gap is closed")))))
