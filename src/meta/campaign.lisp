;;; -*- Mode: Lisp; Syntax: Common-Lisp; indent-tabs-mode: nil; coding: utf-8; Show-Trailing-Whitespace: t -*-
;;;
;;; campaign.lisp — Campaign scheduler and DAG execution
;;;

(in-package #:librecode-meta.campaign)

;;; ============================================================================
;;; campaign-node and campaign-dag structs
;;; ============================================================================

(defstruct boundary
  "Structured dispatch-boundary grant -- mirrors contracts/ibc-boundary.ncl
field-for-field. The one representation of a node's dispatch-time
authorization; distinct from REWORK-DIAGNOSTIC below, which is an
ephemeral, failure-triggered artifact, not a second boundary."
  (may-commit nil :type boolean)       ; Whether this dispatch grants commit authorization
  (file-surface nil :type list)        ; Paths/globs this dispatch is authorized to modify
  (halt-conditions nil :type list)     ; Conditions under which the dispatch must halt and report
  (prompt nil :type (or null string))) ; The base instructions the harness reads at dispatch

(defun make-boundary-from-prompt (prompt)
  "Convenience constructor for call sites that only care about the prompt
text; the other three fields default inert/empty (never production-shaped),
so a test stub is never mistaken for a real dispatch grant."
  (make-boundary :prompt prompt :may-commit nil :file-surface nil :halt-conditions nil))

(defstruct campaign-node
  "Represents an execution unit within a campaign DAG."
  (id nil :type (or null string))
  (goal nil :type (or null string))
  (file-surface nil :type list)        ; Paths (files or directories) this node is authorized to touch
  (dependencies nil :type list)        ; List of parent node IDs
  (sequential-p nil :type boolean)     ; Must run sequentially, cannot be parallelized
  (status :pending :type keyword)      ; :pending, :dispatched, :landed, :accepted, :rework, :skipped
  (phase 0 :type (integer 0))          ; librecode-model deposit phase, threaded from the journal fold
  (deposit nil)                        ; librecode-model deposit struct (or nil, never landed), threaded from the fold
  (harness-type nil :type symbol)      ; Class name of harness (e.g., 'harness-opencode)
  (harness-instance nil)               ; Reference to the active CLOS harness-instance
  (boundary nil :type (or null boundary))          ; Structured dispatch-boundary grant (contracts/ibc-boundary.ncl)
  (rework-diagnostic nil :type (or null string)))  ; Formatted failure-trace text from a prior rework, decomplected from BOUNDARY

(defun campaign-node-effective-prompt (node)
  "Compose the dispatch prompt for NODE: the boundary's prompt (or the
node's goal, if no boundary is set), augmented with any rework-diagnostic
from a prior in-process failure -- the walker keeps its full original
authorization/instructions on retry, now augmented with failure context
instead of losing them to it."
  (let ((base (if (campaign-node-boundary node)
                   (boundary-prompt (campaign-node-boundary node))
                   (campaign-node-goal node)))
        (diagnostic (campaign-node-rework-diagnostic node)))
    (if diagnostic
        (format nil "~A~%~%~A" base diagnostic)
        base)))

(defstruct (campaign-dag
            (:constructor %make-campaign-dag))
  "Represents the Campaign DAG task graph."
  (nodes nil :type list)               ; List of campaign-nodes
  (layers nil :type vector)            ; Array of layers derived via Kahn's algorithm
  (shared-branch nil :type string))    ; Git integration branch for the campaign

(defun make-campaign-dag (&rest args &key nodes layers shared-branch)
  "Constructor for campaign-dag. Computes Kahn layers if not explicitly provided."
  (declare (ignore shared-branch))
  (let ((computed-layers (or layers
                             (and nodes (compute-kahn-layers nodes))
                             (make-array 0))))
    (apply #'%make-campaign-dag :layers computed-layers args)))

;;; ============================================================================
;;; Kahn's Algorithm Layering Scheduler
;;; ============================================================================

(defun compute-kahn-layers (nodes)
  "Derives a vector of topological layers from NODES list using Kahn's algorithm.
Signals a protocol-invariant-violation error if a dependency cycle is detected
or if any dependency is unresolved."
  (let* ((node-ids (mapcar #'campaign-node-id nodes))
         (in-degrees (make-hash-table :test 'equal))
         (adj (make-hash-table :test 'equal))
         (layers (make-array 0 :adjustable t :fill-pointer 0))
         (processed-count 0))
    ;; Validate that all dependency IDs are present in nodes
    (dolist (n nodes)
      (let ((id (campaign-node-id n))
            (deps (campaign-node-dependencies n)))
        (dolist (dep deps)
          (unless (member dep node-ids :test #'string=)
            (error 'librecode-runner.conditions:protocol-invariant-violation
                   :invariant "dependency-resolution"
                   :message (format nil "Node ~S depends on unresolved node ~S" id dep))))))

    ;; Initialize in-degrees and adjacency lists
    (dolist (n nodes)
      (let ((id (campaign-node-id n))
            (deps (campaign-node-dependencies n)))
        (setf (gethash id in-degrees) 0)
        (dolist (dep deps)
          (when (member dep node-ids :test #'string=)
            (incf (gethash id in-degrees))
            (push id (gethash dep adj))))))

    ;; Kahn's algorithm layering loop
    (loop
      (let ((zero-in-degree-layer nil))
        ;; Find all nodes with 0 in-degree in the remaining graph
        (maphash (lambda (id deg)
                   (when (= deg 0)
                     (push id zero-in-degree-layer)))
                 in-degrees)
        ;; Sort the layer deterministically by ID using string<
        (setf zero-in-degree-layer (sort zero-in-degree-layer #'string<))
        ;; If no nodes have 0 in-degree but we haven't processed all nodes, there is a cycle!
        (when (null zero-in-degree-layer)
          (if (< processed-count (length nodes))
              (error 'librecode-runner.conditions:protocol-invariant-violation
                     :invariant "cyclic-dependency"
                     :message "Cycle detected in campaign DAG. Cannot compute Kahn layers.")
              (return)))
        ;; Remove zero-in-degree nodes from our degrees tracker so they aren't selected again
        (dolist (id zero-in-degree-layer)
          (remhash id in-degrees))
        ;; Add layer to layers vector
        (vector-push-extend zero-in-degree-layer layers)
        (incf processed-count (length zero-in-degree-layer))
        ;; Update dependencies (decrement child in-degrees)
        (dolist (parent zero-in-degree-layer)
          (dolist (child (gethash parent adj))
            (when (gethash child in-degrees)
              (decf (gethash child in-degrees)))))))
    ;; Return the layers as a simple vector
    (coerce layers 'simple-vector)))

;;; ============================================================================
;;; campaign class and supervisor implementation
;;; ============================================================================

(define-condition escalation-required (error)
  ((campaign :initarg :campaign :reader escalation-required-campaign)
   (node :initarg :node :reader escalation-required-node)
   (failure-descriptor :initarg :failure-descriptor :reader escalation-required-failure-descriptor)
   (reply-mailbox :initarg :reply-mailbox :reader escalation-required-reply-mailbox))
  (:report (lambda (condition stream)
             (format stream "Campaign escalation required for node ~A due to failure: ~A"
                     (campaign-node-id (escalation-required-node condition))
                     (librecode-runner.protocol:failure-descriptor-message (escalation-required-failure-descriptor condition))))))

(defclass campaign ()
  ((dag :initarg :dag :accessor campaign-dag :type campaign-dag)
   (journal-path :initarg :journal-path :accessor campaign-journal-path :type (or string pathname))
   (repository-path :initarg :repository-path :accessor campaign-repository-path :type (or string pathname))
   (workspace-dir :initarg :workspace-dir :accessor campaign-workspace-dir :type (or string pathname))
   (active-harnesses :initform (make-hash-table :test 'equal) :accessor campaign-active-harnesses :type hash-table)
   (active-harnesses-lock :initform (bt:make-lock "active-harnesses-lock") :reader campaign-active-harnesses-lock)
   (journal-lock :initform (bt:make-lock "journal-lock") :reader campaign-journal-lock)
   (git-lock :initform (bt:make-lock "git-lock") :reader campaign-git-lock)
   (supervisor-mailbox :initarg :supervisor-mailbox :accessor campaign-supervisor-mailbox)
   (reply-mailbox :initarg :reply-mailbox :accessor campaign-reply-mailbox)
   (failure-counts :initform (make-hash-table :test 'equal) :accessor campaign-failure-counts)
   (escalation-hook :initarg :escalation-hook :initform nil :accessor campaign-escalation-hook)
   (max-retries :initarg :max-retries :initform 4 :accessor campaign-max-retries)
   (autonomous-p :initarg :autonomous-p :initform nil :accessor campaign-autonomous-p)
   (autonomous-supervisor-thread :initform nil :accessor campaign-autonomous-supervisor-thread)))

(defmethod initialize-instance :after ((self campaign) &key &allow-other-keys)
  (unless (slot-boundp self 'supervisor-mailbox)
    (setf (campaign-supervisor-mailbox self) (librecode-runner.protocol:make-mailbox :name "campaign-supervisor")))
  (unless (slot-boundp self 'reply-mailbox)
    (setf (campaign-reply-mailbox self) (librecode-runner.protocol:make-mailbox :name "campaign-reply"))))

(defun git-repo-p (repo-path)
  (and repo-path
       (or (uiop:directory-exists-p (uiop:merge-pathnames* ".git/" repo-path))
           (uiop:file-exists-p (uiop:merge-pathnames* ".git" repo-path)))))

(defun run-git-command (repo-path args)
  (let ((cmd-list (append (list "env"
                                "GIT_AUTHOR_NAME=Test User"
                                "GIT_AUTHOR_EMAIL=test@example.com"
                                "GIT_COMMITTER_NAME=Test User"
                                "GIT_COMMITTER_EMAIL=test@example.com"
                                "git")
                          (mapcar #'string args))))
    (multiple-value-bind (stdout stderr exit-code)
        (librecode-meta.gate::run-program-capture cmd-list :directory repo-path)
      (unless (= exit-code 0)
        (error "Git command ~S failed in ~A with exit code ~A: ~A" cmd-list repo-path exit-code stderr))
      (values stdout stderr))))

(defun git-branch-exists-p (repo-path branch-name)
  (handler-case
      (progn
        (run-git-command repo-path (list "show-ref" "--verify" (format nil "refs/heads/~A" branch-name)))
        t)
    (error () nil)))

(defun get-node-worktree-dir (campaign node)
  (uiop:merge-pathnames* (format nil "worktrees/~A/" (campaign-node-id node))
                         (uiop:ensure-directory-pathname (campaign-workspace-dir campaign))))

(defun prepare-node-worktree (campaign node worktree-dir)
  (let* ((repo-path (campaign-repository-path campaign))
         (shared-branch (campaign-dag-shared-branch (campaign-dag campaign)))
         (node-id (campaign-node-id node))
         (node-branch (format nil "campaign-node-~A" node-id)))
    (when (git-repo-p repo-path)
      (bt:with-lock-held ((campaign-git-lock campaign))
        ;; Clean up any stale worktree directory in git metadata, but don't delete branch if we want to resume
        (ignore-errors
         (run-git-command repo-path (list "worktree" "remove" "-f" (namestring worktree-dir))))
        (ignore-errors
         (run-git-command repo-path (list "worktree" "prune")))
        
        (if (git-branch-exists-p repo-path node-branch)
            ;; Branch exists, add worktree referencing it
            (run-git-command repo-path (list "worktree" "add" (namestring worktree-dir) node-branch))
            ;; Branch does not exist, create new branch from shared-branch
            (run-git-command repo-path (list "worktree" "add" "-b" node-branch (namestring worktree-dir) shared-branch)))))
    t))

(defun merge-node-branch (campaign node)
  (let* ((repo-path (campaign-repository-path campaign))
         (shared-branch (campaign-dag-shared-branch (campaign-dag campaign)))
         (node-id (campaign-node-id node))
         (node-branch (format nil "campaign-node-~A" node-id)))
    (when (git-repo-p repo-path)
      (bt:with-lock-held ((campaign-git-lock campaign))
        ;; 1. Checkout the shared branch
        (run-git-command repo-path (list "checkout" shared-branch))
        ;; 2. Merge the node branch
        (run-git-command repo-path (list "merge" node-branch "--no-edit"))
        ;; 3. Clean up the worktree
        (let ((worktree-dir (get-node-worktree-dir campaign node)))
          (ignore-errors
           (run-git-command repo-path (list "worktree" "remove" "-f" (namestring worktree-dir))))
          (ignore-errors
           (run-git-command repo-path (list "worktree" "prune")))
          ;; 4. Delete the node branch
          (ignore-errors
           (run-git-command repo-path (list "branch" "-D" node-branch))))))
    t))

(defun prune-node-branch (campaign node)
  (let* ((repo-path (campaign-repository-path campaign))
         (node-id (campaign-node-id node))
         (node-branch (format nil "campaign-node-~A" node-id)))
    (when (git-repo-p repo-path)
      (bt:with-lock-held ((campaign-git-lock campaign))
        ;; 1. Clean up the worktree
        (let ((worktree-dir (get-node-worktree-dir campaign node)))
          (ignore-errors
           (run-git-command repo-path (list "worktree" "remove" "-f" (namestring worktree-dir))))
          (ignore-errors
           (run-git-command repo-path (list "worktree" "prune")))
          ;; 2. Delete the node branch
          (ignore-errors
           (run-git-command repo-path (list "branch" "-D" node-branch))))))
    t))

(defun safe-write-journal-entry (campaign stream entry)
  (bt:with-lock-held ((campaign-journal-lock campaign))
    (write-journal-entry stream entry)))

(defun list-prefix-p (list-a list-b)
  (cond ((null list-a) t)
        ((null list-b) nil)
        ((equal (car list-a) (car list-b))
         (list-prefix-p (cdr list-a) (cdr list-b)))
        (t nil)))

(defun canonicalize-path (p)
  (handler-case
      (truename p)
    (error ()
      (merge-pathnames (pathname p) *default-pathname-defaults*))))

(defun parse-path-spec (p)
  (let* ((canonical (canonicalize-path p))
         (dir (pathname-directory canonical))
         (name (pathname-name canonical))
         (type (pathname-type canonical))
         (is-dir (or (uiop:directory-exists-p canonical)
                     (and (null name) (null type))
                     (let ((str (namestring p)))
                       (and (> (length str) 0)
                            (char= (char str (1- (length str))) #\/))))))
    (if is-dir
        (list :directory (append dir (when name (list name))))
        (list :file dir (cons name type)))))

(defun specs-overlap-p (spec1 spec2)
  (cond
    ((and (eq (first spec1) :directory)
          (eq (first spec2) :directory))
     (let ((dir1 (second spec1))
           (dir2 (second spec2)))
       (or (list-prefix-p dir1 dir2)
           (list-prefix-p dir2 dir1))))
    
    ((and (eq (first spec1) :directory)
          (eq (first spec2) :file))
     (let ((dir1 (second spec1))
           (dir2 (second spec2)))
       (list-prefix-p dir1 dir2)))
    
    ((and (eq (first spec1) :file)
          (eq (first spec2) :directory))
     (let ((dir1 (second spec1))
           (dir2 (second spec2)))
       (list-prefix-p dir2 dir1)))
    
    ((and (eq (first spec1) :file)
          (eq (first spec2) :file))
     (let ((dir1 (second spec1))
           (file1 (third spec1))
           (dir2 (second spec2))
           (file2 (third spec2)))
       (and (equal dir1 dir2)
            (equal (car file1) (car file2))
            (equal (cdr file1) (cdr file2)))))
    (t nil)))

(defun path-overlap-p (p1 p2)
  (specs-overlap-p (parse-path-spec p1) (parse-path-spec p2)))

(defun surfaces-overlap-p (surf1 surf2)
  (some (lambda (s1)
          (some (lambda (s2)
                  (path-overlap-p s1 s2))
                surf2))
        surf1))

(defun group-nodes-for-scheduling (nodes)
  (let ((batches nil))
    (dolist (node nodes)
      (let ((placed nil))
        (unless (campaign-node-sequential-p node)
          (dolist (batch batches)
            (unless (or (some #'campaign-node-sequential-p batch)
                        (some (lambda (other)
                                (surfaces-overlap-p (campaign-node-file-surface node)
                                                   (campaign-node-file-surface other)))
                              batch))
              ;; Find the last cons cell and append
              (setf (cdr (last batch)) (list node))
              (setf placed t)
              (return))))
        (unless placed
          (push (list node) batches))))
    (nreverse (mapcar #'identity batches))))

;;; ============================================================================
;;; IBC-sufficiency gate -- validates a campaign-node's
;;; structured BOUNDARY against contracts/ibc-boundary.ncl before any
;;; harness action for that node. A nil boundary (the pre-existing
;;; goal-fallback path, campaign-node-effective-prompt above) is out of
;;; scope for this gate; the call site in run-node-execution below only
;;; invokes it when a boundary is actually set.
;;; ============================================================================

(defun boundary->json-hash-table (boundary)
  "Serialize BOUNDARY's 4 kebab-case slots to a hash-table keyed by
contracts/ibc-boundary.ncl's exact snake_case field names -- 1:1, no
extra/missing keys. NIL
may-commit/file-surface/halt-conditions round-trip to JSON false/[]/[]
(all valid per the contract); only a NIL prompt has no valid counterpart,
left for the gate itself to reject."
  (let ((ht (make-hash-table :test 'equal)))
    (setf (gethash "may_commit" ht) (boundary-may-commit boundary))
    (setf (gethash "file_surface" ht) (boundary-file-surface boundary))
    (setf (gethash "halt_conditions" ht) (boundary-halt-conditions boundary))
    (setf (gethash "prompt" ht) (boundary-prompt boundary))
    ht))

(defun coerce-json-array-fields (hash-table)
  "Return a fresh hash-table equivalent to HASH-TABLE, except its
file_surface/halt_conditions values (when present) are coerced to vectors.
com.inuoe.jzon:stringify cannot distinguish a Lisp NIL meaning \"empty
list\" from NIL meaning \"boolean false\", so an empty FILE-SURFACE/
HALT-CONDITIONS would otherwise round-trip to JSON `false` instead of `[]`
-- which contracts/ibc-boundary.ncl's Array String type rejects.
may_commit/prompt pass through untouched: their NIL is genuinely boolean
false / absent, never an empty-array ambiguity."
  (let ((out (make-hash-table :test 'equal)))
    (maphash (lambda (k v)
               (setf (gethash k out)
                     (if (member k '("file_surface" "halt_conditions") :test #'string=)
                         (coerce v 'vector)
                         v)))
             hash-table)
    out))

(defun run-boundary-contract-gate (json-hash-table)
  "Validate JSON-HASH-TABLE against contracts/ibc-boundary.ncl by shelling
`nickel export <tmp>.json --apply-contract contracts/ibc-boundary.ncl`.
Any non-zero exit -- missing field, null prompt, or any other contract
violation -- signals GATE-FAILURE unconditionally. Deliberately does NOT
reuse gate.lisp's NICKEL-CONTRACT-VIOLATION-P/PROTOCOL-INVARIANT-VIOLATION
pairing: that classifier's substring checks also match ordinary
boundary insufficiency, which would mislabel a per-node-recoverable defect
as a campaign-halting one."
  (let* ((contract-path (namestring (truename (librecode-meta.gate::resolve-gate-path "contracts/ibc-boundary.ncl"))))
         (json-text (com.inuoe.jzon:stringify (coerce-json-array-fields json-hash-table)))
         (temp-path (uiop:merge-pathnames*
                     (format nil "~A.json" (symbol-name (gensym "ibc-boundary-gate-")))
                     (uiop:ensure-directory-pathname (uiop:temporary-directory)))))
    (unwind-protect
         (progn
           (with-open-file (stream temp-path :direction :output
                                              :if-exists :supersede
                                              :if-does-not-exist :create)
             (write-string json-text stream))
           (let* ((nickel-bin (librecode-meta.gate::resolve-absolute-binary "nickel"))
                  (cmd-list (list nickel-bin "export" (namestring temp-path)
                                  "--apply-contract" contract-path)))
             (multiple-value-bind (stdout stderr exit-code)
                 (librecode-meta.gate::run-program-capture cmd-list)
               (declare (ignore stdout))
               (if (= exit-code 0)
                   t
                   (error 'librecode-runner.conditions:gate-failure
                          :message stderr
                          :command (format nil "~{~A~^ ~}" cmd-list)
                          :exit-code exit-code)))))
      (uiop:delete-file-if-exists temp-path))))

(defun gate-check-boundary (boundary)
  "The pre-dispatch sufficiency gate's entry point: serialize BOUNDARY and
run it through RUN-BOUNDARY-CONTRACT-GATE. Returns T on a passing grant;
signals GATE-FAILURE on any contract violation."
  (run-boundary-contract-gate (boundary->json-hash-table boundary)))

(defvar *provider-url-override* nil
  "Internal, unexported override for the real provider base-url threaded
into a dispatched node's harness-spawn config plist, read by
RUN-NODE-EXECUTION below. NIL (the default, and the value every existing
call site leaves it at) means no override is in play -- the config plist's
:provider-url key carries NIL exactly as it always implicitly did, so a
harness-spawn method that never reads that key sees no behavior change at
all. RUN-NODE-EXECUTION dispatches each node's own work on a fresh worker
thread (EXECUTE-NODE-BATCH's BT:MAKE-THREAD calls), which does not inherit
a calling thread's dynamic LET bindings -- so a caller (e.g. a REPL charter
session's driver function) MUST set this via SETF under UNWIND-PROTECT, not
LET, for a dispatched node's worker thread to see the override at all.
Never holds a credential -- the real provider token reaches the dispatched
child exclusively through RUN-CHILD's own environment-variable sourcing.")

(defvar *model-override* nil
  "Internal, unexported override for the real provider model threaded into
a dispatched node's harness-spawn config plist, read by RUN-NODE-EXECUTION
below. NIL (the default) preserves the existing \"mock-model\" literal
unchanged for every call site that never binds this. Same SETF-not-LET
caveat as *PROVIDER-URL-OVERRIDE* above applies -- worker-thread dispatch
never sees a calling thread's LET binding.")

(defun run-node-execution (campaign node journal-stream)
  (let* ((node-id (campaign-node-id node))
         (harness-type (campaign-node-harness-type node))
         (worktree-dir (get-node-worktree-dir campaign node))
         (repo-path (campaign-repository-path campaign))
         (db-path "librecode.db")
         ;; Prepare the config for harness-spawn. :provider is an inert
         ;; label only harness-librecode.lisp's (out-of-surface,
         ;; auth-free) path branches on -- real reach turns entirely on
         ;; :provider-url/:model, which *PROVIDER-URL-OVERRIDE*/
         ;; *MODEL-OVERRIDE* let a caller (e.g. a REPL charter session)
         ;; set to real values without disturbing this literal.
         (config (list :id node-id
                       :db-path db-path
                       :workspace-root worktree-dir
                       :provider "mock-provider"
                       :provider-url *provider-url-override*
                       :model (or *model-override* "mock-model")
                       :max-steps 10)))
    ;; 0. Pre-dispatch sufficiency gate: a non-nil boundary MUST pass
    ;; contracts/ibc-boundary.ncl before any worktree/harness action for
    ;; this node is reached. A nil boundary is the existing goal-fallback
    ;; path and is untouched (gate-check-boundary is simply not called).
    (when (campaign-node-boundary node)
      (gate-check-boundary (campaign-node-boundary node)))

    ;; 1. Prepare worktree/workspace
    (prepare-node-worktree campaign node worktree-dir)
    (librecode-meta.harness:harness-prepare-workspace harness-type repo-path worktree-dir)
    
    ;; Write dispatch to journal BEFORE starting
    (safe-write-journal-entry campaign journal-stream (list :node-dispatched node-id))
    (setf (campaign-node-status node) :dispatched)
    
    ;; 2. Spawn child harness
    (let ((harness (librecode-meta.harness:harness-spawn harness-type config)))
      (setf (campaign-node-harness-instance node) harness)
      (bt:with-lock-held ((campaign-active-harnesses-lock campaign))
        (setf (gethash node-id (campaign-active-harnesses campaign)) harness))
      
      (unwind-protect
           (progn
             ;; Prompt the harness with the composed boundary/rework-diagnostic prompt
             (librecode-meta.harness:harness-prompt harness (campaign-node-effective-prompt node) :mode :steer)
             
             ;; Monitor loop
             (loop
               (let ((status (librecode-meta.harness:harness-status harness)))
                 (cond
                   ((eq status :idle)
                    (return))
                   ((eq status :error)
                    (error 'librecode-runner.conditions:harness-failure
                           :message (format nil "Child harness for node ~A entered error state" node-id)
                           :process-id node-id
                           :exit-code -1))
                   ((eq status :terminated)
                    (error 'librecode-runner.conditions:harness-failure
                           :message (format nil "Child harness for node ~A was terminated" node-id)
                           :process-id node-id
                           :exit-code -2))
                   (t
                    ;; Sleep/block using event queue to avoid busy-waiting
                    (librecode-meta.harness:harness-read-event harness :timeout 0.5))))))
        ;; Clean up harness in all cases
        (librecode-meta.harness:harness-terminate harness)
        (bt:with-lock-held ((campaign-active-harnesses-lock campaign))
          (remhash node-id (campaign-active-harnesses campaign)))
        (setf (campaign-node-harness-instance node) nil)))
    
    ;; If we got here, it was successful! Mark landed.
    (safe-write-journal-entry campaign journal-stream (list :node-landed node-id))
    (setf (campaign-node-status node) :landed)
    t))

(defun execute-node-batch (campaign batch journal-stream)
  (loop
    (let ((failed-nodes nil)
          (failed-conditions nil)
          (threads nil)
          (lock (bt:make-lock "batch-lock")))
      ;; Spawn threads for each pending/rework node in the batch
      (dolist (node batch)
        (let ((status (campaign-node-status node)))
          (cond
            ((eq status :landed)
             nil)
            ((member status '(:pending :rework :dispatched))
             (push (bt:make-thread
                    (lambda ()
                      (handler-case
                          (run-node-execution campaign node journal-stream)
                        (serious-condition (c)
                          (bt:with-lock-held (lock)
                            (push node failed-nodes)
                            (push c failed-conditions)))))
                    :name (format nil "node-runner-~A" (campaign-node-id node)))
                   threads)))))
      ;; Wait for all threads to finish
      (dolist (thread threads)
        (bt:join-thread thread))
      ;; If there are failures, signal them at the parent level
      (if failed-nodes
          (loop for failed-node in failed-nodes
                for failed-cond in failed-conditions
                do
                (let ((node-id (campaign-node-id failed-node)))
                  (if (campaign-autonomous-p campaign)
                      (let* ((failure-counts (campaign-failure-counts campaign))
                             (count (setf (gethash node-id failure-counts)
                                          (1+ (gethash node-id failure-counts 0))))
                             (limit (campaign-max-retries campaign)))
                        (if (>= count limit)
                            (let* ((escalation-cond
                                     (make-condition 'escalation-required
                                                     :campaign campaign
                                                     :node failed-node
                                                     :failure-descriptor (librecode-runner.protocol:condition-to-descriptor failed-cond)
                                                     :reply-mailbox (campaign-reply-mailbox campaign)))
                                   (choice (restart-case
                                               (if (campaign-escalation-hook campaign)
                                                   (funcall (campaign-escalation-hook campaign) escalation-cond)
                                                   (error escalation-cond))
                                             (resume-escalation (action)
                                               :report "Resume campaign after escalation"
                                               action))))
                              (cond
                                ((and choice (symbolp choice) (string-equal choice "SKIP-NODE"))
                                 (setf (campaign-node-status failed-node) :skipped)
                                 (safe-write-journal-entry campaign journal-stream (list :node-skipped node-id))
                                 (prune-node-branch campaign failed-node))
                                ((and choice (symbolp choice) (string-equal choice "RETRY-NODE"))
                                 (setf (campaign-node-status failed-node) :pending))
                                (t
                                 (error "Unhandled escalation resolution action: ~S" choice))))
                            (cond
                              ((= count 1)
                               (setf (campaign-node-status failed-node) :pending))
                              ((= count 2)
                               (setf (campaign-node-rework-diagnostic failed-node)
                                     (format nil "Error trace from failure: ~A" (princ-to-string failed-cond)))
                               (safe-write-journal-entry campaign journal-stream (list :node-rework node-id (campaign-node-rework-diagnostic failed-node)))
                               (setf (campaign-node-status failed-node) :rework))
                              ((and (>= count 3) (< count (1- limit)))
                               (setf (campaign-node-status failed-node) :skipped)
                               (safe-write-journal-entry campaign journal-stream (list :node-skipped node-id))
                               (prune-node-branch campaign failed-node))
                              (t
                               (setf (campaign-node-status failed-node) :pending)))))
                      (let ((choice
                              (block nil
                                (librecode-runner.protocol:with-failure-relay
                                    ((campaign-supervisor-mailbox campaign)
                                     (campaign-reply-mailbox campaign)
                                     :recovery-menu '((retry-node) (skip-node))
                                     :apply-choice (lambda (choice args)
                                                     (let ((restart (find (symbol-name choice)
                                                                          (compute-restarts)
                                                                          :key (lambda (r) (symbol-name (restart-name r)))
                                                                          :test #'string=)))
                                                       (if restart
                                                           (apply #'invoke-restart restart args)
                                                           (error "Restart ~A not found" choice)))))
                                  (restart-case
                                      (error 'librecode-runner.conditions:harness-failure
                                             :message (format nil "Harness error on node ~A: ~A" node-id (princ-to-string failed-cond))
                                             :process-id node-id
                                             :exit-code -1)
                                    (retry-node ()
                                      :report "Retry the failed node"
                                      :retry)
                                    (skip-node ()
                                      :report "Skip the failed node"
                                      :skip))))))
                        (cond
                          ((null choice)
                           (error "Campaign execution aborted by supervisor"))
                          ((eq choice :retry)
                           (setf (campaign-node-status failed-node) :pending))
                          ((eq choice :skip)
                           (setf (campaign-node-status failed-node) :skipped)
                           (safe-write-journal-entry campaign journal-stream (list :node-skipped node-id))
                           (prune-node-branch campaign failed-node)))))))
          ;; No failures! Merge all nodes in the batch
          (progn
            (dolist (node batch)
              (when (eq (campaign-node-status node) :landed)
                (setf (campaign-node-status node) :accepted)
                (safe-write-journal-entry campaign journal-stream (list :node-accepted (campaign-node-id node)))
                (merge-node-branch campaign node)))
            (return))))))

(defparameter *replay-invariants*
  (list (cons "phase-monotonic-p" 'librecode-model:phase-monotonic-p)
        (cons "no-pending-proven-p" 'librecode-model:no-pending-proven-p)
        (cons "tamper-evident-p" 'librecode-model:tamper-evident-p)
        (cons "dag-preserved-p" 'librecode-model:dag-preserved-p)
        (cons "surface-monotonic-p" 'librecode-model:surface-monotonic-p)
        (cons "schedule-correct-p" 'librecode-model:schedule-correct-p))
  "Every invariant exported from src/model/packages.lisp's invariants.lisp
export block, paired with its name for error reporting. This list is the
source of truth for \"which invariants gate resume\" and must track that
export block -- if a future node adds a seventh invariant there, add it
here too.")

(defun check-replay-invariants (model-dag events)
  "Run every entry in *REPLAY-INVARIANTS* against MODEL-DAG/EVENTS (the
(dag events) pair every librecode-model invariant predicate takes), and
signal a JOURNAL-INVARIANT-VIOLATION naming the first one that returns NIL.
Fails fast rather than collecting every violation: the six invariants are
independent boolean checks over the same replayed trajectory, not sequenced
diagnostics, so there is no 'later' violation a fail-fast exit would hide
information about that isn't already implied by the first."
  (dolist (entry *replay-invariants*)
    (destructuring-bind (name . predicate) entry
      (unless (funcall predicate model-dag events)
        (error 'librecode-runner.conditions:journal-invariant-violation
               :invariant name
               :message (format nil "~A returned NIL for the replayed journal's trajectory." name))))))

(defun run-campaign (campaign)
  (let* ((dag (campaign-dag campaign))
         (journal-path (campaign-journal-path campaign))
         (layers (campaign-dag-layers dag)))
    ;; 1. Replay journal if it exists to restore state
    (when (and journal-path (probe-file journal-path))
      (multiple-value-bind (replayed-dag last-valid-pos model-state)
          (replay-journal journal-path dag)
        ;; REPLAY-JOURNAL mutates and returns DAG's own identity (topology
        ;; fields are never touched, only status/phase/deposit/file-surface
        ;; are folded onto it in place) — thread that forward explicitly
        ;; rather than silently discarding it, so a future change to
        ;; REPLAY-JOURNAL's threading contract fails loudly instead of
        ;; leaving callers reading stale state (p4-discarded-fold).
        (assert (eq replayed-dag dag) ()
                "replay-journal must mutate and return DAG's own identity, not a copy")
        ;; Boot-gate: a replayed trajectory that fails a crown-jewel
        ;; invariant is a log-integrity problem, not something to continue
        ;; silently past -- check BEFORE truncating, so a rejected journal
        ;; is left on disk untouched for inspection rather than truncated
        ;; against a state we're about to refuse.
        (check-replay-invariants (librecode-model:model-state-dag model-state)
                                  (librecode-model:model-state-events model-state))
        #+sbcl
        (sb-posix:truncate (namestring journal-path) last-valid-pos)
        #-sbcl
        (error "Truncation only supported on SBCL")))
    
    ;; 2. Open journal stream in append/create mode
    (with-open-file (journal-stream journal-path
                                    :direction :output
                                    :if-exists :append
                                    :if-does-not-exist :create)
      ;; 3. Iterate through layers
      (dotimes (layer-idx (length layers))
        (let* ((layer-node-ids (aref layers layer-idx))
               (layer-nodes (mapcar (lambda (id)
                                      (find id (campaign-dag-nodes dag)
                                            :key #'campaign-node-id
                                            :test #'string=))
                                    layer-node-ids))
               ;; Eligible nodes in this layer (not accepted or skipped yet)
               (eligible-nodes (remove-if (lambda (status) (member status '(:accepted :skipped)))
                                          layer-nodes
                                          :key #'campaign-node-status)))
          (when eligible-nodes
            (let ((batches (group-nodes-for-scheduling eligible-nodes)))
              (dolist (batch batches)
                (execute-node-batch campaign batch journal-stream))))))))
  t)

