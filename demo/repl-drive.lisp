;;; -*- Mode: Lisp; Syntax: Common-Lisp; indent-tabs-mode: nil; coding: utf-8; Show-Trailing-Whitespace: t -*-
;;;
;;; repl-drive.lisp — Native REPL entry for chartering and driving one
;;; campaign end to end
;;;
;;; This is a LIBRARY, not a script: loading it defines functions and does
;;; not run anything. Load it inside a REPL already carrying all three
;;; systems (`just repl` does this) via:
;;;
;;;   (load "demo/repl-drive.lisp")
;;;
;;; A typical interactive session against a real, non-mock provider looks
;;; like this. Set the provider credential env var run-child itself reads
;;; (named in src/runner/child.lisp) before charting a real endpoint:
;;;
;;;   (sb-posix:setenv "<see src/runner/child.lisp for the env var name>" "<real-token>" 1)
;;;   (defparameter *repo* (repl-drive-init-git-sandbox #P"/tmp/repl-drive-demo/repo/"))
;;;   (defparameter *node*
;;;     (librecode-meta.campaign:make-campaign-node
;;;      :id "drive-node"
;;;      :goal "Demonstrate a real, human-driven campaign turn"
;;;      :file-surface '("proof.txt")
;;;      :harness-type 'repl-drive-subprocess-harness
;;;      :boundary (librecode-meta.campaign:make-boundary
;;;                 :may-commit t
;;;                 :file-surface '("proof.txt")
;;;                 :halt-conditions '("stop if proof.txt already exists with different content")
;;;                 :prompt "Write proof.txt containing 'repl-drive-proof' and commit it.")))
;;;   (defparameter *dag*
;;;     (librecode-meta.campaign:make-campaign-dag :nodes (list *node*) :shared-branch "master"))
;;;   (defparameter *campaign*
;;;     (make-instance 'librecode-meta.campaign:campaign
;;;                    :dag *dag*
;;;                    :journal-path #P"/tmp/repl-drive-demo/campaign-journal.lisp-expr"
;;;                    :repository-path *repo*
;;;                    :workspace-dir #P"/tmp/repl-drive-demo/workspace/"
;;;                    :autonomous-p t))
;;;   (repl-drive-run-campaign *campaign*
;;;                            :provider-url "https://api.example.com/v1"
;;;                            :model "some-real-model")
;;;   (librecode-meta.campaign:campaign-node-status *node*)
;;;   (librecode-meta.campaign:replay-journal #P"/tmp/repl-drive-demo/campaign-journal.lisp-expr")
;;;

(in-package :cl-user)

(require :asdf)
(push (truename "./") asdf:*central-registry*)

(handler-bind ((warning #'muffle-warning))
  (asdf:load-system :librecode-runner)
  (asdf:load-system :librecode-meta))

;;; ============================================================================
;;; Sandbox convenience
;;; ============================================================================

(defun repl-drive-init-git-sandbox (repo-path)
  "Git-init a fresh repository at REPO-PATH (creating the directory if
needed) with one seed commit, so a REPL session has a real repository path
to charter a campaign against without hand-typing the same bootstrap
sequence every time. Returns REPO-PATH."
  (let ((repo-path (uiop:ensure-directory-pathname repo-path)))
    (ensure-directories-exist repo-path)
    (uiop:run-program (list "git" "init" "-b" "master") :directory (namestring repo-path))
    (uiop:run-program (list "git" "config" "user.name" "REPL Drive") :directory (namestring repo-path))
    (uiop:run-program (list "git" "config" "user.email" "repl-drive@example.com") :directory (namestring repo-path))
    (let ((seed-file (uiop:merge-pathnames* "README.md" repo-path)))
      (with-open-file (s seed-file :direction :output :if-exists :supersede :if-does-not-exist :create)
        (format s "Sandbox repository for a REPL-driven campaign.~%")))
    (uiop:run-program (list "git" "add" "README.md") :directory (namestring repo-path))
    (uiop:run-program (list "git" "commit" "-m" "chore: seed repl-drive sandbox") :directory (namestring repo-path))
    repo-path))

;;; ============================================================================
;;; Real-reach subprocess harness
;;; ============================================================================
;;;
;;; Mirrors demo/mvp-demo.lisp's real-demo-subprocess-harness and
;;; t/e2e-tests.lisp's e2e-subprocess-harness: a throwaway subprocess-harness
;;; subclass that spawns a genuine librecode-runner.child:run-child process
;;; and delegates to subprocess-harness's generic harness-spawn. The one
;;; difference from both precedents: provider-url/model are read out of the
;;; config plist campaign.lisp's run-node-execution builds (threaded via
;;; *provider-url-override*/*model-override*) rather than resolved from this
;;; file's own environment variables or hardcoded -- this is the seam a REPL
;;; charter session actually drives.

(defclass repl-drive-subprocess-harness (librecode-meta.harness::subprocess-harness)
  ())

(defmethod librecode-meta.harness:harness-spawn ((type (eql 'repl-drive-subprocess-harness)) config)
  (let* ((session-id (getf config :id))
         (workspace-root (getf config :workspace-root))
         (db-path (getf config :db-path))
         (provider-url (getf config :provider-url))
         (model (getf config :model))
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
         ;; The real credential is never interpolated here -- only
         ;; provider-url/model cross this boundary. RUN-CHILD sources its
         ;; own credential env var (named in src/runner/child.lisp) itself,
         ;; from its own inherited process environment, once it is already
         ;; running.
         (command (list "sbcl" "--noinform" "--non-interactive"
                        "--eval" "(require :sb-posix)"
                        "--eval" "(sb-posix:setenv \"CL_SOURCE_REGISTRY\" \"\" 1)"
                        "--eval" "(require :asdf)"
                        "--eval" (format nil "(asdf:initialize-source-registry '~S)" source-registry-sexpr)
                        "--eval" (format nil "(push (truename ~S) asdf:*central-registry*)" (namestring project-root))
                        "--eval" "(asdf:load-system :librecode-runner)"
                        "--eval" (format nil "(librecode-runner.child:run-child :workspace-root ~S :db-path ~S :provider-url ~S :model ~S :session-id ~S)"
                                         (namestring workspace-root)
                                         db-path
                                         provider-url
                                         model
                                         session-id))))
    (librecode-meta.harness:harness-spawn
     'librecode-meta.harness::subprocess-harness
     (list* :command command config))))

(defmethod librecode-meta.harness:harness-prepare-workspace ((class (eql 'repl-drive-subprocess-harness)) repo-path target-dir)
  (librecode-meta.harness:harness-prepare-workspace 'librecode-meta.harness::subprocess-harness repo-path target-dir))

(defmethod librecode-meta.harness:harness-cleanup-workspace ((class (eql 'repl-drive-subprocess-harness)) repo-path target-dir &key force)
  (librecode-meta.harness:harness-cleanup-workspace 'librecode-meta.harness::subprocess-harness repo-path target-dir :force force))

;;; ============================================================================
;;; Dispatch trigger
;;; ============================================================================

(defun repl-drive-run-campaign (campaign &key provider-url model)
  "Run CAMPAIGN via librecode-meta.campaign:run-campaign, with the two
unexported provider-override special variables set to PROVIDER-URL/MODEL
for the duration of the call so a dispatched node's harness-subclass sees
them in its config plist instead of the built-in mock defaults. Passing
neither keyword argument reproduces the existing mock-only behavior
exactly.

This mutates the two special variables' GLOBAL value (via SETF inside
UNWIND-PROTECT) rather than binding them with LET: RUN-CAMPAIGN dispatches
each node's RUN-NODE-EXECUTION on its own worker thread
(EXECUTE-NODE-BATCH's BT:MAKE-THREAD calls), and a thread spawned that way
does not inherit the calling thread's dynamic LET bindings -- only the
global value is visible from inside it. A REPL charter session therefore
drives one campaign at a time through this function; a second concurrent
call from another thread would race the same two globals.

Never accepts or threads a credential -- that reaches the dispatched child
exclusively through its own inherited process environment, via the
credential env var run-child itself reads (named in
src/runner/child.lisp), set by the caller before invoking this function."
  (let ((prior-url librecode-meta.campaign::*provider-url-override*)
        (prior-model librecode-meta.campaign::*model-override*))
    (unwind-protect
         (progn
           (setf librecode-meta.campaign::*provider-url-override* provider-url)
           (setf librecode-meta.campaign::*model-override* model)
           (librecode-meta.campaign:run-campaign campaign))
      (setf librecode-meta.campaign::*provider-url-override* prior-url)
      (setf librecode-meta.campaign::*model-override* prior-model))))
