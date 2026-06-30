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
               #:sqlite)
  :serial t
  :components
  ((:module "t"
    :components
    ((:file "event-store-tests")
     (:file "agent-tests"))))
  :perform (asdf:test-op (op c)
                         (let ((results (append
                                         (uiop:symbol-call :fiveam :run
                                                           (uiop:find-symbol* :event-store-suite :librecode-test.event-store))
                                         (uiop:symbol-call :fiveam :run
                                                           (uiop:find-symbol* :agent-suite :librecode-test.agent)))))
                           (uiop:symbol-call :fiveam :explain! results)
                           (unless (every (lambda (r)
                                            (typep r (uiop:find-symbol* :test-passed :fiveam)))
                                          results)
                             (error "Test suite failed!")))))
