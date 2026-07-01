;;; -*- Mode: Lisp; Syntax: Common-Lisp; indent-tabs-mode: nil; coding: utf-8; Show-Trailing-Whitespace: t -*-
;;;
;;; recovery-tests.lisp — Unit tests for recovery / condition restart strategies
;;;

(defpackage #:librecode-test.recovery
  (:use #:cl #:fiveam)
  (:export #:recovery-suite))
(in-package #:librecode-test.recovery)

(def-suite recovery-suite :description "Test condition restart and harness recovery")
(in-suite recovery-suite)

(test dummy-recovery-test
  (is-true t))
