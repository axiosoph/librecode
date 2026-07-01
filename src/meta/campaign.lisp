;;; -*- Mode: Lisp; Syntax: Common-Lisp; indent-tabs-mode: nil; coding: utf-8; Show-Trailing-Whitespace: t -*-
;;;
;;; campaign.lisp — Campaign scheduler and DAG execution
;;;

(in-package #:librecode-meta.campaign)

;;; ============================================================================
;;; campaign-node and campaign-dag structs
;;; ============================================================================

(defstruct campaign-node
  "Represents an execution unit within a campaign DAG."
  (id nil :type (or null string))
  (goal nil :type (or null string))
  (file-surface nil :type list)        ; Paths (files or directories) this node is authorized to touch
  (dependencies nil :type list)        ; List of parent node IDs
  (sequential-p nil :type boolean)     ; Must run sequentially, cannot be parallelized
  (status :pending :type keyword)      ; :pending, :dispatched, :landed, :accepted, :rework, :skipped
  (harness-type nil :type symbol)      ; Class name of harness (e.g., 'harness-opencode)
  (harness-instance nil)               ; Reference to the active CLOS harness-instance
  (ibc nil :type (or null string)))    ; Initial Boundary Condition text (instructions/goals)

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

(defun run-node-execution (campaign node journal-stream)
  (let* ((node-id (campaign-node-id node))
         (harness-type (campaign-node-harness-type node))
         (worktree-dir (get-node-worktree-dir campaign node))
         (repo-path (campaign-repository-path campaign))
         (db-path "librecode.db")
         ;; Prepare the config for harness-spawn
         (config (list :id node-id
                       :db-path db-path
                       :workspace-root worktree-dir
                       :provider "mock-provider"
                       :model "mock-model"
                       :max-steps 10)))
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
             ;; Prompt the harness with the goal/ibc
             (librecode-meta.harness:harness-prompt harness (or (campaign-node-ibc node) (campaign-node-goal node)) :mode :steer)
             
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
                               (setf (campaign-node-ibc failed-node)
                                     (format nil "Error trace from failure: ~A" (princ-to-string failed-cond)))
                               (safe-write-journal-entry campaign journal-stream (list :node-rework node-id (campaign-node-ibc failed-node)))
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

(defun run-campaign (campaign)
  (let* ((dag (campaign-dag campaign))
         (journal-path (campaign-journal-path campaign))
         (layers (campaign-dag-layers dag)))
    ;; 1. Replay journal if it exists to restore state
    (when (and journal-path (probe-file journal-path))
      (multiple-value-bind (replayed-dag last-valid-pos)
          (replay-journal journal-path dag)
        (declare (ignore replayed-dag))
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
            (safe-write-journal-entry campaign journal-stream (list :layer-advanced layer-idx))
            (let ((batches (group-nodes-for-scheduling eligible-nodes)))
              (dolist (batch batches)
                (execute-node-batch campaign batch journal-stream))))))))
  t)

