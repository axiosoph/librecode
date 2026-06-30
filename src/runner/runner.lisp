;;; -*- Mode: Lisp; Syntax: Common-Lisp; indent-tabs-mode: nil; coding: utf-8; Show-Trailing-Whitespace: t -*-
;;;
;;; runner.lisp — LLM turn execution and provider interfacing
;;;

(in-package #:librecode-runner.runner)

(defvar *provider-url* "http://localhost:8080/v1/chat/completions"
  "The LLM provider endpoint URL.")

(defvar *tool-registry* (make-instance 'librecode-runner.tool:tool-registry)
  "The default active tool registry.")

(defun get-latest-epoch-baseline (session-id)
  "Retrieve the latest baseline text from context_epoch read projection."
  (when (and (boundp 'librecode-runner.event-store:*db*)
             librecode-runner.event-store:*db*)
    (let ((db librecode-runner.event-store:*db*))
      (sqlite:execute-single db
        "SELECT baseline_text FROM context_epoch WHERE session_id = ?"
        session-id))))

(defun get-session-history-messages (session-id)
  "Retrieve session history messages from session_history read projection."
  (when (and (boundp 'librecode-runner.event-store:*db*)
             librecode-runner.event-store:*db*)
    (let ((db librecode-runner.event-store:*db*))
      (sqlite:execute-to-list db
        "SELECT role, content FROM session_history WHERE session_id = ? ORDER BY created_at ASC"
        session-id))))

(defun strip-jsonc-comments (text)
  "Remove C-style single-line and multi-line comments from JSON string."
  (let ((len (length text))
        (out (make-array 0 :element-type 'character :fill-pointer 0 :adjustable t))
        (in-string nil)
        (escaped nil)
        (i 0))
    (loop while (< i len)
          do (let ((char (char text i)))
               (cond
                 (escaped
                  (vector-push-extend char out)
                  (setf escaped nil)
                  (incf i))
                 (in-string
                  (vector-push-extend char out)
                  (cond
                    ((char= char #\\)
                     (setf escaped t))
                    ((char= char #\")
                     (setf in-string nil)))
                  (incf i))
                 (t
                  (cond
                    ((char= char #\")
                     (setf in-string t)
                     (vector-push-extend char out)
                     (incf i))
                    ((and (< (1+ i) len)
                          (char= char #\/)
                          (char= (char text (1+ i)) #\/))
                     (incf i 2)
                     (loop while (and (< i len)
                                      (not (char= (char text i) #\Newline)))
                           do (incf i)))
                    ((and (< (1+ i) len)
                          (char= char #\/)
                          (char= (char text (1+ i)) #\*))
                     (incf i 2)
                     (let ((found-end nil))
                       (loop while (and (< i len) (not found-end))
                             do (if (and (< (1+ i) len)
                                         (char= (char text i) #\*)
                                         (char= (char text (1+ i)) #\/))
                                    (progn
                                      (setf found-end t)
                                      (incf i 2))
                                    (incf i)))))
                    (t
                     (vector-push-extend char out)
                     (incf i)))))))
    out))

(defun process-sse-line-data (line text-accum tools-accum)
  "Parse a single SSE streaming delta line and accumulate content and tool calls."
  (let ((trimmed (string-trim '(#\Space #\Tab #\Return #\Newline) line)))
    (when (alexandria:starts-with-subseq "data: " trimmed)
      (let* ((data-val (subseq trimmed 5))
             (parsed (unless (string= data-val "[DONE]")
                       (handler-case
                           (com.inuoe.jzon:parse (strip-jsonc-comments data-val))
                         (error () nil)))))
        (when (hash-table-p parsed)
          (let ((err (gethash "error" parsed)))
            (when err
              (error 'librecode-runner.conditions:provider-error
                     :endpoint *provider-url*
                     :provider "mock"
                     :message (format nil "SSE provider error: ~A" err))))
          (let ((choices (gethash "choices" parsed)))
            (when (and choices (> (length choices) 0))
              (let* ((choice (elt choices 0))
                     (delta (gethash "delta" choice)))
                (when delta
                  (let ((content (gethash "content" delta)))
                    (when (stringp content)
                      (loop for char across content
                            do (vector-push-extend char text-accum))))
                  (let ((tool-calls (gethash "tool_calls" delta)))
                    (when tool-calls
                      (loop for tc across tool-calls
                            do (let* ((index (gethash "index" tc))
                                      (id (gethash "id" tc))
                                      (function (gethash "function" tc)))
                                 (when (or id function)
                                   (let ((existing (gethash index tools-accum)))
                                     (unless existing
                                       (setf existing (list :id "" :name "" :arguments "")))
                                     (when id
                                       (setf (getf existing :id) id))
                                     (when function
                                       (let ((name (gethash "name" function))
                                             (args (gethash "arguments" function)))
                                         (when name
                                           (setf (getf existing :name) name))
                                         (when args
                                           (setf (getf existing :arguments)
                                                 (concatenate 'string (getf existing :arguments) args)))))
                                     (setf (gethash index tools-accum) existing))))))))))))))))

(defun get-active-agent (session-id)
  "Retrieve or construct the agent for the active session."
  (let* ((db librecode-runner.event-store:*db*)
         (agent-id (or (sqlite:execute-single db
                         "SELECT agent_id FROM session_state WHERE session_id = ?"
                         session-id)
                       "default-agent"))
         (saved-rules (librecode-runner.agent::load-saved-rules)))
    (make-instance 'librecode-runner.agent:agent
                   :id agent-id
                   :ruleset saved-rules
                   :system-context "")))

(defun save-assistant-message (session-id text-content tool-calls)
  "Commit the assistant response to event log and session history."
  (let* ((db librecode-runner.event-store:*db*)
         (now (librecode-runner.event-store::current-timestamp-ms))
         (msg-id (format nil "msg-~A-~A" now (random 100000))))
    (let ((payload (if tool-calls
                       (com.inuoe.jzon:stringify
                        (librecode-runner.event-store::coerce-to-hash-table
                         `((:text . ,text-content)
                           (:tool_calls . ,(mapcar (lambda (tc)
                                                     `((:id . ,(getf tc :id))
                                                       (:type . "function")
                                                       (:function . ((:name . ,(getf tc :name))
                                                                     (:arguments . ,(getf tc :arguments))))))
                                                   tool-calls)))))
                       text-content)))
      (let ((next-seq (librecode-runner.agent::get-next-event-sequence session-id)))
        (librecode-runner.event-store:commit-event
         session-id
         `((:message-id . ,msg-id)
           (:role . "assistant")
           (:content . ,payload))
         :message-assistant
         next-seq))
      (sqlite:execute-non-query db
        "INSERT INTO session_history (id, session_id, role, content, created_at)
         VALUES (?, ?, 'assistant', ?, ?)"
        msg-id session-id payload now))))

(defun save-tool-message (session-id call-id tool-name content)
  "Commit a tool execution result to event log and session history."
  (let ((db librecode-runner.event-store:*db*)
        (now (librecode-runner.event-store::current-timestamp-ms))
        (next-seq (librecode-runner.agent::get-next-event-sequence session-id)))
    (librecode-runner.event-store:commit-event
     session-id
     `((:tool-call-id . ,call-id)
       (:tool-name . ,tool-name)
       (:content . ,content))
     :tool-response
     next-seq)
    (sqlite:execute-non-query db
      "INSERT INTO session_history (id, session_id, role, content, created_at)
       VALUES (?, ?, 'tool', ?, ?)"
      (format nil "tool-~A-~A" call-id (random 100000)) session-id content now)))

(defun execute-parallel-tools (session-id tool-calls registry)
  "Execute multiple tool-calls concurrently. Relays results or errors back to coordinator mailbox."
  (let ((pending-calls (length tool-calls))
        (results (make-hash-table :test 'equal))
        (agent (get-active-agent session-id)))
    (dolist (tc tool-calls)
      (let* ((call-id (getf tc :id))
             (name (getf tc :name))
             (arguments-str (getf tc :arguments))
             (args-plist (handler-case
                             (let ((parsed (com.inuoe.jzon:parse (strip-jsonc-comments arguments-str))))
                               (if (hash-table-p parsed)
                                   (let ((plist nil))
                                     (maphash (lambda (k v)
                                                (push (intern (string-upcase k) :keyword) plist)
                                                (push v plist))
                                              parsed)
                                     (nreverse plist))
                                   nil))
                           (error () nil)))
             (tool (bt:with-lock-held ((librecode-runner.tool::registry-lock registry))
                     (gethash name (librecode-runner.tool::registry-tools registry)))))
        (if (not tool)
            (setf (gethash call-id results) (format nil "Error: Tool ~A not found" name))
            (let ((worker-mbox (librecode-runner.protocol:make-mailbox :name (format nil "worker-mbox-~A" call-id))))
              (librecode-runner.protocol:register-worker-mailbox session-id worker-mbox)
              (bt:make-thread
               (lambda ()
                 (let ((self (bt:current-thread))
                       (librecode-runner.agent:*current-session-id* session-id))
                   (declare (special librecode-runner.agent:*current-session-id*))
                   (librecode-runner.protocol:register-worker-thread session-id self)
                   (unwind-protect
                        (handler-case
                            (progn
                              ;; Evaluate permission request at execution site
                              (librecode-runner.agent:check-permission agent "execute_tool" name)
                              (let ((res (funcall (librecode-runner.tool:tool-handler tool) args-plist)))
                                (librecode-runner.protocol:send-message
                                 librecode-runner.protocol:*session-mailbox*
                                 `(:tool-success ,call-id ,res))))
                          (error (c)
                            (librecode-runner.protocol:send-message
                             librecode-runner.protocol:*session-mailbox*
                             `(:tool-error ,call-id ,(format nil "~A" c)))))
                     (librecode-runner.protocol:unregister-worker-thread session-id self)
                     (librecode-runner.protocol:unregister-worker-mailbox session-id worker-mbox))))
               :name (format nil "tool-worker-~A" name))))))

    ;; Read from unified session mailbox for all tools to settle
    (loop while (> pending-calls (hash-table-count results))
          do (let ((msg (librecode-runner.protocol:receive-message librecode-runner.protocol:*session-mailbox*)))
               (cond
                 ((null msg) nil)
                 ((eq (car msg) :interrupt)
                  (error 'librecode-runner.conditions:harness-failure
                         :message "Session interrupted during parallel tool execution."))
                 ((eq (car msg) :abort)
                  (error 'librecode-runner.conditions:harness-failure
                         :message "Session aborted during parallel tool execution."))
                 ((eq (car msg) :tool-success)
                  (destructuring-bind (call-id res-val) (cdr msg)
                    (setf (gethash call-id results) res-val)))
                 ((eq (car msg) :tool-error)
                  (destructuring-bind (call-id err-msg) (cdr msg)
                    (setf (gethash call-id results) err-msg))))))

    (let ((res-list nil))
      (maphash (lambda (k v)
                 (push v res-list)
                 (push k res-list))
               results)
      res-list)))

(defun execute-provider-turn (session provider model)
  "Execute a single provider turn for the given session.
Enforces that exactly one provider call is made. Returns t if continuation is allowed."
  (unless librecode-runner.event-store:*db*
    (error "No active database connection in *db*."))
  (librecode-runner.protocol:flush-mailbox librecode-runner.protocol:*session-mailbox*)
  (let* ((session-id (librecode-runner.session::coerce-session-id session)))
    ;; 1. Promote any pending steer inputs
    (librecode-runner.session:promote-pending-inputs session-id :mode :steer)

    ;; 2. Build history and baseline messages
    (let* ((baseline (get-latest-epoch-baseline session-id))
           (history (get-session-history-messages session-id))
           (messages nil))
      (let ((sys-prompt (or baseline "")))
        (push (alexandria:plist-hash-table `("role" "system" "content" ,sys-prompt)) messages))

      (dolist (h history)
        (push (alexandria:plist-hash-table `("role" ,(first h) "content" ,(second h))) messages))

      (setf messages (nreverse messages))

      ;; 3. Make LLM request (exactly one call)
      (let* ((request-body (com.inuoe.jzon:stringify
                            (alexandria:plist-hash-table
                             `("model" ,model
                               "messages" ,(mapcar #'librecode-runner.event-store::coerce-to-hash-table messages)
                               "stream" t))))
             (dex-stream (handler-case
                             (dexador:post *provider-url*
                                           :headers '(("Content-Type" . "application/json"))
                                           :content request-body
                                           :want-stream t)
                           (error (c)
                             (error 'librecode-runner.conditions:provider-error
                                    :endpoint *provider-url*
                                    :provider provider
                                    :message (format nil "HTTP POST failed: ~A" c))))))
        (multiple-value-bind (text-content tool-calls)
            (unwind-protect
                  (let ((text-accum (make-array 0 :element-type 'character :fill-pointer 0 :adjustable t))
                        (tools-accum (make-hash-table :test 'equal)))
                    ;; Spawn Dedicated SSE reader thread
                    (let ((mbox librecode-runner.protocol:*session-mailbox*)
                          (rid (format nil "reader-~A" (random 1000000))))
                      (bt:make-thread
                       (lambda ()
                         (let ((librecode-runner.protocol:*session-mailbox* mbox))
                           (handler-case
                               (loop
                                 (let ((line (read-line dex-stream nil :eof)))
                                   (if (eq line :eof)
                                       (progn
                                         (librecode-runner.protocol:send-message
                                          librecode-runner.protocol:*session-mailbox*
                                          `(:sse-eof ,rid))
                                         (return))
                                       (librecode-runner.protocol:send-message
                                        librecode-runner.protocol:*session-mailbox*
                                        `(:sse-line ,rid ,line)))))
                             (error (c)
                               (librecode-runner.protocol:send-message
                                librecode-runner.protocol:*session-mailbox*
                                `(:sse-error ,rid ,c))))))
                       :name "sse-reader-thread")

                     ;; Unified Event Loop on *session-mailbox*
                     (loop
                       (let ((msg (librecode-runner.protocol:receive-message librecode-runner.protocol:*session-mailbox*)))
                         (cond
                           ((null msg) (return))
                           ((eq (car msg) :interrupt)
                            (close dex-stream)
                            (error 'librecode-runner.conditions:harness-failure
                                   :message "Session interrupted during LLM execution turn."))
                           ((eq (car msg) :abort)
                            (close dex-stream)
                            (error 'librecode-runner.conditions:harness-failure
                                   :message "Session aborted during LLM execution turn."))
                           ;; Filter reader-specific messages by reader-id
                           ((and (member (car msg) '(:sse-line :sse-eof :sse-error))
                                 (not (equal (second msg) rid)))
                            nil)
                           ((eq (car msg) :sse-error)
                            (error 'librecode-runner.conditions:provider-error
                                   :endpoint *provider-url*
                                   :provider provider
                                   :message (format nil "SSE stream error: ~A" (third msg))))
                           ((eq (car msg) :sse-eof)
                            (return))
                           ((eq (car msg) :sse-line)
                            (process-sse-line-data (third msg) text-accum tools-accum))))))

                    (let ((tc-list nil))
                      (maphash (lambda (k v)
                                 (declare (ignore k))
                                 (push v tc-list))
                               tools-accum)
                      (values (coerce text-accum 'string) (nreverse tc-list))))
              (close dex-stream))

          ;; 4. Save assistant response
          (save-assistant-message session-id text-content tool-calls)

          ;; 5. Settle concurrent tool calls if any
          (if tool-calls
              (progn
                (let ((results (execute-parallel-tools session-id tool-calls *tool-registry*)))
                  (loop for (call-id res-val) on results by #'cddr
                        do (let ((tc (find call-id tool-calls :key (lambda (x) (getf x :id)) :test #'string=)))
                             (save-tool-message session-id call-id (getf tc :name) res-val))))
                t) ; continuation allowed
              nil))))))
