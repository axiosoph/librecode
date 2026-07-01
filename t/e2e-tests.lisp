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
                           :ibc "ibc-e2e"))
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
                           :ibc "ibc-e2e"))
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
                                   :ibc "ibc-e2e"))
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
