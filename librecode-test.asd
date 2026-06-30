;;; -*- Mode: Lisp; Syntax: Common-Lisp; indent-tabs-mode: nil; coding: utf-8; Show-Trailing-Whitespace: t -*-
;;;
;;; librecode-test.asd — ASDF system definition for librecode-test
;;;

(asdf:load-asd (merge-pathnames "librecode.asd" *load-pathname*))

(asdf:defsystem #:librecode-test
  :description "Unit and property-based test suite for librecode."
  :author "nrd"
  :license "MIT"
  :depends-on (#:librecode-runner
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
     (:file "http-tests"))))
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
                                                           (uiop:find-symbol* :http-suite :librecode-test.http)))))
                           (uiop:symbol-call :fiveam :explain! results)
                           (unless (every (lambda (r)
                                            (typep r (uiop:find-symbol* :test-passed :fiveam)))
                                          results)
                             (error "Test suite failed!")))))
