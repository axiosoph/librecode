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
                         :message-factory (lambda (desc reply-mbox)
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
