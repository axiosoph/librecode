;;; -*- Mode: Lisp; Syntax: Common-Lisp; indent-tabs-mode: nil; coding: utf-8; Show-Trailing-Whitespace: t -*-
;;;
;;; provider.lisp — LLM provider interface and SSE stream parser
;;;

(in-package #:librecode-runner.provider)

(defvar *session-configs* (make-hash-table :test 'equal)
  "Registry of session provider configurations mapping session-id to plist.")

(defvar *session-configs-lock* (bt:make-lock "session-configs-lock")
  "Lock protecting the session configs registry.")

(defun configure-session (session-id &key base-url model auth)
  "Register or update the LLM provider configuration for the given SESSION-ID."
  (let ((id (if (stringp session-id)
                session-id
                (format nil "~A" session-id))))
    (bt:with-lock-held (*session-configs-lock*)
      (setf (gethash id *session-configs*)
            (list :base-url base-url
                  :model model
                  :auth auth)))))

(defun get-session-config (session-id)
  "Retrieve the LLM provider configuration for the given SESSION-ID."
  (let ((id (if (stringp session-id)
                session-id
                (format nil "~A" session-id))))
    (bt:with-lock-held (*session-configs-lock*)
      (gethash id *session-configs*))))

(defun clear-session-configs ()
  "Clear all registered session provider configurations."
  (bt:with-lock-held (*session-configs-lock*)
    (clrhash *session-configs*)))

(defun resolve-provider-endpoint (base-url)
  "Resolve the base-url into a full chat-completions endpoint."
  (if (null base-url)
      nil
      (let* ((trimmed (string-right-trim '(#\/) base-url))
             (suffix "/chat/completions"))
        (if (alexandria:ends-with-subseq suffix trimmed :test #'char=)
            trimmed
            (format nil "~A~A" trimmed suffix)))))
