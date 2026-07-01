;;; -*- Mode: Lisp; Syntax: Common-Lisp; indent-tabs-mode: nil; coding: utf-8; Show-Trailing-Whitespace: t -*-
;;;
;;; provider.lisp — LLM provider interface and SSE stream parser
;;;

(in-package #:librecode-runner.provider)

(defun configure-session (session-id &key base-url model auth)
  "Register or update the LLM provider configuration for the given SESSION-ID via commit-event."
  (let ((payload (list :base-url base-url
                       :model model
                       :auth auth)))
    (librecode-runner.event-store:commit-event session-id payload :session-provider-configured)))

(defun get-session-config (session-id)
  "Retrieve the LLM provider configuration for the given SESSION-ID from *db*."
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
                :auth auth))))))

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
             (suffixes '("/v1/chat/completions" "/chat/completions" "/v1/messages"))
             (has-suffix (some (lambda (suffix)
                                 (alexandria:ends-with-subseq suffix trimmed :test #'char=))
                               suffixes))
             (resolved-path (if has-suffix
                                trimmed
                                (format nil "~A/chat/completions" trimmed))))
        (format nil "~A~A" resolved-path url-query))))
