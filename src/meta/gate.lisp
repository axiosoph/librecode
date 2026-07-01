;;; -*- Mode: Lisp; Syntax: Common-Lisp; indent-tabs-mode: nil; coding: utf-8; Show-Trailing-Whitespace: t -*-
;;;
;;; gate.lisp — Campaign validation gate DSL and subprocess runner
;;;

(in-package #:librecode-meta.gate)

(defun resolve-absolute-binary (cmd &optional directory)
  "Resolve command CMD to an absolute path.
If CMD is already absolute or contains a slash, verify it exists and return it.
Otherwise search the PATH environment variable."
  (let ((cmd-str (namestring cmd)))
    (cond
      ((or (uiop:absolute-pathname-p cmd-str)
           (search "/" cmd-str))
       (let* ((base-dir (or directory *default-pathname-defaults*))
              (path (uiop:merge-pathnames* (uiop:parse-unix-namestring cmd-str)
                                           (uiop:ensure-directory-pathname base-dir)))
              (exists (probe-file path)))
         (if exists
             (namestring exists)
             (error "Command file not found: ~A" path))))
      (t
       (let ((path-env (uiop:getenv "PATH")))
         (if path-env
           (let ((dirs (uiop:split-string path-env :separator ":")))
             (dolist (dir dirs (error "Command not found in PATH: ~A" cmd-str))
               (let ((file (uiop:merge-pathnames* cmd-str (uiop:ensure-directory-pathname dir))))
                 (when (uiop:file-exists-p file)
                   (return (namestring file))))))
           (error "PATH environment variable not set, cannot locate command: ~A" cmd-str)))))))

(defun split-spaces (string)
  "Split a string by space characters, removing empty strings."
  (remove "" (uiop:split-string string :separator " ") :test #'string=))

(defun parse-command (command)
  "Parse command into a list of strings."
  (cond
    ((listp command)
     (mapcar #'string command))
    ((stringp command)
     (split-spaces command))
    (t (error "Invalid command specification: ~A" command))))

(defun resolve-command-list (cmd-list &optional directory)
  "Resolve the first element of CMD-LIST to an absolute path."
  (let* ((binary (car cmd-list))
         (abs-binary (resolve-absolute-binary binary directory)))
    (cons abs-binary (cdr cmd-list))))

(defun run-program-capture (cmd-list &key directory)
  "Run the command CMD-LIST using uiop:launch-program, capturing stdout/stderr."
  (let* ((proc (uiop:launch-program cmd-list
                                    :output :stream
                                    :error-output :stream
                                    :directory directory))
         (stdout (uiop:slurp-stream-string (uiop:process-info-output proc)))
         (stderr (uiop:slurp-stream-string (uiop:process-info-error-output proc)))
         (exit-code (uiop:wait-process proc)))
    (values stdout stderr exit-code)))

(defun resolve-gate-path (path)
  "Resolve PATH against *workspace-root* if bound, otherwise return PATH."
  (let ((root (and (boundp 'librecode-runner.event-store:*workspace-root*)
                   (symbol-value 'librecode-runner.event-store:*workspace-root*))))
    (if (and root (not (uiop:absolute-pathname-p path)))
        (uiop:merge-pathnames* path (uiop:ensure-directory-pathname root))
        path)))

(defun find-dag-apply-contract ()
  "Search for the dag_apply.ncl contract in expected locations."
  (let ((paths (list "ledger/contracts/dag_apply.ncl"
                     "t/contracts/dag_apply.ncl"
                     "../ledger/contracts/dag_apply.ncl")))
    (dolist (p paths (error "dag_apply.ncl contract not found in expected locations."))
      (let ((resolved (resolve-gate-path p)))
        (when (uiop:file-exists-p resolved)
          (return resolved))))))

(defun nickel-contract-violation-p (command exit-code stderr)
  "Check if the command is nickel and the output stderr indicates contract violation."
  (declare (ignore exit-code))
  (and (search "nickel" command :test #'char-equal)
       (or (search "contract broken" stderr :test #'char-equal)
           (search "contract violation" stderr :test #'char-equal)
           (search "cycle detected" stderr :test #'char-equal)
           (search "dangling depends_on" stderr :test #'char-equal)
           (search "duplicate node" stderr :test #'char-equal)
           (search "yaml parse error" stderr :test #'char-equal)
           (search "parse error" stderr :test #'char-equal)
           (search "missing definition" stderr :test #'char-equal))))

(defun run-nickel-export-on-dag (dag-path &optional contract-path)
  "Run nickel export check on campaign DAG path."
  (let* ((dag-resolved (resolve-gate-path dag-path)))
    (unless (uiop:file-exists-p dag-resolved)
      (error "DAG file not found: ~A" dag-resolved))
    (let* ((dag-abs (namestring (truename dag-resolved)))
           (contract-resolved (resolve-gate-path (or contract-path (find-dag-apply-contract)))))
      (unless (uiop:file-exists-p contract-resolved)
        (error "Contract file not found: ~A" contract-resolved))
      (let* ((contract-abs (namestring (truename contract-resolved)))
             (nickel-bin (resolve-absolute-binary "nickel"))
             (cmd-list (list nickel-bin "export" dag-abs "--apply-contract" contract-abs)))
        (multiple-value-bind (stdout stderr exit-code)
            (run-program-capture cmd-list)
          (declare (ignore stdout))
          (if (= exit-code 0)
              t
              (if (nickel-contract-violation-p "nickel" exit-code stderr)
                  (error 'librecode-runner.conditions:protocol-invariant-violation
                         :message stderr
                         :invariant "DAG safety contract")
                  (error 'librecode-runner.conditions:gate-failure
                         :message stderr
                         :command (format nil "~{~A~^ ~}" cmd-list)
                         :exit-code exit-code))))))))

(defun make-keyword-lambda-list (lambda-list)
  "Convert a positional lambda-list to keyword parameters for defgate."
  (if (member '&key lambda-list)
      lambda-list
      (let ((keys nil))
        (dolist (var lambda-list)
          (unless (member var '(&optional &rest &key &aux))
            (push var keys)))
        (append (list '&key) (nreverse keys) (list '&allow-other-keys)))))

(defun expand-defgate (name lambda-list body)
  "Helper function for defgate macro expansion."
  (multiple-value-bind (docstring clauses)
      (if (and (stringp (car body)) (cdr body))
          (values (car body) (cdr body))
          (values nil body))
    (let* ((clauses-alist (mapcar (lambda (c) (cons (car c) (cdr c))) clauses))
           (target-form (second (assoc :target clauses-alist)))
           (verify-form (second (assoc :verify clauses-alist)))
           (worktree-form (second (assoc :worktree clauses-alist)))
           (execute-args (cdr (assoc :execute clauses-alist)))
           (on-failure-form (second (assoc :on-failure clauses-alist)))
           (execute-eval-form (cond
                                ((null execute-args) nil)
                                ((null (cdr execute-args)) (car execute-args))
                                (t `(list ,@execute-args)))))
      (let* ((pkg (or (symbol-package name) *package*))
             (target-sym (intern "TARGET" pkg))
             (worktree-sym (intern "WORKTREE" pkg))
             (exit-code-sym (intern "EXIT-CODE" pkg))
             (stdout-sym (intern "STDOUT" pkg))
             (stderr-sym (intern "STDERR" pkg))
             (success-sym (intern "SUCCESS" pkg))
             (cmd-list-sym (intern "CMD-LIST" pkg))
             (body-forms nil)
             (kw-lambda-list (make-keyword-lambda-list lambda-list)))
        (when execute-eval-form
          (push `(multiple-value-bind (out err code)
                     (let ((resolved-cmd (librecode-meta.gate::resolve-command-list ,cmd-list-sym ,(if worktree-form worktree-sym nil))))
                       (librecode-meta.gate::run-program-capture resolved-cmd :directory ,(if worktree-form worktree-sym nil)))
                   (setf ,stdout-sym out
                         ,stderr-sym err
                         ,exit-code-sym code
                         ,success-sym (= code 0)))
                body-forms))
        (when verify-form
          (push `(when ,success-sym
                   (setf ,success-sym (not (null ,verify-form))))
                body-forms))
        (let ((failure-handling
                (if on-failure-form
                    on-failure-form
                    `(if (and ,exit-code-sym (/= ,exit-code-sym 0))
                         (if (librecode-meta.gate::nickel-contract-violation-p (car ,cmd-list-sym) ,exit-code-sym ,stderr-sym)
                             (error 'librecode-runner.conditions:protocol-invariant-violation
                                    :message ,stderr-sym
                                    :invariant "DAG safety contract")
                             (error 'librecode-runner.conditions:gate-failure
                                    :message ,stderr-sym
                                    :command (format nil "~{~A~^ ~}" ,cmd-list-sym)
                                    :exit-code ,exit-code-sym))
                         (error 'librecode-runner.conditions:gate-failure
                                :message "Verification failed"
                                :command "verify"
                                :exit-code -1)))))
          `(progn
             (defun ,name ,kw-lambda-list
               ,@(when docstring (list docstring))
               (let* (,@(when target-form `((,target-sym (librecode-meta.gate::resolve-gate-path ,target-form))))
                      ,@(when worktree-form `((,worktree-sym (librecode-meta.gate::resolve-gate-path ,worktree-form)))))
                 (declare (ignorable ,@(when target-form (list target-sym))
                                     ,@(when worktree-form (list worktree-sym))))
                 (let ((,success-sym t)
                       ,exit-code-sym
                       ,stdout-sym
                       ,stderr-sym
                       ,@(when execute-eval-form
                           `((,cmd-list-sym (let ((raw-cmd ,execute-eval-form))
                                              (if (listp raw-cmd)
                                                  raw-cmd
                                                  (librecode-meta.gate::split-spaces raw-cmd)))))))
                   (declare (ignorable ,success-sym ,exit-code-sym ,stdout-sym ,stderr-sym
                                       ,@(when execute-eval-form (list cmd-list-sym))))
                   ,@(nreverse body-forms)
                   (if ,success-sym
                       t
                       ,failure-handling))))))))))

(defmacro defgate (name lambda-list &body body)
  "Define a validation gate NAME with LAMBDA-LIST and BODY."
  (expand-defgate name lambda-list body))

(defun run-gate (gate &rest args &key (contract nil) &allow-other-keys)
  "Run the verification gate GATE.
If GATE is a symbol, retrieve its definition (or run it as a function).
If GATE is a string or pathname, run nickel export over the campaign DAG."
  (cond
    ((symbolp gate)
     (apply gate args))
    ((or (pathnamep gate) (stringp gate))
     (run-nickel-export-on-dag gate contract))
    (t (error "Invalid gate specification: ~A" gate))))
