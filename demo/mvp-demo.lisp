;;; -*- Mode: Lisp; Syntax: Common-Lisp; indent-tabs-mode: nil; coding: utf-8; Show-Trailing-Whitespace: t -*-
;;;
;;; mvp-demo.lisp — MVP vertical integration campaign demo using local Ollama
;;;

(in-package :cl-user)

(require :asdf)
(push (truename "./") asdf:*central-registry*)

(format t "~&[INFO] Loading librecode systems...~%")
(handler-bind ((warning #'muffle-warning))
  (asdf:load-system :librecode-runner)
  (asdf:load-system :librecode-meta))

;;; ============================================================================
;;; Prerequisites Check
;;; ============================================================================

(defun check-ollama-prerequisites (base-url model)
  (format t "~&[INFO] Checking Ollama prerequisites at ~A for model '~A'...~%" base-url model)
  (handler-case
      (let* ((models-url (format nil "~A/models" base-url))
             (response (dexador:get models-url :connect-timeout 3 :read-timeout 3))
             (parsed (com.inuoe.jzon:parse response))
             (found nil))
        (when (and (hash-table-p parsed) (gethash "data" parsed))
          (loop for m across (gethash "data" parsed)
                do (when (or (string-equal (gethash "id" m) model)
                             (string-equal (gethash "id" m) (format nil "~A:latest" model)))
                     (setf found t))))
        (unless found
          ;; Try fallback /api/tags in case /v1/models query doesn't list the exact tag
          (handler-case
              (let* ((base (string-right-trim "/v1" base-url))
                     (native-url (format nil "~A/api/tags" base))
                     (native-resp (dexador:get native-url :connect-timeout 2))
                     (native-parsed (com.inuoe.jzon:parse native-resp)))
                (when (and (hash-table-p native-parsed) (gethash "models" native-parsed))
                  (loop for m across (gethash "models" native-parsed)
                        do (when (or (string-equal (gethash "name" m) model)
                                     (string-equal (gethash "name" m) (format nil "~A:latest" model)))
                             (setf found t)))))
            (error () nil)))
        (if found
            (format t "[INFO] Ollama check passed. Model '~A' is available.~%" model)
            (progn
              (format t "~%[ERROR] Model '~A' is not pulled in Ollama.~%" model)
              (format t "Prerequisite: Please pull the model using the following command:~%")
              (format t "  ollama pull ~A~%~%" model)
              (uiop:quit 1))))
    (error (c)
      ;; Try fallback /api/tags direct connection check
      (handler-case
          (let* ((base (string-right-trim "/v1" base-url))
                 (native-url (format nil "~A/api/tags" base))
                 (response (dexador:get native-url :connect-timeout 2))
                 (parsed (com.inuoe.jzon:parse response))
                 (found nil))
            (when (and (hash-table-p parsed) (gethash "models" parsed))
              (loop for m across (gethash "models" parsed)
                    do (when (or (string-equal (gethash "name" m) model)
                                 (string-equal (gethash "name" m) (format nil "~A:latest" model)))
                         (setf found t))))
            (if found
                (format t "[INFO] Ollama check passed (fallback API). Model '~A' is available.~%" model)
                (progn
                  (format t "~%[ERROR] Model '~A' is not pulled in Ollama.~%" model)
                  (format t "Prerequisite: Please pull the model using the following command:~%")
                  (format t "  ollama pull ~A~%~%" model)
                  (uiop:quit 1))))
        (error ()
          (format t "~%[ERROR] Could not connect to Ollama at ~A: ~A~%" base-url c)
          (format t "Prerequisite: Please make sure Ollama is installed and running.~%")
          (format t "Download Ollama from: https://ollama.com~%~%")
          (uiop:quit 1))))))

;;; ============================================================================
;;; Custom Subprocess Harness Type
;;; ============================================================================

(defclass real-demo-subprocess-harness (librecode-meta.harness::subprocess-harness)
  ())

(defmethod librecode-meta.harness:harness-spawn ((type (eql 'real-demo-subprocess-harness)) config)
  (let* ((session-id (getf config :id))
         (workspace-root (getf config :workspace-root))
         (db-path (getf config :db-path))
         (project-root (truename "./"))
         (raw-registry (uiop:getenv "CL_SOURCE_REGISTRY"))
         (paths (and raw-registry (uiop:split-string raw-registry :separator '(#\:))))
         (clean-paths (remove-if (lambda (p) (or (null p) (string= p ""))) paths))
         (directives (mapcar (lambda (p)
                               (if (alexandria:ends-with-subseq "//" p)
                                   (list :tree (subseq p 0 (- (length p) 2)))
                                   (list :directory p)))
                             clean-paths))
         (source-registry-sexpr (append (list :source-registry)
                                        directives
                                        (list :ignore-inherited-configuration)))
         (ollama-base-url (or (uiop:getenv "OLLAMA_BASE_URL") "http://localhost:11434/v1"))
         (ollama-model (or (uiop:getenv "OLLAMA_MODEL") "qwen2.5-coder:3b"))
         ;; Build the command to run standard sbcl loading the system and running child runner.
         (command (list "sbcl" "--noinform" "--non-interactive"
                        "--eval" "(require :sb-posix)"
                        "--eval" "(sb-posix:setenv \"CL_SOURCE_REGISTRY\" \"\" 1)"
                        "--eval" "(require :asdf)"
                        "--eval" (format nil "(asdf:initialize-source-registry '~S)" source-registry-sexpr)
                        "--eval" (format nil "(push (truename ~S) asdf:*central-registry*)" (namestring project-root))
                        "--eval" "(asdf:load-system :librecode-runner)"
                        "--eval" (format nil "(librecode-runner.child:run-child :workspace-root ~S :db-path ~S :provider-url ~S :model ~S :session-id ~S :max-steps 2)"
                                         (namestring workspace-root)
                                         db-path
                                         ollama-base-url
                                         ollama-model
                                         session-id))))
    (librecode-meta.harness:harness-spawn
     'librecode-meta.harness::subprocess-harness
     (list* :command command config))))

(defmethod librecode-meta.harness:harness-prepare-workspace ((class (eql 'real-demo-subprocess-harness)) repo-path target-dir)
  (librecode-meta.harness:harness-prepare-workspace 'librecode-meta.harness::subprocess-harness repo-path target-dir))

(defmethod librecode-meta.harness:harness-cleanup-workspace ((class (eql 'real-demo-subprocess-harness)) repo-path target-dir &key force)
  (librecode-meta.harness:harness-cleanup-workspace 'librecode-meta.harness::subprocess-harness repo-path target-dir :force force))

;;; ============================================================================
;;; Main Demo Driver
;;; ============================================================================

(defun run-demo ()
  (let* ((ollama-base-url (or (uiop:getenv "OLLAMA_BASE_URL") "http://localhost:11434/v1"))
         (ollama-model (or (uiop:getenv "OLLAMA_MODEL") "qwen2.5-coder:3b")))
    
    ;; 1. Check prerequisites
    (check-ollama-prerequisites ollama-base-url ollama-model)
    
    ;; 2. Initialize sandboxed paths
    (let* ((workspace-root (truename "./"))
           (demo-sandbox-name (format nil "demo-sandbox-~A-~A/" (get-universal-time) (random 1000)))
           (demo-sandbox (uiop:merge-pathnames* demo-sandbox-name workspace-root))
           (repo-dir (uiop:merge-pathnames* "repo/" demo-sandbox))
           (workspace-dir (uiop:merge-pathnames* "workspace/" demo-sandbox))
           (journal-file (uiop:merge-pathnames* "campaign-journal.lisp-expr" demo-sandbox)))
      
      (format t "~&[INFO] Initializing sandboxed demo repository at ~A...~%" (namestring repo-dir))
      ;; Clean up sandbox
      (uiop:delete-directory-tree demo-sandbox :validate (constantly t) :if-does-not-exist :ignore)
      (ensure-directories-exist repo-dir)
      (ensure-directories-exist workspace-dir)
      
      ;; Git init and setup config
      (uiop:run-program '("git" "init" "-b" "master") :directory (namestring repo-dir))
      (uiop:run-program '("git" "config" "user.name" "Demo User") :directory (namestring repo-dir))
      (uiop:run-program '("git" "config" "user.email" "demo@example.com") :directory (namestring repo-dir))
      
      ;; Make initial commit
      (let ((dummy-file (uiop:merge-pathnames* "dummy.txt" repo-dir)))
        (with-open-file (s dummy-file :direction :output :if-exists :supersede :if-does-not-exist :create)
          (format s "Initial commit~%"))
        (uiop:run-program '("git" "add" "dummy.txt") :directory (namestring repo-dir))
        (uiop:run-program '("git" "commit" "-m" "initial commit") :directory (namestring repo-dir)))
      
      ;; 3. Build and execute campaign
      (format t "[INFO] Creating and starting the multi-agent campaign...~%")
      (let* ((goal-instructions
               "You must use the bash tool to run the following command exactly:
echo 'antigravity-proof' > proof.txt && git add proof.txt && git commit -m 'feat: add gated artifact'

Do not use write_file or any other tool. Stop immediately when done.")
             (node (librecode-meta.campaign:make-campaign-node
                    :id "demo-node"
                    :goal "Write proof.txt and commit it to git"
                    :file-surface '("proof.txt")
                    :harness-type 'real-demo-subprocess-harness
                    :ibc goal-instructions))
             (dag (librecode-meta.campaign:make-campaign-dag :nodes (list node) :shared-branch "master"))
             (campaign (make-instance 'librecode-meta.campaign:campaign
                                      :dag dag
                                      :journal-path journal-file
                                      :repository-path repo-dir
                                      :workspace-dir workspace-dir
                                      :autonomous-p t)))
        
        ;; Run campaign
        (librecode-meta.campaign:run-campaign campaign)
        
        ;; 4. Define and run verification gate
        (format t "~&[INFO] Running campaign verification gate...~%")
        (librecode-meta.gate:defgate verify-demo-artifact (node-id)
          (:target "proof.txt")
          (:verify (let ((path target))
                     (declare (ignore node-id))
                     (and (probe-file path)
                          (let ((content (uiop:read-file-string path)))
                            (search "proof" content :test #'char-equal)))))
          (:on-failure (error 'librecode-runner.conditions:gate-failure
                              :message "Gated artifact verification failed: proof.txt not found or invalid content"
                              :command "verify-demo-artifact"
                              :exit-code -1)))
        
        (handler-case
            (let ((librecode-runner.event-store:*workspace-root* repo-dir))
              (librecode-meta.gate:run-gate 'verify-demo-artifact :node-id "demo-node")
              (format t "~&==================================================~%")
              (format t "SUCCESS: Campaign verification gate passed!~%")
              (format t "Artifact 'proof.txt' was successfully created and verified.~%")
              (format t "==================================================~%~%")
              (uiop:delete-directory-tree demo-sandbox :validate (constantly t) :if-does-not-exist :ignore))
          (librecode-runner.conditions:gate-failure (c)
            (format t "~&[ERROR] Verification gate failed:~%")
            (format t "  ~A~%~%" (librecode-runner.conditions:gate-failure-message c))
            (uiop:quit 1))
          (error (c)
            (format t "~&[ERROR] Verification error: ~A~%~%" c)
            (uiop:quit 1)))
        
        (uiop:quit 0)))))

(run-demo)
