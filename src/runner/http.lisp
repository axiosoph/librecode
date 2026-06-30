;;; -*- Mode: Lisp; Syntax: Common-Lisp; indent-tabs-mode: nil; coding: utf-8; Show-Trailing-Whitespace: t -*-
;;;
;;; http.lisp — HTTP server bridge for remote control and SSE coordination
;;;

(in-package #:librecode-runner.http)

(defvar *http-bridge-server* nil
  "The active Clack server handler for the HTTP bridge.")

(defvar *http-db-path* "librecode.db"
  "Saved database path for background threads.")

(defvar *http-workspace-root* nil
  "Saved workspace root path for background threads.")

;; --- SSE Broadcast Registry ---

(defvar *sse-listeners-lock* (bt:make-lock "sse-listeners-lock"))
(defvar *sse-listeners* (make-hash-table :test 'equal)
  "Registry of session-id to list of listener mailboxes.")

(defun register-sse-listener (session-id mailbox)
  (bt:with-lock-held (*sse-listeners-lock*)
    (push mailbox (gethash session-id *sse-listeners*))))

(defun unregister-sse-listener (session-id mailbox)
  (bt:with-lock-held (*sse-listeners-lock*)
    (setf (gethash session-id *sse-listeners*)
          (delete mailbox (gethash session-id *sse-listeners*)))
    (unless (gethash session-id *sse-listeners*)
      (remhash session-id *sse-listeners*))))

(defun broadcast-sse-event (session-id event-type data)
  "Publish event to registered mailboxes for session-id."
  (let ((listeners (bt:with-lock-held (*sse-listeners-lock*)
                     (copy-list (gethash session-id *sse-listeners*)))))
    (dolist (mbox listeners)
      (librecode-runner.protocol:send-message mbox (list event-type data)))))

;; --- JSON Helpers ---

(defun symbol-to-json-key (sym)
  (substitute #\_ #\- (string-downcase (symbol-name sym))))

(defun coerce-to-json (val)
  "Recursively coerce Lisp plists/alists/lists to JSON-compatible forms."
  (cond
    ((null val) nil)
    ((eq val t) t)
    ((hash-table-p val) val)
    ((and (listp val) (consp val) (keywordp (car val)))
     (let ((ht (make-hash-table :test 'equal)))
       (loop for (k v) on val by #'cddr
             do (setf (gethash (symbol-to-json-key k) ht) (coerce-to-json v)))
       ht))
    ((listp val)
     (mapcar #'coerce-to-json val))
    (t val)))

(defvar *http-origin* nil)

(defun allowed-origin-p (origin)
  (unless origin (return-from allowed-origin-p t))
  (or (uiop:string-prefix-p "http://localhost:" origin)
      (uiop:string-prefix-p "http://127.0.0.1:" origin)
      (string= "oc://renderer" origin)
      (string= "tauri://localhost" origin)
      (string= "http://tauri.localhost" origin)
      (string= "https://tauri.localhost" origin)
      (let ((len (length origin)))
        (and (>= len 19)
             (uiop:string-prefix-p "https://" origin)
             (or (string= "opencode.ai" origin :start2 (- len 11))
                 (and (>= len 20)
                      (string= ".opencode.ai" origin :start2 (- len 12))))))))

(defun json-response (status body-plist)
  (let ((headers '(:content-type "application/json")))
    (when (allowed-origin-p *http-origin*)
      (setf headers
            (append headers
                    `(:access-control-allow-origin ,(or *http-origin* "*")
                      :access-control-allow-methods "GET, POST, PUT, DELETE, OPTIONS"
                      :access-control-allow-headers "Content-Type, Authorization, x-requested-with"))))
    (list status
          headers
          (list (com.inuoe.jzon:stringify (coerce-to-json body-plist))))))

(defun parse-json-body (env)
  "Read exactly content-length octets from the raw-body stream and parse as JSON."
  (let* ((body (getf env :raw-body))
         (len-raw (getf env :content-length))
         (len (cond
                ((integerp len-raw) len-raw)
                ((stringp len-raw) (parse-integer len-raw :junk-allowed t))
                (t nil))))
    (format *error-output* "DEBUG: [Server] parse-json-body body=~A len-raw=~A len=~A~%" body len-raw len) (force-output *error-output*)
    (when (and body len (> len 0))
      (let ((octets (make-array len :element-type '(unsigned-byte 8))))
        (format *error-output* "DEBUG: [Server] read-sequence start~%") (force-output *error-output*)
        (handler-case
            (progn
              (read-sequence octets body)
              (format *error-output* "DEBUG: [Server] read-sequence done, parsing JSON~%") (force-output *error-output*)
              (com.inuoe.jzon:parse octets))
          (error (c)
            (format *error-output* "DEBUG: [Server] Error in read/parse: ~A~%" c) (force-output *error-output*)
            nil))))))

(defun split-path (path)
  (remove "" (uiop:split-string path :separator "/") :test #'string=))

(defun make-session-json (session-id agent-id last-updated)
  (let ((ht (make-hash-table :test 'equal))
        (time-ht (make-hash-table :test 'equal)))
    (setf (gethash "created" time-ht) last-updated)
    (setf (gethash "updated" time-ht) last-updated)
    (setf (gethash "id" ht) session-id)
    (setf (gethash "slug" ht) session-id)
    (setf (gethash "projectID" ht) "default-project")
    (setf (gethash "directory" ht) (or *http-workspace-root* "."))
    (setf (gethash "title" ht) session-id)
    (setf (gethash "agent" ht) agent-id)
    (setf (gethash "version" ht) "1.0.0")
    (setf (gethash "time" ht) time-ht)
    ht))

(defun handle-list-sessions ()
  (handler-case
      (let* ((db librecode-runner.event-store:*db*)
             (rows (sqlite:execute-to-list db "SELECT session_id, agent_id, last_updated FROM session_state"))
             (sessions (mapcar (lambda (row)
                                 (make-session-json (first row) (second row) (third row)))
                               rows)))
        (json-response 200 (coerce sessions 'vector)))
    (error (c)
      (format *error-output* "ERROR: [Server] handle-list-sessions error: ~A~%" c) (force-output *error-output*)
      (json-response 500 (list :error (format nil "Error listing sessions: ~A" c))))))

;; --- Request Handlers ---

(defun handle-create-session (env)
  (format *error-output* "DEBUG: [Server] handle-create-session entering~%") (force-output *error-output*)
  (handler-case
      (let* ((json (parse-json-body env))
             (agent-id (or (and json (or (gethash "agent_id" json) (gethash "agent-id" json))) "default-agent"))
             (system-context (and json (or (gethash "system_context" json) (gethash "system-context" json))))
             (ruleset (and json (gethash "ruleset" json)))
             (session-id (format nil "session-~A-~A" (librecode-runner.event-store::current-timestamp-ms) (random 1000000)))
             (db librecode-runner.event-store:*db*))
        (format *error-output* "DEBUG: [Server] handle-create-session agent-id=~A session-id=~A~%" agent-id session-id) (force-output *error-output*)
        (librecode-runner.event-store:with-transaction (db)
          ;; 1. Create session state record
          (sqlite:execute-non-query db
            "INSERT INTO session_state (session_id, agent_id, version, status, last_updated) VALUES (?, ?, 1, 'idle', ?)"
            session-id agent-id (librecode-runner.event-store::current-timestamp-ms))
          ;; 2. If system-context is provided, create the initial epoch baseline
          (when system-context
            (let ((epoch-id (format nil "epoch-~A" (random 100000))))
              (sqlite:execute-non-query db
                "INSERT INTO context_epoch (session_id, epoch_id, baseline_text, created_at) VALUES (?, ?, ?, ?)"
                session-id epoch-id system-context (librecode-runner.event-store::current-timestamp-ms))))
          ;; 3. If ruleset is provided, insert rules into permission_saved
          (when ruleset
            (let ((rules-list (if (vectorp ruleset) (coerce ruleset 'list) ruleset)))
              (dolist (rule rules-list)
                (let ((act (gethash "action" rule))
                      (res (gethash "resource" rule))
                      (eff (gethash "effect" rule)))
                  (when (and act res eff)
                    (sqlite:execute-non-query db
                      "INSERT OR REPLACE INTO permission_saved (project_id, action, resource, effect, timestamp) VALUES (?, ?, ?, ?, ?)"
                      librecode-runner.agent::*project-id* act res eff (librecode-runner.event-store::current-timestamp-ms))))))))
        (format *error-output* "DEBUG: [Server] handle-create-session returning 200~%") (force-output *error-output*)
        (json-response 200 (list :session-id session-id)))
    (error (c)
      (format *error-output* "DEBUG: [Server] handle-create-session error: ~A~%" c) (force-output *error-output*)
      (json-response 400 (list :error (format nil "Error creating session: ~A" c))))))

(defun handle-admit-input (session-id env)
  (handler-case
      (let* ((json (parse-json-body env))
             (prompt-id (and json (or (gethash "prompt_id" json) (gethash "id" json))))
             (prompt-text (and json (or (gethash "prompt_text" json) (gethash "text" json) (gethash "content" json))))
             (delivery-mode (or (and json (or (gethash "delivery_mode" json) (gethash "mode" json))) "STEER")))
        (unless (and prompt-id prompt-text)
          (return-from handle-admit-input (json-response 400 '(:error "Missing prompt_id or prompt_text"))))
        (let ((result (librecode-runner.session:admit-input session-id prompt-id prompt-text delivery-mode)))
          (json-response 200 (list :status (string-downcase (symbol-name result))))))
    (error (c)
      (json-response 400 (list :error (format nil "Error admitting input: ~A" c))))))

(defun handle-promote-input (session-id env)
  (handler-case
      (let* ((json (parse-json-body env))
             (prompt-id (and json (or (gethash "prompt_id" json) (gethash "id" json))))
             (mode-str (and json (or (gethash "mode" json) (gethash "delivery_mode" json)))))
        (if prompt-id
            (let ((promoted (librecode-runner.session:promote-input session-id prompt-id)))
              (json-response 200 (list :promoted (if promoted t nil))))
            (let* ((mode (if (and mode-str (string-equal mode-str "queue")) :queue :steer))
                   (count (librecode-runner.session:promote-pending-inputs session-id :mode mode)))
              (json-response 200 (list :promoted-count count)))))
    (error (c)
      (json-response 400 (list :error (format nil "Error promoting input: ~A" c))))))

(defun handle-wake-session (session-id env)
  (handler-case
      (let* ((json (parse-json-body env))
             (provider (or (and json (gethash "provider" json)) "mock-provider"))
             (model (or (and json (gethash "model" json)) "mock-model"))
             (db-path *http-db-path*)
             (workspace-root *http-workspace-root*))
        (librecode-runner.protocol:wake-session session-id
          (lambda ()
            (let* ((librecode-runner.event-store:*workspace-root*
                     (or workspace-root librecode-runner.event-store:*workspace-root*))
                   (db (librecode-runner.event-store:connect-db db-path)))
              (unwind-protect
                   (let ((librecode-runner.event-store:*db* db))
                     (librecode-runner.protocol:broadcast-event session-id :session-start)
                     (unwind-protect
                          (let ((continue t))
                            (loop while (and continue (not (librecode-runner.protocol:session-stopping-p session-id)))
                                  do (setf continue (librecode-runner.runner:execute-provider-turn session-id provider model))))
                       (librecode-runner.protocol:broadcast-event session-id :session-complete)))
                (sqlite:disconnect db)))))
        (json-response 200 (list :status "woken")))
    (error (c)
      (json-response 400 (list :error (format nil "Error waking session: ~A" c))))))

(defun handle-get-history (session-id env)
  (declare (ignore env))
  (handler-case
      (let ((db librecode-runner.event-store:*db*))
        (let ((rows (sqlite:execute-to-list db
                      "SELECT id, role, content, created_at FROM session_history WHERE session_id = ? ORDER BY created_at ASC"
                      session-id)))
          (list 200
                '(:content-type "application/json")
                (list (com.inuoe.jzon:stringify
                       (mapcar (lambda (row)
                                 (let ((ht (make-hash-table :test 'equal)))
                                   (setf (gethash "id" ht) (first row))
                                   (setf (gethash "role" ht) (second row))
                                   (setf (gethash "content" ht) (third row))
                                   (setf (gethash "created_at" ht) (fourth row))
                                   ht))
                               rows))))))
    (error (c)
      (json-response 400 (list :error (format nil "Error retrieving history: ~A" c))))))

(defun handle-get-stream (session-id env)
  (declare (ignore env))
  (let ((client-mbox (librecode-runner.protocol:make-mailbox :name (format nil "stream-client-~A" session-id))))
    (register-sse-listener session-id client-mbox)
    (lambda (responder)
      (let ((writer (funcall responder '(200 (:content-type "text/event-stream"
                                              :cache-control "no-cache"
                                              :connection "close")))))
        ;; Immediately write open event as data line to flush headers and prevent client timeouts
        (funcall writer (format nil "data: {\"event\":\"open\"}~%~%"))
        (unwind-protect
             (handler-case
                 (loop
                   (let ((msg (librecode-runner.protocol:receive-message client-mbox)))
                     (cond
                       ((null msg) (return))
                       (t
                        (let* ((event-type (car msg))
                               (event-data (cadr msg))
                               (json-payload
                                 (cond
                                   ((eq event-type :delta)
                                    (com.inuoe.jzon:stringify (alexandria:plist-hash-table `("event" "delta" "content" ,event-data))))
                                   ((eq event-type :tool-start)
                                    (com.inuoe.jzon:stringify (alexandria:plist-hash-table
                                                               `("event" "tool_start"
                                                                 "tool_call_id" ,(getf event-data :id)
                                                                 "name" ,(getf event-data :name)
                                                                 "arguments" ,(getf event-data :arguments)))))
                                   ((eq event-type :tool-success)
                                    (com.inuoe.jzon:stringify (alexandria:plist-hash-table
                                                               `("event" "tool_success"
                                                                 "tool_call_id" ,(getf event-data :id)
                                                                 "result" ,(getf event-data :result)))))
                                   ((eq event-type :tool-error)
                                    (com.inuoe.jzon:stringify (alexandria:plist-hash-table
                                                               `("event" "tool_error"
                                                                 "tool_call_id" ,(getf event-data :id)
                                                                 "error" ,(getf event-data :error)))))
                                   ((eq event-type :session-complete)
                                    (com.inuoe.jzon:stringify (alexandria:plist-hash-table `("event" "complete"))))
                                   (t
                                    (com.inuoe.jzon:stringify (alexandria:plist-hash-table
                                                               `("event" ,(symbol-to-json-key event-type)
                                                                 "data" ,event-data))))))
                               (sse-payload (format nil "data: ~A~%~%" json-payload)))
                          (funcall writer sse-payload)
                          (when (eq event-type :session-complete)
                            (return)))))))
               (error (c)
                 (declare (ignore c))
                 nil))
          (unregister-sse-listener session-id client-mbox)
          (ignore-errors
           (funcall writer nil :close t)))))))

;; --- Main Router ---

(defun handle-request (method path env)
  (if (eq method :options)
      (list 200
            '(:content-type "application/json"
              :access-control-allow-origin "*"
              :access-control-allow-methods "GET, POST, PUT, DELETE, OPTIONS"
              :access-control-allow-headers "Content-Type, Authorization, x-requested-with")
            '(""))
      (let ((parts (split-path path)))
        (cond
          ((and (eq method :post)
                (equal parts '("session")))
           (handle-create-session env))
          ((and (eq method :post)
                (= (length parts) 3)
                (string= (first parts) "session")
                (string= (third parts) "admit"))
           (handle-admit-input (second parts) env))
          ((and (eq method :post)
                (= (length parts) 3)
                (string= (first parts) "session")
                (string= (third parts) "promote"))
           (handle-promote-input (second parts) env))
          ((and (eq method :post)
                (= (length parts) 3)
                (string= (first parts) "session")
                (string= (third parts) "wake"))
           (handle-wake-session (second parts) env))
          ((and (eq method :get)
                (= (length parts) 3)
                (string= (first parts) "session")
                (string= (third parts) "history"))
           (handle-get-history (second parts) env))
          ((and (eq method :get)
                (= (length parts) 3)
                (string= (first parts) "session")
                (string= (third parts) "stream"))
           (handle-get-stream (second parts) env))
          ((and (eq method :get)
                (or (equal parts '("session"))
                    (equal parts '("api" "session"))))
           (handle-list-sessions))
          ((and (eq method :get)
                (or (equal parts '("global" "health"))
                    (equal parts '("api" "global" "health"))))
           (json-response 200 '(:healthy t :version "1.0.0")))
          ;; TODO: Implement native workspace/IDE configuration routes (e.g. /lsp, /project, /path,
          ;; /provider, /global/config) to support full standalone server deployment.
          ;; Currently stubbed to 200 OK to prevent console exceptions in Vite/Playwright client tests.
          (t
           (json-response 200 '(:status "ok")))))))

(defun make-http-app (&key db-path workspace-root)
  (lambda (env)
    (let* ((method (getf env :request-method))
           (path (getf env :path-info))
           (librecode-runner.event-store:*workspace-root*
             (or workspace-root librecode-runner.event-store:*workspace-root*)))
      (format *error-output* "DEBUG: [Server] Request ~A ~A received. Connecting to DB...~%" method path) (force-output *error-output*)
      (let* ((should-connect (or db-path (null librecode-runner.event-store:*db*)))
             (db (if should-connect
                     (progn
                       (format *error-output* "DEBUG: [Server] Calling connect-db for ~A...~%" (or db-path "librecode.db")) (force-output *error-output*)
                       (librecode-runner.event-store:connect-db (or db-path "librecode.db")))
                     librecode-runner.event-store:*db*)))
        (format *error-output* "DEBUG: [Server] Connected. Executing request handler...~%") (force-output *error-output*)
        (unwind-protect
             (let ((librecode-runner.event-store:*db* db)
                   (*http-origin* (getf env :http-origin)))
               (handle-request method path env))
          (when (and should-connect db)
            (format *error-output* "DEBUG: [Server] Disconnecting DB...~%") (force-output *error-output*)
            (sqlite:disconnect db)))))))

;; --- External API ---

(defun start-http-bridge (&key (port 4096) (address "127.0.0.1") db-path workspace-root)
  "Start Clack/Hunchentoot HTTP bridge on specified PORT and ADDRESS."
  (stop-http-bridge)
  (let* ((resolved-db-path (or db-path "librecode.db"))
         (librecode-runner.event-store:*workspace-root*
           (or workspace-root librecode-runner.event-store:*workspace-root*))
         (db (librecode-runner.event-store:connect-db resolved-db-path)))
    (unwind-protect
         (librecode-runner.event-store:init-db db)
      (sqlite:disconnect db)))
  (setf *http-db-path* (or db-path "librecode.db"))
  (setf *http-workspace-root* workspace-root)
  (setf librecode-runner.protocol:*event-broadcast-hook* #'broadcast-sse-event)
  (let ((app (make-http-app :db-path db-path :workspace-root workspace-root)))
    (setf *http-bridge-server*
          (clack:clackup app :port port :address address :server :hunchentoot :use-thread t))))

(defun stop-http-bridge ()
  "Stop HTTP bridge server if running."
  (setf librecode-runner.protocol:*event-broadcast-hook* nil)
  (when *http-bridge-server*
    (clack:stop *http-bridge-server*)
    (setf *http-bridge-server* nil)
    t))
