;;; -*- Mode: Lisp; Syntax: Common-Lisp; indent-tabs-mode: nil; coding: utf-8; Show-Trailing-Whitespace: t -*-
;;;
;;; event-store-tests.lisp — Unit and property tests for librecode event store
;;;

(defpackage #:librecode-test.event-store
  (:use #:cl
        #:fiveam
        #:check-it
        #:librecode-runner.event-store
        #:librecode-runner.conditions)
  (:shadowing-import-from #:check-it #:*num-trials*)
  (:export #:event-store-suite))

(in-package #:librecode-test.event-store)

(def-suite event-store-suite
  :description "Suite for event store tests.")

(in-suite event-store-suite)

;;; --- Sandbox Fixtures ---

(defun create-temp-directory-path ()
  "Create a temporary directory under standard system temp directory and return its path."
  (let* ((tempdir (uiop:temporary-directory))
         (unique-dir (make-pathname :directory (append (pathname-directory tempdir)
                                                       (list (format nil "librecode-sandbox-~A-~A"
                                                                     (get-universal-time)
                                                                     (random 1000000)))))))
    (ensure-directories-exist unique-dir)
    unique-dir))

(defun delete-directory-and-files (path)
  "Recursively delete the sandbox directory PATH."
  (let ((path (uiop:ensure-directory-pathname path)))
    (when (uiop:directory-exists-p path)
      (uiop:delete-directory-tree path
                                  :validate (lambda (p)
                                              (search "librecode-sandbox" (namestring p)))
                                  :if-does-not-exist :keep))))

(defun init-sandbox-git (path)
  "Stub for git initialization inside sandbox."
  (uiop:run-program (list "git" "init" (namestring path)) :output nil))

(defun write-sandbox-config (path config-plist)
  "Stub for writing sandbox configuration."
  (declare (ignore path config-plist))
  nil)

(defmacro with-tmp-sandbox ((path-var &key git config-plist) &body body)
  "Creates a temporary directory, binds PATH-VAR, and cleans up on exit."
  `(let ((,path-var (create-temp-directory-path)))
     (unwind-protect
          (progn
            (when ,git
              (init-sandbox-git ,path-var))
            (when ,config-plist
              (write-sandbox-config ,path-var ,config-plist))
            ,@body)
       (handler-case
           (delete-directory-and-files ,path-var)
         (serious-condition () nil)))))

(defmacro with-test-db ((db-var sandbox-dir) &body body)
  "Binds *workspace-root* and *db* to a local test SQLite DB within the sandbox."
  `(let* ((*workspace-root* ,sandbox-dir))
     (let* ((*db* (connect-db "test.db"))
            (,db-var *db*))
       (unwind-protect
            (progn
              (init-db *db*)
              ,@body)
         (sqlite:disconnect *db*)))))

;;; --- Unit Tests ---

(test test-foreign-keys
  "Asserts foreign key constraints and cascading deletes are enforced."
  (with-tmp-sandbox (dir)
    (with-test-db (db dir)
      ;; 1. Setup session and history record
      (sqlite:execute-non-query db
        "INSERT INTO session_state (session_id, agent_id, version, status, last_updated)
         VALUES (?, ?, ?, ?, ?)"
        "session-1" "agent-1" 1 "active" 1000)
      (sqlite:execute-non-query db
        "INSERT INTO session_history (id, session_id, role, content, created_at)
         VALUES (?, ?, ?, ?, ?)"
        "history-1" "session-1" "user" "hello" 1000)

      ;; Verify insertions
      (is (equal "session-1" (sqlite:execute-single db "SELECT session_id FROM session_state")))
      (is (equal "history-1" (sqlite:execute-single db "SELECT id FROM session_history")))

      ;; Delete session to verify cascade delete deletes history record
      (sqlite:execute-non-query db "DELETE FROM session_state WHERE session_id = ?" "session-1")
      (is (null (sqlite:execute-single db "SELECT id FROM session_history WHERE id = ?" "history-1")))

      ;; 2. Verify foreign key violation on missing session reference
      (signals sqlite:sqlite-error
        (sqlite:execute-non-query db
          "INSERT INTO session_history (id, session_id, role, content, created_at)
           VALUES (?, ?, ?, ?, ?)"
          "history-invalid" "non-existent-session" "user" "hello" 1000)))))

(test test-immediate-transactions
  "Validates serialization of immediate transactions and concurrent write safety."
  (with-tmp-sandbox (dir)
    (let ((db-path (uiop:merge-pathnames* "test.db" dir)))
      ;; Initialize schema
      (let ((db (connect-db db-path)))
        (unwind-protect
             (init-db db)
          (sqlite:disconnect db)))

      (let ((thread-a-in-tx nil)
            (thread-a-done nil)
            (write-success nil)
            (concurrent-write-failed nil))

        (let ((thread-a (bt:make-thread
                         (lambda ()
                           (let ((*workspace-root* dir)
                                 (*db* (connect-db db-path)))
                             (unwind-protect
                                  (progn
                                    (with-immediate-transaction (*db*)
                                      (sqlite:execute-non-query *db*
                                        "INSERT INTO session_state (session_id, agent_id, version, status, last_updated)
                                         VALUES (?, ?, ?, ?, ?)"
                                        "session-concurrent" "agent-a" 1 "active" 1000)
                                      (setf thread-a-in-tx t)
                                      (sleep 0.4))
                                    (setf write-success t))
                               (sqlite:disconnect *db*)
                               (setf thread-a-done t)))))))

          ;; Wait for Thread A to start and acquire its write lock
          (loop until thread-a-in-tx do (sleep 0.01))

          ;; Attempt concurrent write from Thread B (main thread) with timeout 0
          (let ((*workspace-root* dir)
                (*db* (connect-db db-path)))
            (unwind-protect
                 (progn
                   (sqlite:execute-non-query *db* "PRAGMA busy_timeout = 0;")
                   (handler-case
                       (with-immediate-transaction (*db*)
                         (sqlite:execute-non-query *db*
                           "INSERT INTO session_state (session_id, agent_id, version, status, last_updated)
                            VALUES (?, ?, ?, ?, ?)"
                           "session-concurrent" "agent-b" 1 "active" 1000))
                     (sqlite:sqlite-error ()
                       (setf concurrent-write-failed t))))
              (sqlite:disconnect *db*)))

          ;; Wait for Thread A to complete
          (loop until thread-a-done do (sleep 0.01))
          (bt:join-thread thread-a)

          ;; Assert safety properties
          (is-true write-success)
          (is-true concurrent-write-failed))))))

(test test-acid-commit
  "Verifies rollback of both event log and projections on error."
  (with-tmp-sandbox (dir)
    (with-test-db (db dir)
      ;; Execute a commit-event that succeeds
      (commit-event "session-good"
                    '((:agent-id . "agent-good") (:status . "active"))
                    :test-event
                    1)
      
      ;; Verify it committed
      (is (equal 1 (sqlite:execute-single db "SELECT sequence FROM event_log WHERE session_id = ?" "session-good")))
      (is (equal "session-good" (sqlite:execute-single db "SELECT session_id FROM session_state WHERE session_id = ?" "session-good")))

      ;; Attempt a commit-event that will fail during apply-projectors (due to invalid list parameter binding)
      (handler-case
          (commit-event "session-bad"
                        '((:agent-id . (1 2 3)) (:status . "active"))
                        :test-event
                        1)
        (error (c)
          (declare (ignore c))
          nil))

      ;; Verify that BOTH the event log and the projection were rolled back
      (is (null (sqlite:execute-single db "SELECT sequence FROM event_log WHERE session_id = ?" "session-bad")))
      (is (null (sqlite:execute-single db "SELECT session_id FROM session_state WHERE session_id = ?" "session-bad"))))))

;;; --- Property Tests ---

(defun val-equal-p (v1 v2)
  "Recursively check equality of coerced Lisp structures vs parsed JSON structures."
  (cond
    ((and (stringp v1) (stringp v2))
     (string= v1 v2))
    ((and (hash-table-p v1) (hash-table-p v2))
     (and (= (hash-table-count v1) (hash-table-count v2))
          (loop for k being the hash-keys of v1 using (hash-value val1)
                always (multiple-value-bind (val2 found) (gethash k v2)
                         (and found (val-equal-p val1 val2))))))
    ((and (listp v1) (listp v2))
     (and (= (length v1) (length v2))
          (every #'val-equal-p v1 v2)))
    ((and (vectorp v1) (vectorp v2))
     (and (= (length v1) (length v2))
          (every #'val-equal-p v1 v2)))
    (t (equal v1 v2))))

(defun round-trip-ok-p (payload)
  "Test if payload round-trips correctly through serialization."
  (handler-case
      (let* ((canonical (librecode-runner.event-store::coerce-to-hash-table payload))
             (serialized (librecode-runner.event-store::serialize-payload payload))
             (parsed (com.inuoe.jzon:parse serialized)))
        (val-equal-p canonical parsed))
    (error () nil)))

(test test-serialization-roundtrip-plist
  "Property test verifying that arbitrary generated plists roundtrip parse cleanly."
  (is-true
   (check-it
    (generator
     (map (lambda (pairs)
            (loop for (k v) in pairs
                  append (list k v)))
          (list (tuple (map (lambda (str) (intern (string-upcase str) :keyword))
                            (string :min-length 1 :max-length 8))
                       (or (integer)
                           (string :min-length 0 :max-length 8)
                           (boolean)))
                :min-length 1 :max-length 10)))
    #'round-trip-ok-p)))

(test test-serialization-roundtrip-alist
  "Property test verifying that arbitrary generated alists roundtrip parse cleanly."
  (is-true
   (check-it
    (generator
     (map (lambda (pairs)
            (loop for (k v) in pairs
                  collect (cons k v)))
          (list (tuple (map (lambda (str) (intern (string-upcase str) :keyword))
                            (string :min-length 1 :max-length 8))
                       (or (integer)
                           (string :min-length 0 :max-length 8)
                           (boolean)))
                :min-length 1 :max-length 10)))
    #'round-trip-ok-p)))

(test test-serialization-roundtrip-hash-table
  "Property test verifying that arbitrary generated hash-tables roundtrip parse cleanly."
  (is-true
   (check-it
    (generator
     (map (lambda (pairs)
            (let ((ht (make-hash-table :test 'equal)))
              (loop for (k v) in pairs
                    do (setf (gethash k ht) v))
              ht))
          (list (tuple (string :min-length 1 :max-length 8)
                       (or (integer)
                           (string :min-length 0 :max-length 8)
                           (boolean)))
                :min-length 1 :max-length 10)))
    #'round-trip-ok-p)))

;;; --- Nested Property-Based Serialization ---

(check-it:def-generator nested-json-structure (depth)
  (if (<= depth 0)
      (check-it:generator
       (or (integer)
           (string :min-length 1 :max-length 8)
           (boolean)))
      (check-it:generator
       (or (integer)
           (string :min-length 1 :max-length 8)
           (boolean)
           (map (lambda (lst) (coerce lst 'vector))
                (list (nested-json-structure (1- depth)) :min-length 1 :max-length 3))
           (map (lambda (pairs)
                  (loop for (k v) in pairs
                        append (list k v)))
                (list (tuple (map (lambda (str) (intern (string-upcase str) :keyword))
                                  (string :min-length 1 :max-length 8))
                             (nested-json-structure (1- depth)))
                      :min-length 1 :max-length 3))
           (map (lambda (pairs)
                  (loop for (k v) in pairs
                        collect (cons k v)))
                (list (tuple (map (lambda (str) (intern (string-upcase str) :keyword))
                                  (string :min-length 1 :max-length 8))
                             (nested-json-structure (1- depth)))
                      :min-length 1 :max-length 3))
           (map (lambda (pairs)
                  (let ((ht (make-hash-table :test 'equal)))
                    (loop for (k v) in pairs
                          do (setf (gethash k ht) v))
                    ht))
                (list (tuple (string :min-length 1 :max-length 8)
                             (nested-json-structure (1- depth)))
                      :min-length 1 :max-length 3))))))

(check-it:def-generator nested-json-top (depth)
  (check-it:generator
   (or (map (lambda (lst) (coerce lst 'vector))
            (list (nested-json-structure depth) :min-length 1 :max-length 3))
       (map (lambda (pairs)
              (loop for (k v) in pairs
                    append (list k v)))
            (list (tuple (map (lambda (str) (intern (string-upcase str) :keyword))
                              (string :min-length 1 :max-length 8))
                         (nested-json-structure depth))
                  :min-length 1 :max-length 3))
       (map (lambda (pairs)
              (loop for (k v) in pairs
                    collect (cons k v)))
            (list (tuple (map (lambda (str) (intern (string-upcase str) :keyword))
                              (string :min-length 1 :max-length 8))
                         (nested-json-structure depth))
                  :min-length 1 :max-length 3))
       (map (lambda (pairs)
              (let ((ht (make-hash-table :test 'equal)))
                (loop for (k v) in pairs
                      do (setf (gethash k ht) v))
                ht))
            (list (tuple (string :min-length 1 :max-length 8)
                         (nested-json-structure depth))
                  :min-length 1 :max-length 3)))))

(test test-serialization-roundtrip-nested
  "Property test verifying that recursively generated nested mixtures of plists, alists, hash-tables, and vectors round-trip parse cleanly."
  (is-true
   (check-it
    (check-it:generator (nested-json-top 3))
    #'round-trip-ok-p)))

;;; --- Concurrency Stress Testing ---

(test test-concurrency-stress
  "Verify concurrency stress properties: spawning 20+ threads executing random transactions with timeouts, zero deadlocks, hangs, or leaked connections."
  (with-tmp-sandbox (dir)
    (with-test-db (main-db dir)
      (identity main-db)
      (let ((connections nil)
            (connections-lock (bt:make-lock "connections-lock"))
            (threads nil)
            (num-threads 25)
            (ops-per-thread 15)
            (db-path "test.db"))
        (unwind-protect
             (progn
               (dotimes (i num-threads)
                 (let ((thread-id i))
                   (push (bt:make-thread
                          (lambda ()
                            (dotimes (j ops-per-thread)
                              (let* ((*workspace-root* dir)
                                     (db (connect-db db-path)))
                                (bt:with-lock-held (connections-lock)
                                  (push db connections))
                                (unwind-protect
                                     (progn
                                       (case (random 2)
                                         (0
                                          (handler-case
                                              (let ((*db* db))
                                                (commit-event
                                                 (format nil "session-~A" (random 3))
                                                 `((:agent-id . ,(format nil "agent-~A-~A" thread-id j))
                                                   (:status . "running"))
                                                 :concurrency-event
                                                 (+ (* thread-id 1000) j)))
                                            (sqlite:sqlite-error (c)
                                              (declare (ignore c))
                                              nil)))
                                         (1
                                          (handler-case
                                              (sqlite:execute-to-list db "SELECT * FROM session_state")
                                            (sqlite:sqlite-error (c)
                                              (declare (ignore c))
                                              nil)))))
                                  (sqlite:disconnect db))
                                (sleep (random 0.02))))))
                         threads)))
               (let ((start-time (get-universal-time))
                     (timeout-seconds 12))
                 (loop
                   (let ((alive (remove-if-not #'bt:thread-alive-p threads)))
                     (when (null alive)
                       (return))
                     (when (> (- (get-universal-time) start-time) timeout-seconds)
                       (dolist (th alive)
                         (ignore-errors (bt:destroy-thread th)))
                       (error "Concurrency stress test timed out: threads did not finish within ~A seconds. Possible deadlock!" timeout-seconds))
                     (sleep 0.1)))))
          (let ((leaked-count 0))
            (bt:with-lock-held (connections-lock)
              (dolist (db connections)
                (when (and (slot-boundp db 'sqlite::handle)
                           (sqlite::handle db))
                  (incf leaked-count))))
            (is (= 0 leaked-count) "Leaked database connections detected!"))
          (let* ((*workspace-root* dir)
                 (final-db (connect-db db-path)))
            (unwind-protect
                 (progn
                   (is (listp (sqlite:execute-to-list final-db "SELECT count(*) FROM event_log")))
                   (is (integerp (sqlite:execute-single final-db "SELECT count(*) FROM session_state"))))
              (sqlite:disconnect final-db))))))))

;;; --- Metamorphic Projection Testing ---

(defun extract-field (payload field-type)
  "Extracts field-type (:agent-id or :status) from payload."
  (cond
    ((hash-table-p payload)
     (case field-type
       (:agent-id (or (gethash "agent_id" payload)
                      (gethash "agent-id" payload)))
       (:status (gethash "status" payload))))
    ((and (listp payload) (consp payload) (consp (car payload)))
     (case field-type
       (:agent-id (or (cdr (assoc :agent-id payload))
                      (cdr (assoc :agent_id payload))))
       (:status (cdr (assoc :status payload)))))
    ((listp payload)
     (case field-type
       (:agent-id (or (getf payload :agent-id)
                      (getf payload :agent_id)))
       (:status (getf payload :status))))
    (t nil)))

(defun fold-session-state (events)
  "Folds over a list of event plists to calculate the expected state."
  (let ((current-agent-id "unknown-agent")
        (current-status "idle")
        (last-version 0)
        (has-inserted-p nil))
    (dolist (evt events)
      (let* ((payload (getf evt :payload))
             (version (getf evt :version))
             (agent-id (extract-field payload :agent-id))
             (status (or (extract-field payload :status)
                         current-status)))
        (unless has-inserted-p
          (setf current-agent-id (or agent-id "unknown-agent")
                has-inserted-p t))
        (setf current-status status
              last-version version)))
    (values current-agent-id last-version current-status)))

(defun random-payload-type ()
  (let ((types '(:plist :alist :hash-table)))
    (nth (random (length types)) types)))

(defun make-random-payload (payload-type agent-id status)
  (let ((kv-pairs nil))
    (when agent-id
      (push (cons :agent-id agent-id) kv-pairs))
    (when status
      (push (cons :status status) kv-pairs))
    (case payload-type
      (:plist
       (loop for (k . v) in kv-pairs
             append (list k v)))
      (:alist
       kv-pairs)
      (:hash-table
       (let ((ht (make-hash-table :test 'equal)))
         (loop for (k . v) in kv-pairs
               do (setf (gethash (string-downcase (symbol-name k)) ht) v))
         ht)))))

(defun generate-random-events (len)
  (loop for version from 1 to len
        collect (let* ((agent-id (if (< (random 10) 7)
                                     (format nil "agent-~A" (random 5))
                                     nil))
                       (status (if (< (random 10) 7)
                                   (format nil "status-~A" (random 5))
                                   nil))
                       (payload-type (random-payload-type))
                       (payload (make-random-payload payload-type agent-id status)))
                  (list :version version
                        :payload payload))))

(test test-metamorphic-projection
  "Assert metamorphic equivalence: final database projection state matches pure fold of event log."
  (with-tmp-sandbox (dir)
    (with-test-db (db dir)
      (let ((session-id "session-metamorphic")
            (events (generate-random-events 25)))
        (dolist (evt events)
          (let ((*db* db))
            (commit-event session-id
                          (getf evt :payload)
                          :metamorphic-event
                          (getf evt :version))))
        (multiple-value-bind (expected-agent-id expected-version expected-status)
            (fold-session-state events)
          (let* ((row (sqlite:execute-to-list db
                         "SELECT agent_id, version, status FROM session_state WHERE session_id = ?"
                         session-id))
                 (actual (car row))
                 (actual-agent-id (first actual))
                 (actual-version (second actual))
                 (actual-status (third actual)))
            (is (equal expected-agent-id actual-agent-id))
            (is (= expected-version actual-version))
            (is (equal expected-status actual-status))))))))


(test test-atomic-sequence-concurrency
  "Verify that concurrent committers allocating sequence numbers internally in commit-event results in race-free gap-free allocations."
  (with-tmp-sandbox (dir)
    (let ((db-path (uiop:merge-pathnames* "test.db" dir))
          (session-id "session-concurrency")
          (num-threads 5)
          (ops-per-thread 5))
      ;; Initialize schema
      (let ((db (connect-db db-path)))
        (unwind-protect
             (init-db db)
          (sqlite:disconnect db)))
      (let ((threads nil))
        (dotimes (i num-threads)
          (let ((thread-id i))
            (push (bt:make-thread
                   (lambda ()
                     (let ((*workspace-root* dir)
                           (*db* (connect-db db-path)))
                       (unwind-protect
                            (dotimes (j ops-per-thread)
                              (handler-case
                                  (commit-event session-id
                                                `((:thread-id . ,thread-id) (:op-id . ,j))
                                                :concurrency-event)
                                (error () nil))
                              (sleep 0.005))
                         (sqlite:disconnect *db*)))))
                  threads)))
        (dolist (th threads)
          (bt:join-thread th))
        ;; Verify the total number of events in event_log.
        (let* ((*workspace-root* dir)
               (db (connect-db db-path))
               (count (sqlite:execute-single db "SELECT count(*) FROM event_log WHERE session_id = ?" session-id))
               (sequences (mapcar #'car (sqlite:execute-to-list db "SELECT sequence FROM event_log WHERE session_id = ? ORDER BY sequence ASC" session-id))))
          (unwind-protect
               (progn
                 (is (= (* num-threads ops-per-thread) count))
                 (is (equal (loop for x from 1 to (* num-threads ops-per-thread) collect x)
                            sequences)))
            (sqlite:disconnect db)))))))
