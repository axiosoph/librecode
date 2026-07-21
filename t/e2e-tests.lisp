;;; -*- Mode: Lisp; Syntax: Common-Lisp; indent-tabs-mode: nil; coding: utf-8; Show-Trailing-Whitespace: t -*-
;;;
;;; e2e-tests.lisp — End-to-end integration and journal resume tests
;;;

(defpackage #:librecode-test.e2e
  (:use #:cl
        #:fiveam)
  (:export #:e2e-suite))

(in-package #:librecode-test.e2e)

(def-suite e2e-suite
  :description "Suite for end-to-end integration tests.")

(in-suite e2e-suite)

(defvar *e2e-mock-port* nil)
(defvar *e2e-source-registry-sexpr* nil)
(defvar *e2e-project-root* nil)

(defun init-e2e-env ()
  (setf *e2e-project-root* (truename "./"))
  (let* ((raw-registry (uiop:getenv "CL_SOURCE_REGISTRY"))
         (paths (and raw-registry (uiop:split-string raw-registry :separator '(#\:))))
         (clean-paths (remove-if (lambda (p) (or (null p) (string= p ""))) paths))
         (directives (mapcar (lambda (p)
                               (if (alexandria:ends-with-subseq "//" p)
                                   (list :tree (subseq p 0 (- (length p) 2)))
                                   (list :directory p)))
                             clean-paths)))
    (setf *e2e-source-registry-sexpr*
          (append (list :source-registry)
                  directives
                  (list :ignore-inherited-configuration)))))

(defun get-free-port ()
  "Find a free port on localhost."
  (let ((socket (usocket:socket-listen "127.0.0.1" 0)))
    (unwind-protect
         (usocket:get-local-port socket)
      (usocket:socket-close socket))))

;; Define the check-e2e-artifact gate
(librecode-meta.gate:defgate check-e2e-artifact (node-id)
  (:target "e2e-artifact.txt")
  (:verify (and (probe-file target)
                (string= "hello e2e" (string-trim '(#\Space #\Tab #\Return #\Newline) (uiop:read-file-string target)))))
  (:on-failure (error 'librecode-runner.conditions:gate-failure
                      :message "E2E verification failed"
                      :command "check-e2e-artifact"
                      :exit-code -1)))

;; Define EQL specialize methods for e2e-subprocess-harness symbol
(defmethod librecode-meta.harness:harness-spawn ((type (eql 'e2e-subprocess-harness)) config)
  (let* ((workspace-root (getf config :workspace-root))
         (id (getf config :id))
         (db-path "librecode-e2e.db")
         (provider-url (format nil "http://127.0.0.1:~A/stream" *e2e-mock-port*))
         (command (list "sbcl" "--noinform" "--non-interactive"
                        "--eval" "(require :sb-posix)"
                        "--eval" "(sb-posix:setenv \"CL_SOURCE_REGISTRY\" \"\" 1)"
                        "--eval" "(require :asdf)"
                        "--eval" (format nil "(asdf:initialize-source-registry '~S)" *e2e-source-registry-sexpr*)
                        "--eval" (format nil "(push (truename ~S) asdf:*central-registry*)" (namestring *e2e-project-root*))
                        "--eval" "(asdf:load-system :librecode-runner)"
                        "--eval" (format nil "(librecode-runner.child:run-child :workspace-root ~S :db-path ~S :provider-url ~S :model ~S :task ~S :session-id ~S)"
                                         (namestring workspace-root) db-path provider-url "mock-model" "mock-task" id)))
         (full-config (list* :command command config)))
    (librecode-meta.harness:harness-spawn 'librecode-meta.harness::subprocess-harness full-config)))

(defmethod librecode-meta.harness:harness-prepare-workspace ((class (eql 'e2e-subprocess-harness)) repo-path target-dir)
  (librecode-meta.harness:harness-prepare-workspace 'librecode-meta.harness::subprocess-harness repo-path target-dir))

(defmethod librecode-meta.harness:harness-cleanup-workspace ((class (eql 'e2e-subprocess-harness)) repo-path target-dir &key force)
  (librecode-meta.harness:harness-cleanup-workspace 'librecode-meta.harness::subprocess-harness repo-path target-dir :force force))

(test test-e2e-gated-artifact
  "A deterministic run-campaign with a real subprocess child + real write_file + mock provider MUST produce a real file change that PASSES the native gate."
  (init-e2e-env)
  (let* ((port (get-free-port))
         (acceptor (make-instance 'hunchentoot:easy-acceptor :port port))
         (request-count 0)
         (dispatcher-lock (bt:make-lock "dispatcher-lock")))
    (let ((dispatcher (lambda (request)
                        (when (and (equal (hunchentoot:script-name request) "/stream/chat/completions")
                                   (= (hunchentoot:acceptor-port (hunchentoot:request-acceptor request)) port))
                          (let ((current-count (bt:with-lock-held (dispatcher-lock)
                                                 (incf request-count))))
                            (lambda ()
                              (setf (hunchentoot:content-type*) "text/event-stream")
                              (let ((stream (hunchentoot:send-headers)))
                                (cond
                                  ((= current-count 1)
                                   ;; First turn: return write_file tool call
                                   (write-sequence
                                    (flexi-streams:string-to-octets
                                     (format nil "data: {\"choices\": [{\"delta\": {\"tool_calls\": [{\"index\": 0, \"id\": \"call-1\", \"function\": {\"name\": \"write_file\", \"arguments\": \"{\\\"path\\\": \\\"e2e-artifact.txt\\\", \\\"content\\\": \\\"hello e2e\\\"}\"}}]}}]}~%")
                                     :external-format :utf-8)
                                    stream))
                                  ((= current-count 2)
                                   ;; Second turn: return git commit tool call
                                   (write-sequence
                                    (flexi-streams:string-to-octets
                                     (format nil "data: {\"choices\": [{\"delta\": {\"tool_calls\": [{\"index\": 0, \"id\": \"call-2\", \"function\": {\"name\": \"bash\", \"arguments\": \"{\\\"command\\\": \\\"git add e2e-artifact.txt && git -c user.name='Test User' -c user.email='test@example.com' commit -m 'add e2e-artifact'\\\"}\"}}]}}]}~%")
                                     :external-format :utf-8)
                                    stream))
                                  (t
                                   ;; Third turn: completion
                                   (write-sequence
                                    (flexi-streams:string-to-octets
                                     (format nil "data: {\"choices\": [{\"delta\": {\"content\": \"Done!\"}}]}~%")
                                     :external-format :utf-8)
                                    stream)))
                                (force-output stream)
                                (write-sequence
                                 (flexi-streams:string-to-octets (format nil "data: [DONE]~%") :external-format :utf-8)
                                 stream)
                                (force-output stream)
                                "")))))))
      (push dispatcher hunchentoot:*dispatch-table*)
      (unwind-protect
           (librecode-test.event-store::with-tmp-sandbox (dir :git t)
             (librecode-test.supervision::setup-test-git-repo dir)
             (hunchentoot:start acceptor)
             (setf *e2e-mock-port* port)
             (let* ((node (librecode-meta.campaign:make-campaign-node
                           :id "node-e2e"
                           :goal "Produce E2E artifact"
                           :file-surface '("e2e-artifact.txt")
                           :harness-type 'e2e-subprocess-harness
                           :boundary (librecode-meta.campaign:make-boundary-from-prompt "ibc-e2e")))
                    (dag (librecode-meta.campaign:make-campaign-dag :nodes (list node) :shared-branch "master"))
                    (journal-file (uiop:merge-pathnames* "campaign-journal.lisp-expr" dir))
                    (workspace-dir (uiop:merge-pathnames* "workspace/" dir))
                    (campaign (make-instance 'librecode-meta.campaign:campaign
                                             :dag dag
                                             :journal-path journal-file
                                             :repository-path dir
                                             :workspace-dir workspace-dir
                                             :autonomous-p t)))
               ;; Run campaign
               (librecode-meta.campaign:run-campaign campaign)
               ;; Verify node status
               (is (eq :accepted (librecode-meta.campaign:campaign-node-status node)))
               ;; Verify artifact exists and check it using the gate
               (let ((librecode-runner.event-store:*workspace-root* dir))
                 (is (eq t (librecode-meta.gate:run-gate 'check-e2e-artifact :node-id "node-e2e"))))))
        (progn
          (hunchentoot:stop acceptor)
          (setf hunchentoot:*dispatch-table* (delete dispatcher hunchentoot:*dispatch-table*)))))))

(test test-e2e-mid-campaign-resume
  "A campaign killed mid-run MUST resume from the journal and complete, producing the same gated artifact."
  (init-e2e-env)
  (let* ((port (get-free-port))
         (acceptor (make-instance 'hunchentoot:easy-acceptor :port port))
         (request-count 0)
         (dispatcher-lock (bt:make-lock "dispatcher-lock")))
    (let ((dispatcher (lambda (request)
                        (when (and (equal (hunchentoot:script-name request) "/stream/chat/completions")
                                   (= (hunchentoot:acceptor-port (hunchentoot:request-acceptor request)) port))
                          (let ((current-count (bt:with-lock-held (dispatcher-lock)
                                                 (incf request-count))))
                            (lambda ()
                              (setf (hunchentoot:content-type*) "text/event-stream")
                              (let ((stream (hunchentoot:send-headers)))
                                (cond
                                  ((= current-count 1)
                                   ;; First turn: return write_file tool call
                                   (write-sequence
                                    (flexi-streams:string-to-octets
                                     (format nil "data: {\"choices\": [{\"delta\": {\"tool_calls\": [{\"index\": 0, \"id\": \"call-1\", \"function\": {\"name\": \"write_file\", \"arguments\": \"{\\\"path\\\": \\\"e2e-artifact.txt\\\", \\\"content\\\": \\\"hello e2e\\\"}\"}}]}}]}~%")
                                     :external-format :utf-8)
                                    stream))
                                  ((= current-count 2)
                                   ;; Second turn: return git commit tool call
                                   (write-sequence
                                    (flexi-streams:string-to-octets
                                     (format nil "data: {\"choices\": [{\"delta\": {\"tool_calls\": [{\"index\": 0, \"id\": \"call-2\", \"function\": {\"name\": \"bash\", \"arguments\": \"{\\\"command\\\": \\\"git add e2e-artifact.txt && git -c user.name='Test User' -c user.email='test@example.com' commit -m 'add e2e-artifact'\\\"}\"}}]}}]}~%")
                                     :external-format :utf-8)
                                    stream))
                                  (t
                                   ;; Third turn: completion
                                   (write-sequence
                                    (flexi-streams:string-to-octets
                                     (format nil "data: {\"choices\": [{\"delta\": {\"content\": \"Done!\"}}]}~%")
                                     :external-format :utf-8)
                                    stream)))
                                (force-output stream)
                                (write-sequence
                                 (flexi-streams:string-to-octets (format nil "data: [DONE]~%") :external-format :utf-8)
                                 stream)
                                (force-output stream)
                                "")))))))
      (push dispatcher hunchentoot:*dispatch-table*)
      (unwind-protect
           (librecode-test.event-store::with-tmp-sandbox (dir :git t)
             (librecode-test.supervision::setup-test-git-repo dir)
             (hunchentoot:start acceptor)
             (setf *e2e-mock-port* port)
             (let* ((node (librecode-meta.campaign:make-campaign-node
                           :id "node-e2e"
                           :goal "Produce E2E artifact"
                           :file-surface '("e2e-artifact.txt")
                           :harness-type 'e2e-subprocess-harness
                           :boundary (librecode-meta.campaign:make-boundary-from-prompt "ibc-e2e")))
                    (dag (librecode-meta.campaign:make-campaign-dag :nodes (list node) :shared-branch "master"))
                    (journal-file (uiop:merge-pathnames* "campaign-journal.lisp-expr" dir))
                    (workspace-dir (uiop:merge-pathnames* "workspace/" dir))
                    (campaign (make-instance 'librecode-meta.campaign:campaign
                                             :dag dag
                                             :journal-path journal-file
                                             :repository-path dir
                                             :workspace-dir workspace-dir
                                             :autonomous-p t)))
               
               ;; 1. Start campaign in separate thread
               (let ((campaign-thread
                       (bt:make-thread (lambda () (librecode-meta.campaign:run-campaign campaign))
                                       :name "e2e-campaign-thread")))
                 
                 ;; 2. Poll journal file until node-dispatched is written (case-insensitive search)
                 (let ((start-time (get-universal-time))
                       (timeout 10.0)
                       (dispatched nil))
                   (loop
                     (when (and (probe-file journal-file)
                                (search "NODE-DISPATCHED" (uiop:read-file-string journal-file) :test #'char-equal))
                       (setf dispatched t)
                       (return))
                     (when (>= (- (get-universal-time) start-time) timeout)
                       (return))
                     (sleep 0.05))
                   (is-true dispatched)
                   
                   ;; 3. Kill/destroy the campaign thread
                   (bt:destroy-thread campaign-thread))
                 
                 ;; Wait for thread exit and cleanup
                 (sleep 0.5)
                 
                 ;; Reset request-count for the resumed child run
                 (bt:with-lock-held (dispatcher-lock)
                   (setf request-count 0))
                 
                 ;; 4. Run the campaign again on the same journal
                 (let* ((node-new (librecode-meta.campaign:make-campaign-node
                                   :id "node-e2e"
                                   :goal "Produce E2E artifact"
                                   :file-surface '("e2e-artifact.txt")
                                   :harness-type 'e2e-subprocess-harness
                                   :boundary (librecode-meta.campaign:make-boundary-from-prompt "ibc-e2e")))
                        (dag-new (librecode-meta.campaign:make-campaign-dag :nodes (list node-new) :shared-branch "master"))
                        (campaign-new (make-instance 'librecode-meta.campaign:campaign
                                                     :dag dag-new
                                                     :journal-path journal-file
                                                     :repository-path dir
                                                     :workspace-dir workspace-dir
                                                     :autonomous-p t)))
                   
                   (librecode-meta.campaign:run-campaign campaign-new)
                   
                   ;; Verify node status
                   (is (eq :accepted (librecode-meta.campaign:campaign-node-status node-new)))
                   
                   ;; Verify artifact exists and check it using the gate
                   (let ((librecode-runner.event-store:*workspace-root* dir))
                     (is (eq t (librecode-meta.gate:run-gate 'check-e2e-artifact :node-id "node-e2e"))))))))
        (progn
          (hunchentoot:stop acceptor)
          (setf hunchentoot:*dispatch-table* (delete dispatcher hunchentoot:*dispatch-table*)))))))

;;; --- Scenario floor: read/write -> fail -> correct -> succeed, through a
;;; REAL subprocess child and through a kill/resume cycle ---
;;;
;;; The two tests below extend the harness scaffolding above (not the two
;;; existing tests themselves) with the campaign's capstone arc: the child's
;;; own outbound HTTP request to this mock IS the external vantage point that
;;; makes the intermediate "failure handed back as an ordinary tool result"
;;; step observable from the test process -- the child never sees anything
;;; but its own tool-result turn, but the request body it sends for its NEXT
;;; turn carries that tool-result in its message history, and this process's
;;; mock server is what receives it. See t/scenario-tests.lisp for the
;;; in-process variant of the same arc (premises p7-*, IBC P7).

(defun make-decision-tracker ()
  "Return (values RECORD-FN SNAPSHOT-FN): a thread-safe accumulator of keyword
tags in call order, for asserting which branch of a scripted responder fired
and in what sequence. Needed because a subprocess child's HTTP requests are
served on Hunchentoot's own worker threads, not the thread driving the
campaign."
  (let ((decisions nil)
        (lock (bt:make-lock "scenario-decisions-lock")))
    (values (lambda (tag) (bt:with-lock-held (lock) (push tag decisions)))
            (lambda () (bt:with-lock-held (lock) (reverse decisions))))))

(defun make-scenario-responder (record-decision)
  "Build a dispatcher scripting write_file(e2e-artifact.txt) -> a bash command
that FAILS -> a different, corrective bash command that succeeds ->
completion, branching on the inbound request's tool-role message HISTORY
rather than a raw call count (premise
p7-mock-provider-can-branch-on-tool-result-history). Branching on history
rather than a counter is also what makes this script resilient across a
kill/resume cycle with no counter to reset: a resumed child's next request
carries whatever history actually survived the kill, and the responder picks
up from exactly there. RECORD-DECISION is called with a keyword tag (:write
:bash-fail :bash-correct :done) each time a branch fires.

The fail->correct pair is a realistic \"forgot to git add\" mistake: the
first bash attempt commits straight away and fails (nothing staged yet); the
correction adds the file first, then commits, and succeeds. This preserves
test-e2e-gated-artifact's existing precedent that a node's file-surface
changes must be committed inside the child's own turn sequence to be merged
back into the shared branch and become visible to the native gate at the
outer repository root -- the fail/correct step is inserted around that
requirement, not in place of it."
  (lambda (request call-index)
    (declare (ignore call-index))
    (let* ((body (com.inuoe.jzon:parse (hunchentoot:raw-post-data :force-text t :request request)))
           (tool-msgs (librecode-test.mock-provider:tool-role-messages body))
           (n (length tool-msgs))
           (last-content (and tool-msgs (gethash "content" (car (last tool-msgs))))))
      (cond
        ((= n 0)
         (funcall record-decision :write)
         (list (list :tool-calls
                     (list (list :id "call-1" :name "write_file"
                                 :arguments "{\"path\": \"e2e-artifact.txt\", \"content\": \"hello e2e\"}")))))
        ((= n 1)
         (funcall record-decision :bash-fail)
         (list (list :tool-calls
                     (list (list :id "call-2" :name "bash"
                                 :arguments "{\"command\": \"git -c user.name='Test User' -c user.email='test@example.com' commit -m 'add e2e-artifact'\"}")))))
        ((and (= n 2) (stringp last-content) (search "Error:" last-content))
         (funcall record-decision :bash-correct)
         (list (list :tool-calls
                     (list (list :id "call-3" :name "bash"
                                 :arguments "{\"command\": \"git add e2e-artifact.txt && git -c user.name='Test User' -c user.email='test@example.com' commit -m 'add e2e-artifact'\"}")))))
        (t
         (funcall record-decision :done)
         (list (list :content "Done!")))))))

(test test-e2e-scenario-fail-correct
  "Constraint [c7-subprocess-variant]: a REAL subprocess child (not mocked at
the tool level) writes an artifact, runs a bash command that FAILS, is handed
that failure as an ordinary tool result on its NEXT turn (never a crashed
child process -- premise p7-bash-failure-becomes-tool-error), and only then
issues a different, corrective bash command that succeeds -- verified via the
existing native check-e2e-artifact gate, with the fail->correct sequence
itself grounded by this mock's own observation of the request-body history
that drove it (premise p7-subprocess-harness-precedent-exists)."
  (init-e2e-env)
  (multiple-value-bind (record-decision get-decisions) (make-decision-tracker)
    (librecode-test.mock-provider:with-mock-provider
        (port :path "/stream/chat/completions"
              :responder (make-scenario-responder record-decision))
      (setf *e2e-mock-port* port)
      (librecode-test.event-store::with-tmp-sandbox (dir :git t)
        (librecode-test.supervision::setup-test-git-repo dir)
        (let* ((node (librecode-meta.campaign:make-campaign-node
                      :id "node-scenario"
                      :goal "Produce E2E artifact via a fail-then-correct bash step"
                      :file-surface '("e2e-artifact.txt")
                      :harness-type 'e2e-subprocess-harness
                      :boundary (librecode-meta.campaign:make-boundary-from-prompt "ibc-e2e-scenario")))
               (dag (librecode-meta.campaign:make-campaign-dag :nodes (list node) :shared-branch "master"))
               (journal-file (uiop:merge-pathnames* "campaign-journal.lisp-expr" dir))
               (workspace-dir (uiop:merge-pathnames* "workspace/" dir))
               (campaign (make-instance 'librecode-meta.campaign:campaign
                                        :dag dag
                                        :journal-path journal-file
                                        :repository-path dir
                                        :workspace-dir workspace-dir
                                        :autonomous-p t)))
          (librecode-meta.campaign:run-campaign campaign)
          (is (eq :accepted (librecode-meta.campaign:campaign-node-status node)))
          (let ((librecode-runner.event-store:*workspace-root* dir))
            (is (eq t (librecode-meta.gate:run-gate 'check-e2e-artifact :node-id "node-scenario"))))
          ;; Exactly once each, in order -- no kill/resume race in this variant.
          (is (equal '(:write :bash-fail :bash-correct :done) (funcall get-decisions))))))))

(test test-e2e-scenario-kill-resume-fail-correct
  "Constraint [c7-kill-resume-variant]: a campaign running the same
write->fail->correct->succeed arc as TEST-E2E-SCENARIO-FAIL-CORRECT is killed
mid-run (same timing precedent as test-e2e-mid-campaign-resume: any point
after NODE-DISPATCHED is sufficient, per this IBC's resolved decision) and
resumed from the journal with a fresh campaign instance; the final artifact
must still be correct after resume. Because the responder branches on message
HISTORY rather than a raw call counter, no counter needs resetting across the
kill -- whatever the killed attempt's HTTP requests actually reached is
exactly what the resumed child's own history-driven request will reflect, so
the resumed run picks the arc back up (or restarts it) correctly either way.
Decision-order assertions here tolerate the fact that a hunchentoot worker
thread already streaming a response when the campaign-driving thread is
destroyed is not itself killed -- so a branch already in flight at the kill
may still get recorded -- without weakening what's actually being proven:
that a bash failure and its correction both occurred, in the right relative
order, and the run still lands correctly after resume."
  (init-e2e-env)
  (multiple-value-bind (record-decision get-decisions) (make-decision-tracker)
    (librecode-test.mock-provider:with-mock-provider
        (port :path "/stream/chat/completions"
              :responder (make-scenario-responder record-decision))
      (setf *e2e-mock-port* port)
      (librecode-test.event-store::with-tmp-sandbox (dir :git t)
        (librecode-test.supervision::setup-test-git-repo dir)
        (let* ((node (librecode-meta.campaign:make-campaign-node
                      :id "node-scenario-kr"
                      :goal "Produce E2E artifact via a fail-then-correct bash step"
                      :file-surface '("e2e-artifact.txt")
                      :harness-type 'e2e-subprocess-harness
                      :boundary (librecode-meta.campaign:make-boundary-from-prompt "ibc-e2e-scenario-kr")))
               (dag (librecode-meta.campaign:make-campaign-dag :nodes (list node) :shared-branch "master"))
               (journal-file (uiop:merge-pathnames* "campaign-journal.lisp-expr" dir))
               (workspace-dir (uiop:merge-pathnames* "workspace/" dir))
               (campaign (make-instance 'librecode-meta.campaign:campaign
                                        :dag dag
                                        :journal-path journal-file
                                        :repository-path dir
                                        :workspace-dir workspace-dir
                                        :autonomous-p t)))

          ;; 1. Start campaign in a separate thread.
          (let ((campaign-thread
                  (bt:make-thread (lambda () (librecode-meta.campaign:run-campaign campaign))
                                   :name "e2e-scenario-campaign-thread")))

            ;; 2. Poll the journal until NODE-DISPATCHED appears.
            (let ((start-time (get-universal-time))
                  (timeout 10.0)
                  (dispatched nil))
              (loop
                (when (and (probe-file journal-file)
                           (search "NODE-DISPATCHED" (uiop:read-file-string journal-file) :test #'char-equal))
                  (setf dispatched t)
                  (return))
                (when (>= (- (get-universal-time) start-time) timeout)
                  (return))
                (sleep 0.05))
              (is-true dispatched)

              ;; 3. Hard-kill the campaign-driving thread.
              (bt:destroy-thread campaign-thread))

            ;; Wait for thread exit and cleanup.
            (sleep 0.5)

            ;; 4. Run the campaign again on the same journal -- no counter to
            ;; reset: the responder reads whatever message history the
            ;; resumed child's own request actually carries.
            (let* ((node-new (librecode-meta.campaign:make-campaign-node
                              :id "node-scenario-kr"
                              :goal "Produce E2E artifact via a fail-then-correct bash step"
                              :file-surface '("e2e-artifact.txt")
                              :harness-type 'e2e-subprocess-harness
                              :boundary (librecode-meta.campaign:make-boundary-from-prompt "ibc-e2e-scenario-kr")))
                   (dag-new (librecode-meta.campaign:make-campaign-dag :nodes (list node-new) :shared-branch "master"))
                   (campaign-new (make-instance 'librecode-meta.campaign:campaign
                                                :dag dag-new
                                                :journal-path journal-file
                                                :repository-path dir
                                                :workspace-dir workspace-dir
                                                :autonomous-p t)))

              (librecode-meta.campaign:run-campaign campaign-new)

              (is (eq :accepted (librecode-meta.campaign:campaign-node-status node-new)))

              (let ((librecode-runner.event-store:*workspace-root* dir))
                (is (eq t (librecode-meta.gate:run-gate 'check-e2e-artifact :node-id "node-scenario-kr"))))

              ;; A failure occurred and was corrected, in that relative
              ;; order, and the run terminated -- tolerant of a possible
              ;; duplicate decision from an in-flight response thread that
              ;; outlived the destroyed campaign-thread (see docstring).
              (let ((decisions (funcall get-decisions)))
                (is-true (member :bash-fail decisions))
                (is-true (member :bash-correct decisions))
                (is (< (position :bash-fail decisions) (position :bash-correct decisions :from-end t)))
                (is (eq :done (car (last decisions))))))))))))
