;;; -*- Mode: Lisp; Syntax: Common-Lisp; indent-tabs-mode: nil; coding: utf-8; Show-Trailing-Whitespace: t -*-
;;;
;;; event-store.lisp — Durable event sourcing and SQLite integration
;;;

(in-package #:librecode-runner.event-store)

(defvar *workspace-root* nil
  "The dynamic workspace root directory. File resolutions must be relative to this path.")

(defvar *db* nil
  "The active thread-local SQLite database connection.")

(defun resolve-path (relative-path)
  "Resolve a relative path against the dynamic *workspace-root*.
If *workspace-root* is nil, or if relative-path is absolute, returns relative-path."
  (let ((path (pathname relative-path)))
    (if (and *workspace-root* (not (uiop:absolute-pathname-p path)))
        (uiop:merge-pathnames* path (uiop:ensure-directory-pathname *workspace-root*))
        path)))

(defun connect-db (db-path)
  "Establish a connection to the SQLite database at DB-PATH.
Resolves DB-PATH relative to *workspace-root*.
Enforces journal_mode=WAL, busy_timeout=5000, and foreign_keys=ON immediately on connection."
  (let* ((resolved (resolve-path db-path))
         (db (sqlite:connect resolved)))
    (handler-bind ((error (lambda (c)
                            (declare (ignore c))
                            (sqlite:disconnect db))))
      (sqlite:execute-non-query db "PRAGMA foreign_keys = ON;")
      (sqlite:execute-non-query db "PRAGMA journal_mode = WAL;")
      (sqlite:execute-non-query db "PRAGMA busy_timeout = 5000;"))
    db))

(defmacro with-immediate-transaction ((db) &body body)
  "Executes BODY inside a SQLite immediate transaction.
Rolls back completely if an error occurs."
  (let ((ok (gensym "OK"))
        (db-var (gensym "DB")))
    `(let ((,ok nil)
           (,db-var ,db))
       (sqlite:execute-non-query ,db-var "BEGIN IMMEDIATE TRANSACTION")
       (unwind-protect
            (multiple-value-prog1
                (progn ,@body)
              (sqlite:execute-non-query ,db-var "COMMIT")
              (setf ,ok t))
         (unless ,ok
           (sqlite:execute-non-query ,db-var "ROLLBACK"))))))

(defmacro with-transaction ((db) &body body)
  "Alias for with-immediate-transaction, maintaining exported API parity."
  `(with-immediate-transaction (,db) ,@body))

(defun current-timestamp-ms ()
  "Return the current Unix epoch timestamp in milliseconds."
  #+sbcl
  (multiple-value-bind (sec usec) (sb-ext:get-time-of-day)
    (+ (* sec 1000) (floor usec 1000)))
  #-sbcl
  (* (get-universal-time) 1000))

(defun serialize-payload (payload)
  "Serialize PAYLOAD (either a string, plist, or hash-table) to a JSON string."
  (if (stringp payload)
      payload
      (com.inuoe.jzon:stringify payload)))

(defun parse-event-safely (event)
  "Parse a JSON string EVENT safely, returning the parsed object or NIL."
  (handler-case
      (if (stringp event)
          (com.inuoe.jzon:parse event)
          event)
    (error () nil)))

(defun init-db (db)
  "Initialize the 10 SQLite database tables and indices on the DB connection."
  ;; 1. event_log
  (sqlite:execute-non-query db
    "CREATE TABLE IF NOT EXISTS event_log (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        session_id TEXT NOT NULL,
        sequence INTEGER NOT NULL,
        event_type TEXT NOT NULL,
        payload TEXT NOT NULL,
        timestamp INTEGER NOT NULL,
        UNIQUE(session_id, sequence)
    );")
  (sqlite:execute-non-query db
    "CREATE INDEX IF NOT EXISTS idx_event_log_session ON event_log(session_id);")

  ;; 2. session_input
  (sqlite:execute-non-query db
    "CREATE TABLE IF NOT EXISTS session_input (
        id TEXT PRIMARY KEY,
        session_id TEXT NOT NULL,
        prompt_text TEXT NOT NULL,
        delivery_mode TEXT NOT NULL,
        status TEXT NOT NULL,
        timestamp INTEGER NOT NULL
    );")
  (sqlite:execute-non-query db
    "CREATE INDEX IF NOT EXISTS idx_session_input_pending ON session_input(session_id, status);")

  ;; 3. permission_saved
  (sqlite:execute-non-query db
    "CREATE TABLE IF NOT EXISTS permission_saved (
        project_id TEXT NOT NULL,
        action TEXT NOT NULL,
        resource TEXT NOT NULL,
        effect TEXT NOT NULL,
        timestamp INTEGER NOT NULL,
        PRIMARY KEY (project_id, action, resource)
    );")

  ;; 4. session_state
  (sqlite:execute-non-query db
    "CREATE TABLE IF NOT EXISTS session_state (
        session_id TEXT PRIMARY KEY,
        agent_id TEXT NOT NULL,
        version INTEGER NOT NULL,
        status TEXT NOT NULL,
        last_updated INTEGER NOT NULL
    );")

  ;; 5. session_history
  (sqlite:execute-non-query db
    "CREATE TABLE IF NOT EXISTS session_history (
        id TEXT PRIMARY KEY,
        session_id TEXT NOT NULL,
        role TEXT NOT NULL,
        content TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        FOREIGN KEY(session_id) REFERENCES session_state(session_id) ON DELETE CASCADE
    );")
  (sqlite:execute-non-query db
    "CREATE INDEX IF NOT EXISTS idx_session_history_session ON session_history(session_id);")

  ;; 6. context_epoch
  (sqlite:execute-non-query db
    "CREATE TABLE IF NOT EXISTS context_epoch (
        session_id TEXT PRIMARY KEY,
        epoch_id TEXT NOT NULL,
        baseline_text TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        FOREIGN KEY(session_id) REFERENCES session_state(session_id) ON DELETE CASCADE
    );")

  ;; 7. deposits
  (sqlite:execute-non-query db
    "CREATE TABLE IF NOT EXISTS deposits (
        id TEXT PRIMARY KEY,
        step TEXT NOT NULL,
        evidence TEXT NOT NULL CHECK(length(evidence) > 0),
        created_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now'))
    );")

  ;; 8. deposit_cites
  (sqlite:execute-non-query db
    "CREATE TABLE IF NOT EXISTS deposit_cites (
        deposit_id TEXT NOT NULL,
        path TEXT NOT NULL,
        PRIMARY KEY (deposit_id, path),
        FOREIGN KEY (deposit_id) REFERENCES deposits(id) ON DELETE CASCADE
    );")

  ;; 9. deposit_refs
  (sqlite:execute-non-query db
    "CREATE TABLE IF NOT EXISTS deposit_refs (
        source_id TEXT NOT NULL,
        target_id TEXT NOT NULL,
        ref_type TEXT NOT NULL,
        PRIMARY KEY (source_id, target_id, ref_type),
        FOREIGN KEY (source_id) REFERENCES deposits(id) ON DELETE CASCADE,
        FOREIGN KEY (target_id) REFERENCES deposits(id) ON DELETE CASCADE
    );")

  ;; 10. findings
  (sqlite:execute-non-query db
    "CREATE TABLE IF NOT EXISTS findings (
        id TEXT PRIMARY KEY,
        session_id TEXT NOT NULL,
        rule_id TEXT,
        status TEXT NOT NULL CHECK(status IN ('open', 'resolved')),
        evaluator TEXT,
        resolved_at INTEGER,
        resolution_deposit_id TEXT,
        FOREIGN KEY(id) REFERENCES deposits(id) ON DELETE CASCADE,
        FOREIGN KEY(session_id) REFERENCES session_state(session_id) ON DELETE CASCADE,
        FOREIGN KEY(resolution_deposit_id) REFERENCES deposits(id) ON DELETE SET NULL
    );")
  (sqlite:execute-non-query db
    "CREATE INDEX IF NOT EXISTS idx_findings_session ON findings(session_id);")

  db)

(defun apply-projectors (db session-id event type version)
  "Applies event projections to update session_state in DB."
  (declare (ignore type))
  (let* ((parsed (parse-event-safely event))
         (agent-id (or (when (hash-table-p parsed)
                         (or (gethash "agent_id" parsed)
                             (gethash "agent-id" parsed)))
                       (when (listp parsed)
                         (or (cdr (assoc :agent-id parsed))
                             (cdr (assoc :agent_id parsed))
                             (getf parsed :agent-id)
                             (getf parsed :agent_id)))
                       (sqlite:execute-single db "SELECT agent_id FROM session_state WHERE session_id = ?" session-id)
                       "unknown-agent"))
         (status (or (when (hash-table-p parsed)
                       (gethash "status" parsed))
                     (when (listp parsed)
                       (or (cdr (assoc :status parsed))
                           (getf parsed :status)))
                     (sqlite:execute-single db "SELECT status FROM session_state WHERE session_id = ?" session-id)
                     "idle"))
         (now (current-timestamp-ms)))
    (sqlite:execute-non-query db
      "INSERT INTO session_state (session_id, agent_id, version, status, last_updated)
       VALUES (?, ?, ?, ?, ?)
       ON CONFLICT(session_id) DO UPDATE SET
         version = excluded.version,
         status = excluded.status,
         last_updated = excluded.last_updated"
      session-id agent-id version status now)))

(defun commit-event (session-id event type version)
  "Commits an event to the event log and applies projectors inside a single transaction."
  (unless *db*
    (error "No active database connection in *db*."))
  (let ((payload-str (serialize-payload event))
        (type-str (string type))
        (now (current-timestamp-ms)))
    (with-immediate-transaction (*db*)
      (sqlite:execute-non-query *db*
        "INSERT INTO event_log (session_id, sequence, event_type, payload, timestamp)
         VALUES (?, ?, ?, ?, ?)"
        session-id version type-str payload-str now)
      (apply-projectors *db* session-id event type version))))
