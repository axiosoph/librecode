;;; -*- Mode: Lisp; Syntax: Common-Lisp; indent-tabs-mode: nil; coding: utf-8; Show-Trailing-Whitespace: t -*-
;;;
;;; runner.lisp — LLM turn execution and provider interfacing
;;;

(in-package #:librecode-runner.runner)

(defvar *provider-url* "http://localhost:8080/v1/chat/completions"
  "The LLM provider endpoint URL.")

(defvar *backup-provider-url* "http://localhost:8081/v1/chat/completions"
  "The backup LLM provider endpoint URL.")

(defvar *tool-registry* (make-instance 'librecode-runner.tool:tool-registry)
  "The default active tool registry.")

(defvar *worker-marker* nil
  "Dynamic marker to verify stack preservation during worker restart invocation.")

(defvar *last-skip-preserved-stack-p* nil
  "Internal, test-only proof that a supervised skip-and-continue restart ran
without unwinding the failing worker's stack -- set from *worker-marker*'s
value as observed at the restart's invocation site. Never surfaced as tool
output; inspect via the internal symbol from tests only.")

(defun get-latest-epoch-baseline (session-id)
  "Retrieve the latest baseline text from context_epoch read projection."
  (when (and (boundp 'librecode-runner.event-store:*db*)
             librecode-runner.event-store:*db*)
    (let ((db librecode-runner.event-store:*db*))
      (sqlite:execute-single db
        "SELECT baseline_text FROM context_epoch WHERE session_id = ?"
        session-id))))

(defun get-session-history-messages (session-id)
  "Retrieve session history rows (id role content tool_call_id) from the
session_history read projection, ordered by CREATED-AT. TOOL-CALL-ID is NIL
for every row except tool-role rows recorded under the tool-linkage schema."
  (when (and (boundp 'librecode-runner.event-store:*db*)
             librecode-runner.event-store:*db*)
    (let ((db librecode-runner.event-store:*db*))
      (sqlite:execute-to-list db
        "SELECT id, role, content, tool_call_id FROM session_history WHERE session_id = ? ORDER BY created_at ASC"
        session-id))))

(defun parse-assistant-payload (content)
  "Parse an assistant session_history row's CONTENT column.
Returns (values text tool-calls), where TOOL-CALLS is a list of
(:id :name :arguments) plists reconstructed from the persisted
{text, tool_calls: [...]} JSON payload, or NIL for a plain-text
assistant response with no tool calls."
  (let ((parsed (handler-case (com.inuoe.jzon:parse content) (error () nil))))
    (if (and (hash-table-p parsed) (gethash "tool_calls" parsed))
        (values (gethash "text" parsed)
                (map 'list
                     (lambda (tc)
                       (let ((fn (gethash "function" tc)))
                         (list :id (gethash "id" tc)
                               :name (and fn (gethash "name" fn))
                               :arguments (and fn (gethash "arguments" fn)))))
                     (gethash "tool_calls" parsed)))
        (values content nil))))

(defun reconstruct-wire-message (session-id row)
  "Reconstruct a single spec-form OpenAI chat-completions message plist from a
SESSION_HISTORY row (id role content tool-call-id). Signals
LIBRECODE-RUNNER.CONDITIONS:LEGACY-HISTORY-ROW for a tool-role row that
predates tool_call_id tracking, rather than silently emitting an unlinked
tool message a real provider endpoint would reject or mis-thread."
  (destructuring-bind (id role content tool-call-id) row
    (cond
      ((string= role "tool")
       (unless (and tool-call-id (plusp (length tool-call-id)))
         (error 'librecode-runner.conditions:legacy-history-row
                :session-id session-id
                :row-id id
                :message (format nil "Tool-role row ~A carries no tool_call_id -- it predates tool-call linkage tracking." id)))
       (list :role "tool" :tool_call_id tool-call-id :content content))
      ((string= role "assistant")
       (multiple-value-bind (text tool-calls) (parse-assistant-payload content)
         (if tool-calls
             (list :role "assistant"
                   :content (or text "")
                   :tool_calls (map 'vector
                                    (lambda (tc)
                                      (list :id (getf tc :id)
                                            :type "function"
                                            :function (list :name (getf tc :name)
                                                             :arguments (getf tc :arguments))))
                                    tool-calls))
             (list :role "assistant" :content content))))
      (t (list :role role :content content)))))

(defun get-wire-history-messages (session-id)
  "Retrieve and reconstruct SESSION-ID's history as an ordered list of
spec-form OpenAI chat-completions message plists, ready for outbound request
assembly. See RECONSTRUCT-WIRE-MESSAGE and GET-SESSION-HISTORY-MESSAGES."
  (mapcar (lambda (row) (reconstruct-wire-message session-id row))
          (get-session-history-messages session-id)))

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

(defun parse-fallback-tool-call (text)
  "Attempt to parse a tool call from raw text if the model returned it in content."
  (handler-case
      (let* ((trimmed (string-trim '(#\Space #\Tab #\Return #\Newline) text))
             (json-str (cond
                         ((search "```json" trimmed)
                          (let* ((start (+ (search "```json" trimmed) 7))
                                 (end (search "```" trimmed :start2 start)))
                            (if end
                                (subseq trimmed start end)
                                (subseq trimmed start))))
                         ((search "```" trimmed)
                          (let* ((start (+ (search "```" trimmed) 3))
                                 (end (search "```" trimmed :start2 start)))
                            (if end
                                (subseq trimmed start end)
                                (subseq trimmed start))))
                         (t trimmed)))
             (first-brace (position #\{ json-str))
             (last-brace (position #\} json-str :from-end t))
             (clean-json (if (and first-brace last-brace (< first-brace last-brace))
                             (subseq json-str first-brace (1+ last-brace))
                             json-str))
             (parsed (com.inuoe.jzon:parse clean-json)))
        (when (hash-table-p parsed)
          (let ((name (gethash "name" parsed))
                (arguments (gethash "arguments" parsed)))
            (when (and name arguments)
              (let ((args-str (if (stringp arguments)
                                  arguments
                                  (com.inuoe.jzon:stringify arguments))))
                (return-from parse-fallback-tool-call
                  (list (list :id "call-fallback-1"
                              :name name
                              :arguments args-str))))))
          (let ((func (gethash "function" parsed)))
            (when (and func (hash-table-p func))
              (let ((name (gethash "name" func))
                    (arguments (gethash "arguments" func)))
                (when (and name arguments)
                  (let ((args-str (if (stringp arguments)
                                      arguments
                                      (com.inuoe.jzon:stringify arguments))))
                    (return-from parse-fallback-tool-call
                      (list (list :id "call-fallback-1"
                                  :name name
                                  :arguments args-str))))))))))
    (error () nil))
  nil)

(defun process-sse-line-data (session-id line text-accum tools-accum)
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
              (let ((err-str (format nil "~A" err)))
                (if (or (search "context_length_exceeded" err-str)
                        (search "context_overflow" err-str)
                        (search "token limit" err-str))
                    (error 'librecode-runner.conditions:context-overflow
                           :message err-str
                           :budget 2000
                           :requested 2500)
                    (error 'librecode-runner.conditions:provider-error
                           :endpoint *provider-url*
                           :provider "mock"
                           :message (format nil "SSE provider error: ~A" err-str))))))
          (let ((choices (gethash "choices" parsed)))
            (when (and choices (> (length choices) 0))
              (let* ((choice (elt choices 0))
                     (delta (gethash "delta" choice)))
                (when delta
                  (let ((content (gethash "content" delta)))
                    (when (stringp content)
                      (librecode-runner.protocol:broadcast-event session-id :delta content)
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
                           (:tool_calls . ,(map 'vector
                                                (lambda (tc)
                                                  `((:id . ,(getf tc :id))
                                                    (:type . "function")
                                                    (:function . ((:name . ,(getf tc :name))
                                                                  (:arguments . ,(getf tc :arguments))))))
                                                tool-calls)))))
                       text-content)))
      (librecode-runner.event-store:commit-event
       session-id
       `((:message-id . ,msg-id)
         (:role . "assistant")
         (:content . ,payload))
       :message-assistant)
      (sqlite:execute-non-query db
        "INSERT INTO session_history (id, session_id, role, content, created_at)
         VALUES (?, ?, 'assistant', ?, ?)"
        msg-id session-id payload now))))

(defun save-tool-message (session-id call-id tool-name content)
  "Commit a tool execution result to event log and session history."
  (let ((db librecode-runner.event-store:*db*)
        (now (librecode-runner.event-store::current-timestamp-ms)))
    (librecode-runner.event-store:commit-event
     session-id
     `((:tool-call-id . ,call-id)
       (:tool-name . ,tool-name)
       (:content . ,content))
     :tool-response)
    (sqlite:execute-non-query db
      "INSERT INTO session_history (id, session_id, role, content, created_at, tool_call_id)
       VALUES (?, ?, 'tool', ?, ?, ?)"
      (format nil "tool-~A-~A" call-id (random 100000)) session-id content now call-id)))

(defun parse-tool-arguments (arguments-str)
  "Parse ARGUMENTS-STR (a JSON object string) into a keyword plist.
Signals an error if the JSON is malformed; a well-formed non-object JSON
value yields NIL args (an empty plist), not a parse error."
  (let ((parsed (com.inuoe.jzon:parse (strip-jsonc-comments arguments-str))))
    (if (hash-table-p parsed)
        (let ((plist nil))
          (maphash (lambda (k v)
                     (push (intern (string-upcase k) :keyword) plist)
                     (push v plist))
                   parsed)
          (nreverse plist))
        nil)))

(defun execute-tool-with-supervised-timeout (tool args-plist name)
  "Execute TOOL synchronously in the CURRENT thread, bounded by a real,
stack-preserving timeout -- the mechanism the SUPERVISED branch of
RUN-TOOL-WORKER uses instead of EXECUTE-TOOL-ASYNC. EXECUTE-TOOL-ASYNC runs
the handler on a separate worker thread and relays the outcome by
re-signaling in the caller's thread, which loses the original
stack/dynamic-binding context a live supervisor's skip-and-continue restart
depends on (see TEST-NO-UNWIND-HANDSHAKE). SB-EXT:WITH-TIMEOUT instead
delivers its expiry as an SB-EXT:TIMEOUT condition IN PLACE -- same thread,
same stack -- so an enclosing handler (WITH-FAILURE-RELAY's) can resolve it
without unwinding past the original call.
The effective timeout is the tool call's own :timeout argument when supplied,
otherwise *DEFAULT-TOOL-TIMEOUT* -- the same composition EXECUTE-TOOL-ASYNC
uses on the unsupervised path. SB-EXT:TIMEOUT is translated, in place, into
LIBRECODE-RUNNER.CONDITIONS:TOOL-TIMEOUT for consistency with the rest of the
codebase's timeout vocabulary (see CONDITION-TO-DESCRIPTOR).
A cooperative-cancellation registry (*ACTIVE-SUBPROCESSES*) is bound around
the call so a subprocess-launching tool (e.g. bash) can register its child
process and have it forcibly terminated on timeout: SB-EXT:WITH-TIMEOUT's
asynchronous interrupt is not reliably delivered while a thread is blocked in
a subprocess/FFI wait, so the registry is the mechanism that actually
unblocks that case (a pure-Lisp hang, by contrast, IS reliably interrupted by
SB-EXT:WITH-TIMEOUT alone)."
  (let* ((effective-timeout (or (getf args-plist :timeout)
                                 librecode-runner.tool:*default-tool-timeout*))
         (active-subprocs-binding (librecode-runner.tool:make-subprocess-cancellation-registry)))
    (unwind-protect
         (handler-bind
             ((sb-ext:timeout
                (lambda (c)
                  (declare (ignore c))
                  (error 'librecode-runner.conditions:tool-timeout
                         :tool-id name
                         :duration effective-timeout
                         :message (format nil "Tool ~A execution exceeded timeout of ~A seconds."
                                           name effective-timeout)))))
           (let ((librecode-runner.tool:*active-subprocesses* active-subprocs-binding))
             (sb-ext:with-timeout effective-timeout
               (librecode-runner.tool:execute-tool tool args-plist))))
      (librecode-runner.tool:cancel-and-terminate-registered-subprocesses active-subprocs-binding))))

(defun run-tool-worker (session-id call-id name tool args-plist agent worker-mbox)
  "Execute TOOL in the current (worker) thread and relay its outcome to the
coordinator's session mailbox. In the DEFAULT (unsupervised) branch, execution
is bounded by a real timeout via EXECUTE-TOOL-ASYNC's cooperative-cancellation
machinery: the tool call's own :timeout argument (e.g. bash's) wins when
supplied, otherwise *DEFAULT-TOOL-TIMEOUT* applies as the floor for every
tool. The SUPERVISED branch below bounds execution via
EXECUTE-TOOL-WITH-SUPERVISED-TIMEOUT instead -- a stack-preserving, in-thread
timeout (SB-EXT:WITH-TIMEOUT) rather than EXECUTE-TOOL-ASYNC's cross-thread
relay, since the latter was found to break WITH-FAILURE-RELAY's
no-stack-unwind guarantee (see TEST-NO-UNWIND-HANDSHAKE and the P9 handoff
report for that reconsideration).
In a supervised session (*session-supervised-p*), an ordinary handler error is
relayed through the failure-relay handshake so a live supervisor may choose to
skip or retry it. Otherwise -- the default -- the error settles locally as a
:tool-error result and the turn continues."
  (if librecode-runner.protocol:*session-supervised-p*
      (loop
        (restart-case
            (librecode-runner.protocol:with-failure-relay
                (librecode-runner.protocol:*session-mailbox*
                 worker-mbox
                 :recovery-menu '((skip-and-continue) (retry-tool))
                 :message-factory (lambda (desc reply-mbox recovery-menu)
                                    `(:worker-error ,call-id ,desc ,reply-mbox ,recovery-menu))
                 :apply-choice (lambda (choice args)
                                 (let ((restart (find-restart choice)))
                                   (if restart
                                       (if (eq choice 'skip-and-continue)
                                           (let ((marker-val (and (boundp '*worker-marker*) *worker-marker*)))
                                             (apply #'invoke-restart restart marker-val args))
                                           (apply #'invoke-restart restart args))
                                       (error "Restart ~A not found on worker stack" choice)))))
              ;; Evaluate permission request at execution site
              (librecode-runner.agent:check-permission agent "execute_tool" name)
              (let ((res (execute-tool-with-supervised-timeout tool args-plist name)))
                (librecode-runner.protocol:send-message
                 librecode-runner.protocol:*session-mailbox*
                 `(:tool-success ,call-id ,res)))
              (return))
          (skip-and-continue (&optional marker-val)
            :report "Skip this tool execution and continue session."
            (setf *last-skip-preserved-stack-p* (eq marker-val :active))
            (librecode-runner.protocol:broadcast-event session-id :tool-skipped (list :id call-id :name name))
            (librecode-runner.protocol:send-message
             librecode-runner.protocol:*session-mailbox*
             `(:tool-success ,call-id "Warning: Tool execution skipped."))
            (return))
          (retry-tool ()
            :report "Retry executing the tool."
            ;; Loop back and retry
            )))
      (handler-case
          (progn
            (librecode-runner.agent:check-permission agent "execute_tool" name)
            (let ((res (librecode-runner.tool:execute-tool-async
                        tool args-plist
                        :timeout (or (getf args-plist :timeout)
                                     librecode-runner.tool:*default-tool-timeout*))))
              (librecode-runner.protocol:send-message
               librecode-runner.protocol:*session-mailbox*
               `(:tool-success ,call-id ,res))))
        (serious-condition (c)
          (librecode-runner.protocol:send-message
           librecode-runner.protocol:*session-mailbox*
           `(:tool-error ,call-id ,(format nil "Error: ~A" c)))))))

(defun execute-parallel-tools (session-id tool-calls registry)
  "Execute multiple tool-calls concurrently. Relays results or errors back to coordinator mailbox."
  (let ((pending-calls (length tool-calls))
        (results (make-hash-table :test 'equal))
        (agent (get-active-agent session-id))
        (spawned-mailboxes nil)
        (spawned-threads nil))
    (unwind-protect
         (progn
           (dolist (tc tool-calls)
             (let* ((call-id (getf tc :id))
                    (name (getf tc :name))
                    (arguments-str (getf tc :arguments))
                    (tool (bt:with-lock-held ((librecode-runner.tool::registry-lock registry))
                            (gethash name (librecode-runner.tool::registry-tools registry)))))
               (multiple-value-bind (args-plist parse-condition)
                   (handler-case
                       (values (parse-tool-arguments arguments-str) nil)
                     (error (c) (values nil c)))
                 (cond
                   ((not tool)
                    (setf (gethash call-id results) (format nil "Error: Tool ~A not found" name)))
                   (parse-condition
                    (setf (gethash call-id results)
                          (format nil "Error: malformed tool arguments JSON: ~A" parse-condition)))
                   (t
                    (let ((worker-mbox (librecode-runner.protocol:make-mailbox :name (format nil "worker-mbox-~A" call-id))))
                      (push worker-mbox spawned-mailboxes)
                      (librecode-runner.protocol:register-worker-mailbox session-id worker-mbox)
                      (librecode-runner.protocol:broadcast-event session-id :tool-start (list :id call-id :name name :arguments arguments-str))
                      (let ((thread
                             (bt:make-thread
                              (librecode-runner.protocol:with-session-context-captured
                                (let ((self (bt:current-thread)))
                                  (librecode-runner.protocol:register-worker-thread session-id self)
                                  (unwind-protect
                                       (run-tool-worker session-id call-id name tool args-plist agent worker-mbox)
                                    (librecode-runner.protocol:unregister-worker-thread session-id self)
                                    (librecode-runner.protocol:unregister-worker-mailbox session-id worker-mbox))))
                              :name (format nil "tool-worker-~A" name))))
                        (push thread spawned-threads))))))))

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
                           (librecode-runner.protocol:broadcast-event session-id :tool-success (list :id call-id :result res-val))
                           (setf (gethash call-id results) res-val)))
                        ((eq (car msg) :tool-error)
                         (destructuring-bind (call-id err-msg) (cdr msg)
                           (librecode-runner.protocol:broadcast-event session-id :tool-error (list :id call-id :error err-msg))
                           (setf (gethash call-id results) err-msg)))
                        ((eq (car msg) :worker-error)
                         (destructuring-bind (call-id descriptor reply-mbox recovery-menu) (cdr msg)
                           (let ((condition (librecode-runner.protocol:descriptor-to-condition descriptor)))
                             (librecode-runner.protocol:broadcast-event session-id :tool-worker-error
                                                                         (list :id call-id :condition condition :recovery-menu recovery-menu))
                             (restart-case
                                 (error condition)
                               (skip-and-continue ()
                                 :report "Request worker to skip and continue."
                                 (librecode-runner.protocol:send-message reply-mbox '(skip-and-continue)))
                               (retry-tool ()
                                 :report "Request worker to retry the tool."
                                 (librecode-runner.protocol:send-message reply-mbox '(retry-tool)))))))))))
      (progn
        (dolist (m spawned-mailboxes)
          (ignore-errors (librecode-runner.protocol:send-message m '(:abort)))
          (librecode-runner.protocol:unregister-worker-mailbox session-id m))
        (dolist (thr spawned-threads)
          (ignore-errors (librecode-runner.protocol:join-thread-with-timeout thr 2.0)))))

    (let ((res-list nil))
      (maphash (lambda (k v)
                 (push v res-list)
                 (push k res-list))
               results)
      res-list)))

(defun execute-provider-turn (session provider model &key withhold-tools (model-capabilities '(:gpu :fast :slow :strongest :cheapest-sufficient)))
  "Execute a single provider turn for the given session.
Enforces that exactly one provider call is made. Returns t if continuation is allowed."
  (let* ((session-id (librecode-runner.session::coerce-session-id session))
         (sess-config (librecode-runner.provider:get-session-config session-id))
         (base-url (and sess-config (getf sess-config :base-url)))
         (config-model (and sess-config (getf sess-config :model)))
         (auth (and sess-config (getf sess-config :auth)))
         (current-url (if base-url
                          (librecode-runner.provider:resolve-provider-endpoint base-url)
                          *provider-url*))
         (current-provider provider)
         (current-model (or config-model model)))
    (loop
      (restart-case
          (let ((*provider-url* current-url))
            (unless librecode-runner.event-store:*db*
              (error "No active database connection in *db*."))
            (librecode-runner.protocol:flush-mailbox librecode-runner.protocol:*session-mailbox*)
            (let* (;; 1. Promote any pending steer inputs
                   (steer-promoted (librecode-runner.session:promote-pending-inputs session-id :mode :steer))
                   ;; 2. Build history and baseline messages
                   (baseline (get-latest-epoch-baseline session-id))
                   (history (get-wire-history-messages session-id))
                   (messages (let ((msgs nil)
                                   (sys-prompt (or baseline "")))
                               (push (alexandria:plist-hash-table `("role" "system" "content" ,sys-prompt)) msgs)
                               (dolist (h history)
                                 (push h msgs))
                               (nreverse msgs)))
                   ;; 3. Materialize tools if not withheld
                   (agent (get-active-agent session-id))
                   (materialized (unless withhold-tools
                                   (librecode-runner.tool:materialize-tools *tool-registry* agent model-capabilities)))
                   (request-plist (let ((plist (list :model current-model
                                                     :messages (mapcar #'librecode-runner.event-store::coerce-to-hash-table messages)
                                                     :stream t)))
                                    (if materialized
                                        (append plist (list :tools (map 'vector (lambda (tool)
                                                                                  (list :type "function"
                                                                                        :function (list :name (getf tool :name)
                                                                                                        :description (getf tool :description)
                                                                                                        :parameters (getf tool :parameters))))
                                                                        materialized)))
                                        plist)))
                   (request-body (com.inuoe.jzon:stringify
                                  (librecode-runner.event-store::coerce-to-hash-table request-plist)))
                   (dex-stream (handler-case
                                   (dexador:post *provider-url*
                                                 :headers (let ((h (list (cons "Content-Type" "application/json"))))
                                                            (when auth
                                                              (push (cons "Authorization" (format nil "Bearer ~A" auth)) h))
                                                            h)
                                                 :content request-body
                                                 :want-stream t
                                                 :connect-timeout 10
                                                 :read-timeout 30
                                                 :keep-alive nil)
                                 (dexador:http-request-failed (c)
                                   (let* ((body-raw (dexador:response-body c))
                                          (body (if (streamp body-raw)
                                                    (alexandria:read-stream-content-into-string body-raw)
                                                    body-raw))
                                          (parsed (ignore-errors (com.inuoe.jzon:parse body)))
                                          (err-msg (and (hash-table-p parsed) (gethash "error" parsed))))
                                     (if (and (stringp err-msg)
                                              (or (search "context_length_exceeded" err-msg)
                                                  (search "context_overflow" err-msg)
                                                  (search "token limit" err-msg)))
                                         (error 'librecode-runner.conditions:context-overflow
                                                :message err-msg
                                                :budget 2000
                                                :requested 2500)
                                         (error 'librecode-runner.conditions:provider-error
                                                :endpoint *provider-url*
                                                :provider current-provider
                                                :message (format nil "HTTP request failed body: ~A (err-msg: ~A)" body err-msg)))))
                                 (error (c)
                                   (error 'librecode-runner.conditions:provider-error
                                          :endpoint *provider-url*
                                          :provider current-provider
                                          :message (format nil "HTTP POST failed: ~A" c))))))
              (declare (ignore steer-promoted))
              (multiple-value-bind (text-content tool-calls)
                  (unwind-protect
                       (let ((text-accum (make-array 0 :element-type 'character :fill-pointer 0 :adjustable t))
                             (tools-accum (make-hash-table :test 'equal)))
                         ;; Spawn Dedicated SSE reader thread
                         (let ((mbox librecode-runner.protocol:*session-mailbox*)
                               (rid (format nil "reader-~A" (random 1000000))))
                           (bt:make-thread
                            (librecode-runner.protocol:with-session-context-captured
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
                                   `(:sse-error ,rid ,c)))))
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
                                         :provider current-provider
                                         :message (format nil "SSE stream error: ~A" (third msg))))
                                 ((eq (car msg) :sse-eof)
                                  (return))
                                 ((eq (car msg) :sse-line)
                                  (process-sse-line-data session-id (third msg) text-accum tools-accum))))))
  
                           (let ((tc-list nil))
                             (maphash (lambda (k v)
                                        (declare (ignore k))
                                        (push v tc-list))
                                      tools-accum)
                             (let ((text-content (coerce text-accum 'string))
                                   (final-tc-list (nreverse tc-list)))
                               (if (null final-tc-list)
                                   (let ((fallback (parse-fallback-tool-call text-content)))
                                     (values text-content fallback))
                                   (values text-content final-tc-list)))))
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
                      (return-from execute-provider-turn t)) ; continuation allowed
                    (return-from execute-provider-turn nil)))))
        (compact-and-retry ()
          :report "Compact session history and retry the provider turn."
          (librecode-runner.compaction:compact-context session))
        (retry-with-backup-provider (&optional (backup-url *backup-provider-url*))
          :report "Retry the provider turn with a backup provider URL."
          (setf current-url backup-url))))))
