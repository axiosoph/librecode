;;; -*- Mode: Lisp; Syntax: Common-Lisp; indent-tabs-mode: nil; coding: utf-8; Show-Trailing-Whitespace: t -*-
;;;
;;; provider.lisp — LLM provider interface and SSE stream parser
;;;

(in-package #:librecode-runner.provider)

(defparameter +redacted-auth-marker+ "[REDACTED]"
  "Sentinel persisted in place of a real credential in both durable sinks
(event_log.payload and session_provider_config.auth). Never a valid Bearer
token, so it can never be mistaken for a live credential by a downstream
reader that skipped rehydration.")

(defvar *session-auth-holder* (make-hash-table :test 'equal)
  "Process-local, session-keyed holder for the real (unredacted) provider
credential. CONFIGURE-SESSION populates it; GET-SESSION-CONFIG rehydrates
the live token from it for the same-process authenticated turn. Never
persisted -- process-lifetime-only retention is the accepted at-rest
boundary (N7 non-goals); a fresh process (e.g. after restart) has no entry
and GET-SESSION-CONFIG falls back to NIL, which correctly trips the
fail-safe send guard for a non-loopback endpoint rather than leaking or
misusing the marker as a header value.")

(defun configure-session (session-id &key base-url model auth)
  "Register or update the LLM provider configuration for the given SESSION-ID via commit-event.
A non-nil AUTH is held in-process (*session-auth-holder*) and never committed
in cleartext: the durable event payload and its projection persist
+redacted-auth-marker+ in its place."
  (if auth
      (setf (gethash session-id *session-auth-holder*) auth)
      (remhash session-id *session-auth-holder*))
  (let ((payload (list :base-url base-url
                       :model model
                       :auth (and auth +redacted-auth-marker+))))
    (librecode-runner.event-store:commit-event session-id payload :session-provider-configured)))

(defun get-session-config (session-id)
  "Retrieve the LLM provider configuration for the given SESSION-ID from *db*.
When the durable AUTH column holds +redacted-auth-marker+, rehydrate the
real credential from *session-auth-holder* (NIL if this process never held
it, e.g. after a restart) rather than returning the marker itself."
  (unless (and (boundp 'librecode-runner.event-store:*db*)
               librecode-runner.event-store:*db*)
    (error "No active database connection in *db*."))
  (let ((db librecode-runner.event-store:*db*)
        (id (if (stringp session-id)
                session-id
                (format nil "~A" session-id))))
    (let ((row (sqlite:execute-to-list db
                 "SELECT base_url, model, auth FROM session_provider_config WHERE session_id = ?"
                 id)))
      (when row
        (destructuring-bind (base-url model auth) (car row)
          (list :base-url base-url
                :model model
                :auth (if (equal auth +redacted-auth-marker+)
                          (gethash id *session-auth-holder*)
                          auth)))))))

(defun clear-session-configs ()
  "Clear all registered session provider configurations from *db*."
  (unless (and (boundp 'librecode-runner.event-store:*db*)
               librecode-runner.event-store:*db*)
    (error "No active database connection in *db*."))
  (sqlite:execute-non-query librecode-runner.event-store:*db*
                            "DELETE FROM session_provider_config;"))

(defun resolve-provider-endpoint (base-url)
  "Resolve the base-url into a generic completion endpoint, supporting query parameters.
If the path part ends with a known suffix, use it as-is. Otherwise, append /chat/completions
and preserve the query parameters."
  (if (null base-url)
      nil
      (let* ((q-pos (position #\? base-url))
             (url-path (if q-pos (subseq base-url 0 q-pos) base-url))
             (url-query (if q-pos (subseq base-url q-pos) ""))
             (trimmed (string-right-trim '(#\/) url-path))
             (suffixes '("/v1/chat/completions" "/chat/completions"))
             (has-suffix (some (lambda (suffix)
                                 (alexandria:ends-with-subseq suffix trimmed :test #'char=))
                               suffixes))
             (resolved-path (if has-suffix
                                trimmed
                                (format nil "~A/chat/completions" trimmed))))
        (format nil "~A~A" resolved-path url-query))))
