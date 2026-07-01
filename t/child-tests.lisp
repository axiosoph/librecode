;;; -*- Mode: Lisp; Syntax: Common-Lisp; indent-tabs-mode: nil; coding: utf-8; Show-Trailing-Whitespace: t -*-
;;;
;;; child-tests.lisp — Unit tests for child harness
;;;

(defpackage #:librecode-test.child
  (:use #:cl
        #:fiveam
        #:librecode-runner.child)
  (:export #:child-suite))

(in-package #:librecode-test.child)

(def-suite child-suite
  :description "Suite for child harness tests.")

(in-suite child-suite)

(test stub-test
  "A placeholder compiling test."
  (is-true t))
