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
        (librecode-runner.tool:with-path-lock ((namestring resolved))
          (read-file-with-limit resolved path))
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
        (librecode-runner.tool:with-path-lock ((namestring resolved))
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

(defun count-string-occurrences (content target)
  "Count non-overlapping occurrences of the exact substring target within content.
An empty target counts as zero -- treated as a non-match, since exact-string
replacement against an existing file requires a concrete, non-empty search string."
  (if (zerop (length target))
      0
      (loop with count = 0
            with start = 0
            for pos = (search target content :start2 start)
            while pos
            do (incf count)
               (setf start (+ pos (length target)))
            finally (return count))))

(defun replace-string-occurrences (content old new replace-all)
  "Replace occurrences of old with new in content.
When replace-all is true, replaces every non-overlapping occurrence; otherwise
replaces the single occurrence (the caller guarantees exactly one match exists)."
  (if (not replace-all)
      (let ((pos (search old content)))
        (concatenate 'string (subseq content 0 pos) new (subseq content (+ pos (length old)))))
      (with-output-to-string (out)
        (loop with start = 0
              for pos = (search old content :start2 start)
              while pos
              do (write-string content out :start start :end pos)
                 (write-string new out)
                 (setf start (+ pos (length old)))
              finally (write-string content out :start start)))))

(defun handle-edit (args)
  "Perform an exact-string replacement of oldString with newString within an
existing file inside the workspace-root, sandboxed identically to
read_file/write_file."
  (let* ((path (getf args :filePath))
         (old-string (getf args :oldString))
         (new-string (getf args :newString))
         (replace-all (getf args :replaceAll))
         (resolved (resolve-safe-path path)))
    (check-resource-permission "edit" (namestring resolved))
    (when (librecode-runner.tool:tool-cancelled-p)
      (error "Tool execution was cancelled."))
    (when (string= old-string new-string)
      (error 'simple-error
             :format-control "No changes to apply: oldString and newString are identical for ~A."
             :format-arguments (list path)))
    ;; The whole read -> count -> compute -> write sequence is a single
    ;; critical section: it must run atomically with respect to any other
    ;; concurrent read_file/write_file/edit call against this same resolved
    ;; path, or two concurrent edits (or an edit racing a write_file) could
    ;; both read the same stale content and one's write would silently
    ;; clobber the other's (finding F20).
    (librecode-runner.tool:with-path-lock ((namestring resolved))
      (unless (probe-file resolved)
        (error 'simple-error
               :format-control "File not found: ~A"
               :format-arguments (list path)))
      (let ((content (handler-case
                          (read-file-with-limit resolved path)
                        (error (c)
                          (error 'simple-error :format-control "Failed to read file ~A for editing: ~A"
                                               :format-arguments (list path c))))))
        (let ((count (count-string-occurrences content old-string)))
          (cond
            ((zerop count)
             (error 'simple-error
                    :format-control "Could not find oldString in ~A; it must match the file content exactly, including whitespace and line endings."
                    :format-arguments (list path)))
            ((and (> count 1) (not replace-all))
             (error 'simple-error
                    :format-control "Found ~D matches for oldString in ~A; provide more surrounding context to make the match unique, or pass replaceAll: true."
                    :format-arguments (list count path)))
            (t
             (let ((new-content (replace-string-occurrences content old-string new-string replace-all)))
               (when (> (length new-content) (* 10 1024 1024))
                 (error 'simple-error
                        :format-control "Resulting content size ~D characters exceeds 10MB limit for ~A."
                        :format-arguments (list (length new-content) path)))
               (handler-case
                   (progn
                     (with-open-file (stream resolved
                                             :direction :output
                                             :if-exists :supersede
                                             :if-does-not-exist :error
                                             :element-type 'character
                                             :external-format :utf-8)
                       (write-sequence new-content stream))
                     (format nil "Edit applied successfully to ~A (~D replacement~:P)." path count))
                 (error (c)
                   (error 'simple-error :format-control "Failed to write edited file ~A: ~A"
                                        :format-arguments (list path c))))))))))))

(defparameter *bash-output-cap-bytes* (* 1024 1024)
  "Maximum size, in characters, of combined bash output returned to the caller.
Output beyond this size is truncated with an explicit marker rather than
returned unboundedly.")

(defun cap-bash-output (text)
  "Truncate TEXT to *bash-output-cap-bytes* characters, appending an explicit
marker naming how many bytes were omitted. Returns TEXT unchanged if it is
within the cap."
  (let ((len (length text)))
    (if (<= len *bash-output-cap-bytes*)
        text
        (format nil "~A~%... [output truncated, ~D bytes omitted]"
                (subseq text 0 *bash-output-cap-bytes*)
                (- len *bash-output-cap-bytes*)))))

(defun read-bash-output-with-deadline (process-info timeout-seconds)
  "Read PROCESS-INFO's merged output stream to EOF and wait for its exit code
on a background thread, bounded by TIMEOUT-SECONDS wall-clock time. Signals
librecode-runner.conditions:tool-timeout if the deadline elapses first.
Termination of PROCESS-INFO on timeout is the caller's responsibility --
handle-bash's existing leak-prevention cleanup already does this, which also
closes the pipe and lets the background reader thread unblock and exit on
its own (never a raw thread kill)."
  (let ((lock (bt:make-lock "bash-output-deadline-lock"))
        (cv (bt:make-condition-variable :name "bash-output-deadline-cv"))
        (finished-p nil)
        (output nil)
        (exit-code nil))
    (bt:make-thread
     (lambda ()
       (let ((out (uiop:slurp-stream-string (uiop:process-info-output process-info)))
             (code (uiop:wait-process process-info)))
         (bt:with-lock-held (lock)
           (setf output out exit-code code finished-p t)
           (bt:condition-notify cv))))
     :name "bash-output-reader")
    (bt:with-lock-held (lock)
      (let ((start-time (get-internal-real-time))
            (timeout-units (* timeout-seconds internal-time-units-per-second)))
        (loop until finished-p
              do (let* ((elapsed (- (get-internal-real-time) start-time))
                        (remaining-units (- timeout-units elapsed)))
                   (when (<= remaining-units 0)
                     (error 'librecode-runner.conditions:tool-timeout
                            :tool-id "bash"
                            :duration timeout-seconds
                            :message (format nil "Bash command exceeded timeout of ~A seconds."
                                              timeout-seconds)))
                   (bt:condition-wait cv lock
                                      :timeout (float (/ remaining-units internal-time-units-per-second) 1.0))))))
    (values output exit-code)))

(defun handle-bash (args)
  "Execute a shell command inside the workspace-root and return combined stdout/stderr.
An optional :timeout (seconds) bounds execution; on expiry the subprocess is
terminated via the existing cooperative-cancellation cleanup below and the
call settles as a tool-timeout condition. Combined output is capped at
*bash-output-cap-bytes*."
  (let* ((command (getf args :command))
         (timeout (getf args :timeout))
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
                                                       ;; Merge stderr into the stdout stream at launch
                                                       ;; time: two separate unmerged pipes deadlock when
                                                       ;; a child fills the stderr pipe buffer before
                                                       ;; stdout reaches EOF, since the stdout slurp below
                                                       ;; blocks waiting for an EOF that never arrives.
                                                       :error-output :output
                                                       :directory (namestring workspace-root)))
               (librecode-runner.tool:register-active-subprocess process-info)
               (if timeout
                   (multiple-value-bind (out code) (read-bash-output-with-deadline process-info timeout)
                     (setf combined out exit-code code))
                   (progn
                     (setf combined (uiop:slurp-stream-string (uiop:process-info-output process-info)))
                     (setf exit-code (uiop:wait-process process-info)))))
           (error (c)
             (error 'simple-error :format-control "Bash invocation failed: ~A" :format-arguments (list c))))
      ;; Subprocess leak prevention -- also the timeout's cooperative
      ;; termination path: a signaled tool-timeout unwinds through here.
      (when (and process-info (uiop:process-alive-p process-info))
        (uiop:terminate-process process-info :urgent t))
      (when process-info
        (librecode-runner.tool:unregister-active-subprocess process-info)))
    (if (= exit-code 0)
        (cap-bash-output combined)
        (error 'simple-error :format-control "Command ~S failed with exit code ~D. Output:~%~A"
                             :format-arguments (list command exit-code (cap-bash-output combined))))))

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
                               :properties (:command (:type "string" :description "Command to execute.")
                                            :timeout (:type "number" :description "Optional wall-clock timeout in seconds. If exceeded, the command is terminated and the call fails with a timeout error."))
                               :required #(:command))
                 :capabilities nil
                 :handler #'handle-bash))

(defparameter edit-tool
  (make-instance 'librecode-runner.tool:tool
                 :name "edit"
                 :description "Perform an exact-string replacement within an existing file in the workspace."
                 :parameters '(:type "object"
                               :properties (:filePath (:type "string" :description "Relative path of the file to edit.")
                                            :oldString (:type "string" :description "The exact text to replace.")
                                            :newString (:type "string" :description "The text to replace it with; must differ from oldString.")
                                            :replaceAll (:type "boolean" :description "Replace all occurrences of oldString (default false)."))
                               :required #(:filePath :oldString :newString))
                 :capabilities nil
                 :handler #'handle-edit))

(defun register-builtin-tools (registry)
  "Register the built-in tools (read_file, write_file, bash, and edit) in the given registry."
  (librecode-runner.tool:register-tool registry read-file-tool)
  (librecode-runner.tool:register-tool registry write-file-tool)
  (librecode-runner.tool:register-tool registry bash-tool)
  (librecode-runner.tool:register-tool registry edit-tool)
  registry)

;; Automatically register into default tool registry
(register-builtin-tools librecode-runner.runner::*tool-registry*)
