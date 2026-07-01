;;; -*- Mode: Lisp; Syntax: Common-Lisp; indent-tabs-mode: nil; coding: utf-8; Show-Trailing-Whitespace: t -*-
;;;
;;; gate-tests.lisp — Unit tests for validation gates DSL
;;;

(defpackage #:librecode-test.gate
  (:use #:cl #:fiveam)
  (:export #:gate-suite))
(in-package #:librecode-test.gate)

(def-suite gate-suite :description "Test validation gates DSL")
(in-suite gate-suite)

(test dummy-gate-test
  (is-true t))
