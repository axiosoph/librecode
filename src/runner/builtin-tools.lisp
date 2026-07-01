;;; -*- Mode: Lisp; Syntax: Common-Lisp; indent-tabs-mode: nil; coding: utf-8; Show-Trailing-Whitespace: t -*-
;;;
;;; builtin-tools.lisp — Built-in tools for workspace and code interaction
;;;

(in-package #:librecode-runner.builtin-tools)

(defun handle-read-file (args)
  "Read a file inside the workspace-root as a UTF-8 string."
  (let* ((path (getf args :path))
         (resolved (librecode-runner.event-store::resolve-path path)))
    (handler-case
        (with-open-file (stream resolved :direction :input :element-type 'character :external-format :utf-8)
          (let ((seq (make-string (file-length stream))))
            (read-sequence seq stream)
            seq))
      (error (c)
        (error 'simple-error :format-control "Failed to read file ~A: ~A"
                             :format-arguments (list path c))))))

(defun handle-write-file (args)
  "Write string content to a file inside the workspace-root, creating parent directories if needed."
  (let* ((path (getf args :path))
         (content (getf args :content))
         (resolved (librecode-runner.event-store::resolve-path path)))
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
         (exit-code nil)
         (combined nil))
    (handler-case
        (let* ((process-info (uiop:launch-program (list "bash" "-c" command)
                                                  :output :stream
                                                  :error-output :stream
                                                  :directory (namestring workspace-root)))
               (stdout (uiop:slurp-stream-string (uiop:process-info-output process-info)))
               (stderr (uiop:slurp-stream-string (uiop:process-info-error-output process-info))))
          (setf exit-code (uiop:wait-process process-info))
          (setf combined (concatenate 'string stdout stderr)))
      (error (c)
        (error 'simple-error :format-control "Bash invocation failed: ~A" :format-arguments (list c))))
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

;; Automatically register into default tool registry
(librecode-runner.tool:register-tool librecode-runner.runner::*tool-registry* read-file-tool)
(librecode-runner.tool:register-tool librecode-runner.runner::*tool-registry* write-file-tool)
(librecode-runner.tool:register-tool librecode-runner.runner::*tool-registry* bash-tool)
