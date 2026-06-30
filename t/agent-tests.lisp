;;; -*- Mode: Lisp; Syntax: Common-Lisp; indent-tabs-mode: nil; coding: utf-8; Show-Trailing-Whitespace: t -*-
;;;
;;; agent-tests.lisp — Unit and property tests for CLOS agent and permissions
;;;

(defpackage #:librecode-test.agent
  (:use #:cl
        #:fiveam
        #:check-it
        #:librecode-runner.agent
        #:librecode-runner.conditions)
  (:shadowing-import-from #:check-it #:*num-trials*)
  (:export #:agent-suite))

(in-package #:librecode-test.agent)

(def-suite agent-suite
  :description "Suite for CLOS agent and permission tests.")

(in-suite agent-suite)

;;; --- Sandbox Fixtures ---

(defun create-temp-directory-path ()
  (let* ((tempdir (uiop:temporary-directory))
         (unique-dir (make-pathname :directory (append (pathname-directory tempdir)
                                                       (list (format nil "librecode-agent-sandbox-~A-~A"
                                                                     (get-universal-time)
                                                                     (random 1000000)))))))
    (ensure-directories-exist unique-dir)
    unique-dir))

(defun delete-directory-and-files (path)
  (let ((path (uiop:ensure-directory-pathname path)))
    (when (uiop:directory-exists-p path)
      (uiop:delete-directory-tree path
                                  :validate (lambda (p)
                                              (search "librecode-agent-sandbox" (namestring p)))
                                  :if-does-not-exist :keep))))

(defmacro with-tmp-sandbox ((path-var) &body body)
  `(let ((,path-var (create-temp-directory-path)))
     (unwind-protect
          (progn ,@body)
       (handler-case
            (delete-directory-and-files ,path-var)
          (serious-condition () nil)))))

(defmacro with-test-db ((db-var sandbox-dir) &body body)
  `(let* ((librecode-runner.event-store:*workspace-root* ,sandbox-dir))
     (let* ((librecode-runner.event-store:*db* (librecode-runner.event-store:connect-db "test.db"))
            (,db-var librecode-runner.event-store:*db*))
       (unwind-protect
            (progn
              (librecode-runner.event-store:init-db librecode-runner.event-store:*db*)
              ,@body)
         (sqlite:disconnect librecode-runner.event-store:*db*)))))

;;; --- Unit Tests ---

(test test-basic-wildcard-matches
  "Test simple wildcard matching behavior."
  (is-true (librecode-runner.agent::wildcard-match "git*" "git commit"))
  (is-true (librecode-runner.agent::wildcard-match "*" "anything"))
  (is-true (librecode-runner.agent::wildcard-match "foo*bar" "foobar"))
  (is-true (librecode-runner.agent::wildcard-match "foo*bar" "foo-middle-bar"))
  (is-false (librecode-runner.agent::wildcard-match "foo*bar" "foobaz"))
  (is-false (librecode-runner.agent::wildcard-match "git" "git commit"))
  (is-true (librecode-runner.agent::wildcard-match "git" "git")))

(test test-headless-denial
  "Headless mode should raise a denied-error when an :ask rule is matched or defaulted."
  (let* ((agent (make-instance 'agent
                               :id "agent-headless"
                               :ruleset nil
                               :system-context nil))
         (*interactive-p* nil))
    (signals denied-error
      (check-permission agent "write_file" "/etc/hosts"))))

(test test-static-deny-precedence
  "Static agent ruleset :deny effect must reject immediately."
  (let* ((rule (make-instance 'permission-rule
                              :action "rm"
                              :resource "*"
                              :effect :deny))
         (agent (make-instance 'agent
                               :id "agent-deny"
                               :ruleset (list rule)
                               :system-context nil))
         (*interactive-p* t))
    (signals denied-error
      (check-permission agent "rm" "file.txt"))))

(test test-interactive-cv-liveness
  "Verify concurrent blocked threads are notified and unblocked without deadlocks."
  (let* ((agent (make-instance 'agent
                               :id "agent-interactive"
                               :ruleset nil
                               :system-context nil))
         (num-threads 5)
         (threads nil)
         (results (make-array num-threads :initial-element nil))
         (*interactive-p* t))
    (dotimes (i num-threads)
      (let ((idx i))
        (push (bt:make-thread
               (lambda ()
                 (handler-case
                     (let ((res (check-permission agent (format nil "action-~A" idx) "resource")))
                       (setf (aref results idx) res))
                   (serious-condition (c)
                     (setf (aref results idx) c)))))
              threads)))

    ;; Wait for all requests to appear in *pending-requests*
    (loop
      (let ((count 0))
        (bt:with-lock-held (*pending-requests-lock*)
          (setf count (hash-table-count *pending-requests*)))
        (when (= count num-threads)
          (return))
        (sleep 0.05)))

    ;; Resolve all requests
    (let ((req-ids nil))
      (bt:with-lock-held (*pending-requests-lock*)
        (maphash (lambda (k v)
                   (declare (ignore v))
                   (push k req-ids))
                 *pending-requests*))
      (dolist (req-id req-ids)
        (resolve-permission-request req-id :allow)))

    ;; Wait for all threads to join
    (dolist (th threads)
      (bt:join-thread th))

    ;; Assert all threads completed with :allow
    (dotimes (i num-threads)
      (is (eq :allow (aref results i))))))

(test test-interactive-denial
  "Verify interactive denial signals a denied-error condition."
  (let* ((agent (make-instance 'agent
                               :id "agent-deny"
                               :ruleset nil
                               :system-context nil))
         (thread-finished nil)
         (thread-error nil)
         (*interactive-p* t))
    (let ((th (bt:make-thread
               (lambda ()
                 (handler-case
                     (check-permission agent "write" "file")
                   (denied-error (c)
                     (setf thread-error c))
                   (serious-condition (c)
                     (setf thread-error (list :other-serious c)))
                   (error (c)
                     (setf thread-error (list :other-error c))))
                 (setf thread-finished t)))))

      ;; Wait for request to register
      (loop
        (let ((count 0))
          (bt:with-lock-held (*pending-requests-lock*)
            (setf count (hash-table-count *pending-requests*)))
          (when (= count 1)
            (return))
          (sleep 0.02)))

      ;; Resolve with :deny
      (let ((req-id nil))
        (bt:with-lock-held (*pending-requests-lock*)
          (maphash (lambda (k v) (declare (ignore v)) (setf req-id k)) *pending-requests*))
        (resolve-permission-request req-id :deny))

      (bt:join-thread th)
      (is-true thread-finished)
      (is (typep thread-error 'denied-error))
      (is (equal "write" (denied-error-action thread-error)))
      (is (equal "file" (denied-error-resource thread-error))))))

(test test-always-decision-db-persistence
  "Verify that a resolve-permission-request with :always writes to SQLite and merges rules."
  (with-tmp-sandbox (dir)
    (with-test-db (db dir)
      (let* ((agent (make-instance 'agent
                                   :id "agent-always"
                                   :ruleset nil
                                   :system-context nil))
             (*interactive-p* t)
             (*project-id* "test-project-123")
             (thread-finished nil)
             (thread-result nil))
        (let ((th (bt:make-thread
                   (lambda ()
                     (let ((librecode-runner.event-store:*db* db)
                           (*project-id* "test-project-123"))
                       (setf thread-result (check-permission agent "exec" "script.sh")
                             thread-finished t))))))
          ;; Wait for request
          (loop
            (let ((count 0))
              (bt:with-lock-held (*pending-requests-lock*)
                (setf count (hash-table-count *pending-requests*)))
              (when (= count 1)
                (return))
              (sleep 0.02)))

          ;; Resolve with :always
          (let ((req-id nil)
                (librecode-runner.event-store:*db* db))
            (bt:with-lock-held (*pending-requests-lock*)
              (maphash (lambda (k v) (declare (ignore v)) (setf req-id k)) *pending-requests*))
            (resolve-permission-request req-id :always))

          (bt:join-thread th)
          (is-true thread-finished)
          (is (eq :allow thread-result))

          ;; Verify row in permission_saved table
          (let ((saved-rows (sqlite:execute-to-list db "SELECT project_id, action, resource, effect FROM permission_saved")))
            (is (= 1 (length saved-rows)))
            (is (equal (list "test-project-123" "exec" "script.sh" "allow") (car saved-rows))))

          ;; Query again using check-permission. It should immediately allow because of database rule merge.
          (let ((second-result (let ((librecode-runner.event-store:*db* db)
                                     (*project-id* "test-project-123"))
                                 (check-permission agent "exec" "script.sh"))))
            (is (eq :allow second-result))))))))

(test test-event-asked-persistence
  "Verify event-permission-asked is committed when *current-session-id* is bound."
  (with-tmp-sandbox (dir)
    (with-test-db (db dir)
      (let* ((agent (make-instance 'agent
                                   :id "agent-evt"
                                   :ruleset nil
                                   :system-context nil))
             (*interactive-p* t)
             (*current-session-id* "session-123")
             (thread-finished nil))
        ;; Initialize session state so commit-event projection doesn't fail
        (sqlite:execute-non-query db
          "INSERT INTO session_state (session_id, agent_id, version, status, last_updated)
           VALUES (?, ?, ?, ?, ?)"
          "session-123" "agent-evt" 0 "idle" 1000)

        (let ((th (bt:make-thread
                   (lambda ()
                     (let ((librecode-runner.event-store:*db* db)
                           (*current-session-id* "session-123"))
                       (check-permission agent "read" "conf.json")
                       (setf thread-finished t))))))
          ;; Wait for request
          (loop
            (let ((count 0))
              (bt:with-lock-held (*pending-requests-lock*)
                (setf count (hash-table-count *pending-requests*)))
              (when (= count 1)
                (return))
              (sleep 0.02)))

          ;; Resolve
          (let ((req-id nil)
                (librecode-runner.event-store:*db* db))
            (bt:with-lock-held (*pending-requests-lock*)
              (maphash (lambda (k v) (declare (ignore v)) (setf req-id k)) *pending-requests*))
            (resolve-permission-request req-id :allow))

          (bt:join-thread th)
          (is-true thread-finished)

          ;; Verify event committed to SQLite
          (let ((events (sqlite:execute-to-list db "SELECT session_id, event_type FROM event_log")))
            (is (= 1 (length events)))
            (is (equal (list "session-123" "EVENT-PERMISSION-ASKED") (car events)))))))))

(test test-cascading-rejection
  "Verify that resolving one request with :reject/:deny automatically rejects/denies all other pending requests in the same session."
  (let* ((agent (make-instance 'agent
                               :id "agent-cascade"
                               :ruleset nil
                               :system-context nil))
         (*interactive-p* t)
         (*current-session-id* "session-cascade")
         (num-threads 3)
         (threads nil)
         (errors (make-array num-threads :initial-element nil)))
    (dotimes (i num-threads)
      (let ((idx i))
        (push (bt:make-thread
               (lambda ()
                 (let ((*current-session-id* "session-cascade"))
                   (handler-case
                       (check-permission agent (format nil "action-~A" idx) "resource")
                     (denied-error (c)
                       (setf (aref errors idx) c))
                     (serious-condition (c)
                       (setf (aref errors idx) (list :other-serious c)))))))
              threads)))

    ;; Wait for all requests to register
    (loop
      (let ((count 0))
        (bt:with-lock-held (*pending-requests-lock*)
          (setf count (hash-table-count *pending-requests*)))
        (when (= count num-threads)
          (return))
        (sleep 0.05)))

    ;; Deny/reject one request
    (let ((req-id nil))
      (bt:with-lock-held (*pending-requests-lock*)
        (maphash (lambda (k v) (declare (ignore v)) (setf req-id k)) *pending-requests*))
      (resolve-permission-request req-id :deny))

    ;; Wait for all threads to join
    (dolist (th threads)
      (bt:join-thread th))

    ;; Assert all threads terminated with denied-error
    (dotimes (i num-threads)
      (is (typep (aref errors i) 'denied-error)))))

;;; --- Property Tests ---

(test test-wildcard-universality
  "Property: a rule with '*' as action and resource patterns always matches any generated action and resource."
  (is-true
   (check-it
    (generator (tuple (string :min-length 1 :max-length 20)
                      (string :min-length 1 :max-length 20)))
    (lambda (inputs)
      (destructuring-bind (action resource) inputs
        (let* ((rule (make-instance 'permission-rule
                                    :action "*"
                                    :resource "*"
                                    :effect :allow))
               (agent (make-instance 'agent
                                     :id "test-agent"
                                     :ruleset (list rule)
                                     :system-context nil)))
          (eq (evaluate-permissions agent action resource) :allow)))))))

(test test-wildcard-monotonicity
  "Property: if action pattern A matches B, then *A* must match B."
  (is-true
   (check-it
    (generator (tuple (string :min-length 1 :max-length 10)
                      (string :min-length 1 :max-length 10)))
    (lambda (inputs)
      (destructuring-bind (pat-str target-str) inputs
        (declare (ignore pat-str))
        (let* ((pattern (if (and (> (length target-str) 3) (evenp (length target-str)))
                            (concatenate 'string (subseq target-str 0 (floor (length target-str) 2)) "*")
                            target-str)))
          (if (librecode-runner.agent::wildcard-match pattern target-str)
              (let ((wrapped-both (concatenate 'string "*" pattern "*"))
                    (wrapped-prefix (concatenate 'string "*" pattern))
                    (wrapped-suffix (concatenate 'string pattern "*")))
                (and (librecode-runner.agent::wildcard-match wrapped-both target-str)
                     (librecode-runner.agent::wildcard-match wrapped-prefix target-str)
                     (librecode-runner.agent::wildcard-match wrapped-suffix target-str)))
              t)))))))

(test test-last-match-wins-priority
  "Property: appending a matching rule to the ruleset overrides previous matching rules."
  (is-true
   (check-it
    (generator
     (tuple (string :min-length 1 :max-length 10)
            (string :min-length 1 :max-length 10)
            (or (constantly :allow) (constantly :deny) (constantly :ask))
            (or (constantly :allow) (constantly :deny) (constantly :ask))))
    (lambda (inputs)
      (destructuring-bind (action resource prior-effect new-effect) inputs
        (let* ((prior-rule (make-instance 'permission-rule
                                          :action "*"
                                          :resource "*"
                                          :effect prior-effect))
               (new-rule (make-instance 'permission-rule
                                        :action action
                                        :resource resource
                                        :effect new-effect))
               (agent (make-instance 'agent
                                     :id "test"
                                     :ruleset (list prior-rule new-rule)
                                     :system-context nil)))
          (eq (evaluate-permissions agent action resource) new-effect)))))))
