;;; -*- Mode: Lisp; Syntax: Common-Lisp; indent-tabs-mode: nil; coding: utf-8; Show-Trailing-Whitespace: t -*-
;;;
;;; e2e-tests.lisp — End-to-end integration tests
;;;

(defpackage #:librecode-test.e2e
  (:use #:cl
        #:fiveam)
  (:export #:e2e-suite))

(in-package #:librecode-test.e2e)

(def-suite e2e-suite
  :description "Suite for end-to-end integration tests.")

(in-suite e2e-suite)

(test stub-test
  "A placeholder compiling test."
  (is-true t))
