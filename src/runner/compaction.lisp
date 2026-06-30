;;; -*- Mode: Lisp; Syntax: Common-Lisp; indent-tabs-mode: nil; coding: utf-8; Show-Trailing-Whitespace: t -*-
;;;
;;; compaction.lisp — Context compaction engine and baseline resets
;;;

(in-package #:librecode-runner.compaction)

(defun estimate-tokens (text)
  "Heuristic token count based on string length."
  (floor (length text) 4))

(defun compact-context (session &key (max-tokens 2000))
  "Check session history token usage, and if it exceeds MAX-TOKENS, compact it.
Summarizes older messages, updates the baseline epoch, commits a baseline event,
and deletes compacted messages from the history."
  (unless librecode-runner.event-store:*db*
    (error "No active database connection in *db*."))
  (let* ((session-id (librecode-runner.session::coerce-session-id session))
         (db librecode-runner.event-store:*db*)
         (history (sqlite:execute-to-list db
                    "SELECT id, role, content, created_at FROM session_history
                     WHERE session_id = ? ORDER BY created_at ASC"
                    session-id)))
    (let ((total-tokens 0)
          (msg-tokens-list nil))
      (dolist (row history)
        (let* ((content (third row))
               (tokens (estimate-tokens content)))
          (incf total-tokens tokens)
          (push (list :id (first row)
                      :role (second row)
                      :content content
                      :created-at (fourth row)
                      :tokens tokens)
                msg-tokens-list)))
      (setf msg-tokens-list (nreverse msg-tokens-list))

      (if (> total-tokens max-tokens)
          (let* ((total-count (length msg-tokens-list))
                 ;; Keep at least 2 messages
                 (keep-count (min total-count (max 2 (floor total-count 3))))
                 (split-idx (- total-count keep-count))
                 (older (subseq msg-tokens-list 0 split-idx)))
            (if older
                (let* ((summary-lines (mapcar (lambda (m)
                                                (format nil "[~A]: ~A" (getf m :role) (getf m :content)))
                                              older))
                       (summary (format nil "Summary of past context:~%~{~A~^~%~}" summary-lines))
                       (epoch-id (format nil "epoch-~A" (librecode-runner.event-store::current-timestamp-ms)))
                       (next-seq (librecode-runner.agent::get-next-event-sequence session-id))
                       (now (librecode-runner.event-store::current-timestamp-ms)))
                  ;; Commit baseline update event for replay self-containment (this runs inside its own transaction)
                  (librecode-runner.event-store:commit-event
                   session-id
                   `((:epoch-id . ,epoch-id)
                     (:baseline-text . ,summary)
                     (:status . "compacted"))
                   :context-baseline-updated
                   next-seq)
                  ;; Insert/Replace in context_epoch and delete from history inside a single transaction
                  (librecode-runner.event-store:with-transaction (db)
                    (sqlite:execute-non-query db
                      "INSERT OR REPLACE INTO context_epoch (session_id, epoch_id, baseline_text, created_at)
                       VALUES (?, ?, ?, ?)"
                      session-id epoch-id summary now)
                    (dolist (m older)
                      (sqlite:execute-non-query db
                        "DELETE FROM session_history WHERE id = ?"
                        (getf m :id))))
                  t)
                nil))
          nil))))
