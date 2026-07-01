;;; -*- Mode: Lisp; Syntax: Common-Lisp; indent-tabs-mode: nil; coding: utf-8; Show-Trailing-Whitespace: t -*-
;;;
;;; provider-tests.lisp — Unit tests for LLM provider interface and SSE parsing
;;;

(defpackage #:librecode-test.provider
  (:use #:cl
        #:fiveam
        #:librecode-runner.provider)
  (:export #:provider-suite))

(in-package #:librecode-test.provider)

(def-suite provider-suite
  :description "Suite for LLM provider tests.")

(in-suite provider-suite)

(test stub-test
  "A placeholder compiling test."
  (is-true t))
