;;; -*- Mode: Lisp; Syntax: Common-Lisp; indent-tabs-mode: nil; coding: utf-8; Show-Trailing-Whitespace: t -*-
;;;
;;; agent.lisp — CLOS agents and ruleset enforcement
;;;

(in-package #:librecode-runner.agent)

(defclass agent ()
  ((id :initarg :id :reader agent-id)
   (ruleset :initarg :ruleset :reader agent-ruleset)
   (system-context :initarg :system-context :reader agent-system-context))
  (:documentation "A multi-agent model representing an identity, its ruleset, and its system context."))

(defstruct permission-rule
  "Immutable permission rule representing a policy mapping action/resource to effect."
  (action "" :type string :read-only t)
  (resource "" :type string :read-only t)
  (effect :ask :type keyword :read-only t))

(defvar *interactive-p* t
  "Flag indicating whether the permission ask loop runs in interactive mode (t) or headless mode (nil).")

(defvar *current-session-id* nil
  "The active session ID, if any.")

(defvar *project-id* "default"
  "The current project ID for database-persisted permissions.")

(defclass permission-request ()
  ((id :initarg :id :reader permission-request-id)
   (session-id :initarg :session-id :reader permission-request-session-id :initform nil)
   (action :initarg :action :reader permission-request-action)
   (resource :initarg :resource :reader permission-request-resource)
   (lock :initarg :lock :reader permission-request-lock)
   (cv :initarg :cv :reader permission-request-cv)
   (resolved-p :initform nil :accessor permission-request-resolved-p)
   (decision :initform nil :accessor permission-request-decision))
  (:documentation "A thread-safe descriptor tracking a pending interactive user permission resolution."))

(defvar *pending-requests* (make-hash-table :test 'equal)
  "Thread-safe registry of pending permission requests.")

(defvar *pending-requests-lock* (bt:make-lock "pending-requests-lock")
  "Lock protecting the *pending-requests* registry.")

(defvar *next-req-id* 0
  "Monotonic counter for unique permission request IDs.")

(defun generate-req-id ()
  "Generate a unique request ID."
  (bt:with-lock-held (*pending-requests-lock*)
    (format nil "req-~A" (incf *next-req-id*))))

(defun wildcard-match (pattern string)
  "Return t if STRING matches PATTERN, supporting '*' as matching zero or more characters."
  (when (and (stringp pattern) (stringp string))
    (let ((p-len (length pattern))
          (s-len (length string)))
      (labels ((match-from (p-idx s-idx)
                 (cond
                   ((and (= p-idx p-len) (= s-idx s-len)) t)
                   ((= p-idx p-len) nil)
                   ((char= (char pattern p-idx) #\*)
                    (or (match-from (1+ p-idx) s-idx)
                        (and (< s-idx s-len)
                             (match-from p-idx (1+ s-idx)))))
                   ((= s-idx s-len) nil)
                   ((char= (char pattern p-idx) (char string s-idx))
                    (match-from (1+ p-idx) (1+ s-idx)))
                   (t nil))))
        (match-from 0 0)))))

(defun evaluate-permissions (agent action resource)
  "Evaluate rules in the agent's ruleset using a last-match-wins algorithm.
If no rule matches, defaults to returning :ask."
  (let* ((rules (agent-ruleset agent))
         (matched (find-if (lambda (rule)
                             (and (wildcard-match (permission-rule-action rule) action)
                                  (wildcard-match (permission-rule-resource rule) resource)))
                           rules
                           :from-end t)))
    (if matched
        (permission-rule-effect matched)
        :ask)))

(defun load-saved-rules ()
  "Retrieve saved permission rules from SQLite for the active *project-id*."
  (when (and (boundp 'librecode-runner.event-store:*db*)
             librecode-runner.event-store:*db*
             (boundp '*project-id*)
             *project-id*)
    (handler-case
        (let ((rows (sqlite:execute-to-list
                     librecode-runner.event-store:*db*
                     "SELECT action, resource, effect FROM permission_saved WHERE project_id = ?"
                     *project-id*)))
          (mapcar (lambda (row)
                    (destructuring-bind (action resource effect-str) row
                      (make-permission-rule
                       :action action
                       :resource resource
                       :effect (intern (string-upcase effect-str) :keyword))))
                  rows))
      (error () nil))))

(defun resolve-ask-permission (agent action resource)
  "Handle permission request in interactive mode: blocks the current thread until resolution."
  (declare (ignore agent))
  (let* ((req-id (generate-req-id))
         (lock (bt:make-lock (format nil "lock-~A" req-id)))
         (cv (bt:make-condition-variable :name (format nil "cv-~A" req-id)))
         (req (make-instance 'permission-request
                             :id req-id
                             :session-id *current-session-id*
                             :action action
                             :resource resource
                             :lock lock
                             :cv cv)))
    ;; Register request
    (bt:with-lock-held (*pending-requests-lock*)
      (setf (gethash req-id *pending-requests*) req))

    ;; Commit event if session ID is active
    (when (and (boundp '*current-session-id*) *current-session-id*)
      (handler-case
          (librecode-runner.event-store:commit-event
           *current-session-id*
           `((:req-id . ,req-id)
             (:action . ,action)
             (:resource . ,resource)
             (:status . "asked"))
           :event-permission-asked)
        (error () nil)))

    ;; Block current thread on condition variable
    (bt:with-lock-held (lock)
      (loop until (or (permission-request-resolved-p req)
                      (librecode-runner.protocol:session-stopping-p *current-session-id*))
            do (bt:condition-wait cv lock :timeout 0.1)))

    ;; Return status or signal denied-error
    (when (librecode-runner.protocol:session-stopping-p *current-session-id*)
      (error 'librecode-runner.conditions:harness-failure
             :message "Session stopped while waiting for permission."))

    (let ((decision (permission-request-decision req)))
      (cond
        ((member decision '(:allow :accept :always))
         :allow)
        (t
         (error 'librecode-runner.conditions:denied-error
                :action action
                :resource resource
                :message (format nil "Access denied by interactive user decision: ~S" decision)))))))

(defun check-permission (agent action resource)
  "Evaluate permission for the given agent, action, and resource.
Combines agent static checks, saved SQLite rules, and the interactive ask loop."
  ;; 1. Static Agent Rules Check
  (let ((static-effect (evaluate-permissions agent action resource)))
    (when (eq static-effect :deny)
      (error 'librecode-runner.conditions:denied-error
             :action action
             :resource resource
             :message "Access denied by static permission ruleset policy.")))

  ;; 2. Saved Rules Merge
  (let* ((saved-rules (load-saved-rules))
         (merged-agent (make-instance 'agent
                                      :id (agent-id agent)
                                      :ruleset (append (agent-ruleset agent) saved-rules)
                                      :system-context (agent-system-context agent)))
         (effect (evaluate-permissions merged-agent action resource)))
    (cond
      ((eq effect :allow)
       :allow)
      ((eq effect :deny)
       (error 'librecode-runner.conditions:denied-error
              :action action
              :resource resource
              :message "Access denied by merged permission policy."))
      ((eq effect :ask)
       ;; 3. Resolve Ask Loop
       (if (not *interactive-p*)
           (error 'librecode-runner.conditions:denied-error
                  :action action
                  :resource resource
                  :message "Access denied by permission policy (headless mode).")
           (resolve-ask-permission agent action resource)))
      (t
       (error "Unknown permission effect: ~S" effect)))))

(defun resolve-permission-request (req-id decision)
  "Resolve a pending permission request.
If decision is :always, write an entry to the SQLite permission_saved table.
If decision is :reject or :deny, cascades rejection to all sibling requests of the same session."
  (let ((req (bt:with-lock-held (*pending-requests-lock*)
               (gethash req-id *pending-requests*))))
    (unless req
      (error "No pending permission request found for ID: ~S" req-id))

    (let ((lock (permission-request-lock req))
          (cv (permission-request-cv req)))
      ;; 1. Set resolution status
      (bt:with-lock-held (lock)
        (setf (permission-request-decision req) decision
              (permission-request-resolved-p req) t))

      ;; 2. Persist to SQLite if decision is :always
      (when (eq decision :always)
        (when (and (boundp 'librecode-runner.event-store:*db*)
                   librecode-runner.event-store:*db*
                   (boundp '*project-id*)
                   *project-id*)
          (librecode-runner.event-store:with-immediate-transaction (librecode-runner.event-store:*db*)
            (sqlite:execute-non-query
             librecode-runner.event-store:*db*
             "INSERT OR REPLACE INTO permission_saved (project_id, action, resource, effect, timestamp)
              VALUES (?, ?, ?, ?, ?)"
             *project-id*
             (permission-request-action req)
             (permission-request-resource req)
             "allow"
             (librecode-runner.event-store::current-timestamp-ms)))))

      ;; 3. Cascading rejection
      (when (member decision '(:reject :deny))
        (let ((sess-id (permission-request-session-id req)))
          (when sess-id
            (let ((sibling-reqs nil))
              (bt:with-lock-held (*pending-requests-lock*)
                (maphash (lambda (k r)
                           (declare (ignore k))
                           (when (and (equal (permission-request-session-id r) sess-id)
                                      (not (permission-request-resolved-p r)))
                             (push r sibling-reqs)))
                         *pending-requests*))
              (dolist (sib sibling-reqs)
                (let ((sib-lock (permission-request-lock sib))
                      (sib-cv (permission-request-cv sib)))
                  (bt:with-lock-held (sib-lock)
                    (setf (permission-request-decision sib) :deny
                          (permission-request-resolved-p sib) t)
                    (bt:condition-notify sib-cv))))))))

      ;; 4. Remove from registry
      (bt:with-lock-held (*pending-requests-lock*)
        (remhash req-id *pending-requests*))

      ;; 5. Safely notify cv last
      (bt:with-lock-held (lock)
        (bt:condition-notify cv))
      t)))
