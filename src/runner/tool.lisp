;;; -*- Mode: Lisp; Syntax: Common-Lisp; indent-tabs-mode: nil; coding: utf-8; Show-Trailing-Whitespace: t -*-
;;;
;;; tool.lisp — Tool execution, registry, and deep plist merging
;;;

(in-package #:librecode-runner.tool)

(defvar *active-subprocesses* nil
  "Special variable bound dynamically to track active subprocesses launched by tool execution.
Bound to (cons registry lock) where registry is (cons processes cancelled-p).")

(defun register-active-subprocess (process-info)
  "Register an active subprocess in the current execution context.
If the context has been cancelled, terminates the process immediately."
  (when (and (boundp '*active-subprocesses*) *active-subprocesses*)
    (destructuring-bind (registry . lock) *active-subprocesses*
      (bt:with-lock-held (lock)
        (if (cdr registry)
            (handler-case (uiop:terminate-process process-info :urgent t)
              (error () nil))
            (push process-info (car registry)))))))

(defun unregister-active-subprocess (process-info)
  "Unregister an active subprocess from the current execution context."
  (when (and (boundp '*active-subprocesses*) *active-subprocesses*)
    (destructuring-bind (registry . lock) *active-subprocesses*
      (bt:with-lock-held (lock)
        (setf (car registry) (delete process-info (car registry)))))))

(defun tool-cancelled-p ()
  "Return t if the current tool execution context has been cancelled."
  (when (and (boundp '*active-subprocesses*) *active-subprocesses*)
    (destructuring-bind (registry . lock) *active-subprocesses*
      (bt:with-lock-held (lock)
        (cdr registry)))))

(defvar *path-locks-registry* (cons (make-hash-table :test 'equal) (bt:make-lock "path-locks-registry-lock"))
  "Registry of per-resolved-path locks serializing file-touching tool calls
(read_file/write_file/edit) against the SAME path within a turn's
concurrently-dispatched tool_calls. Bound to (cons hash-table meta-lock),
mirroring *active-subprocesses*'s (registry . lock) shape: the hash table
maps a resolved path's namestring to the bt:lock guarding that single file's
critical section. Locks are created lazily on first use and never removed --
the table only ever holds one entry per distinct path a tool call has
touched, and retaining a small lock object for the life of the process is
cheap. Different paths get different locks, so concurrent calls to distinct
files never block each other.")

(defun get-path-lock (path-key)
  "Return the bt:lock serializing tool access to PATH-KEY (a resolved path's
namestring), creating it under the registry's meta-lock on first use."
  (destructuring-bind (table . meta-lock) *path-locks-registry*
    (bt:with-lock-held (meta-lock)
      (or (gethash path-key table)
          (setf (gethash path-key table)
                (bt:make-lock (format nil "path-lock-~A" path-key)))))))

(defmacro with-path-lock ((path-key) &body body)
  "Execute BODY while holding the single mutual-exclusion lock for PATH-KEY (a
resolved path's namestring). Concurrent tool_calls -- read_file, write_file,
edit -- that resolve to the SAME path serialize on this lock, so edit's
read -> compute -> write critical section can never interleave with another
concurrent call against the same file (the race that silently drops one
side's write); calls against DIFFERENT paths acquire different locks and
are not serialized against each other."
  (let ((lock-var (gensym "PATH-LOCK")))
    `(let ((,lock-var (get-path-lock ,path-key)))
       (bt:with-lock-held (,lock-var)
         ,@body))))

(defclass tool ()
  ((name :initarg :name :reader tool-name :type string)
   (description :initarg :description :reader tool-description :type string)
   (parameters :initarg :parameters :reader tool-parameters :type list)
   (capabilities :initarg :capabilities :reader tool-capabilities :type list :initform nil)
   (handler :initarg :handler :reader tool-handler :type function)
   (parsed-schema :reader tool-parsed-schema :initform nil))
  (:documentation "A dynamic executable tool definition."))

(defclass tool-registry ()
  ((tools :initform (make-hash-table :test 'equal) :reader registry-tools)
   (lock :initform (bt:make-lock "tool-registry-lock") :reader registry-lock))
  (:documentation "A thread-safe registry of tools."))

(defun register-tool (registry tool)
  "Register a tool in the registry."
  (bt:with-lock-held ((registry-lock registry))
    (setf (gethash (tool-name tool) (registry-tools registry)) tool))
  tool)

(defun find-key-value-position (plist key)
  "Find the position of the key in plist, checking only key positions (even indices).
Returns the index of the key if found, or nil."
  (loop for idx from 0 by 2
        for tail = plist then (cddr tail)
        while tail
        do (when (eq (car tail) key)
             (return idx))))

(defun plist-p (x)
  "Return t if x is a property list."
  (and (listp x)
       (consp x)
       (let ((len (list-length x)))
         (and len
              (evenp len)
              (loop for k in x by #'cddr
                    always (symbolp k))))))

(defun key-to-string (key)
  (if (symbolp key)
      (string-downcase (symbol-name key))
      (format nil "~A" key)))

(defun coerce-to-hash-table (val &optional schema)
  (cond
    ((eq val nil) nil)
    ((eq val t) t)
    ((or (eq val :null) (eq val 'null)) 'null)
    ((stringp val) val)
    ((hash-table-p val)
     (let ((new-ht (make-hash-table :test 'equal)))
       (maphash (lambda (k v)
                  (let* ((k-str (key-to-string k))
                         (k-keyword (intern (string-upcase k-str) :keyword))
                         (sub-schema (and (listp schema) (getf (getf schema :properties) k-keyword))))
                    (setf (gethash k-str new-ht)
                          (coerce-to-hash-table v sub-schema))))
                val)
       new-ht))
    ((and (listp schema) (equal (getf schema :type) "array"))
     (let ((items-schema (getf schema :items)))
       (map 'vector (lambda (item) (coerce-to-hash-table item items-schema)) val)))
    ((plist-p val)
     (let ((ht (make-hash-table :test 'equal)))
       (loop for (k v) on val by #'cddr
             do (let* ((k-str (key-to-string k))
                       (k-keyword (intern (string-upcase k-str) :keyword))
                       (sub-schema (and (listp schema) (getf (getf schema :properties) k-keyword))))
                  (cond
                    ((and (member k-keyword '(:required :enum)) (listp v))
                     (setf (gethash k-str ht)
                           (map 'vector (lambda (item)
                                          (if (symbolp item)
                                              (key-to-string item)
                                              (coerce-to-hash-table item)))
                                v)))
                    (t
                     (setf (gethash k-str ht)
                           (coerce-to-hash-table v sub-schema))))))
       ht))
    ((vectorp val)
     (map 'vector (lambda (item) (coerce-to-hash-table item)) val))
    ((listp val)
     ;; Represent JSON arrays as Lisp vectors in coerced output
     (map 'vector (lambda (item) (coerce-to-hash-table item)) val))
    ((and (symbolp val) (not (member val '(t nil null))))
     (key-to-string val))
    (t val)))

(defmethod initialize-instance :after ((self tool) &key)
  "Pre-parse and cache the schema on the tool."
  (let* ((params (slot-value self 'parameters))
         (schema-ht (if params (coerce-to-hash-table params) nil))
         (schema-json (if schema-ht
                          (com.inuoe.jzon:stringify schema-ht)
                          "{}")))
    (setf (slot-value self 'parsed-schema)
          (cl-jschema:parse schema-json))))

(defun coerce-arguments-by-schema (properties arguments)
  "Recursively coerce arguments plist based on the properties schema plist.
If a property is of type 'object' and its argument is nil/empty list,
coerce it to an empty hash-table so cl-jschema can validate its required fields."
  (let ((coerced (copy-list arguments)))
    (loop for (key val) on coerced by #'cddr
          do (let* ((prop-schema (getf properties key))
                    (prop-type (getf prop-schema :type)))
               (cond
                 ((and (equal prop-type "object") (null val))
                  (setf (getf coerced key) (make-hash-table :test 'equal)))
                 ((and (equal prop-type "object") (plist-p val))
                  (let ((sub-properties (getf prop-schema :properties)))
                    (setf (getf coerced key)
                          (coerce-arguments-by-schema sub-properties val))))
                 ((and (equal prop-type "array") (or (listp val) (vectorp val)))
                  (let* ((items-schema (getf prop-schema :items))
                         (items-type (getf items-schema :type)))
                    (setf (getf coerced key)
                          (map 'vector
                               (lambda (item)
                                 (cond
                                   ((and (equal items-type "object") (null item))
                                    (make-hash-table :test 'equal))
                                   ((and (equal items-type "object") (plist-p item))
                                    (coerce-arguments-by-schema (getf items-schema :properties) item))
                                   (t (coerce-to-hash-table item items-schema))))
                               val)))))))
    coerced))

(defun deep-merge-plists (plist1 plist2)
  "Recursively merge two property lists.
If a key exists in both and both values are plists, recursively merge them.
Otherwise, the value from plist2 overrides plist1."
  (cond
    ((null plist1) plist2)
    ((null plist2) plist1)
    ((not (plist-p plist1)) plist2)
    ((not (plist-p plist2)) plist2)
    (t
     (let ((result (copy-list plist1)))
       (loop for (k2 v2) on plist2 by #'cddr
             do (let ((k1-pos (find-key-value-position result k2)))
                  (if k1-pos
                      (let ((v1 (elt result (1+ k1-pos))))
                        (if (and (plist-p v1) (plist-p v2))
                            (setf (nth (1+ k1-pos) result) (deep-merge-plists v1 v2))
                            (setf (nth (1+ k1-pos) result) v2)))
                      (setf result (nconc result (list k2 v2))))))
       result))))

(defun validate-arguments (tool arguments)
  "Validate arguments against tool parameters schema.
Eliminates redundant JSON serialization."
  (let* ((schema (tool-parameters tool))
         (parsed-schema (tool-parsed-schema tool))
         (properties (getf schema :properties))
         (coerced-args (if properties
                           (coerce-arguments-by-schema properties arguments)
                           arguments))
         (coerced-args-ht (or (coerce-to-hash-table coerced-args schema)
                              (make-hash-table :test 'equal))))
    (handler-case
        (cl-jschema:validate parsed-schema coerced-args-ht)
      (cl-jschema:invalid-json (c)
        (let* ((errors (cl-jschema:invalid-json-errors c))
               (msg (format nil "JSON Schema validation failed: ~{~A at ~A~^; ~}"
                            (mapcan (lambda (err)
                                      (list (or (cl-jschema:invalid-json-value-error-message err) "Invalid value")
                                            (or (cl-jschema:invalid-json-value-json-pointer err) "/")))
                                    errors))))
          (error 'simple-error :format-control "~A" :format-arguments (list msg)))))))

(defun materialize-tools (registry agent model-capabilities)
  "Filter registered tools by permissions and capabilities, and return their plist representations."
  (let ((tools nil))
    (bt:with-lock-held ((registry-lock registry))
      (maphash (lambda (name tool)
                 (declare (ignore name))
                 (push tool tools))
               (registry-tools registry)))
    ;; Filter and map
    (let ((result nil))
      (dolist (tool tools)
        (let ((name (tool-name tool))
              (req-caps (tool-capabilities tool)))
          ;; 1. Check ruleset/permissions
          (when (handler-case
                    (let ((static-effect (librecode-runner.agent:evaluate-permissions agent "execute_tool" name)))
                      (unless (eq static-effect :deny)
                        (let* ((saved-rules (librecode-runner.agent::load-saved-rules))
                               (merged-agent (make-instance 'librecode-runner.agent:agent
                                                            :id (librecode-runner.agent:agent-id agent)
                                                            :ruleset (append (librecode-runner.agent:agent-ruleset agent) saved-rules)
                                                            :system-context (librecode-runner.agent:agent-system-context agent)))
                               (effect (librecode-runner.agent:evaluate-permissions merged-agent "execute_tool" name)))
                          (not (eq effect :deny)))))
                  (librecode-runner.conditions:denied-error () nil))
            ;; 2. Check model capabilities
            (when (subsetp req-caps model-capabilities :test #'eq)
              (push (list :name name
                          :description (tool-description tool)
                          :parameters (tool-parameters tool))
                    result)))))
      result)))

(defparameter *default-tool-timeout* 60
  "Default wall-clock timeout, in seconds, applied to a tool call on the live
execution path (RUN-TOOL-WORKER) when the call's own arguments don't specify
one. 60s balances a genuinely slow bash command (build, install, long-running
script) against a test suite exercising the no-explicit-timeout path not
taking forever; individual tool calls that need longer should pass their own
:timeout argument (e.g. bash's), which always takes precedence over this
default.")

(defun execute-tool (tool arguments)
  "Synchronously execute the tool with given arguments."
  (validate-arguments tool arguments)
  (funcall (tool-handler tool) arguments))

(defun execute-tool-async (tool arguments &key timeout)
  "Asynchronously execute the tool in a worker thread, blocking the current thread until completion or timeout."
  (validate-arguments tool arguments)
  (let* ((lock (bt:make-lock "tool-execution-lock"))
         (cv (bt:make-condition-variable :name "tool-execution-cv"))
         (finished-p nil)
         (result-val nil)
         (result-err nil)
         (worker-thread nil)
         ;; Cooperative cancellation tracking
         (registry (cons nil nil))
         (procs-lock (bt:make-lock "tool-active-procs-lock"))
         (active-subprocs-binding (cons registry procs-lock)))
    (setf worker-thread
          (bt:make-thread
           (librecode-runner.protocol:with-session-context-captured
             (let ((*active-subprocesses* active-subprocs-binding))
               (multiple-value-bind (val err)
                   (handler-case
                       (funcall (tool-handler tool) arguments)
                     (serious-condition (c)
                       (values nil c)))
                 (bt:with-lock-held (lock)
                   (if err
                       (setf result-err err)
                       (setf result-val val))
                   (setf finished-p t)
                   (bt:condition-notify cv)))))
           :name (format nil "tool-worker-~A" (tool-name tool))))
    (unwind-protect
         (bt:with-lock-held (lock)
           (if timeout
               (let* ((start-time (get-internal-real-time))
                      (timeout-units (* timeout internal-time-units-per-second)))
                 (loop until finished-p
                       do (let* ((elapsed (- (get-internal-real-time) start-time))
                                 (remaining-units (- timeout-units elapsed)))
                            (when (<= remaining-units 0)
                              (error 'librecode-runner.conditions:tool-timeout
                                     :tool-id (tool-name tool)
                                     :duration timeout
                                     :message (format nil "Tool ~A execution exceeded timeout of ~A seconds."
                                                      (tool-name tool) timeout)))
                            (let* ((remaining-seconds (float (/ remaining-units internal-time-units-per-second) 1.0))
                                   (res (bt:condition-wait cv lock :timeout remaining-seconds)))
                              (unless res
                                (unless finished-p
                                  (error 'librecode-runner.conditions:tool-timeout
                                         :tool-id (tool-name tool)
                                         :duration timeout
                                         :message (format nil "Tool ~A execution exceeded timeout of ~A seconds."
                                                          (tool-name tool) timeout))))))))
               (loop until finished-p
                     do (bt:condition-wait cv lock)))
           (if result-err
               (error result-err)
               result-val))
      ;; Cleanup: terminate active subprocesses to unblock the worker thread
      ;; and let it exit naturally.
      (let ((procs-to-kill nil))
        (bt:with-lock-held (procs-lock)
          (setf (cdr registry) t)
          (setf procs-to-kill (car registry))
          (setf (car registry) nil))
        (dolist (proc procs-to-kill)
          (when (and proc (uiop:process-alive-p proc))
            (handler-case
                (uiop:terminate-process proc :urgent t)
              (error () nil))))))))
