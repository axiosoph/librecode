;;; -*- Mode: Lisp; Syntax: Common-Lisp; indent-tabs-mode: nil; coding: utf-8; Show-Trailing-Whitespace: t -*-
;;;
;;; compaction.lisp — Context compaction engine and baseline resets
;;;

(in-package #:librecode-runner.compaction)

(defun estimate-tokens (text)
  "Heuristic token count based on string length."
  (floor (length text) 4))

(defun assistant-tool-call-ids (content)
  "Return the list of call-ids an assistant row's CONTENT declares via a
top-level tool_calls JSON array, or NIL for plain text / malformed content.
Only trusts the already-validated top-level tool_calls key (never string
matching), so adversarial tool-argument text that merely looks like a
tool_calls array cannot be mistaken for one."
  (let ((parsed (handler-case (com.inuoe.jzon:parse content) (error () nil))))
    (when (and (hash-table-p parsed) (gethash "tool_calls" parsed))
      (map 'list (lambda (tc) (gethash "id" tc)) (gethash "tool_calls" parsed)))))

(defun compute-group-ranges (msg-tokens-list)
  "Return a vector parallel to MSG-TOKENS-LIST where element I is a (MIN . MAX)
cons spanning the index range of the tool-call/tool-result group row I
belongs to (a plain message's own singleton range, or the shared range of an
assistant tool-call row and every tool-result row linked to it by
tool_call_id)."
  (let* ((n (length msg-tokens-list))
         (rows (coerce msg-tokens-list 'vector))
         (call-id->assistant-idx (make-hash-table :test 'equal))
         (group-rep (make-array n)))
    (dotimes (i n)
      (setf (aref group-rep i) i)
      (let ((row (aref rows i)))
        (when (equal (getf row :role) "assistant")
          (dolist (call-id (assistant-tool-call-ids (getf row :content)))
            (when call-id (setf (gethash call-id call-id->assistant-idx) i))))))
    (dotimes (i n)
      (let ((row (aref rows i)))
        (when (equal (getf row :role) "tool")
          (let ((assistant-idx (gethash (getf row :tool-call-id) call-id->assistant-idx)))
            (when assistant-idx (setf (aref group-rep i) assistant-idx))))))
    (let ((ranges (make-array n :initial-element nil)))
      (dotimes (i n)
        (let* ((rep (aref group-rep i))
               (range (aref ranges rep)))
          (setf (aref ranges rep)
                (if range
                    (cons (min (car range) i) (max (cdr range) i))
                    (cons i i)))))
      (map 'vector (lambda (i) (aref ranges (aref group-rep i))) group-rep))))

(defun adjust-split-for-groups (split-idx group-ranges)
  "Adjust SPLIT-IDX until it no longer falls strictly inside any group's
(MIN . MAX) range in GROUP-RANGES -- i.e. until no group has members on both
sides of the split. Never splits a group: a straddled group is pushed
forward into the compacted side (compacting more, per the resolved
preference), UNLESS it is the group containing the last message in history,
in which case the split is pulled back so that most-recent group is kept
whole instead -- pushing it forward would compact away all of history's
newest content, which [a2] rules out even at the cost of missing the token
target."
  (let* ((n (length group-ranges))
         (tail-range (when (plusp n) (aref group-ranges (1- n)))))
    (loop
      (let ((moved nil))
        (dotimes (i n)
          (let ((range (aref group-ranges i)))
            (when (and (< (car range) split-idx) (>= (cdr range) split-idx))
              (setf split-idx (if (eq range tail-range)
                                  (car range)
                                  (1+ (cdr range))))
              (setf moved t))))
        (unless moved (return split-idx))))))

(defun compact-context (session &key (max-tokens 2000))
  "Check session history token usage, and if it exceeds MAX-TOKENS, compact it.
Summarizes older messages, updates the baseline epoch, commits a baseline event,
and deletes compacted messages from the history."
  (unless librecode-runner.event-store:*db*
    (error "No active database connection in *db*."))
  (let* ((session-id (librecode-runner.session::coerce-session-id session))
         (db librecode-runner.event-store:*db*)
         (history (sqlite:execute-to-list db
                    "SELECT id, role, content, created_at, tool_call_id FROM session_history
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
                      :tool-call-id (fifth row)
                      :tokens tokens)
                msg-tokens-list)))
      (setf msg-tokens-list (nreverse msg-tokens-list))

      (if (> total-tokens max-tokens)
          (let* ((total-count (length msg-tokens-list))
                 ;; Keep at least 2 messages
                 (keep-count (min total-count (max 2 (floor total-count 3))))
                 (naive-split-idx (- total-count keep-count))
                 ;; Never let a tool-call/tool-result group straddle the
                 ;; split: push the boundary forward to keep the whole group
                 ;; on the compacted side rather than orphan half of it.
                 (split-idx (adjust-split-for-groups
                             naive-split-idx
                             (compute-group-ranges msg-tokens-list)))
                 (older (subseq msg-tokens-list 0 split-idx)))
            (if older
                (let* ((summary-lines (mapcar (lambda (m)
                                                (format nil "[~A]: ~A" (getf m :role) (getf m :content)))
                                              older))
                       (summary (format nil "Summary of past context:~%~{~A~^~%~}" summary-lines))
                       (epoch-id (format nil "epoch-~A" (librecode-runner.event-store::current-timestamp-ms)))
                       (compacted-ids (map 'vector (lambda (m) (getf m :id)) older)))
                  ;; Commit baseline update event for replay self-containment.
                  ;; Database updates are deferred to apply-projectors in event-store.lisp to ensure I2 atomicity.
                  (librecode-runner.event-store:commit-event
                   session-id
                   `((:epoch-id . ,epoch-id)
                     (:baseline-text . ,summary)
                     (:status . "compacted")
                     (:compacted-message-ids . ,compacted-ids))
                   :context-baseline-updated)
                  t)
                nil))
          nil))))
