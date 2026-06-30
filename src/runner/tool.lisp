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

(defun key-to-string (key)
  (if (symbolp key)
      (string-downcase (symbol-name key))
      (format nil "~A" key)))

#+sbcl
(sb-ext:without-package-locks
  (defun cl-jschema::json-false-p (value)
    (or (eq value nil) (eq value 'yason:false)))
  (defun cl-jschema::json-true-p (value)
    (or (eq value t) (eq value 'yason:true)))
  (defun cl-jschema::json-null-p (value)
    (or (eq value 'null) (eq value :null)))
  (let ((array-spec (find "array" cl-jschema::*type-specs* :key #'cl-jschema::type-spec-name :test #'equal)))
    (when array-spec
      (setf (cl-jschema::type-spec-lisp-type array-spec) 'vector))))
#-sbcl
(progn
  (defun cl-jschema::json-false-p (value)
    (or (eq value nil) (eq value 'yason:false)))
  (defun cl-jschema::json-true-p (value)
    (or (eq value t) (eq value 'yason:true)))
  (defun cl-jschema::json-null-p (value)
    (or (eq value 'null) (eq value :null)))
  (let ((array-spec (find "array" cl-jschema::*type-specs* :key #'cl-jschema::type-spec-name :test #'equal)))
    (when array-spec
      (setf (cl-jschema::type-spec-lisp-type array-spec) 'vector))))

(defun coerce-to-hash-table (val)
  (cond
    ((eq val nil) 'yason:false)
    ((eq val 'yason:false) 'yason:false)
    ((eq val 'yason:true) 'yason:true)
    ((eq val t) 'yason:true)
    ((or (eq val :null) (eq val 'null)) :null)
    ((hash-table-p val)
     (let ((new-ht (make-hash-table :test 'equal)))
       (maphash (lambda (k v)
                  (setf (gethash (key-to-string k) new-ht)
                        (coerce-to-hash-table v)))
                val)
       new-ht))
    ((plist-p val)
     (let ((ht (make-hash-table :test 'equal)))
       (loop for (k v) on val by #'cddr
             do (setf (gethash (key-to-string k) ht)
                      (coerce-to-hash-table v)))
       ht))
    ((vectorp val)
     (if (stringp val)
         val
         (map 'vector #'coerce-to-hash-table val)))
    ((listp val)
     ;; Represent JSON arrays as Lisp vectors in coerced output
     (map 'vector #'coerce-to-hash-table val))
    ((and (symbolp val) (not (member val '(t nil null yason:true yason:false))))
     (key-to-string val))
    (t val)))

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

(defun sanitize-parsed-arguments (val)
  "Recursively traverse parsed JSON object, converting any vectors (except strings)
to simple-vectors so that cl-jschema can validate them."
  (cond
    ((hash-table-p val)
     (maphash (lambda (k v)
                (setf (gethash k val) (sanitize-parsed-arguments v)))
              val)
     val)
    ((vectorp val)
     (if (stringp val)
         val
         (map 'simple-vector #'sanitize-parsed-arguments val)))
    (t val)))

(defun validate-arguments (schema arguments)
  "Validate arguments against schema. schema is a plist.
Arguments is a plist."
  (let* ((schema-json (if schema
                          (with-output-to-string (s)
                            (yason:encode (coerce-to-hash-table schema) s))
                          "{}"))
         (arguments-json (if arguments
                             (with-output-to-string (s)
                               (yason:encode (coerce-to-hash-table arguments) s))
                             "{}"))
         (parsed-schema (cl-jschema:parse schema-json))
         (parsed-arguments (let ((yason:*parse-json-booleans-as-symbols* t)
                                 (yason:*parse-json-null-as-keyword* t)
                                 (yason:*parse-json-arrays-as-vectors* t))
                             (sanitize-parsed-arguments (yason:parse arguments-json)))))
    (handler-case
        (cl-jschema:validate parsed-schema parsed-arguments)
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
