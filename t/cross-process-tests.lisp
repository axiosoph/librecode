;;; -*- Mode: Lisp; Syntax: Common-Lisp; indent-tabs-mode: nil; coding: utf-8; Show-Trailing-Whitespace: t -*-
;;;
;;; cross-process-tests.lisp — Unit tests for cross-process metaharness control
;;;

(defpackage #:librecode-test.cross-process
  (:use #:cl #:fiveam)
  (:export #:cross-process-suite))
(in-package #:librecode-test.cross-process)

(def-suite cross-process-suite :description "Test cross process metaharness control")
(in-suite cross-process-suite)

(test dummy-cross-process-test
  (is-true t))
