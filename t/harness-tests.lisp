;;; -*- Mode: Lisp; Syntax: Common-Lisp; indent-tabs-mode: nil; coding: utf-8; Show-Trailing-Whitespace: t -*-
;;;
;;; harness-tests.lisp — Unit tests for child harness interfaces
;;;

(defpackage #:librecode-test.harness
  (:use #:cl #:fiveam)
  (:export #:harness-suite))
(in-package #:librecode-test.harness)

(def-suite harness-suite :description "Test child harness management")
(in-suite harness-suite)

(test dummy-harness-test
  (is-true t))
