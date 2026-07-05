;;; -*- Mode: Lisp; Syntax: Common-Lisp; indent-tabs-mode: nil; coding: utf-8; Show-Trailing-Whitespace: t -*-
;;;
;;; failure-relay-tests.lisp — Unit tests for the failure-relay thread propagation primitive
;;;

(defpackage #:librecode-test.failure-relay
  (:use #:cl #:fiveam)
  (:export #:failure-relay-suite))
(in-package #:librecode-test.failure-relay)

(def-suite failure-relay-suite :description "Test failure relay primitive")
(in-suite failure-relay-suite)

(test test-failure-relay-synthetic
  "Verify that failure-relay successfully transports descriptors, blocks context, and invokes custom restarts."
  (let* ((supervisor-mbox (librecode-runner.protocol:make-mailbox :name "test-supervisor"))
         (worker-mbox (librecode-runner.protocol:make-mailbox :name "test-worker"))
         (step-tracker nil)
         (worker-thread
           (bt:make-thread
            (lambda ()
              (push :worker-start step-tracker)
              (loop
                (restart-case
                    (librecode-runner.protocol:with-failure-relay
                        (supervisor-mbox
                         worker-mbox
                         :recovery-menu '((use-alternative) (retry-computation))
                         :message-factory (lambda (desc reply-mbox recovery-menu)
                                            (declare (ignore recovery-menu))
                                            (list :custom-failure desc reply-mbox))
                         :apply-choice (lambda (choice args)
                                         (let ((restart (find-restart choice)))
                                           (if restart
                                               (apply #'invoke-restart restart args)
                                               (error "Restart ~A not found" choice)))))
                      (push :eval-site step-tracker)
                      (error 'librecode-runner.conditions:provider-error
                             :message "Synthetic error"
                             :endpoint "/test"
                             :provider "synthetic-provider")
                      (push :should-not-reach step-tracker)
                      (return 100))
                  (use-alternative (val)
                    :report "Use alternative value."
                    (push (list :use-alternative val) step-tracker)
                    (return val))
                  (retry-computation ()
                    :report "Retry the computation."
                    (push :retry step-tracker))))))))
    (unwind-protect
         (let ((msg (librecode-runner.protocol:receive-message supervisor-mbox :timeout 2.0)))
           (is (not (null msg)))
           (is (eq (car msg) :custom-failure))
           (let* ((desc (second msg))
                  (reply-mbox (third msg)))
             (is (typep desc 'librecode-runner.protocol:failure-descriptor))
             (is (eq (librecode-runner.protocol:failure-descriptor-type desc)
                     'librecode-runner.conditions:provider-error))
             (is (equal (librecode-runner.protocol:failure-descriptor-message desc)
                        "Provider Error [provider: synthetic-provider, endpoint: /test]: LLM API request failed.
What failed: LLM model turn execution network request.
Why: Synthetic error
Where: HTTP/SSE streaming connection client boundary."))
             (is (equal (getf (librecode-runner.protocol:failure-descriptor-initargs desc) :endpoint) "/test"))
             
             ;; Send retry-computation first
             (librecode-runner.protocol:send-message reply-mbox '(retry-computation))
             
             ;; Wait for next error message
             (let ((msg2 (librecode-runner.protocol:receive-message supervisor-mbox :timeout 2.0)))
               (is (not (null msg2)))
               (let* ((desc2 (second msg2))
                      (reply-mbox2 (third msg2)))
                 ;; Now use alternative
                 (librecode-runner.protocol:send-message reply-mbox2 '(use-alternative 42))
                 (let ((result (librecode-runner.protocol:join-thread-with-timeout worker-thread 2.0)))
                   (is (equal 42 result))
                   (is (equal '(:worker-start :eval-site :retry :eval-site (:use-alternative 42)) (nreverse step-tracker))))))))
      (ignore-errors (bt:destroy-thread worker-thread)))))

(test test-failure-relay-serializes-recovery-menu
  "failure-relay must serialize the recovery-menu into the outgoing message rather
than discarding it, so a supervisor can learn what restarts are available."
  (let* ((supervisor-mbox (librecode-runner.protocol:make-mailbox :name "test-supervisor-menu"))
         (reply-mbox (librecode-runner.protocol:make-mailbox :name "test-reply-menu"))
         (menu '((retry-thing) (skip-thing)))
         (worker-thread
           (bt:make-thread
            (lambda ()
              (librecode-runner.protocol:failure-relay
               supervisor-mbox reply-mbox
               (librecode-runner.protocol:condition-to-descriptor
                (make-condition 'librecode-runner.conditions:provider-error
                                :message "boom" :endpoint "/x" :provider "p"))
               :recovery-menu menu)))))
    (unwind-protect
         (let ((msg (librecode-runner.protocol:receive-message supervisor-mbox :timeout 2.0)))
           (is (not (null msg)))
           (is (eq (car msg) :failure))
           (is (equal menu (fourth msg)))
           (librecode-runner.protocol:send-message reply-mbox '(:abort)))
      (ignore-errors (bt:destroy-thread worker-thread)))))

(test test-failure-relay-message-factory-receives-recovery-menu
  "A custom message-factory must receive the recovery-menu as an argument, so callers
can place it wherever their own wire-message shape expects it."
  (let* ((supervisor-mbox (librecode-runner.protocol:make-mailbox :name "test-supervisor-mf-menu"))
         (reply-mbox (librecode-runner.protocol:make-mailbox :name "test-reply-mf-menu"))
         (menu '((use-alternative) (retry-computation)))
         (worker-thread
           (bt:make-thread
            (lambda ()
              (librecode-runner.protocol:failure-relay
               supervisor-mbox reply-mbox
               (librecode-runner.protocol:condition-to-descriptor
                (make-condition 'librecode-runner.conditions:provider-error
                                :message "boom" :endpoint "/x" :provider "p"))
               :recovery-menu menu
               :message-factory (lambda (desc reply recovery-menu)
                                   (list :custom-failure desc reply recovery-menu)))))))
    (unwind-protect
         (let ((msg (librecode-runner.protocol:receive-message supervisor-mbox :timeout 2.0)))
           (is (not (null msg)))
           (is (eq (car msg) :custom-failure))
           (is (equal menu (fourth msg)))
           (librecode-runner.protocol:send-message reply-mbox '(:abort)))
      (ignore-errors (bt:destroy-thread worker-thread)))))

(test test-failure-descriptor-robust-fallback
  "Verify that descriptor-to-condition falls back to simple-error for unknown condition types."
  (let* ((orig (make-condition 'storage-condition))
         (desc (librecode-runner.protocol:condition-to-descriptor orig))
         (cond-obj (librecode-runner.protocol:descriptor-to-condition desc)))
    (is (typep cond-obj 'simple-error))
    (is (search "Condition of type STORAGE-CONDITION:" (princ-to-string cond-obj)))))

(test test-failure-descriptor-json-compatibility
  "Verify that failure-descriptor is properly coerced to JSON-compatible types."
  (let* ((orig (make-condition 'librecode-runner.conditions:provider-error
                               :message "API down"
                               :endpoint "/v1/chat"
                               :provider "Anthropic"))
         (desc (librecode-runner.protocol:condition-to-descriptor orig))
         (json-compatible (librecode-runner.audit::coerce-to-json-compatible desc)))
    (is (hash-table-p json-compatible))
    (is (equal "provider-error" (gethash "type" json-compatible)))
    (is (equal (librecode-runner.protocol:failure-descriptor-message desc) (gethash "message" json-compatible)))
    (is (hash-table-p (gethash "initargs" json-compatible)))
    (is (equal "API down" (gethash "message" (gethash "initargs" json-compatible))))
    (is (equal "/v1/chat" (gethash "endpoint" (gethash "initargs" json-compatible))))
    (is (equal "Anthropic" (gethash "provider" (gethash "initargs" json-compatible))))
    (let ((encoded (com.inuoe.jzon:stringify json-compatible)))
      (is (stringp encoded))
      (is (search "API down" encoded)))))

