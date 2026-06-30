;;; -*- Mode: Lisp; Syntax: Common-Lisp; indent-tabs-mode: nil; coding: utf-8; Show-Trailing-Whitespace: t -*-
;;;
;;; session.lisp — Session state and two-phase input admission
;;;

(in-package #:librecode-runner.session)

(defclass session ()
  ((id :initarg :id :reader session-id :type string)
   (state :initarg :state :accessor session-state :initform nil))
  (:documentation "Active execution session context."))

(defun coerce-session-id (session)
  "Extract the session ID string if SESSION is a session instance, otherwise return it directly."
  (if (typep session 'session)
      (session-id session)
      (string session)))

(defun admit-input (session prompt-id prompt-text &optional (delivery-mode "STEER"))
  "Admit an input into the durable session_input table.
Handles retry reconciliation for prompt-id reuse."
  (unless librecode-runner.event-store:*db*
    (error "No active database connection in *db*."))
  (let* ((session-id (coerce-session-id session))
         (db librecode-runner.event-store:*db*)
         (existing (sqlite:execute-to-list db
                    "SELECT session_id, prompt_text, delivery_mode, status FROM session_input WHERE id = ?"
                    prompt-id)))
    (if existing
        (destructuring-bind (e-session-id e-prompt-text e-delivery-mode e-status) (car existing)
          (if (and (string= e-session-id session-id)
                   (string= e-prompt-text prompt-text)
                   (string= e-delivery-mode delivery-mode))
              (cond
                ((string= e-status "PROMOTED")
                 ;; Already promoted; return existing session state / resume indicator
                 :promoted)
                ((string= e-status "PENDING")
                 ;; Already pending; treat as no-op
                 :pending)
                (t
                 ;; If status is anything else (e.g. EXPIRED or crashed/aborted), reset to PENDING
                 (sqlite:execute-non-query db
                   "UPDATE session_input SET status = 'PENDING', timestamp = ? WHERE id = ?"
                   (librecode-runner.event-store::current-timestamp-ms) prompt-id)
                 :pending))
              (error 'librecode-runner.conditions:protocol-invariant-violation
                     :invariant "Prompt ID reuse with conflicting fields"
                     :message (format nil "Prompt ID ~A already exists with conflicting fields." prompt-id))))
        (progn
          (sqlite:execute-non-query db
            "INSERT INTO session_input (id, session_id, prompt_text, delivery_mode, status, timestamp)
             VALUES (?, ?, ?, ?, 'PENDING', ?)"
            prompt-id session-id prompt-text delivery-mode (librecode-runner.event-store::current-timestamp-ms))
          :pending))))

(defun promote-input (session prompt-id)
  "Promote a single specific pending input by ID, appending it to the session history."
  (unless librecode-runner.event-store:*db*
    (error "No active database connection in *db*."))
  (let ((session-id (coerce-session-id session))
        (db librecode-runner.event-store:*db*)
        (now (librecode-runner.event-store::current-timestamp-ms)))
    (librecode-runner.event-store:with-transaction (db)
      (let ((input (sqlite:execute-to-list db
                     "SELECT prompt_text FROM session_input WHERE id = ? AND session_id = ? AND status = 'PENDING'"
                     prompt-id session-id)))
        (when input
          (let ((prompt-text (caar input)))
            (sqlite:execute-non-query db
              "UPDATE session_input SET status = 'PROMOTED' WHERE id = ?"
              prompt-id)
            (sqlite:execute-non-query db
              "INSERT INTO session_history (id, session_id, role, content, created_at)
               VALUES (?, ?, 'user', ?, ?)"
              prompt-id session-id prompt-text now)
            t))))))

(defun promote-pending-inputs (session &key (mode :steer))
  "Promote pending inputs of the given MODE (:steer or :queue) for the session.
If mode is :steer, promotes all pending steer inputs.
If mode is :queue, promotes exactly one pending queue input.
Returns the number of inputs promoted."
  (unless librecode-runner.event-store:*db*
    (error "No active database connection in *db*."))
  (let ((session-id (coerce-session-id session))
        (db librecode-runner.event-store:*db*)
        (now (librecode-runner.event-store::current-timestamp-ms)))
    (librecode-runner.event-store:with-transaction (db)
      (cond
        ((eq mode :steer)
         (let ((pending (sqlite:execute-to-list db
                          "SELECT id, prompt_text FROM session_input
                           WHERE session_id = ? AND delivery_mode = 'STEER' AND status = 'PENDING'
                           ORDER BY timestamp ASC"
                          session-id)))
           (dolist (input pending)
             (let ((input-id (first input))
                   (prompt-text (second input)))
               (sqlite:execute-non-query db
                 "UPDATE session_input SET status = 'PROMOTED' WHERE id = ?"
                 input-id)
               (sqlite:execute-non-query db
                 "INSERT INTO session_history (id, session_id, role, content, created_at)
                  VALUES (?, ?, 'user', ?, ?)"
                 input-id session-id prompt-text now)))
           (length pending)))
        ((eq mode :queue)
         (let ((pending (sqlite:execute-to-list db
                          "SELECT id, prompt_text FROM session_input
                           WHERE session_id = ? AND delivery_mode = 'QUEUE' AND status = 'PENDING'
                           ORDER BY timestamp ASC LIMIT 1"
                          session-id)))
           (if pending
               (let* ((input (car pending))
                      (input-id (first input))
                      (prompt-text (second input)))
                 (sqlite:execute-non-query db
                   "UPDATE session_input SET status = 'PROMOTED' WHERE id = ?"
                   input-id)
                 (sqlite:execute-non-query db
                   "INSERT INTO session_history (id, session_id, role, content, created_at)
                    VALUES (?, ?, 'user', ?, ?)"
                   input-id session-id prompt-text now)
                 1)
               0)))))))
