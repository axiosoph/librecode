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

(defun resolve-safe-path (path-str)
  "Resolve and validate path-str against *workspace-root*.
Returns the absolute pathname if safe, otherwise signals a denied-error."
  (let* ((workspace-root (or (and (boundp 'librecode-runner.event-store:*workspace-root*)
                                  librecode-runner.event-store:*workspace-root*)
                             (error 'simple-error :message "Workspace root is not bound.")))
         ;; Ensure workspace-root is an absolute directory pathname
         (abs-workspace (uiop:ensure-absolute-pathname
                         (uiop:ensure-directory-pathname workspace-root)
                         #'uiop:getcwd))
         (norm-workspace-dir (normalize-directory-list (pathname-directory abs-workspace)))
         
         ;; Parse target pathname
         (target-path (pathname path-str))
         ;; Resolve target path against abs-workspace
         (resolved-path (if (uiop:absolute-pathname-p target-path)
                            target-path
                            (uiop:merge-pathnames* target-path abs-workspace)))
         (abs-resolved (uiop:ensure-absolute-pathname resolved-path #'uiop:getcwd))
         (norm-resolved-dir (normalize-directory-list (pathname-directory abs-resolved))))
    
    ;; Verify that the normalized directory components of normalized workspace root
    ;; is a prefix of the normalized resolved directory components.
    (unless (and (>= (length norm-resolved-dir) (length norm-workspace-dir))
                 (equal (subseq norm-resolved-dir 0 (length norm-workspace-dir))
                        norm-workspace-dir))
      (error 'librecode-runner.conditions:denied-error
             :action "resolve_path"
             :resource path-str
             :message (format nil "Directory traversal attack detected: path ~S escapes workspace root ~S"
                              path-str (namestring abs-workspace))))
    abs-resolved))

(defun check-resource-permission (action resource)
  "If *current-session-id* is bound and not nil, run the permission check on the active agent."
  (when (and (boundp 'librecode-runner.agent:*current-session-id*)
             librecode-runner.agent:*current-session-id*)
    (let* ((session-id librecode-runner.agent:*current-session-id*)
           (agent (librecode-runner.runner::get-active-agent session-id)))
      (when agent
        (librecode-runner.agent:check-permission agent action resource)))))

(defun handle-read-file (args)
  "Read a file inside the workspace-root as a UTF-8 string, with directory traversal protection and size checks."
  (let* ((path (getf args :path))
         (resolved (resolve-safe-path path)))
    (check-resource-permission "read_file" (namestring resolved))
    (handler-case
        (with-open-file (stream resolved :direction :input :element-type 'character :external-format :utf-8)
          (let ((len (file-length stream)))
            (when (and len (> len (* 10 1024 1024)))
              (error "File size exceeds 10MB limit (~D bytes)" len))
            (let ((seq (make-string (or len 0))))
              (read-sequence seq stream)
              seq)))
      (error (c)
        (error 'simple-error :format-control "Failed to read file ~A: ~A"
                             :format-arguments (list path c))))))

(defun handle-write-file (args)
  "Write string content to a file inside the workspace-root, creating parent directories if needed."
  (let* ((path (getf args :path))
         (content (getf args :content))
         (resolved (resolve-safe-path path)))
    (check-resource-permission "write_file" (namestring resolved))
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
    (unwind-protect
         (handler-case
             (progn
               (setf process-info (uiop:launch-program (list "bash" "-c" command)
                                                       :output :stream
                                                       :error-output :stream
                                                       :directory (namestring workspace-root)))
               (let ((stdout (uiop:slurp-stream-string (uiop:process-info-output process-info)))
                     (stderr (uiop:slurp-stream-string (uiop:process-info-error-output process-info))))
                 (setf exit-code (uiop:wait-process process-info))
                 (setf combined (concatenate 'string stdout stderr))))
           (error (c)
             (error 'simple-error :format-control "Bash invocation failed: ~A" :format-arguments (list c))))
      ;; Subprocess leak prevention
      (when (and process-info (uiop:process-alive-p process-info))
        (uiop:terminate-process process-info :urgent t)))
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
