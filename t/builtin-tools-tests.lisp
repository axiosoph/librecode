;;; -*- Mode: Lisp; Syntax: Common-Lisp; indent-tabs-mode: nil; coding: utf-8; Show-Trailing-Whitespace: t -*-
;;;
;;; builtin-tools-tests.lisp — Unit tests for built-in tools
;;;

(defpackage #:librecode-test.builtin-tools
  (:use #:cl
        #:fiveam
        #:librecode-runner.builtin-tools)
  (:export #:builtin-tools-suite))

(in-package #:librecode-test.builtin-tools)

(def-suite builtin-tools-suite
  :description "Suite for built-in tools tests.")

(in-suite builtin-tools-suite)

(test stub-test
  "A placeholder compiling test."
  (is-true t))
