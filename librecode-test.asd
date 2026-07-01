;;; -*- Mode: Lisp; Syntax: Common-Lisp; indent-tabs-mode: nil; coding: utf-8; Show-Trailing-Whitespace: t -*-
;;;
;;; librecode-test.asd — ASDF system definition for librecode-test
;;;

(asdf:defsystem #:librecode-test
  :description "Unit and property-based test suite for librecode."
  :author "nrd"
  :license "MIT"
  :depends-on (#:librecode-runner
               #:librecode-meta
               #:fiveam
               #:check-it
               #:sqlite
               #:clack
               #:hunchentoot
               #:clack-handler-hunchentoot
               #:usocket)
  :serial t
  :components
  ((:module "t"
    :components
    ((:file "event-store-tests")
     (:file "agent-tests")
     (:file "audit-tests")
     (:file "tool-tests")
     (:file "session-tests")
     (:file "http-tests")
     (:file "resilience-tests")
     (:file "campaign-tests")
     (:file "journal-tests")
     (:file "harness-tests")
     (:file "gate-tests")
     (:file "supervision-tests")
     (:file "recovery-tests")
     (:file "failure-relay-tests")
     (:file "cross-process-tests")
     (:file "provider-tests")
     (:file "builtin-tools-tests")
     (:file "child-tests")
     (:file "e2e-tests"))))
  :perform (asdf:test-op (op c)
                         (let ((results (append
                                         (uiop:symbol-call :fiveam :run
                                                           (uiop:find-symbol* :event-store-suite :librecode-test.event-store))
                                         (uiop:symbol-call :fiveam :run
                                                           (uiop:find-symbol* :agent-suite :librecode-test.agent))
                                         (uiop:symbol-call :fiveam :run
                                                           (uiop:find-symbol* :audit-suite :librecode-test.audit))
                                         (uiop:symbol-call :fiveam :run
                                                           (uiop:find-symbol* :tool-suite :librecode-test.tool))
                                         (uiop:symbol-call :fiveam :run
                                                           (uiop:find-symbol* :session-suite :librecode-test.session))
                                         (uiop:symbol-call :fiveam :run
                                                           (uiop:find-symbol* :http-suite :librecode-test.http))
                                         (uiop:symbol-call :fiveam :run
                                                           (uiop:find-symbol* :resilience-suite :librecode-test.resilience))
                                         (uiop:symbol-call :fiveam :run
                                                           (uiop:find-symbol* :campaign-suite :librecode-test.campaign))
                                         (uiop:symbol-call :fiveam :run
                                                           (uiop:find-symbol* :journal-suite :librecode-test.journal))
                                         (uiop:symbol-call :fiveam :run
                                                           (uiop:find-symbol* :harness-suite :librecode-test.harness))
                                         (uiop:symbol-call :fiveam :run
                                                           (uiop:find-symbol* :gate-suite :librecode-test.gate))
                                         (uiop:symbol-call :fiveam :run
                                                           (uiop:find-symbol* :supervision-suite :librecode-test.supervision))
                                         (uiop:symbol-call :fiveam :run
                                                           (uiop:find-symbol* :recovery-suite :librecode-test.recovery))
                                         (uiop:symbol-call :fiveam :run
                                                           (uiop:find-symbol* :failure-relay-suite :librecode-test.failure-relay))
                                         (uiop:symbol-call :fiveam :run
                                                           (uiop:find-symbol* :cross-process-suite :librecode-test.cross-process))
                                         (uiop:symbol-call :fiveam :run
                                                           (uiop:find-symbol* :provider-suite :librecode-test.provider))
                                         (uiop:symbol-call :fiveam :run
                                                           (uiop:find-symbol* :builtin-tools-suite :librecode-test.builtin-tools))
                                         (uiop:symbol-call :fiveam :run
                                                           (uiop:find-symbol* :child-suite :librecode-test.child))
                                         (uiop:symbol-call :fiveam :run
                                                           (uiop:find-symbol* :e2e-suite :librecode-test.e2e)))))
                           (uiop:symbol-call :fiveam :explain! results)
                           (unless (every (lambda (r)
                                            (typep r (uiop:find-symbol* :test-passed :fiveam)))
                                          results)
                             (error "Test suite failed!")))))
