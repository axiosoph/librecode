;;; -*- Mode: Lisp; Syntax: Common-Lisp; indent-tabs-mode: nil; coding: utf-8; Show-Trailing-Whitespace: t -*-
;;;
;;; provider.lisp — LLM provider interface and SSE stream parser
;;;

(in-package #:librecode-runner.provider)

(defun configure-session (session-id &key base-url model auth)
  "Register or update the LLM provider configuration for the given SESSION-ID in *db*."
  (unless (and (boundp 'librecode-runner.event-store:*db*)
               librecode-runner.event-store:*db*)
    (error "No active database connection in *db*."))
  (let ((db librecode-runner.event-store:*db*)
        (id (if (stringp session-id)
                session-id
                (format nil "~A" session-id))))
    ;; Dynamically ensure the table exists
    (sqlite:execute-non-query db
      "CREATE TABLE IF NOT EXISTS session_provider_config (
          session_id TEXT PRIMARY KEY,
          base_url TEXT,
          model TEXT,
          auth TEXT
      );")
    (sqlite:execute-non-query db
      "INSERT OR REPLACE INTO session_provider_config (session_id, base_url, model, auth)
       VALUES (?, ?, ?, ?);"
      id base-url model auth)))

(defun get-session-config (session-id)
  "Retrieve the LLM provider configuration for the given SESSION-ID from *db*."
  (unless (and (boundp 'librecode-runner.event-store:*db*)
               librecode-runner.event-store:*db*)
    (error "No active database connection in *db*."))
  (let ((db librecode-runner.event-store:*db*)
        (id (if (stringp session-id)
                session-id
                (format nil "~A" session-id))))
    ;; Dynamically ensure the table exists
    (sqlite:execute-non-query db
      "CREATE TABLE IF NOT EXISTS session_provider_config (
          session_id TEXT PRIMARY KEY,
          base_url TEXT,
          model TEXT,
          auth TEXT
      );")
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
  (let ((db librecode-runner.event-store:*db*))
    ;; Dynamically ensure the table exists
    (sqlite:execute-non-query db
      "CREATE TABLE IF NOT EXISTS session_provider_config (
          session_id TEXT PRIMARY KEY,
          base_url TEXT,
          model TEXT,
          auth TEXT
      );")
    (sqlite:execute-non-query db "DELETE FROM session_provider_config;")))

(defun resolve-provider-endpoint (base-url)
  "Resolve the base-url into a generic completion endpoint.
If base-url ends with a known suffix (e.g. /v1/chat/completions, /chat/completions,
or /v1/messages), use it as-is. Otherwise, append /chat/completions."
  (if (null base-url)
      nil
      (let* ((trimmed (string-right-trim '(#\/) base-url))
             (suffixes '("/v1/chat/completions" "/chat/completions" "/v1/messages")))
        (if (some (lambda (suffix)
                    (alexandria:ends-with-subseq suffix trimmed :test #'char=))
                  suffixes)
            base-url
            (format nil "~A/chat/completions" trimmed)))))
