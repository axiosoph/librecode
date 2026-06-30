;;; -*- Mode: Lisp; Syntax: Common-Lisp; indent-tabs-mode: nil; coding: utf-8; Show-Trailing-Whitespace: t -*-
;;;
;;; audit-tests.lisp — Unit, property, and concurrency tests for librecode audit trail
;;;

(defpackage #:librecode-test.audit
  (:use #:cl
        #:fiveam
        #:check-it
        #:librecode-runner.audit)
  (:shadowing-import-from #:check-it #:*num-trials*)
  (:export #:audit-suite))

(in-package #:librecode-test.audit)

(def-suite audit-suite
  :description "Suite for audit logging tests.")

(in-suite audit-suite)

;;; --- Sandbox Fixtures ---

(defun create-temp-directory-path ()
  (let* ((tempdir (uiop:temporary-directory))
         (unique-dir (make-pathname :directory (append (pathname-directory tempdir)
                                                       (list (format nil "librecode-audit-sandbox-~A-~A"
                                                                     (get-universal-time)
                                                                     (random 1000000)))))))
    (ensure-directories-exist unique-dir)
    unique-dir))

(defun delete-directory-and-files (path)
  (let ((path (uiop:ensure-directory-pathname path)))
    (when (uiop:directory-exists-p path)
      (uiop:delete-directory-tree path
                                  :validate (lambda (p)
                                              (search "librecode-audit-sandbox" (namestring p)))
                                  :if-does-not-exist :keep))))

(defmacro with-tmp-sandbox ((path-var) &body body)
  `(let ((,path-var (create-temp-directory-path)))
     (unwind-protect
          (progn ,@body)
       (handler-case
           (delete-directory-and-files ,path-var)
         (serious-condition () nil)))))

;;; --- Isomorphism check helper ---

(defun sexp-json-equivalent-p (sexp json)
  (cond
    ((null sexp) (null json))
    ((symbolp sexp)
     (and (stringp json)
          (string-equal (symbol-name sexp) json)))
    ((numberp sexp)
     (and (numberp json) (= sexp json)))
    ((stringp sexp)
     (and (stringp json) (string= sexp json)))
    ((hash-table-p json)
     (let ((sexp-ht (librecode-runner.audit::coerce-to-json-compatible sexp)))
       (and (hash-table-p sexp-ht)
            (= (hash-table-count sexp-ht) (hash-table-count json))
            (loop for k being the hash-keys of sexp-ht using (hash-value v-sexp)
                  always (multiple-value-bind (v-json found) (gethash k json)
                           (and found (sexp-json-equivalent-p v-sexp v-json)))))))
    ((listp sexp)
     (and (or (listp json) (vectorp json))
          (= (length sexp) (length json))
          (every #'sexp-json-equivalent-p sexp (coerce json 'list))))
    (t (equal sexp json))))

;;; --- Property Generator for Events ---

(test test-dual-format-parity
  "Dual Format Parity (Isomorphism): Property test verifying S-expression and JSON parity."
  (with-tmp-sandbox (dir)
    (let ((librecode-runner.event-store:*workspace-root* dir))
      (init-audit-logger)
      (unwind-protect
           (is-true
            (check-it
             (generator
              (map (lambda (pairs)
                     (loop for (k v) in pairs
                           append (list k v)))
                   (list (tuple (map (lambda (str) (intern (string-upcase str) :keyword))
                                     (string :min-length 1 :max-length 8))
                                (or (integer)
                                    (string :min-length 1 :max-length 8)
                                    (boolean)))
                         :min-length 1 :max-length 5)))
             (lambda (event)
               (write-audit-event event)
               ;; Briefly sleep to ensure processing / write (though we could also test post shutdown)
               (sleep 0.001)
               t)))
        (shutdown-audit-logger))
      
      ;; Verify logs exist and match
      (let ((lisp-path (uiop:merge-pathnames* #p".ledger/log/audit.lisp-expr" dir))
            (json-path (uiop:merge-pathnames* #p".ledger/log/audit.jsonl" dir)))
        (is-true (uiop:file-exists-p lisp-path))
        (is-true (uiop:file-exists-p json-path))
        
        (let ((sexps (with-open-file (s lisp-path :direction :input :external-format :utf-8)
                       (loop for x = (read s nil :eof)
                             until (eq x :eof)
                             collect x)))
              (jsons (with-open-file (s json-path :direction :input :external-format :utf-8)
                       (loop for line = (read-line s nil :eof)
                             until (eq line :eof)
                             collect (com.inuoe.jzon:parse line)))))
          (is (= (length sexps) (length jsons)))
          (is-true (every #'sexp-json-equivalent-p sexps jsons)))))))

;;; --- Monotonicity (Sequential Order) ---

(test test-sequential-order
  "Sequential Order Preservation (Monotonicity): Single-thread sequential write ordering."
  (with-tmp-sandbox (dir)
    (let ((librecode-runner.event-store:*workspace-root* dir)
          (events (loop for i from 1 to 50
                        collect `(:seq ,i :msg ,(format nil "Event number ~A" i)))))
      (init-audit-logger)
      (dolist (e events)
        (write-audit-event e))
      (shutdown-audit-logger)
      
      (let ((lisp-path (uiop:merge-pathnames* #p".ledger/log/audit.lisp-expr" dir))
            (json-path (uiop:merge-pathnames* #p".ledger/log/audit.jsonl" dir)))
        (let ((sexps (with-open-file (s lisp-path :direction :input :external-format :utf-8)
                       (loop for x = (read s nil :eof)
                             until (eq x :eof)
                             collect x)))
              (jsons (with-open-file (s json-path :direction :input :external-format :utf-8)
                       (loop for line = (read-line s nil :eof)
                             until (eq line :eof)
                             collect (com.inuoe.jzon:parse line)))))
          (is (= 50 (length sexps)))
          (is (= 50 (length jsons)))
          ;; Check exact sequence order
          (loop for i from 0 to 49
                do (is (= (1+ i) (getf (nth i sexps) :seq)))
                   (is (= (1+ i) (gethash "seq" (nth i jsons))))))))))

;;; --- Scheduling Permutation Invariance (Metamorphic) & Thread Safety ---

(test test-scheduling-permutation
  "Scheduling Permutation Invariance (Metamorphic): 50 worker threads write concurrently."
  (with-tmp-sandbox (dir)
    (let* ((librecode-runner.event-store:*workspace-root* dir)
           (num-threads 50)
           (events-per-thread 10)
           (total-events (* num-threads events-per-thread))
           (threads nil)
           (expected-events (make-hash-table :test 'equal)))
      
      (init-audit-logger)
      
      ;; Spawn threads writing concurrently
      (dotimes (i num-threads)
        (let ((thread-id i))
          (push (bt:make-thread
                 (lambda ()
                   (dotimes (j events-per-thread)
                     (let ((event `(:thread-id ,thread-id :index ,j)))
                       (write-audit-event event)
                       (sleep (random 0.005))))))
                threads)))
      
      ;; Wait for all threads to finish
      (dolist (th threads)
        (bt:join-thread th))
      
      (shutdown-audit-logger)
      
      (let ((lisp-path (uiop:merge-pathnames* #p".ledger/log/audit.lisp-expr" dir))
            (json-path (uiop:merge-pathnames* #p".ledger/log/audit.jsonl" dir)))
        (let ((sexps (with-open-file (s lisp-path :direction :input :external-format :utf-8)
                       (loop for x = (read s nil :eof)
                             until (eq x :eof)
                             collect x)))
              (jsons (with-open-file (s json-path :direction :input :external-format :utf-8)
                       (loop for line = (read-line s nil :eof)
                             until (eq line :eof)
                             collect (com.inuoe.jzon:parse line)))))
          
          (is (= total-events (length sexps)))
          (is (= total-events (length jsons)))
          
          ;; Permutation invariance: check set equivalence and counts
          (dolist (s sexps)
            (let ((tid (getf s :thread-id))
                  (idx (getf s :index)))
              (is-true (and (integerp tid) (>= tid 0) (< tid num-threads)))
              (is-true (and (integerp idx) (>= idx 0) (< idx events-per-thread)))
              (let ((key (format nil "~A-~A" tid idx)))
                (is-true (null (gethash key expected-events)))
                (setf (gethash key expected-events) t))))
          
          (is (= total-events (hash-table-count expected-events)))
          
          ;; Also check S-exp vs JSON parity
          (is-true (every #'sexp-json-equivalent-p sexps jsons)))))))

;;; --- Thread Safety & Clean Termination ---

(test test-thread-safety-termination
  "Thread Safety & Termination: Sustain concurrent writes, cleanly stop without orphan threads."
  (with-tmp-sandbox (dir)
    (let ((librecode-runner.event-store:*workspace-root* dir))
      (init-audit-logger)
      
      ;; Log some events from multiple threads
      (let ((threads (loop for i from 1 to 10
                           collect (bt:make-thread
                                    (lambda ()
                                      (dotimes (j 5)
                                        (write-audit-event `(:val ,j))))))))
        (dolist (th threads) (bt:join-thread th)))
      
      ;; Shutdown the logger
      (shutdown-audit-logger)
      
      ;; Verify that the background thread is terminated and reaped
      (sleep 0.1)
      ;; Verify that no thread named "audit-logger-thread" is alive.
      (is-true (not (member "audit-logger-thread"
                            (mapcar #'bt:thread-name (bt:all-threads))
                            :test #'string=))))))
