;;; -*- Mode: Lisp; Syntax: Common-Lisp; indent-tabs-mode: nil; coding: utf-8; Show-Trailing-Whitespace: t -*-
;;;
;;; tool.lisp — Tool execution, registry, and deep plist merging
;;;

(in-package #:librecode-runner.tool)

(defclass tool ()
  ((name :initarg :name :reader tool-name :type string)
   (description :initarg :description :reader tool-description :type string)
   (parameters :initarg :parameters :reader tool-parameters :type list)
   (capabilities :initarg :capabilities :reader tool-capabilities :type list :initform nil)
   (handler :initarg :handler :reader tool-handler :type function))
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

(defun validate-arguments (schema arguments)
  "Validate arguments against schema. schema is a plist.
Arguments is a plist."
  (let ((properties (getf schema :properties))
        (required (getf schema :required)))
    ;; Check required keys
    (dolist (req required)
      (let* ((req-key (if (stringp req) (intern (string-upcase req) :keyword) req))
             (present (nth-value 1 (get-properties arguments (list req-key)))))
        (unless present
          (error 'simple-error :format-control "Missing required parameter: ~A" :format-arguments (list req)))))
    ;; Check types of present arguments
    (loop for (key val) on arguments by #'cddr
          do (let* ((prop-schema (getf properties key))
                    (expected-type (getf prop-schema :type)))
               (when (and prop-schema expected-type)
                 (cond
                   ((equal expected-type "string")
                    (unless (stringp val)
                      (error 'simple-error :format-control "Parameter ~A must be a string, got ~S" :format-arguments (list key val))))
                   ((equal expected-type "integer")
                    (unless (integerp val)
                      (error 'simple-error :format-control "Parameter ~A must be an integer, got ~S" :format-arguments (list key val))))
                   ((equal expected-type "boolean")
                    (unless (typep val 'boolean)
                      (error 'simple-error :format-control "Parameter ~A must be a boolean, got ~S" :format-arguments (list key val))))
                   ((equal expected-type "number")
                    (unless (numberp val)
                      (error 'simple-error :format-control "Parameter ~A must be a number, got ~S" :format-arguments (list key val))))))))))

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

(defun execute-tool (tool arguments)
  "Synchronously execute the tool with given arguments."
  (validate-arguments (tool-parameters tool) arguments)
  (funcall (tool-handler tool) arguments))

(defun execute-tool-async (tool arguments &key timeout)
  "Asynchronously execute the tool in a worker thread, blocking the current thread until completion or timeout."
  (validate-arguments (tool-parameters tool) arguments)
  (let* ((lock (bt:make-lock "tool-execution-lock"))
         (cv (bt:make-condition-variable :name "tool-execution-cv"))
         (finished-p nil)
         (result-val nil)
         (result-err nil)
         (worker-thread nil))
    (setf worker-thread
          (bt:make-thread
           (lambda ()
             (multiple-value-bind (val err)
                 (handler-case
                     (funcall (tool-handler tool) arguments)
                   (error (c)
                     (values nil c)))
               (bt:with-lock-held (lock)
                 (if err
                     (setf result-err err)
                     (setf result-val val))
                 (setf finished-p t)
                 (bt:condition-notify cv))))
           :name (format nil "tool-worker-~A" (tool-name tool))))
    (unwind-protect
         (bt:with-lock-held (lock)
           (if timeout
               (let ((start-time (get-universal-time)))
                 (loop until finished-p
                       do (let ((res (bt:condition-wait cv lock :timeout timeout)))
                            (unless res
                              (unless finished-p
                                (error 'librecode-runner.conditions:tool-timeout
                                       :tool-id (tool-name tool)
                                       :duration timeout
                                       :message (format nil "Tool ~A execution exceeded timeout of ~A seconds."
                                                        (tool-name tool) timeout)))))
                            (let ((elapsed (- (get-universal-time) start-time)))
                              (when (>= elapsed timeout)
                                (unless finished-p
                                  (error 'librecode-runner.conditions:tool-timeout
                                         :tool-id (tool-name tool)
                                         :duration timeout
                                         :message (format nil "Tool ~A execution exceeded timeout of ~A seconds."
                                                          (tool-name tool) timeout)))))))
               (loop until finished-p
                     do (bt:condition-wait cv lock)))
           (if result-err
               (error result-err)
               result-val))
      ;; Cleanup: safely terminate worker thread if it is still running
      (when (and worker-thread (bt:thread-alive-p worker-thread))
        (handler-case
            (bt:destroy-thread worker-thread)
          (error () nil))))))
