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
Enforces busy_timeout=5000, foreign_keys=ON, and journal_mode=WAL immediately on connection."
  (let* ((resolved (resolve-path db-path))
         (db (sqlite:connect resolved))
         (ok nil))
    (unwind-protect
         (progn
           (sqlite:execute-non-query db "PRAGMA busy_timeout = 5000;")
           (sqlite:execute-non-query db "PRAGMA foreign_keys = ON;")
           (sqlite:execute-non-query db "PRAGMA journal_mode = WAL;")
           (setf ok t)
           db)
      (unless ok
        (sqlite:disconnect db)))))

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

(defun alist-p (x)
  "Return t if x is an association list."
  (and (listp x)
       (consp x)
       (loop for cell in x
             always (consp cell))))

(defun plist-p (x)
  "Return t if x is a property list."
  (and (listp x)
       (consp x)
       (let ((len (list-length x)))
         (and len
              (evenp len)
              (loop for k in x by #'cddr
                    always (symbolp k))))))

(defun key-to-string (key)
  (if (symbolp key)
      (string-downcase (symbol-name key))
      (format nil "~A" key)))

(defun coerce-to-hash-table (val)
  (cond
    ((null val) nil)
    ((hash-table-p val)
     (let ((new-ht (make-hash-table :test 'equal)))
       (maphash (lambda (k v)
                  (setf (gethash (key-to-string k) new-ht)
                        (coerce-to-hash-table v)))
                val)
       new-ht))
    ((alist-p val)
     (let ((ht (make-hash-table :test 'equal)))
       (dolist (pair val)
         (setf (gethash (key-to-string (car pair)) ht)
               (coerce-to-hash-table (cdr pair))))
       ht))
    ((plist-p val)
     (let ((ht (make-hash-table :test 'equal)))
       (loop for (k v) on val by #'cddr
             do (setf (gethash (key-to-string k) ht)
                      (coerce-to-hash-table v)))
       ht))
    ((listp val)
     (mapcar #'coerce-to-hash-table val))
    ((vectorp val)
     (if (stringp val)
         val
         (map 'vector #'coerce-to-hash-table val)))
    (t val)))

(defun serialize-payload (payload)
  "Serialize PAYLOAD (either a string, plist, alist, hash-table, or list/vector) to a JSON string.
Recursively coerces plists and alists into hash-tables so they serialize to JSON objects."
  (if (stringp payload)
      payload
      (com.inuoe.jzon:stringify (coerce-to-hash-table payload))))

(defun parse-event-safely (event)
  "Parse a JSON string EVENT safely, returning the parsed object or NIL."
  (handler-case
      (if (stringp event)
          (com.inuoe.jzon:parse event)
          event)
    (error () nil)))

(defun init-db (db)
  "Initialize the 7 SQLite database tables and indices on the DB connection."
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

  ;; 7. session_provider_config
  (sqlite:execute-non-query db
    "CREATE TABLE IF NOT EXISTS session_provider_config (
        session_id TEXT PRIMARY KEY,
        base_url TEXT,
        model TEXT,
        auth TEXT
    );")

  db)



(defun get-event-field (parsed key)
  "Extract a field by keyword KEY (e.g. :epoch-id) from PARSED,
handling hash-tables (with string keys or symbols), alists, and plists."
  (let* ((key-str (string-downcase (symbol-name key)))
         (key-str-alt (substitute #\_ #\- key-str)))
    (cond
      ((hash-table-p parsed)
       (or (gethash key-str parsed)
           (gethash key-str-alt parsed)
           (gethash key parsed)))
      ((alist-p parsed)
       (let ((cell (or (assoc key parsed)
                       (assoc (intern (string-upcase key-str) :keyword) parsed)
                       (assoc (intern (string-upcase key-str-alt) :keyword) parsed))))
         (cdr cell)))
      ((plist-p parsed)
       (or (getf parsed key)
           (getf parsed (intern (string-upcase key-str) :keyword))
           (getf parsed (intern (string-upcase key-str-alt) :keyword))))
      (t nil))))

(defun apply-projectors (db session-id event type version)
  "Applies event projections to update session_state in DB."
  (let* ((parsed (parse-event-safely event))
         (agent-id (or (when (hash-table-p parsed)
                         (or (gethash "agent_id" parsed)
                             (gethash "agent-id" parsed)))
                       (when (alist-p parsed)
                         (or (cdr (assoc :agent-id parsed))
                             (cdr (assoc :agent_id parsed))))
                       (when (plist-p parsed)
                         (or (getf parsed :agent-id)
                             (getf parsed :agent_id)))
                       (sqlite:execute-single db "SELECT agent_id FROM session_state WHERE session_id = ?" session-id)
                       "unknown-agent"))
         (status (or (when (hash-table-p parsed)
                       (gethash "status" parsed))
                     (when (alist-p parsed)
                       (cdr (assoc :status parsed)))
                     (when (plist-p parsed)
                       (getf parsed :status))
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
      session-id agent-id version status now)
    ;; Handle context compaction baseline updates (defer queries to satisfy I2 atomicity)
    (let ((norm-type (if (symbolp type)
                         (intern (string-upcase (symbol-name type)) :keyword)
                         (intern (string-upcase (format nil "~A" type)) :keyword))))
      (when (eq norm-type :session-provider-configured)
        (let ((base-url (get-event-field parsed :base-url))
              (model (get-event-field parsed :model))
              (auth (get-event-field parsed :auth)))
          (sqlite:execute-non-query db
            "INSERT OR REPLACE INTO session_provider_config (session_id, base_url, model, auth)
             VALUES (?, ?, ?, ?)"
            session-id base-url model auth)))
      (when (eq norm-type :context-baseline-updated)
        (let ((epoch-id (get-event-field parsed :epoch-id))
              (baseline-text (get-event-field parsed :baseline-text))
              (compacted-ids (get-event-field parsed :compacted-message-ids)))
          (when (and epoch-id baseline-text)
            (sqlite:execute-non-query db
              "INSERT OR REPLACE INTO context_epoch (session_id, epoch_id, baseline_text, created_at)
               VALUES (?, ?, ?, ?)"
              session-id epoch-id baseline-text now))
          (when compacted-ids
            (cond
              ((vectorp compacted-ids)
               (loop for id across compacted-ids
                     do (sqlite:execute-non-query db
                          "DELETE FROM session_history WHERE id = ?"
                          id)))
              ((listp compacted-ids)
               (loop for id in compacted-ids
                     do (sqlite:execute-non-query db
                          "DELETE FROM session_history WHERE id = ?"
                          id))))))))))

(defun commit-event (session-id event type &optional version)
  "Commits an event to the event log and applies projectors inside a single transaction."
  (unless *db*
    (error "No active database connection in *db*."))
  (let ((payload-str (serialize-payload event))
        (type-str (string type))
        (now (current-timestamp-ms)))
    (with-immediate-transaction (*db*)
      (let ((actual-version (or version
                                (let ((max-seq (sqlite:execute-single *db*
                                                 "SELECT max(sequence) FROM event_log WHERE session_id = ?"
                                                 session-id)))
                                  (if max-seq (1+ max-seq) 1)))))
        (sqlite:execute-non-query *db*
          "INSERT INTO event_log (session_id, sequence, event_type, payload, timestamp)
           VALUES (?, ?, ?, ?, ?)"
          session-id actual-version type-str payload-str now)
        (apply-projectors *db* session-id event type actual-version)
        actual-version))))
