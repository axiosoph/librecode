;;; -*- Mode: Lisp; Syntax: Common-Lisp; indent-tabs-mode: nil; coding: utf-8; Show-Trailing-Whitespace: t -*-
;;;
;;; builtin-tools.lisp — Built-in tools for workspace and code interaction
;;;

(in-package #:librecode-runner.builtin-tools)

(defun normalize-directory-list (dir-list)
  "Normalize directory components list by resolving :up and :back."
  (let ((result nil))
    (dolist (comp dir-list)
      (cond
        ((member comp '(:up :back))
         (if (and result (not (member (car result) '(:absolute :relative :up :back))))
             (pop result)
             (push comp result)))
        (t (push comp result))))
    (nreverse result)))

(defun pathname-parent-directory (path)
  "Return a pathname representing the parent directory of PATH."
  (let* ((directory (pathname-directory path))
         (name (pathname-name path))
         (type (pathname-type path)))
    (cond
      ((or name type)
       ;; It's a file pathname, the parent directory is just its directory.
       (make-pathname :directory directory :name nil :type nil :defaults path))
      ((and (consp directory) (member (car directory) '(:absolute :relative)))
       (if (cdr directory)
           ;; It's a directory pathname, drop the last component to get parent directory.
           (make-pathname :directory (butlast directory) :name nil :type nil :defaults path)
           nil))
      (t nil))))

(defun closest-existing-ancestor (path)
  "Find the closest ancestor directory of PATH (or PATH itself) that exists."
  (loop for p = path then (pathname-parent-directory p)
        while p
        do (when (probe-file p)
             (return (truename p)))
        finally (return nil)))

(defun resolve-safe-path (path-str)
  "Resolve and validate path-str against *workspace-root* with symlink and traversal protection."
  (let* ((workspace-root (or (and (boundp 'librecode-runner.event-store:*workspace-root*)
                                  librecode-runner.event-store:*workspace-root*)
                             (error 'simple-error :message "Workspace root is not bound.")))
         ;; 1. Canonicalize workspace root
         (abs-workspace (uiop:ensure-absolute-pathname
                         (uiop:ensure-directory-pathname workspace-root)
                         #'uiop:getcwd))
         (canonical-workspace (truename abs-workspace))
         (norm-workspace-dir (normalize-directory-list (pathname-directory canonical-workspace)))
         
         ;; 2. Merge target path with workspace root
         (target-path (pathname path-str))
         (resolved-path (if (uiop:absolute-pathname-p target-path)
                            target-path
                            (uiop:merge-pathnames* target-path abs-workspace)))
         (abs-resolved (uiop:ensure-absolute-pathname resolved-path #'uiop:getcwd))
         
         ;; 3. Find closest existing ancestor and canonicalize it
         (existing-ancestor (closest-existing-ancestor abs-resolved)))
    
    (unless existing-ancestor
      (error 'librecode-runner.conditions:denied-error
             :action "resolve_path"
             :resource path-str
             :message "Could not find any existing ancestor for the path."))
    
    ;; 4. Check if the existing ancestor escapes the workspace root
    (let ((norm-ancestor-dir (normalize-directory-list (pathname-directory existing-ancestor))))
      (unless (and (>= (length norm-ancestor-dir) (length norm-workspace-dir))
                   (equal (subseq norm-ancestor-dir 0 (length norm-workspace-dir))
                          norm-workspace-dir))
        (error 'librecode-runner.conditions:denied-error
               :action "resolve_path"
               :resource path-str
               :message (format nil "Symlink/Traversal defense: path ~S escapes workspace root ~S"
                                path-str (namestring canonical-workspace)))))
    
    ;; 5. Lexically normalize the full resolved path to double-protect against lexical ".."
    ;; in the non-existent leaf components.
    (let ((norm-resolved-dir (normalize-directory-list (pathname-directory abs-resolved))))
      (unless (and (>= (length norm-resolved-dir) (length norm-workspace-dir))
                   (equal (subseq norm-resolved-dir 0 (length norm-workspace-dir))
                          norm-workspace-dir))
        (error 'librecode-runner.conditions:denied-error
               :action "resolve_path"
               :resource path-str
               :message (format nil "Traversal defense: path ~S escapes workspace root ~S"
                                path-str (namestring canonical-workspace)))))
    
    abs-resolved))

(defun check-resource-permission (action resource)
  "If *current-session-id* is bound and not nil, run the permission check on the active agent."
  (when (and (boundp 'librecode-runner.agent:*current-session-id*)
             librecode-runner.agent:*current-session-id*)
    (let* ((session-id librecode-runner.agent:*current-session-id*)
           (agent (librecode-runner.runner::get-active-agent session-id)))
      (when agent
        (librecode-runner.agent:check-permission agent action resource)))))

(defun read-file-with-limit (resolved path-str)
  "Read the file resolved path into a string, ensuring it does not exceed 10MB."
  (with-open-file (stream resolved :direction :input :element-type 'character :external-format :utf-8)
    (let ((len (file-length stream)))
      (cond
        ((and len (> len (* 10 1024 1024)))
         (error "File size exceeds 10MB limit (~D bytes)" len))
        (len
         ;; file-length is non-nil and within limits
         (let ((seq (make-string len)))
           (read-sequence seq stream)
           seq))
        (t
         ;; file-length is nil (special file / pipe). Read using uiop:read-file-string.
         (let ((content (uiop:read-file-string resolved :external-format :utf-8)))
           (when (> (length content) (* 10 1024 1024))
             (error "Special file content size exceeds 10MB limit while reading."))
           content))))))

(defun handle-read-file (args)
  "Read a file inside the workspace-root as a UTF-8 string, with directory traversal protection and size checks."
  (let* ((path (getf args :path))
         (resolved (resolve-safe-path path)))
    (check-resource-permission "read_file" (namestring resolved))
    (when (librecode-runner.tool:tool-cancelled-p)
      (error "Tool execution was cancelled."))
    (handler-case
        (read-file-with-limit resolved path)
      (error (c)
        (error 'simple-error :format-control "Failed to read file ~A: ~A"
                             :format-arguments (list path c))))))

(defun handle-write-file (args)
  "Write string content to a file inside the workspace-root, creating parent directories if needed."
  (let* ((path (getf args :path))
         (content (getf args :content))
         (resolved (resolve-safe-path path)))
    (check-resource-permission "write_file" (namestring resolved))
    (when (librecode-runner.tool:tool-cancelled-p)
      (error "Tool execution was cancelled."))
    (when (> (length content) (* 10 1024 1024))
      (error 'simple-error :format-control "Content size ~D characters exceeds 10MB limit."
                           :format-arguments (list (length content))))
    (handler-case
        (progn
          (ensure-directories-exist resolved)
          (with-open-file (stream resolved
                                  :direction :output
                                  :if-exists :supersede
                                  :if-does-not-exist :create
                                  :element-type 'character
                                  :external-format :utf-8)
            (write-sequence content stream))
          (format nil "File written successfully to ~A" path))
      (error (c)
        (error 'simple-error :format-control "Failed to write file ~A: ~A"
                             :format-arguments (list path c))))))

(defun handle-bash (args)
  "Execute a shell command inside the workspace-root and return combined stdout/stderr."
  (let* ((command (getf args :command))
         (workspace-root (or librecode-runner.event-store:*workspace-root*
                             (uiop:getcwd)))
         (process-info nil)
         (exit-code nil)
         (combined nil))
    (check-resource-permission "bash" command)
    (when (librecode-runner.tool:tool-cancelled-p)
      (error "Tool execution was cancelled."))
    (unwind-protect
         (handler-case
             (progn
               (setf process-info (uiop:launch-program (list "bash" "-c" command)
                                                       :output :stream
                                                       :error-output :stream
                                                       :directory (namestring workspace-root)))
               (librecode-runner.tool:register-active-subprocess process-info)
               (let ((stdout (uiop:slurp-stream-string (uiop:process-info-output process-info)))
                     (stderr (uiop:slurp-stream-string (uiop:process-info-error-output process-info))))
                 (setf exit-code (uiop:wait-process process-info))
                 (setf combined (concatenate 'string stdout stderr))))
           (error (c)
             (error 'simple-error :format-control "Bash invocation failed: ~A" :format-arguments (list c))))
      ;; Subprocess leak prevention
      (when (and process-info (uiop:process-alive-p process-info))
        (uiop:terminate-process process-info :urgent t))
      (when process-info
        (librecode-runner.tool:unregister-active-subprocess process-info)))
    (if (= exit-code 0)
        combined
        (error 'simple-error :format-control "Command ~S failed with exit code ~D. Output:~%~A"
                             :format-arguments (list command exit-code combined)))))

(defparameter read-file-tool
  (make-instance 'librecode-runner.tool:tool
                 :name "read_file"
                 :description "Read the text contents of a file in the workspace."
                 :parameters '(:type "object"
                               :properties (:path (:type "string" :description "Relative path of the file to read."))
                               :required #(:path))
                 :capabilities nil
                 :handler #'handle-read-file))

(defparameter write-file-tool
  (make-instance 'librecode-runner.tool:tool
                 :name "write_file"
                 :description "Write text contents to a file in the workspace, ensuring parent directories exist."
                 :parameters '(:type "object"
                               :properties (:path (:type "string" :description "Relative path of the file to write.")
                                            :content (:type "string" :description "UTF-8 encoded string content to write."))
                               :required #(:path :content))
                 :capabilities nil
                 :handler #'handle-write-file))

(defparameter bash-tool
  (make-instance 'librecode-runner.tool:tool
                 :name "bash"
                 :description "Execute a command in a bash shell inside the workspace root."
                 :parameters '(:type "object"
                               :properties (:command (:type "string" :description "Command to execute."))
                               :required #(:command))
                 :capabilities nil
                 :handler #'handle-bash))

(defun register-builtin-tools (registry)
  "Register the built-in tools (read_file, write_file, and bash) in the given registry."
  (librecode-runner.tool:register-tool registry read-file-tool)
  (librecode-runner.tool:register-tool registry write-file-tool)
  (librecode-runner.tool:register-tool registry bash-tool)
  registry)

;; Automatically register into default tool registry
(register-builtin-tools librecode-runner.runner::*tool-registry*)
